import Foundation

/// Asks Microsoft's own software-download service for a current retail ISO link.
///
/// This is the same public flow the Windows download page uses in a browser:
/// register a session, look up the SKUs for a product edition, then ask for that
/// SKU's download links. ImageHub never mirrors or redistributes anything — the
/// link it hands to `Downloader` points at Microsoft's CDN.
///
/// Microsoft rate-limits and geo/IP-filters this endpoint, and the download URLs
/// expire after roughly 24 hours. When it refuses, the error explains what
/// happened and the UI offers importing an ISO by hand instead.
enum MicrosoftISOService {
    struct ServiceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let profile = "606624d44113"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Product edition IDs move with each feature update, so the page is scraped
    /// first and these are only the fallback.
    private static func fallbackEditionIDs(for release: WindowsRelease) -> [String] {
        switch release {
        case .win11: return ["3113", "3131", "2935"]
        case .win10: return ["2618", "2033"]
        }
    }

    private static func pageURL(for release: WindowsRelease) -> URL {
        switch release {
        case .win11:
            return URL(string: "https://www.microsoft.com/en-us/software-download/windows11")!
        case .win10:
            return URL(string: "https://www.microsoft.com/en-us/software-download/windows10ISO")!
        }
    }

    /// Resolves a downloadable ISO for the given release and language.
    static func findDownload(
        release: WindowsRelease,
        language: String,
        log: (@Sendable (String) -> Void)? = nil
    ) async throws -> AvailableDownload {
        let session = UUID().uuidString.lowercased()

        log?("Registering a download session with Microsoft…")
        try await registerSession(session)

        log?("Looking up the current \(release.label) product edition…")
        let editionIDs = try await editionIDs(for: release)
        guard !editionIDs.isEmpty else {
            throw ServiceError(
                message: "Microsoft's download page didn't list any \(release.label) editions."
            )
        }

        var lastError: Error?
        for editionID in editionIDs {
            do {
                let sku = try await findSKU(
                    editionID: editionID, language: language, session: session, log: log
                )
                log?("Requesting download links for “\(sku.productName)”…")
                return try await downloadLink(
                    sku: sku, release: release, language: language, session: session, log: log
                )
            } catch {
                lastError = error
                log?("Edition \(editionID) didn't work: \(error.localizedDescription)")
            }
        }
        throw lastError
            ?? ServiceError(message: "Microsoft didn't offer a download for \(release.label).")
    }

    // MARK: - Steps

    private static func registerSession(_ session: String) async throws {
        // This endpoint sets the anti-abuse token the connector API checks for.
        let url = URL(
            string: "https://vlscppe.microsoft.com/fp/tags?org_id=y6jn8c31&session_id=\(session)"
        )!
        _ = try? await data(from: url, referer: nil)
    }

