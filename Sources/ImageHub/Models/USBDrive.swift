import Foundation

/// A whole physical disk as reported by `diskutil`.
struct USBDrive: Identifiable, Equatable, Hashable {
    /// `disk4`
    var id: String
    /// `/dev/disk4`
    var deviceNode: String
    /// `SanDisk Ultra USB 3.0 Media`
    var mediaName: String
    var sizeBytes: Int64
    var isInternal: Bool
    var isRemovable: Bool
    var isEjectable: Bool
    /// `USB`, `Thunderbolt`, `PCI-Express`, …
    var busProtocol: String
    var volumeNames: [String]
    var mountPoints: [String]
    var isWholeDisk: Bool
    /// True for mounted disk images (a mounted ISO reports as external and
    /// ejectable, so it passed the eligibility test and was offered as a build
    /// target — the very ISO the build was reading from).
    var isVirtual: Bool = false

    var displayName: String {
        mediaName.isEmpty ? id : mediaName
    }

    var subtitle: String {
        var parts: [String] = [sizeBytes.byteSize, busProtocol.isEmpty ? "Unknown bus" : busProtocol]
        if !volumeNames.isEmpty {
            parts.append(volumeNames.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    /// Only external, ejectable media is ever offered as a build target — an
    /// internal disk must never show up in the picker.
    var isEligibleTarget: Bool {
        isWholeDisk && !isInternal && !isVirtual && (isRemovable || isEjectable)
    }

    /// Windows install media needs room for the ISO plus the payload.
    func hasRoom(forISOSize iso: Int64) -> Bool {
        sizeBytes >= iso + 512_000_000
    }
}
