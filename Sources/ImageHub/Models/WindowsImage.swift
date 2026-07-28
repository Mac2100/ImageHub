import Foundation

/// One edition inside an ISO's `install.wim` / `install.esd`.
struct ImageEdition: Codable, Equatable, Hashable, Identifiable {
    var index: Int
    var name: String
    var editionDescription: String = ""
    var sizeBytes: Int64 = 0

    var id: Int { index }
}

/// An ISO in the local library. The file lives under
/// `~/Library/Application Support/ImageHub/Images/`; this is the metadata record.
struct WindowsImage: Codable, Equatable, Hashable, Identifiable {
    enum Origin: String, Codable, Hashable {
        case microsoft
        case imported
        case remoteURL

        var label: String {
            switch self {
            case .microsoft: return "Microsoft"
            case .imported: return "Imported"
            case .remoteURL: return "Internal URL"
            }
        }

        var symbol: String {
            switch self {
            case .microsoft: return "cloud.fill"
            case .imported: return "folder.fill"
            case .remoteURL: return "link"
            }
        }
    }

    var id: UUID = UUID()
    var name: String = ""
    var release: WindowsRelease = .win11
    /// Feature update label such as "24H2", when known.
    var buildLabel: String = ""
    var language: String = "en-US"
    var architecture: String = "x64"

    /// Absolute path to the ISO. Managed copies live in the library directory;
    /// linked images can point anywhere (a NAS mount, an external drive).
    var path: String = ""
    /// False when the ISO was linked in place rather than copied into the library.
    var managed: Bool = true

    var sizeBytes: Int64 = 0
    var sha256: String = ""
    var origin: Origin = .imported
    var sourceURL: String = ""
    var addedAt: Date = Date()
    var lastVerifiedAt: Date?

    /// Populated by `ImageInspector` after the ISO is mounted once.
    var editions: [ImageEdition] = []
    var installImageName: String = ""
    var installImageSizeBytes: Int64 = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, UUID())
        name = c.v(.name, "")
        release = c.v(.release, WindowsRelease.win11)
        buildLabel = c.v(.buildLabel, "")
        language = c.v(.language, "en-US")
        architecture = c.v(.architecture, "x64")
        path = c.v(.path, "")
        managed = c.v(.managed, true)
        sizeBytes = c.v(.sizeBytes, 0)
        sha256 = c.v(.sha256, "")
        origin = c.v(.origin, Origin.imported)
        sourceURL = c.v(.sourceURL, "")
        addedAt = c.v(.addedAt, Date())
        lastVerifiedAt = c.opt(.lastVerifiedAt)
        editions = c.v(.editions, [])
        installImageName = c.v(.installImageName, "")
        installImageSizeBytes = c.v(.installImageSizeBytes, 0)
    }

    var url: URL { URL(fileURLWithPath: path) }

    var fileExists: Bool {
        !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    var displayName: String {
        if !name.isEmpty { return name }
        var parts = [release.label]
        if !buildLabel.isEmpty { parts.append(buildLabel) }
        parts.append("(\(language), \(architecture))")
        return parts.joined(separator: " ")
    }

    /// `install.wim` above this size cannot be copied onto a FAT32 boot volume
    /// and has to be split into `install.swm` parts.
    static let fat32FileLimit: Int64 = 4_294_967_295

    var installImageNeedsSplit: Bool {
        installImageSizeBytes >= WindowsImage.fat32FileLimit
    }

    var subtitle: String {
        var parts: [String] = [sizeBytes.byteSize, origin.label]
        if !editions.isEmpty { parts.append("\(editions.count) editions") }
        return parts.joined(separator: " · ")
    }

    func edition(matching wanted: String) -> ImageEdition? {
        editions.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }
}

/// A release Microsoft is currently offering for download.
struct AvailableDownload: Identifiable, Equatable, Hashable {
    var id: String { "\(productID)-\(language)-\(architecture)" }
    var productID: String
    var title: String
    var release: WindowsRelease
    var buildLabel: String
    var language: String
    var architecture: String
    var downloadURL: URL
    var sizeBytes: Int64
    /// Microsoft's download links are time-limited; after this the URL 403s.
    var expiresAt: Date?

    var subtitle: String {
        var parts: [String] = []
        if sizeBytes > 0 { parts.append(sizeBytes.byteSize) }
        parts.append(language)
        parts.append(architecture)
        return parts.joined(separator: " · ")
    }
}
