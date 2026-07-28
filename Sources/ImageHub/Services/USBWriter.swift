import Foundation

/// Turns (template + ISO + USB drive) into bootable Windows install media.
///
/// The media it produces is a stock Windows Setup USB with three additions:
/// `autounattend.xml` at the root, an `ImageHub\` payload folder, and — when the
/// image demands it — a split `install*.swm` instead of `install.wim`.
@MainActor
enum USBWriter {

    struct WriteError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Files Windows Setup will not boot without.
    private static let requiredBootFiles = [
        "bootmgr",
        "boot/bcd",
        "sources/boot.wim"
    ]

    static func build(
        template: DeploymentTemplate,
        image: WindowsImage,
        drive: USBDrive,
        job: BuildJob
    ) async {
        job.phase = .running
        job.startedAt = Date()

        let log: @Sendable (String) -> Void = { line in
            Task { @MainActor in job.append(line) }
        }

        var mounted: DiskService.MountedImage?

        do {
            // 1 — Validate ------------------------------------------------------
            job.begin(.validate)
            let errors = template.validationErrors
            guard errors.isEmpty else {
                throw WriteError(message: errors.joined(separator: " "))
            }
            guard image.fileExists else {
                throw WriteError(message: "The ISO for this image is missing: \(image.path)")
            }
            guard drive.hasRoom(forISOSize: image.sizeBytes) else {
                throw WriteError(
                    message: """
                        \(drive.displayName) holds \(drive.sizeBytes.byteSize) but this image needs \
                        about \((image.sizeBytes + 512_000_000).byteSize) including the payload.
                        """
                )
            }
            job.append("Template “\(template.name)” → \(drive.displayName) (\(drive.deviceNode))")
            for warning in template.validationWarnings {
                job.append("⚠︎ \(warning)")
            }
            job.finish(.validate)
            try checkCancelled(job)

            // 2 — Image is already local at this point; record what we're using.
            job.begin(.acquireImage, "Using \(image.displayName)")
            job.append("ISO: \(image.path) (\(image.sizeBytes.byteSize))")
            job.finish(.acquireImage)

            // 3 — Erase ---------------------------------------------------------
            job.begin(.erase, "Wiping \(drive.displayName)")
            let label = UserDefaults.standard.string(forKey: "defaultVolumeLabel") ?? "IMAGEHUB"
            try await DiskService.eraseToFAT32(
                drive: drive,
                label: label,
                scheme: template.disk.partitionStyle,
                log: log
            )
            let volume = try await DiskService.waitForVolume(onDisk: drive.id)
            job.append("New volume mounted at \(volume.path)")
            job.finish(.erase)
            try checkCancelled(job)

            // 4 — Copy everything except the install image -----------------------
            let attached = try await DiskService.attachISO(at: image.url, log: log)
            mounted = attached
            job.begin(.copyBootFiles, "Copying Windows Setup files")
            try await copyBootFiles(from: attached.mountPoint, to: volume, job: job, log: log)
            job.finish(.copyBootFiles)
            try checkCancelled(job)

            // 5 — install.wim, split if it can't fit on FAT32 ---------------------
            job.begin(.installImage)
            try await writeInstallImage(
                template: template,
                isoMount: attached.mountPoint,
                volume: volume,
                job: job,
                log: log
            )
            job.finish(.installImage)
            try checkCancelled(job)

            // 6 — Answer file ----------------------------------------------------
            job.begin(.answerFile)
            let secrets = AnswerFileBuilder.ResolvedSecrets.load(for: template)
            let xml = AnswerFileBuilder(template: template, secrets: secrets).build()
            try Data(xml.utf8).write(to: volume.appendingPathComponent("autounattend.xml"))
            // A copy under sources/ is what Setup looks for when booting from
            // some firmware; harmless duplication, one less way to fail.
            try? Data(xml.utf8).write(
                to: volume.appendingPathComponent("sources/autounattend.xml")
            )
            job.append("Wrote autounattend.xml (\(xml.count) bytes)")
            job.finish(.answerFile)

            // 7 — Payload --------------------------------------------------------
            job.begin(.payload)
            let payload = try PayloadBuilder.write(
                template: template,
                secrets: secrets,
                to: volume,
                log: log
            )
            job.append("Payload: \(payload.lastPathComponent)/")
            job.finish(.payload)

            // 8 — Verify ---------------------------------------------------------
            job.begin(.verify)
            try verifyMedia(at: volume, job: job)
            job.finish(.verify)

            await DiskService.detach(attached)
            mounted = nil

            if UserDefaults.standard.bool(forKey: "ejectAfterBuild") {
                job.append("Ejecting \(drive.id)…")
                await DiskService.eject(drive.id)
            }

            job.succeed()
            Notifier.buildFinished(template: template.name, drive: drive.displayName, success: true)
            ToastCenter.shared.show(
                "USB ready",
                detail: "\(template.name) → \(drive.displayName)"
            )
        } catch is CancellationRequested {
            if let mounted { await DiskService.detach(mounted) }
            job.markCancelled()
            ToastCenter.shared.show("Build cancelled", detail: drive.displayName, style: .info)
        } catch {
            if let mounted { await DiskService.detach(mounted) }
            job.fail(job.currentStage, error.localizedDescription)
            Notifier.buildFinished(template: template.name, drive: drive.displayName, success: false)
            ToastCenter.shared.show(
                "Build failed",
                detail: error.localizedDescription,
                style: .error
            )
        }
    }

    // MARK: - Steps

