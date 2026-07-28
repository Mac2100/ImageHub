import AppKit
import Foundation

/// Checks GitHub Releases for a newer version of ImageHub.
@MainActor
final class UpdateChecker: ObservableObject {
    static let repo = "Mac2100/ImageHub"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        /// GitHub answered 404: either no release exists yet, or the repository
        /// is private and anonymous API calls cannot see its releases.
        case noReleasesVisible
        case updateAvailable(version: String, url: URL)
        case failed(String)
    }

    @Published var status: Status = .idle
    @Published var lastChecked: Date?

    private struct Release: Decodable {
        var tag_name: String
        var html_url: String
        var assets: [Asset]?

        struct Asset: Decodable {
            var name: String
            var browser_download_url: String
        }
    }

    func checkOnLaunchIfEnabled() {
        guard UserDefaults.standard.object(forKey: "autoCheckUpdates") == nil
                || UserDefaults.standard.bool(forKey: "autoCheckUpdates") else { return }
        Task { await check() }
    }

    /// Runs a check and, for user-initiated checks, always reports the outcome —
    /// including the one that matters. Silent launch checks stay silent.
    ///
    /// An alert rather than a toast for the "update available" case: toasts live
    /// in the main window, so choosing "Check for Updates…" with the window
    /// closed would have produced nothing at all.
    func check(userInitiated: Bool) async {
        await check()
        guard userInitiated else { return }
        switch status {
        case .upToDate:
            ToastCenter.shared.show(
                "No updates available",
                detail: "ImageHub \(AppVersion.current) is the latest version"
            )
        case .noReleasesVisible:
            ToastCenter.shared.show(
                "No releases visible",
                detail: "Private repositories can't be checked anonymously",
                style: .info
            )
        case .failed(let message):
            ToastCenter.shared.show("Update check failed", detail: message, style: .error)
        case .updateAvailable(let version, let url):
            promptToInstall(version: version, url: url)
        case .idle, .checking:
            break
        }
    }

    /// Offers the update straight away, so "Check for Updates…" is a complete
    /// action instead of a hint to go and open Settings.
    func promptToInstall(version: String, url: URL) {
        guard !SelfUpdater.shared.isBusy else { return }

        let alert = NSAlert()
        alert.messageText = "ImageHub \(version) is available"
        alert.informativeText = """
            You're running \(AppVersion.current). Installing downloads the update, \
            replaces the app in place, and relaunches it.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            SelfUpdater.shared.install(from: url)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(Self.releasesPage)
        default:
            break
        }
    }

    func check() async {
        status = .checking
        defer { lastChecked = Date() }
        do {
            var request = URLRequest(
                url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
            )
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            if http.statusCode == 404 {
                status = .noReleasesVisible
                return
            }
            guard http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.hasPrefix("v")
                ? String(release.tag_name.dropFirst())
                : release.tag_name

            if Self.isVersion(latest, newerThan: AppVersion.current) {
                let dmg = release.assets?.first { $0.name.hasSuffix(".dmg") }
                let url = dmg.flatMap { URL(string: $0.browser_download_url) }
                    ?? (URL(string: release.html_url) ?? Self.releasesPage)
                status = .updateAvailable(version: latest, url: url)
                Notifier.shared.post(
                    .updateAvailable,
                    title: "ImageHub \(latest) is available",
                    body: "Install it from Settings → Updates."
                )
            } else {
                status = .upToDate
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Numeric dotted-version comparison ("1.2.10" > "1.2.9").
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
