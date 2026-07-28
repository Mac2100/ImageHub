import AppKit
import SwiftUI

/// A small floating panel shown while an update installs.
///
/// "Check for Updates…" is reachable from the app menu with no window open, so
/// the download had no visible progress anywhere except Settings → Updates —
/// clicking Install looked like nothing had happened for the length of a
/// multi-megabyte download.
@MainActor
final class UpdateProgressWindow {
    static let shared = UpdateProgressWindow()

    private var window: NSWindow?

    private init() {}

    func show(version: String) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 190),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Updating ImageHub"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.contentView = NSHostingView(
            rootView: UpdateProgressView(version: version) { [weak self] in
                self?.hide()
            }
            .environment(\.appTheme, ThemeStore.shared.theme)
        )
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = panel
    }

    func hide() {
        window?.orderOut(nil)
        window?.close()
        window = nil
    }
}

struct UpdateProgressView: View {
    let version: String
    let onClose: () -> Void

    @ObservedObject private var updater = SelfUpdater.shared
    @Environment(\.appTheme) private var theme
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 14) {
            theme.glyph(size: 46)
                .scaleEffect(pulse ? 1.06 : 0.94)
                .opacity(isFinished ? 1 : (pulse ? 1 : 0.85))
                .animation(
                    isFinished
                        ? .default
                        : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: pulse
                )

            VStack(spacing: 4) {
                Text(headline)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch updater.phase {
            case .downloading:
                // A real fraction once the server reports a length, otherwise
                // an indeterminate bar rather than a stuck 0%.
                if updater.downloadProgress > 0 {
                    ProgressView(value: updater.downloadProgress)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            case .installing, .relaunching:
                ProgressView()
                    .progressViewStyle(.linear)
            case .failed:
                Button("Close", action: onClose)
                    .buttonStyle(.borderedProminent)
            case .idle:
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .padding(22)
        .frame(width: 380)
        .onAppear { pulse = true }
    }

    private var isFinished: Bool {
        if case .failed = updater.phase { return true }
        return false
    }

    private var headline: String {
        switch updater.phase {
        case .downloading: return "Downloading ImageHub \(version)"
        case .installing: return "Installing…"
        case .relaunching: return "Relaunching…"
        case .failed: return "Update failed"
        case .idle: return "Preparing…"
        }
    }

    private var detail: String {
        switch updater.phase {
        case .downloading:
            return updater.downloadProgress > 0
                ? "\(Int(updater.downloadProgress * 100))% complete"
                : "Starting the download…"
        case .installing:
            return "Replacing the app in place."
        case .relaunching:
            return "ImageHub will reopen in a moment."
        case .failed(let message):
            return message
        case .idle:
            return "Getting ready."
        }
    }
}
