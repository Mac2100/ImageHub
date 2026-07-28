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

    /// The copy shipped inside the app bundle, when this build has one.
    static var bundledPath: String? {
        guard let path = Bundle.main.resourceURL?
            .appendingPathComponent("bin/wimlib-imagex").path,
              FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return path
    }

    static var isUsingBundledCopy: Bool {
        guard let located = locate(), let bundled = bundledPath else { return false }
        return located == bundled
    }

    /// Version recorded when the bundled binary was built.
    static var bundledVersion: String? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("wimlib-VERSION.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// wimlib's licence text, shipped beside the binary.
    static var licenseURL: URL? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("wimlib-COPYING.txt"),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    static var isAvailable: Bool { locate() != nil }

    /// Splits `source` into `install.swm`, `install2.swm`, … next to `destination`.
    /// `destination` is the path of the first part.
    ///
    /// `progress` receives 0…1 parsed from wimlib's own output, so the build view
    /// shows real movement on what is usually the longest stage of a build.
    static func split(
        source: URL,
        firstPart destination: URL,
        log: @escaping @Sendable (String) -> Void,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let tool = locate() else {
            throw ToolError(message: missingToolMessage)
        }
        log("Splitting \(source.lastPathComponent) into \(splitPartSizeMB) MB parts with wimlib…")
        try await Shell.check(
            tool,
            ["split", source.path, destination.path, String(splitPartSizeMB)],
            onLine: { line in
                if let progress, let fraction = splitFraction(from: line) {
                    progress(fraction)
                }
                log(line)
            }
        )
    }

    /// Pulls the fraction out of `Splitting WIM: 2011 MiB of 7177 MiB (28%) written, part 1 of 3`.
    ///
    /// The MiB values are used rather than wimlib's own percentage because they
    /// have more resolution and the percentage is rounded to a whole number.
    static func splitFraction(from line: String) -> Double? {
        guard line.contains("MiB of") else { return nil }
        let numbers = line
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Double($0) }
        guard numbers.count >= 2, numbers[1] > 0 else { return nil }
        return min(1, numbers[0] / numbers[1])
    }

    static let missingToolMessage = """
        This image's install.wim is larger than 4 GB, so it has to be split before \
        it fits on the FAT32 volume that UEFI can boot. That needs wimlib, which \
        normally ships inside ImageHub — this build doesn't have it. Install it \
        with “brew install wimlib”, or point ImageHub at an existing copy in \
        Settings → Tools.
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