    private static func editionIDs(for release: WindowsRelease) async throws -> [String] {
        guard let html = try? await string(from: pageURL(for: release), referer: nil) else {
            return fallbackEditionIDs(for: release)
        }

        // The page renders the edition list as <option value="3113">…</option>.
        var found: [String] = []
        let pattern = #"value="(\d{4})""#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                guard match.numberOfRanges > 1,
                      let captured = Range(match.range(at: 1), in: html) else { continue }
                let id = String(html[captured])
                if !found.contains(id) { found.append(id) }
            }
        }
        found.append(contentsOf: fallbackEditionIDs(for: release).filter { !found.contains($0) })
        return found
    }

    private struct SKU {
        let id: String
        let language: String
        let productName: String
    }

    private static func findSKU(
        editionID: String,
        language: String,
        session: String,
        log: (@Sendable (String) -> Void)?
    ) async throws -> SKU {
        var components = URLComponents(
            string: "https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition"
        )!
        components.queryItems = [
            URLQueryItem(name: "profile", value: profile),
            URLQueryItem(name: "ProductEditionId", value: editionID),
            URLQueryItem(name: "SKU", value: "undefined"),
            URLQueryItem(name: "friendlyFileName", value: "undefined"),
            URLQueryItem(name: "Locale", value: "en-US"),
            URLQueryItem(name: "sessionID", value: session)
        ]

        let json = try await jsonObject(from: components.url!, referer: "https://www.microsoft.com/software-download/windows11")
        try throwIfErrors(in: json)

        guard let skus = json["Skus"] as? [[String: Any]], !skus.isEmpty else {
            throw ServiceError(message: "Microsoft returned no SKUs for edition \(editionID).")
        }

        // Prefer an exact language match, then a prefix match, then English.
        func pick(_ predicate: ([String: Any]) -> Bool) -> [String: Any]? {
            skus.first(where: predicate)
        }
        let wanted = language.lowercased()
        let chosen =
            pick { ($0["Language"] as? String)?.lowercased() == wanted }
            ?? pick { ($0["LocalizedLanguage"] as? String)?.lowercased().hasPrefix(
                wanted.split(separator: "-").first.map(String.init) ?? wanted
            ) == true }
            ?? pick { ($0["LocalizedLanguage"] as? String)?.contains("English (United States)") == true }
            ?? skus[0]

        guard let id = (chosen["Id"] as? String) ?? (chosen["Id"] as? NSNumber)?.stringValue else {
            throw ServiceError(message: "Microsoft's SKU response was missing an ID.")
        }
        return SKU(
            id: id,
            language: (chosen["Language"] as? String) ?? language,
            productName: (chosen["ProductDisplayName"] as? String)
                ?? (chosen["LocalizedLanguage"] as? String)
                ?? "Windows"
        )
    }

    private static func downloadLink(
        sku: SKU,
        release: WindowsRelease,
        language: String,
        session: String,
        log: (@Sendable (String) -> Void)?
    ) async throws -> AvailableDownload {
        var components = URLComponents(
            string: "https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku"
        )!
        components.queryItems = [
            URLQueryItem(name: "profile", value: profile),
            URLQueryItem(name: "productEditionId", value: "undefined"),
            URLQueryItem(name: "SKU", value: sku.id),
            URLQueryItem(name: "friendlyFileName", value: "undefined"),
            URLQueryItem(name: "Locale", value: "en-US"),
            URLQueryItem(name: "sessionID", value: session)
        ]

        let json = try await jsonObject(from: components.url!, referer: "https://www.microsoft.com/software-download/windows11")
        try throwIfErrors(in: json)

        guard let options = json["ProductDownloadOptions"] as? [[String: Any]], !options.isEmpty else {
            throw ServiceError(
                message: "Microsoft didn't return any download links for this SKU."
            )
        }

        // Microsoft only publishes x64 consumer ISOs; ARM64 Windows ships through
        // OEMs, so there is nothing to choose between here.
        let chosen = options.first { option in
            (option["Uri"] as? String)?.lowercased().contains("x64") == true
        } ?? options[0]

        guard let uriString = chosen["Uri"] as? String, let uri = URL(string: uriString) else {
            throw ServiceError(message: "Microsoft's download link was unreadable.")
        }

        let fileName = uri.lastPathComponent
        log?("Microsoft offered \(fileName)")

        return AvailableDownload(
            productID: sku.id,
            title: fileName.isEmpty ? "\(release.label) ISO" : fileName,
            release: release,
            buildLabel: buildLabel(from: fileName),
            language: sku.language,
            architecture: "x64",
            downloadURL: uri,
            sizeBytes: 0,
            // Microsoft's signed links are good for about a day.
            expiresAt: Date().addingTimeInterval(24 * 3600)
        )
    }

    /// `Win11_24H2_English_x64.iso` → `24H2`.
    static func buildLabel(from fileName: String) -> String {
        guard let range = fileName.range(
            of: #"\d{2}H\d"#, options: [.regularExpression, .caseInsensitive]
        ) else { return "" }
        return String(fileName[range]).uppercased()
    }

    // MARK: - HTTP plumbing

    private static func throwIfErrors(in json: [String: Any]) throws {
        guard let errors = json["Errors"] as? [[String: Any]], !errors.isEmpty else { return }
        let codes = errors.compactMap { $0["Value"] as? String }.joined(separator: ", ")
        throw ServiceError(
            message: """
                Microsoft's download service declined the request\(codes.isEmpty ? "" : " (\(codes))"). \
                This usually means the IP address is rate-limited or filtered — VPNs and \
                datacentre ranges are commonly blocked. Import an ISO manually, or point \
                ImageHub at an internal URL instead.
                """
        )
    }

    private static func request(_ url: URL, referer: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        return request
    }

    private static func data(from url: URL, referer: String?) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(url, referer: referer))
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ServiceError(
                message: "Microsoft's download service returned HTTP \(http.statusCode)."
            )
        }
        return data
    }

    private static func string(from url: URL, referer: String?) async throws -> String {
        let data = try await data(from: url, referer: referer)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func jsonObject(from url: URL, referer: String?) async throws -> [String: Any] {
        let data = try await data(from: url, referer: referer)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // The connector sometimes answers with an HTML error page.
            let text = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw ServiceError(
                message: """
                    Microsoft's download service sent something ImageHub couldn't read. \
                    \(text.isEmpty ? "" : "It started with: \(text)")
                    """
            )
        }
        return object
    }
}
