import Foundation
import UserNotifications

/// System (Notification Center) notifications, gated by per-event preferences
/// (Settings → Notifications). Builds take tens of minutes, so the "finished"
/// notification is the one that actually matters.
@MainActor
final class Notifier {
    static let shared = Notifier()

    enum Event: String, CaseIterable {
        case buildFinished = "notifyBuildFinished"
        case buildFailed = "notifyBuildFailed"
        case downloadFinished = "notifyDownloadFinished"
        case updateAvailable = "notifyUpdateAvailable"

        var defaultEnabled: Bool {
            self != .downloadFinished
        }

        var label: String {
            switch self {
            case .buildFinished: return "A drive finishes building"
            case .buildFailed: return "A build fails"
            case .downloadFinished: return "An image finishes downloading"
            case .updateAvailable: return "An ImageHub update is available"
            }
        }
    }

    private var authorizationRequested = false

    private init() {}

    static func isEnabled(_ event: Event) -> Bool {
        if let stored = UserDefaults.standard.object(forKey: event.rawValue) as? Bool {
            return stored
        }
        return event.defaultEnabled
    }

    func post(_ event: Event, title: String, body: String) {
        guard Self.isEnabled(event) else { return }
        // UNUserNotificationCenter requires a real app bundle (not `swift run`).
        guard Bundle.main.bundleIdentifier != nil else { return }

        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    // MARK: - Convenience

    static func buildFinished(template: String, drive: String, success: Bool) {
        shared.post(
            success ? .buildFinished : .buildFailed,
            title: success ? "USB drive ready" : "Build failed",
            body: success
                ? "\(template) was written to \(drive)."
                : "\(template) → \(drive) didn't complete. Check the build log."
        )
    }

    static func downloadFinished(_ name: String) {
        shared.post(
            .downloadFinished,
            title: "Image downloaded",
            body: "\(name) is in your image library."
        )
    }
}
