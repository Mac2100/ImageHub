import Combine
import Foundation

/// The local ISO library: what's on this Mac, where it came from, and whether it
/// is still intact. Downloaded ISOs are copied into
/// `~/Library/Application Support/ImageHub/Images/`; imported ones can be linked
/// in place so a 6 GB file on a NAS isn't duplicated.
@MainActor
final class ImageLibrary: ObservableObject {
    @Published private(set) var images: [WindowsImage] = []
    @Published var isBusy = false
    @Published var busyMessage = ""
    @Published var hashProgress: Double?

    let downloader = Downloader()

    private var cancellables = Set<AnyCancellable>()

    init() {
        load()
        // `downloader` is a nested ObservableObject, so its changes have to be
        // republished by hand or views watching the library never redraw.
        downloader.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Persistence

    func load() {
        guard let data = try? Data(contentsOf: AppPaths.imageIndex) else {
            images = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        images = (try? decoder.decode([WindowsImage].self, from: data)) ?? []
        images.sort { $0.addedAt > $1.addedAt }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(images).write(to: AppPaths.imageIndex, options: .atomic)
    }

    func image(id: UUID?) -> WindowsImage? {
        guard let id else { return nil }
        return images.first { $0.id == id }
    }

    /// Newest usable image matching a template's release/edition wishes.
    func bestMatch(for template: DeploymentTemplate) -> WindowsImage? {
        if template.windows.imageSource == .libraryImage,
           let pinned = image(id: template.windows.libraryImageID), pinned.fileExists {
            return pinned
        }
        return images
            .filter { $0.fileExists && $0.release == template.windows.release }
            .sorted { $0.addedAt > $1.addedAt }
            .first
    }

    // MARK: - Import

    /// Adds an ISO already on disk. `copyIntoLibrary == false` links it in place.
    @discardableResult
    func importISO(at url: URL, copyIntoLibrary: Bool) async -> WindowsImage? {
        isBusy = true
        busyMessage = "Adding \(url.lastPathComponent)…"
        defer {
            isBusy = false
            busyMessage = ""
            hashProgress = nil
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            ToastCenter.shared.show("Not found", detail: url.path, style: .error)
            return nil
        }

        var image = WindowsImage()
        image.origin = .imported
        image.sourceURL = url.path
        image.managed = copyIntoLibrary

        var finalURL = url
        if copyIntoLibrary {
            do {
                try fm.createDirectory(at: AppPaths.images, withIntermediateDirectories: true)
                finalURL = AppPaths.images
                    .appendingPathComponent("\(image.id.uuidString)-\(url.lastPathComponent)")
                busyMessage = "Copying \(url.lastPathComponent) into the library…"
                try fm.copyItem(at: url, to: finalURL)
            } catch {
                ToastCenter.shared.show(
                    "Couldn't copy the ISO",
                    detail: error.localizedDescription,
                    style: .error
                )
                return nil
            }
        }

        image.path = finalURL.path
        image.sizeBytes = Self.fileSize(finalURL)
        image.name = url.deletingPathExtension().lastPathComponent
        image.buildLabel = MicrosoftISOService.buildLabel(from: url.lastPathComponent)
        if url.lastPathComponent.lowercased().contains("win10") {
            image.release = .win10
        }

        await inspect(&image)
        images.insert(image, at: 0)
        persist()
        ToastCenter.shared.show("Image added", detail: image.displayName)
        return image
    }

    /// Downloads the newest ISO Microsoft is publishing for a release.
    @discardableResult
    func downloadLatest(
        release: WindowsRelease,
        language: String,
        log: (@Sendable (String) -> Void)? = nil
    ) async -> WindowsImage? {
        isBusy = true
        busyMessage = "Asking Microsoft for the latest \(release.label) ISO…"
        defer {
            isBusy = false
            busyMessage = ""
            hashProgress = nil
        }

        do {
            let offer = try await MicrosoftISOService.findDownload(
                release: release, language: language, log: log
            )
            return await download(offer)
        } catch {
            ToastCenter.shared.show(
                "Couldn't reach Microsoft's download service",
                detail: error.localizedDescription,
                style: .error
            )
            log?(error.localizedDescription)
            return nil
        }
    }

    /// Downloads a resolved offer into the library.
    @discardableResult
    func download(_ offer: AvailableDownload) async -> WindowsImage? {
        var image = WindowsImage()
        image.origin = .microsoft
        image.release = offer.release
        image.buildLabel = offer.buildLabel
        image.language = offer.language
        image.architecture = offer.architecture
        image.sourceURL = offer.downloadURL.absoluteString
        image.name = offer.title.replacingOccurrences(of: ".iso", with: "")
        image.managed = true

        let destination = AppPaths.images
            .appendingPathComponent("\(image.id.uuidString)-\(offer.downloadURL.lastPathComponent)")

        busyMessage = "Downloading \(offer.title)…"
        do {
            try await downloader.download(from: offer.downloadURL, to: destination)
        } catch {
            ToastCenter.shared.show(
                "Download failed",
                detail: error.localizedDescription,
                style: .error
            )
            return nil
        }

        image.path = destination.path
        image.sizeBytes = Self.fileSize(destination)
        await inspect(&image)
        images.insert(image, at: 0)
        persist()

        Notifier.downloadFinished(image.displayName)
        ToastCenter.shared.show("Image downloaded", detail: image.displayName)
        return image
    }

    /// Adds an ISO from an internal HTTPS URL, optionally checking it against a
    /// known SHA-256 so everyone on the team builds from the same bytes.
    @discardableResult
    func downloadFromURL(
        _ url: URL,
        expectedSHA256: String,
        release: WindowsRelease
    ) async -> WindowsImage? {
        isBusy = true
        busyMessage = "Downloading \(url.lastPathComponent)…"
        defer {
            isBusy = false
            busyMessage = ""
            hashProgress = nil
        }

        var image = WindowsImage()
        image.origin = .remoteURL
        image.release = release
        image.sourceURL = url.absoluteString
        image.name = url.deletingPathExtension().lastPathComponent
        image.buildLabel = MicrosoftISOService.buildLabel(from: url.lastPathComponent)
        image.managed = true

        let destination = AppPaths.images
            .appendingPathComponent("\(image.id.uuidString)-\(url.lastPathComponent)")
        do {
            try await downloader.download(from: url, to: destination)
        } catch {
            ToastCenter.shared.show("Download failed", detail: error.localizedDescription, style: .error)
            return nil
        }

        image.path = destination.path
        image.sizeBytes = Self.fileSize(destination)

        if !expectedSHA256.isEmpty {
            busyMessage = "Verifying checksum…"
            let actual = await computeHash(destination)
            guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                try? FileManager.default.removeItem(at: destination)
                ToastCenter.shared.show(
                    "Checksum mismatch",
                    detail: "The download didn't match the expected SHA-256 and was discarded.",
                    style: .error
                )
                return nil
            }
            image.sha256 = actual
            image.lastVerifiedAt = Date()
        }

        await inspect(&image)
        images.insert(image, at: 0)
        persist()
        ToastCenter.shared.show("Image added", detail: image.displayName)
        return image
    }

    // MARK: - Inspection & verification

    /// Mounts the ISO once to read its edition list out of `install.wim`.
    private func inspect(_ image: inout WindowsImage) async {
        busyMessage = "Reading editions from \(image.url.lastPathComponent)…"
        guard let mounted = try? await DiskService.attachISO(at: image.url, log: { _ in }) else {
            return
        }
        defer { Task { await DiskService.detach(mounted) } }

        let sources = mounted.mountPoint.appendingPathComponent("sources", isDirectory: true)
        let candidates = ["install.wim", "install.esd"]
        for candidate in candidates {
            let file = sources.appendingPathComponent(candidate)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            image.installImageName = candidate
            image.installImageSizeBytes = Self.fileSize(file)
            if let editions = try? WimReader.editions(at: file) {
                image.editions = editions
            }
            break
        }

        if image.editions.contains(where: { $0.name.contains("Windows 10") }) {
            image.release = .win10
        }
    }

    /// Re-reads the edition list for an image already in the library.
    func reinspect(_ image: WindowsImage) async {
        isBusy = true
        defer {
            isBusy = false
            busyMessage = ""
        }
        var copy = image
        await inspect(&copy)
        update(copy)
    }

    /// Hashes an image and stores the result so future builds can verify it.
    func verify(_ image: WindowsImage) async {
        guard image.fileExists else {
            ToastCenter.shared.show("File missing", detail: image.path, style: .error)
            return
        }
        isBusy = true
        busyMessage = "Hashing \(image.url.lastPathComponent)…"
        defer {
            isBusy = false
            busyMessage = ""
            hashProgress = nil
        }

        let actual = await computeHash(image.url)
        var copy = image
        if copy.sha256.isEmpty {
            copy.sha256 = actual
            copy.lastVerifiedAt = Date()
            update(copy)
            ToastCenter.shared.show("Checksum recorded", detail: String(actual.prefix(16)) + "…")
        } else if copy.sha256.caseInsensitiveCompare(actual) == .orderedSame {
            copy.lastVerifiedAt = Date()
            update(copy)
            ToastCenter.shared.show("Image verified", detail: image.displayName)
        } else {
            ToastCenter.shared.show(
                "Checksum mismatch",
                detail: "\(image.displayName) no longer matches the recorded SHA-256.",
                style: .error
            )
        }
    }

    private func computeHash(_ url: URL) async -> String {
        hashProgress = 0
        let result = await Task.detached(priority: .userInitiated) { [weak self] in
            (try? Downloader.sha256(of: url) { fraction in
                Task { @MainActor [weak self] in self?.hashProgress = fraction }
            }) ?? ""
        }.value
        hashProgress = nil
        return result
    }

    // MARK: - Mutation

    func update(_ image: WindowsImage) {
        if let index = images.firstIndex(where: { $0.id == image.id }) {
            images[index] = image
        }
        persist()
    }

    func rename(_ image: WindowsImage, to name: String) {
        var copy = image
        copy.name = name
        update(copy)
    }

    /// Removes the record; deletes the file too when ImageHub owns it.
    func remove(_ image: WindowsImage, deleteFile: Bool) {
        if deleteFile && image.managed && image.fileExists {
            try? FileManager.default.removeItem(at: image.url)
        }
        images.removeAll { $0.id == image.id }
        persist()
    }

    var totalBytesOnDisk: Int64 {
        images.filter { $0.managed && $0.fileExists }.reduce(0) { $0 + $1.sizeBytes }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
