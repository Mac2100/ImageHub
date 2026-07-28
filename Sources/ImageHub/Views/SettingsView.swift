import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ToolsSettingsView()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
            NotificationsSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            UpdatesSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 660, height: 480)
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @EnvironmentObject private var themeStore: ThemeStore

    private let swatchColumns = [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 12)]

    var body: some View {
        Form {
            Picker("Appearance", selection: $themeStore.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Section("Theme") {
                LazyVGrid(columns: swatchColumns, spacing: 12) {
                    ForEach(Themes.all) { theme in
                        themeSwatch(theme)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    private func themeSwatch(_ theme: AppTheme) -> some View {
        let isSelected = themeStore.themeID == theme.id
        return Button {
            withAnimation(.snappy(duration: 0.15)) {
                themeStore.themeID = theme.id
            }
        } label: {
            VStack(spacing: 8) {
                Circle()
                    .fill(theme.gradient)
                    .frame(width: 38, height: 38)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                Text(theme.name)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? theme.primary.opacity(0.1) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.primary.opacity(0.7) : Color.primary.opacity(0.07),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var appState: AppState

    @AppStorage("ejectAfterBuild") private var ejectAfterBuild = false
    @AppStorage("showToasts") private var showToasts = true
    @AppStorage("defaultLanguage") private var defaultLanguage = "en-US"
    @AppStorage(SecretStore.backendKey) private var secretBackend = SecretStore.Backend.keychain.rawValue

    var body: some View {
        Form {
            Section {
                VolumeLabelField()
                Toggle("Eject the drive when a build finishes", isOn: $ejectAfterBuild)
            } header: {
                Text("Media")
            }

            Section {
                Picker("Default image language", selection: $defaultLanguage) {
                    ForEach(WindowsLocales.all, id: \.locale) { entry in
                        Text(entry.label).tag(entry.locale)
                    }
                }
            } header: {
                Text("Downloads")
            }

            Section {
                Toggle("Show toast banners", isOn: $showToasts)
            } header: {
                Text("In-app")
            }

            Section {
                Picker("Store passwords in", selection: $secretBackend) {
                    ForEach(SecretStore.Backend.allCases) { backend in
                        Text(backend.label).tag(backend.rawValue)
                    }
                }
                .onChange(of: secretBackend) { _, newValue in
                    // Setting `backend` migrates the existing secrets across.
                    if let chosen = SecretStore.Backend(rawValue: newValue) {
                        SecretStore.backend = chosen
                        ToastCenter.shared.show(
                            "Passwords moved to the \(chosen.label.lowercased())"
                        )
                    }
                }
                SectionCaption(
                    text: SecretStore.Backend(rawValue: secretBackend)?.help ?? ""
                )
            } header: {
                Text("Template passwords")
            } footer: {
                SectionCaption(
                    text: "Either way these end up in clear text on a drive you build — Windows Setup reads them that way — so treat a finished USB stick as a credential."
                )
            }

            Section {
                LabeledContent("Templates") {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(
                            nil, inFileViewerRootedAtPath: appState.templates.directoryURL.path
                        )
                    }
                    .controlSize(.small)
                }
                LabeledContent("Image library") {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(
                            nil, inFileViewerRootedAtPath: AppPaths.images.path
                        )
                    }
                    .controlSize(.small)
                }
                LabeledContent("Images on disk", value: appState.library.totalBytesOnDisk.byteSize)
            } header: {
                Text("Storage")
            }
        }
        .formStyle(.grouped)
    }
}

/// The USB volume label, normalised on commit rather than per keystroke.
///
/// Rewriting the bound value on every keystroke made this unusable: the caret
/// jumped to the end after each character, and because the sanitiser substitutes
/// a default for an empty string, clearing the field instantly refilled it with
/// "IMAGEHUB". It also carried two labels — one from `LabeledContent` and one
/// from the `TextField`'s own title.
struct VolumeLabelField: View {
    @AppStorage("defaultVolumeLabel") private var stored = "IMAGEHUB"

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("USB volume label") {
                HStack(spacing: 8) {
                    TextField("", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .frame(width: 170)
                        .focused($focused)
                        .onSubmit(commit)
                    Text("\(normalised.count)/11")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if focused && normalised != text {
                Text("Will be saved as “\(normalised)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                SectionCaption(
                    text: "FAT32 labels are at most 11 characters, upper case, letters and digits only. Yours is tidied up when you finish typing."
                )
            }
        }
        .onAppear { text = stored }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
        .onDisappear(perform: commit)
    }

    private var normalised: String {
        DiskService.sanitizeFAT32Label(text)
    }

    private func commit() {
        let value = normalised
        text = value
        stored = value
    }
}

// MARK: - Tools

struct ToolsSettingsView: View {
    @AppStorage(WimTools.userDefaultsKey) private var wimlibPath = ""
    @AppStorage(PayloadBuilder.payloadPathOverrideKey) private var payloadPath = ""

    @State private var installing = false
    @State private var installLog: [String] = []
    @State private var wimlibVersion: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    if let found = WimTools.locate() {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(
                                WimTools.isUsingBundledCopy ? "Included with ImageHub" : "Installed",
                                systemImage: "checkmark.circle.fill"
                            )
                            .foregroundStyle(.green)
                            Text(WimTools.isUsingBundledCopy ? "Inside the app bundle" : found)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let wimlibVersion {
                                Text(wimlibVersion)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } else {
                        Label("Not found", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                SectionCaption(
                    text: "wimlib splits an install.wim that's 4 GB or larger — which every current Windows 11 ISO has — so it fits the FAT32 volume UEFI can boot from. It happens automatically during a build. Reading edition lists doesn't need it."
                )

                // Only worth showing when the bundled copy is missing.
                if !WimTools.isUsingBundledCopy {
                    HStack {
                        Button {
                            installViaBrew()
                        } label: {
                            if installing {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Installing…")
                                }
                            } else {
                                Text("Install with Homebrew")
                            }
                        }
                        .disabled(installing || WimTools.brewPath == nil)

                        if WimTools.brewPath == nil {
                            Text("Homebrew not found")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Link("wimlib.net", destination: URL(string: "https://wimlib.net")!)
                            .font(.caption)
                    }
                }

                if WimTools.isUsingBundledCopy {
                    HStack {
                        Text(
                            "wimlib \(WimTools.bundledVersion ?? "") is GPLv3-licensed and runs as a separate program; ImageHub itself stays MIT."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if let license = WimTools.licenseURL {
                            Button("Licence") { NSWorkspace.shared.open(license) }
                                .controlSize(.small)
                        }
                    }
                }

                PathField(
                    label: "Custom path",
                    path: $wimlibPath,
                    prompt: "Search Homebrew and /usr/local"
                )

                if !installLog.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(installLog.enumerated()), id: \.offset) { entry in
                                Text(entry.element)
                                    .font(.system(size: 10.5).monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: 110)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }
            } header: {
                Text("wimlib")
            }

            Section {
                PathField(
                    label: "Provisioning scripts",
                    path: $payloadPath,
                    prompt: "Bundled with the app",
                    directories: true
                )
                SectionCaption(
                    text: "Point this at a checkout's Shared/payload folder to test changes to Provision.ps1 without rebuilding ImageHub."
                )
            } header: {
                Text("Payload")
            }
        }
        .formStyle(.grouped)
        .task {
            wimlibVersion = await WimTools.version()
        }
    }

    private func installViaBrew() {
        installing = true
        installLog = []
        Task { @MainActor in
            do {
                try await WimTools.installViaHomebrew { line in
                    Task { @MainActor in installLog.append(line) }
                }
                wimlibVersion = await WimTools.version()
                ToastCenter.shared.show(
                    "wimlib installed",
                    detail: WimTools.locate() ?? ""
                )
            } catch {
                installLog.append(error.localizedDescription)
                ToastCenter.shared.show(
                    "Couldn't install wimlib",
                    detail: error.localizedDescription,
                    style: .error
                )
            }
            installing = false
        }
    }
}

// MARK: - Notifications

struct NotificationsSettingsView: View {
    @AppStorage(Notifier.Event.buildFinished.rawValue) private var buildFinished = true
    @AppStorage(Notifier.Event.buildFailed.rawValue) private var buildFailed = true
    @AppStorage(Notifier.Event.downloadFinished.rawValue) private var downloadFinished = false
    @AppStorage(Notifier.Event.updateAvailable.rawValue) private var updateAvailable = true

    var body: some View {
        Form {
            Section {
                Toggle(Notifier.Event.buildFinished.label, isOn: $buildFinished)
                Toggle(Notifier.Event.buildFailed.label, isOn: $buildFailed)
                Toggle(Notifier.Event.downloadFinished.label, isOn: $downloadFinished)
                Toggle(Notifier.Event.updateAvailable.label, isOn: $updateAvailable)
            } header: {
                Text("System notifications")
            } footer: {
                SectionCaption(
                    text: "Delivered through macOS Notification Center — allow notifications for ImageHub when macOS asks the first time. Builds take a while, so this is how you find out it finished without watching it."
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Updates

struct UpdatesSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true

    var body: some View {
        Form {
            LabeledContent("Current version", value: AppVersion.current)
            Toggle("Check for updates at launch", isOn: $autoCheckUpdates)

            UpdateStatusView(updates: appState.updates)

            Link("View releases on GitHub", destination: UpdateChecker.releasesPage)
                .font(.callout)
        }
        .formStyle(.grouped)
    }
}

struct UpdateStatusView: View {
    @ObservedObject var updates: UpdateChecker
    @ObservedObject private var updater = SelfUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task { await updates.check(userInitiated: true) }
                } label: {
                    if updates.status == .checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check Now")
                    }
                }
                .disabled(updates.status == .checking || updater.isBusy)

                switch updates.status {
                case .idle, .checking:
                    EmptyView()
                case .upToDate:
                    Label("You're up to date", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .noReleasesVisible:
                    Label(
                        "No releases visible — private repositories can't be checked anonymously",
                        systemImage: "eye.slash"
                    )
                    .foregroundStyle(.orange)
                case .updateAvailable(let version, let url):
                    Label("Version \(version) is available", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Button("Install & Relaunch") {
                        SelfUpdater.shared.install(from: url)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.isBusy)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                if let lastChecked = updates.lastChecked {
                    Text("Last checked \(lastChecked.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            switch updater.phase {
            case .idle:
                EmptyView()
            case .downloading:
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("Downloading update…")
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                    .foregroundStyle(.secondary)
                    ProgressView(value: updater.downloadProgress)
                }
            case .installing:
                Label {
                    Text("Installing…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .foregroundStyle(.secondary)
            case .relaunching:
                Label("Relaunching…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            theme.glyph(size: 64)
            Text("ImageHub")
                .font(.title.weight(.bold))
            Text("Version \(AppVersion.current)")
                .foregroundStyle(.secondary)
            Text("Bootable Windows golden-image USB drives,\nbuilt from reusable deployment templates.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/\(UpdateChecker.repo)")!)
                Link("Releases", destination: UpdateChecker.releasesPage)
                Link(
                    "MIT License",
                    destination: URL(string: "https://github.com/\(UpdateChecker.repo)/blob/main/LICENSE")!
                )
            }
            .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
