import Foundation

/// Gets hold of the Office Deployment Tool's `setup.exe` so nobody has to.
///
/// The alternative was making every operator find the ODT on Microsoft's download
/// centre, run the self-extractor, and remember where they put the result —
/// before their first build could even start.
///
/// It is fetched from Microsoft's own CDN rather than committed to this repo and
/// bundled like wimlib. Partly size, mostly licence: the ODT ships under Microsoft
/// terms that are not ImageHub's to redistribute under, and downloading it from
/// source at build time sidesteps the question entirely. Office itself is never
/// bundled for the same reason, more emphatically — it is a licensed product.
enum OfficeDeploymentTool {
    /// Microsoft's evergreen copy. Versioned download-centre URLs rot every
    /// release; this one is the Click-to-Run bootstrapper Microsoft themselves
    /// point deployment tooling at, and it is the same binary the ODT extracts.
    static let downloadURL = URL(string: "https://officecdn.microsoft.com/pr/wsus/setup.exe")!

    /// Cached beside the rest of ImageHub's support files, so it is fetched once
    /// per Mac rather than once per build.
    static var cachedURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("ImageHub", isDirectory: true)
            .appendingPathComponent("OfficeDeploymentTool", isDirectory: true)
            .appendingPathComponent("setup.exe")
    }

    static var isCached: Bool {
        FileManager.default.fileExists(atPath: cachedURL.path)
    }

    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Returns a usable `setup.exe`, downloading it if this Mac has not got one.
    ///
    /// `preferred` is the operator's own copy when a template names one; it wins,
    /// because somebody who pinned a version meant it.
    static func resolve(
        preferred: String,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        if !preferred.isEmpty {
            let chosen = URL(fileURLWithPath: preferred)
            guard FileManager.default.fileExists(atPath: chosen.path) else {
                throw ToolError(
                    message: "The Office Deployment Tool this template points at is missing: \(preferred)"
                )
            }
            return chosen
        }

        let destination = cachedURL
        if FileManager.default.fileExists(atPath: destination.path) {
            log("Using the cached Office Deployment Tool.")
            return destination
        }

        log("Downloading the Office Deployment Tool from Microsoft…")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Downloaded to a sibling and moved into place, so an interrupted download
        // never leaves a truncated setup.exe looking like a cached one.
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        do {
            let (temporary, response) = try await URLSession.shared.download(from: downloadURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ToolError(
                    message: "Microsoft's CDN returned HTTP \(http.statusCode) for the Deployment Tool."
                )
            }
            try FileManager.default.moveItem(at: temporary, to: partial)
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError(
                message: """
                    Couldn't download the Office Deployment Tool: \(error.localizedDescription). \
                    Choose a setup.exe by hand on the Apps tab, or check this Mac's connection.
                    """
            )
        }

        // A 7 MB binary that arrives far smaller is a captive-portal login page or
        // an error document, and it would fail much later and less clearly.
        let size = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 1_000_000 else {
            try? FileManager.default.removeItem(at: partial)
            throw ToolError(
                message: """
                    The Office Deployment Tool downloaded as only \(Int64(size).byteSize), which is \
                    not a real setup.exe — usually a captive portal or a proxy error page. \
                    Check this Mac's connection, or choose a setup.exe by hand on the Apps tab.
                    """
            )
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        log("Office Deployment Tool ready (\(Int64(size).byteSize)).")
        return destination
    }
}
