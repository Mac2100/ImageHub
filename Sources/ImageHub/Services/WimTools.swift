import Foundation

/// Locates and drives `wimlib-imagex`, which ImageHub uses for exactly one job:
/// splitting an oversized `install.wim` into FAT32-sized `install*.swm` parts.
///
/// Inspection (edition lists) is handled natively by `WimReader`, so wimlib is
/// only required when the image's `install.wim` is 4 GB or larger — which every
/// current Windows 11 ISO is.
enum WimTools {
    /// Part size in MiB. Comfortably under FAT32's 4 GiB per-file ceiling.
    static let splitPartSizeMB = 3800

    static let userDefaultsKey = "wimlibPath"

    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Search order: bundled inside the app, an explicit path from Settings,
    /// then the usual Homebrew prefixes and `/usr/local`.
    static var searchPaths: [String] {
        var paths: [String] = []
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("bin/wimlib-imagex").path {
            paths.append(bundled)
        }
        if let custom = UserDefaults.standard.string(forKey: userDefaultsKey), !custom.isEmpty {
            paths.append(custom)
        }
        paths.append(contentsOf: [
            "/opt/homebrew/bin/wimlib-imagex",
            "/usr/local/bin/wimlib-imagex",
            "/opt/local/bin/wimlib-imagex",
            "/usr/bin/wimlib-imagex"
        ])
        return paths
    }

    /// Path to a usable `wimlib-imagex`, or nil when none is installed.
    static func locate() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { locate() != nil }

    static func version() async -> String? {
        guard let tool = locate(),
              let output = await Shell.output(tool, ["--version"]) else { return nil }
        return output.split(separator: "\n").first.map(String.init)
    }

    /// Splits `source` into `install.swm`, `install2.swm`, … next to `destination`.
    /// `destination` is the path of the first part.
    static func split(
        source: URL,
        firstPart destination: URL,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let tool = locate() else {
            throw ToolError(message: missingToolMessage)
        }
        log("Splitting \(source.lastPathComponent) into \(splitPartSizeMB) MB parts with wimlib…")
        try await Shell.check(
            tool,
            ["split", source.path, destination.path, String(splitPartSizeMB)],
            onLine: log
        )
    }

    static let missingToolMessage = """
        This image's install.wim is larger than 4 GB, so it has to be split before \
        it fits on the FAT32 volume that UEFI can boot. That needs wimlib. \
        Install it with “brew install wimlib”, or point ImageHub at an existing \
        copy in Settings → Tools.
        """

    // MARK: - Homebrew helper

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `brew install wimlib` with live output so Settings can show progress.
    static func installViaHomebrew(log: @escaping @Sendable (String) -> Void) async throws {
        guard let brew = brewPath else {
            throw ToolError(
                message: "Homebrew isn't installed on this Mac. Install it from brew.sh, then try again."
            )
        }
        log("Running \(brew) install wimlib…")
        try await Shell.check(brew, ["install", "wimlib"], onLine: log)
    }
}
