import Foundation

/// Everything that touches physical disks. `diskutil` is the only tool used, so
/// the destructive footprint is one function (`eraseDisk`) that refuses to run
/// on anything internal.
enum DiskService {
    static let diskutil = "/usr/sbin/diskutil"
    static let hdiutil = "/usr/bin/hdiutil"

    struct DiskError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Enumeration

    /// Returns eligible USB targets plus the drives that were filtered out and
    /// why — the UI shows both so a plugged-in stick never just "disappears".
    static func scan() async -> (eligible: [USBDrive], rejected: [RejectedDrive]) {
        guard let plist = await plistOutput(["list", "-plist"]),
              let entries = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return ([], [])
        }

        var eligible: [USBDrive] = []
        var rejected: [RejectedDrive] = []

        for entry in entries {
            guard let identifier = entry["DeviceIdentifier"] as? String else { continue }
            guard let drive = await describe(identifier, partitions: entry) else { continue }

            if drive.isEligibleTarget {
                eligible.append(drive)
            } else {
                rejected.append(
                    RejectedDrive(
                        id: drive.id,
                        displayName: drive.displayName,
                        reason: drive.isInternal
                            ? "Internal disk — ImageHub never writes to internal storage."
                            : "Not removable or ejectable media."
                    )
                )
            }
        }

