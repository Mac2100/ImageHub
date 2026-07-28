import SwiftUI

@main
struct ImageHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var themeStore = ThemeStore.shared

    init() {
        CommandLineTools.runIfRequested()
    }

    var body: some Scene {
        Window("ImageHub", id: "main") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(themeStore)
                .environment(\.appTheme, themeStore.theme)
                .tint(themeStore.theme.primary)
                .frame(minWidth: 1040, minHeight: 660)
                .task {
                    appState.updates.checkOnLaunchIfEnabled()
                    await appState.refreshDrives()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await appState.updates.check(userInitiated: true) }
                }
            }
            CommandGroup(after: .newItem) {
                Button("New Template") {
                    let template = appState.templates.newTemplate()
                    appState.select(template)
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Build USB Drive…") {
                    appState.startBuild(template: appState.selectedTemplate)
                }
                .keyboardShortcut("b", modifiers: [.command])
                .disabled(appState.isBuilding)
            }
            SidebarCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(themeStore)
                .environment(\.appTheme, themeStore.theme)
                .tint(themeStore.theme.primary)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeStore.shared.applyAppearance()
    }

    /// A half-written USB stick is worse than no USB stick, so quitting mid-build
    /// asks first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppState.shared.isBuilding else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "A drive is still being written."
        alert.informativeText = """
            Quitting now leaves the USB drive unbootable. You can cancel the build \
            first, or quit anyway and re-run it later.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Building")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
