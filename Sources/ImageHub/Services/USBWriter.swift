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
        let fm = FileManager.default

        let log: @Sendable (String) -> Void = { line in
            // Stamped here, not after the hop, so the log stays in the order
            // things actually happened.
            let at = Date()
            Task { @MainActor in job.append(line, at: at) }
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
            // Driver packs are checked here, before the drive is erased. A pack
            // pointed at the wrong folder cost a whole build: it was aimed at a
            // directory holding the 8.47 GB Windows ISO, so the log read "8 files,
            // 8.58 GB, 0 INFs" and then the copy died on FAT32's 4 GB per-file
            // limit with "The file couldn't be saved." Two minutes of copying and
            // a wiped drive for a mistake visible in advance.
            for pack in template.system.driverPacks where pack.enabled && !pack.path.isEmpty {
                let origin = URL(fileURLWithPath: pack.path, isDirectory: true)
                guard fm.fileExists(atPath: origin.path) else { continue }
                let plan = try FileCopier.plan(directory: origin)
                let infs = plan.items.filter { $0.relativePath.lowercased().hasSuffix(".inf") }.count
                if let tooBig = plan.items.first(where: { $0.size >= WindowsImage.fat32FileLimit }) {
                    throw WriteError(
                        message: """
                            Driver pack “\(pack.displayName)” contains \
                            \((tooBig.relativePath as NSString).lastPathComponent) at \
                            \(tooBig.size.byteSize), which is over FAT32's 4 GB per-file limit and \
                            cannot go on Windows install media. This folder holds \
                            \(plan.fileCount) file\(plan.fileCount == 1 ? "" : "s") and \(infs) \
                            INF\(infs == 1 ? "" : "s") — it looks like the wrong folder. Point it at \
                            the *extracted* driver files.
                            """
                    )
                }
                if infs == 0 {
                    throw WriteError(
                        message: """
                            Driver pack “\(pack.displayName)” has no .inf files in \
                            \(pack.path) — \(plan.fileCount) file\(plan.fileCount == 1 ? "" : "s"), \
                            \(plan.totalBytes.byteSize). Drivers are installed from .inf files, so \
                            there is nothing here to install. Vendor packs are often a self-extracting \
                            archive: run it, or expand it, and point this at the folder that contains \
                            the .inf files. Disable the pack to build without it.
                            """
                    )
                }
                job.append("Driver pack “\(pack.displayName)”: \(infs) INF\(infs == 1 ? "" : "s"), \(plan.totalBytes.byteSize) [\(pack.scopeSummary)]")
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
            // The media is always MBR, regardless of the template's partition
            // style — that setting describes the *target* disk's layout, not the
            // stick's. GPTFormat makes macOS add an EFI System Partition to the
            // media, and Windows Setup then has two System partitions to choose
            // between, picks the removable one, and fails to service boot files
            // ("BFSVC: Failed to get system partition", 0x80073B92). MBR media
            // has no ESP and still boots UEFI, since firmware only needs FAT.
            try await DiskService.eraseToFAT32(
                drive: drive,
                label: label,
                scheme: .mbr,
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
            // Small files are no longer fsync'd individually — that cost 20
            // minutes on a real build — so flush the lot once before checking
            // the drive, rather than verifying what is still only in the cache.
            try? await Shell.check("/bin/sync", [])
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

        let token = job.cancelToken
        let bytes = plan.totalBytes
        let started = Date()
        try await Task.detached(priority: .userInitiated) {
            try FileCopier.copy(
                plan: plan,
                to: volume,
                progress: { fraction, _ in
                    Task { @MainActor in
                        job.stageProgress = fraction
                        job.detail = "Copying Windows Setup files — \(Int(fraction * 100))%"
                            + rate(bytes: Double(bytes) * fraction, since: started)
                    }
                },
                isCancelled: { token.isCancelled }
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
        if template.windows.usesCapturedImage {
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
        let splitStarted = Date()
        try await WimTools.split(
            source: source,
            firstPart: firstPart,
            log: log,
            progress: { fraction in
                Task { @MainActor in
                    job.stageProgress = fraction
                    job.detail = "Splitting \(source.lastPathComponent) for FAT32 — "
                        + "\(Int(fraction * 100))%"
                        + rate(bytes: Double(size) * fraction, since: splitStarted)
                }
            }
        )

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
        let token = job.cancelToken
        let bytes = fileSize(of: source)
        let started = Date()
        try await Task.detached(priority: .userInitiated) {
            try FileCopier.copyFile(
                from: source,
                to: destination,
                progress: { fraction in
                    Task { @MainActor in
                        job.stageProgress = fraction
                        job.detail = "Writing \(name) — \(Int(fraction * 100))%"
                            + rate(bytes: Double(bytes) * fraction, since: started)
                    }
                },
                isCancelled: { token.isCancelled }
            )
        }.value
        job.stageProgress = 1
        job.append(
            "Wrote \(name) (\(bytes.byteSize)) in "
                + BuildJob.shortDuration(Date().timeIntervalSince(started))
                + rate(bytes: Double(bytes), since: started)
        )
    }

    /// " — 4.2 MB/s", or "" until there's enough elapsed to mean anything.
    ///
    /// USB sticks vary by more than an order of magnitude, and the difference
    /// between "this drive is slow" and "something is wrong" is a number.
    private static func rate(bytes: Double, since started: Date) -> String {
        let seconds = Date().timeIntervalSince(started)
        guard seconds > 2, bytes > 0 else { return "" }
        return String(format: " — %.1f MB/s", bytes / seconds / 1_000_000)
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

        // AppleDouble sidecars break Setup's OS-analysis service, so sweep any
        // that reached the volume by another route (Finder, Spotlight, a copy
        // that didn't go through FileCopier) rather than trusting the skip list.
        var sidecars = 0
        if let walker = fm.enumerator(atPath: volume.path) {
            for case let path as String in walker
            where (path as NSString).lastPathComponent.hasPrefix("._") {
                try? fm.removeItem(at: volume.appendingPathComponent(path))
                sidecars += 1
            }
        }
        if sidecars > 0 {
            job.append("Removed \(sidecars) macOS “._” sidecar file\(sidecars == 1 ? "" : "s") — Windows Setup can't parse them.")
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