        eligible.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        rejected.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        return (eligible, rejected)
    }

    private static func describe(_ identifier: String, partitions entry: [String: Any]) async -> USBDrive? {
        guard let info = await plistOutput(["info", "-plist", identifier]) else { return nil }

        var volumeNames: [String] = []
        var mountPoints: [String] = []
        for partition in (entry["Partitions"] as? [[String: Any]]) ?? [] {
            if let name = partition["VolumeName"] as? String, !name.isEmpty {
                volumeNames.append(name)
            }
            if let mount = partition["MountPoint"] as? String, !mount.isEmpty {
                mountPoints.append(mount)
            }
        }
        for volume in (entry["APFSVolumes"] as? [[String: Any]]) ?? [] {
            if let name = volume["VolumeName"] as? String, !name.isEmpty {
                volumeNames.append(name)
            }
        }

        return USBDrive(
            id: identifier,
            deviceNode: (info["DeviceNode"] as? String) ?? "/dev/\(identifier)",
            mediaName: (info["MediaName"] as? String) ?? (info["IORegistryEntryName"] as? String) ?? identifier,
            sizeBytes: int64(info["TotalSize"]) ?? int64(entry["Size"]) ?? 0,
            isInternal: (info["Internal"] as? Bool) ?? true,
            isRemovable: (info["RemovableMedia"] as? Bool)
                ?? (info["RemovableMediaOrExternalDevice"] as? Bool) ?? false,
            isEjectable: (info["Ejectable"] as? Bool) ?? false,
            busProtocol: (info["BusProtocol"] as? String) ?? "",
            volumeNames: volumeNames,
            mountPoints: mountPoints,
            isWholeDisk: (info["WholeDisk"] as? Bool) ?? true
        )
    }

    /// Re-reads one drive so the UI can refresh after an erase.
    static func reload(_ identifier: String) async -> USBDrive? {
        guard let plist = await plistOutput(["list", "-plist", identifier]),
              let entries = plist["AllDisksAndPartitions"] as? [[String: Any]],
              let entry = entries.first(where: { ($0["DeviceIdentifier"] as? String) == identifier })
        else { return nil }
        return await describe(identifier, partitions: entry)
    }

    // MARK: - Destructive operations

    /// Wipes a drive and lays down a single FAT32 volume.
    ///
    /// FAT32 is not a preference — UEFI firmware is only required to read FAT,
    /// so it is the one filesystem a Windows Setup USB can reliably boot from.
    /// The 4 GB per-file ceiling that comes with it is why `install.wim` gets
    /// split (see `WimTools`).
    static func eraseToFAT32(
        drive: USBDrive,
        label: String,
        scheme: DiskSpec.PartitionStyle,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        // Re-verify immediately before writing rather than trusting the model
        // the UI was holding: the operator may have unplugged and replugged.
        guard let fresh = await reload(drive.id) else {
            throw DiskError(message: "\(drive.id) is no longer attached.")
        }
        guard fresh.isEligibleTarget else {
            throw DiskError(message: "\(fresh.displayName) is not removable external media — refusing to erase it.")
        }
        guard !fresh.isInternal else {
            throw DiskError(message: "\(fresh.displayName) is an internal disk — refusing to erase it.")
        }

        let volumeLabel = sanitizeFAT32Label(label)
        // `MBRFormat` is the most widely bootable layout for Windows Setup media;
        // GPT is offered for firmware that insists on it.
        let schemeArgument = scheme == .mbr ? "MBRFormat" : "GPTFormat"

        log("Unmounting \(fresh.deviceNode)…")
        _ = try? await Shell.run(diskutil, ["unmountDisk", "force", fresh.deviceNode])

        log("Erasing \(fresh.displayName) as FAT32 “\(volumeLabel)” (\(schemeArgument))…")
        try await Shell.check(
            diskutil,
            ["eraseDisk", "MS-DOS FAT32", volumeLabel, schemeArgument, fresh.deviceNode],
            onLine: log
        )
    }

    /// FAT32 volume labels are 11 characters, upper case, no punctuation.
    static func sanitizeFAT32Label(_ raw: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let cleaned = raw.uppercased().compactMap { allowed.contains($0) ? $0 : nil }
        let label = String(cleaned.prefix(11))
        return label.isEmpty ? "IMAGEHUB" : label
    }

    // MARK: - Mount points

    /// Waits for the freshly created volume to appear in `/Volumes`.
    static func waitForVolume(onDisk identifier: String, timeout: TimeInterval = 30) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let mount = await mountPoint(onDisk: identifier) {
                return URL(fileURLWithPath: mount, isDirectory: true)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw DiskError(message: "The new volume on \(identifier) never mounted.")
    }

    static func mountPoint(onDisk identifier: String) async -> String? {
        guard let plist = await plistOutput(["list", "-plist", identifier]),
              let entries = plist["AllDisksAndPartitions"] as? [[String: Any]],
              let entry = entries.first(where: { ($0["DeviceIdentifier"] as? String) == identifier })
        else { return nil }

        for partition in (entry["Partitions"] as? [[String: Any]]) ?? [] {
            if let mount = partition["MountPoint"] as? String, !mount.isEmpty {
                return mount
            }
        }
        return nil
    }

    static func eject(_ identifier: String) async {
        _ = try? await Shell.run(diskutil, ["eject", identifier])
    }

    // MARK: - ISO mounting

    struct MountedImage {
        let mountPoint: URL
        let devEntry: String?
    }

    /// Attaches an ISO read-only and without showing it in Finder.
    static func attachISO(at url: URL, log: @escaping @Sendable (String) -> Void) async throws -> MountedImage {
        log("Mounting \(url.lastPathComponent)…")
        let result = try await Shell.check(
            hdiutil,
            ["attach", url.path, "-plist", "-nobrowse", "-readonly", "-noverify"]
        )
        guard let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else {
            throw DiskError(message: "Couldn't understand hdiutil's response while mounting the ISO.")
        }

        let mounted = entities.first { ($0["mount-point"] as? String)?.isEmpty == false }
        guard let mountPath = mounted?["mount-point"] as? String else {
            throw DiskError(message: "The ISO attached but no volume mounted.")
        }
        return MountedImage(
            mountPoint: URL(fileURLWithPath: mountPath, isDirectory: true),
            devEntry: mounted?["dev-entry"] as? String
        )
    }

    static func detach(_ image: MountedImage) async {
        let target = image.devEntry ?? image.mountPoint.path
        _ = try? await Shell.run(hdiutil, ["detach", target, "-quiet", "-force"])
    }

    // MARK: - Helpers

    private static func plistOutput(_ arguments: [String]) async -> [String: Any]? {
        guard let stdout = await Shell.output(diskutil, arguments),
              let data = stdout.data(using: .utf8) else { return nil }
        return (try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )) as? [String: Any]
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }
}