    private static func copyBootFiles(
        from mount: URL,
        to volume: URL,
        job: BuildJob,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        // install.wim/.esd are handled separately — they may need splitting.
        let excluded: Set<String> = ["sources/install.wim", "sources/install.esd"]

        let plan = try await Task.detached(priority: .userInitiated) {
            try FileCopier.plan(directory: mount, excluding: excluded)
        }.value

        log("Copying \(plan.fileCount) files (\(plan.totalBytes.byteSize))…")

        try await Task.detached(priority: .userInitiated) {
            try FileCopier.copy(
                plan: plan,
                to: volume,
                progress: { fraction, _ in
                    Task { @MainActor in
                        job.stageProgress = fraction
                        job.detail = "Copying Windows Setup files — \(Int(fraction * 100))%"
                    }
                },
                isCancelled: { MainActor.assumeIsolated { job.cancelRequested } }
            )
        }.value

        job.stageProgress = 1
    }

    private static func writeInstallImage(
        template: DeploymentTemplate,
        isoMount: URL,
        volume: URL,
        job: BuildJob,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        let fm = FileManager.default
        let destinationSources = volume.appendingPathComponent("sources", isDirectory: true)
        if !fm.fileExists(atPath: destinationSources.path) {
            try fm.createDirectory(at: destinationSources, withIntermediateDirectories: true)
        }

        // A template can override the install image with its own captured WIM.
        let source: URL
        if template.windows.imageSource == .customWim && !template.windows.customWimPath.isEmpty {
            source = URL(fileURLWithPath: template.windows.customWimPath)
            guard fm.fileExists(atPath: source.path) else {
                throw WriteError(
                    message: "The captured image this template points at is missing: \(source.path)"
                )
            }
            job.append("Using captured image \(source.lastPathComponent) instead of the one in the ISO.")
        } else if fm.fileExists(atPath: isoMount.appendingPathComponent("sources/install.wim").path) {
            source = isoMount.appendingPathComponent("sources/install.wim")
        } else if fm.fileExists(atPath: isoMount.appendingPathComponent("sources/install.esd").path) {
            source = isoMount.appendingPathComponent("sources/install.esd")
        } else {
            throw WriteError(
                message: "This ISO has no sources/install.wim or install.esd — it may not be Windows install media."
            )
        }

        let size = fileSize(of: source)
        job.append("\(source.lastPathComponent) is \(size.byteSize)")

        if size < WindowsImage.fat32FileLimit {
            job.detail = "Copying \(source.lastPathComponent)"
            let destination = destinationSources
                .appendingPathComponent(source.lastPathComponent)
            try await copyLargeFile(from: source, to: destination, job: job, log: log)
            return
        }

        // Too big for FAT32 — split into install.swm + install2.swm + …
        guard WimTools.isAvailable else {
            throw WriteError(message: WimTools.missingToolMessage)
        }
        job.detail = "Splitting \(source.lastPathComponent) for FAT32"
        let firstPart = destinationSources.appendingPathComponent("install.swm")
        try await WimTools.split(source: source, firstPart: firstPart, log: log)

        let parts = (try? fm.contentsOfDirectory(atPath: destinationSources.path))?
            .filter { $0.lowercased().hasSuffix(".swm") }
            .sorted() ?? []
        guard !parts.isEmpty else {
            throw WriteError(message: "wimlib reported success but no .swm parts were written.")
        }
        job.append("Wrote \(parts.count) split part\(parts.count == 1 ? "" : "s"): \(parts.joined(separator: ", "))")
    }

    private static func copyLargeFile(
        from source: URL,
        to destination: URL,
        job: BuildJob,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        let name = source.lastPathComponent
        try await Task.detached(priority: .userInitiated) {
            try FileCopier.copyFile(
                from: source,
                to: destination,
                progress: { fraction in
                    Task { @MainActor in
                        job.stageProgress = fraction
                        job.detail = "Writing \(name) — \(Int(fraction * 100))%"
                    }
                },
                isCancelled: { MainActor.assumeIsolated { job.cancelRequested } }
            )
        }.value
        job.stageProgress = 1
    }

    private static func verifyMedia(at volume: URL, job: BuildJob) throws {
        let fm = FileManager.default
        var missing: [String] = []

        for relative in requiredBootFiles {
            // The ISO's casing varies (BOOTMGR vs bootmgr); FAT32 is
            // case-insensitive, so a plain existence check is enough.
            if !fm.fileExists(atPath: volume.appendingPathComponent(relative).path) {
                missing.append(relative)
            }
        }

        let sources = volume.appendingPathComponent("sources")
        let hasInstall = ["install.wim", "install.esd", "install.swm"].contains {
            fm.fileExists(atPath: sources.appendingPathComponent($0).path)
        }
        if !hasInstall { missing.append("sources/install.wim (or .swm)") }

        if !fm.fileExists(atPath: volume.appendingPathComponent("autounattend.xml").path) {
            missing.append("autounattend.xml")
        }
        if !fm.fileExists(
            atPath: volume.appendingPathComponent("\(PayloadBuilder.folderName)/Provision.ps1").path
        ) {
            missing.append("ImageHub/Provision.ps1")
        }

        // EFI boot loader — warn rather than fail, since MBR/BIOS-only media
        // legitimately lacks it.
        let efi = volume.appendingPathComponent("efi/boot/bootx64.efi")
        if !fm.fileExists(atPath: efi.path) {
            job.append("⚠︎ No efi/boot/bootx64.efi — this media will only boot in legacy BIOS mode.")
        }

        guard missing.isEmpty else {
            throw WriteError(
                message: "The finished drive is missing: \(missing.joined(separator: ", "))"
            )
        }
        job.append("Verified boot files, install image, answer file, and payload.")
    }

    // MARK: - Helpers

    private static func checkCancelled(_ job: BuildJob) throws {
        if job.cancelRequested { throw CancellationRequested() }
    }

    private static func fileSize(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
