import SwiftUI
import UniformTypeIdentifiers

// MARK: - Applications

struct AppsTab: View {
    @Binding var draft: DeploymentTemplate
    @Environment(\.appTheme) private var theme

    @State private var showingCatalog = false
    @State private var selectedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Applications")
                    .font(.headline)
                Spacer()
                Button {
                    showingCatalog = true
                } label: {
                    Label("Add from catalog", systemImage: "square.grid.2x2")
                }
                .controlSize(.small)

                Menu {
                    Button("winget package") { add(source: .winget) }
                    Button("Bundled installer…") { addInstaller() }
                    Button("PowerShell snippet") { add(source: .script) }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
            }

            if draft.apps.isEmpty {
                EmptyStateView(
                    symbol: "shippingbox",
                    title: "No applications yet",
                    message: "Add winget packages for anything in Microsoft's repository, or bundle an installer onto the USB for offline or version-pinned software."
                ) {
                    Button("Browse catalog") { showingCatalog = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(height: 280)
            } else {
                VStack(spacing: 0) {
                    ForEach($draft.apps) { $app in
                        AppRow(app: $app, isExpanded: selectedID == app.id) {
                            selectedID = selectedID == app.id ? nil : app.id
                        } onDelete: {
                            draft.apps.removeAll { $0.id == app.id }
                        }
                        if app.id != draft.apps.last?.id {
                            Divider()
                        }
                    }
                }
                .glassCard(padding: 0)

                HStack(spacing: 14) {
                    Chip(
                        text: "\(draft.enabledApps.count) enabled",
                        symbol: "checkmark.circle",
                        tint: theme.primary
                    )
                    let winget = draft.enabledApps.filter { $0.source == .winget }.count
                    if winget > 0 {
                        Chip(text: "\(winget) via winget", symbol: "network")
                    }
                    let bundled = draft.enabledApps.filter { $0.source == .installer }.count
                    if bundled > 0 {
                        Chip(text: "\(bundled) bundled", symbol: "arrow.down.app")
                    }
                    Spacer()
                }
            }

            if draft.enabledApps.contains(where: { $0.source == .winget }) {
                NoticeBanner(
                    kind: .info,
                    title: "winget needs internet on first boot",
                    messages: [
                        "Wire the machine up before reimaging, or add a Wi-Fi profile under Configuration so provisioning can get online by itself."
                    ]
                )
            }
        }
        .sheet(isPresented: $showingCatalog) {
            AppCatalogSheet(
                alreadyAdded: Set(draft.apps.map { $0.packageID }.filter { !$0.isEmpty })
            ) { entries in
                for entry in entries where !draft.apps.contains(where: { $0.packageID == entry.id }) {
                    draft.apps.append(entry.selection)
                }
            }
        }
    }

    private func add(source: AppSelection.Source) {
        var app = AppSelection()
        app.source = source
        app.name = source == .script ? "New script step" : ""
        draft.apps.append(app)
        selectedID = app.id
    }

    private func addInstaller() {
        guard let url = Panels.chooseFile(title: "Choose an installer") else { return }
        var app = AppSelection()
        app.source = .installer
        app.installerPath = url.path
        app.name = url.deletingPathExtension().lastPathComponent
        app.silentArgs = SilentSwitchPreset.suggested(forExtension: url.pathExtension).arguments ?? ""
        draft.apps.append(app)
        selectedID = app.id
    }
}

struct AppRow: View {
    @Binding var app: AppSelection
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: $app.enabled)
                    .labelsHidden()
                    .help("Include in this template")

                Image(systemName: app.source.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if app.required {
                    Chip(text: "Required", tint: .orange)
                }
                if !app.isActionable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("This entry is incomplete and will be skipped.")
                }

                // A bare Image in a borderless button is only as clickable as the
                // glyph — about 10pt — and the row's double-tap gesture competes
                // with it, so single clicks were being missed. An explicit frame
                // plus contentShape gives each one a real 28pt target.
                Button {
                    onToggleExpand()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Collapse" : "Expand")

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())

            if isExpanded {
                detail
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .opacity(app.enabled ? 1 : 0.55)
    }

    private var subtitle: String {
        switch app.source {
        case .winget:
            return app.packageID.isEmpty
                ? "No package ID yet"
                : app.packageID + (app.version.isEmpty ? "" : " · \(app.version)")
        case .installer:
            return app.installerPath.isEmpty
                ? "No installer chosen"
                : "\((app.installerPath as NSString).lastPathComponent) \(app.silentArgs)"
        case .script:
            return app.script.isEmpty ? "Empty script" : "PowerShell"
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Source", selection: $app.source) {
                ForEach(AppSelection.Source.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .pickerStyle(.segmented)

            TextField("Display name", text: $app.name)

            switch app.source {
            case .winget:
                TextField("winget package ID (e.g. Google.Chrome)", text: $app.packageID)
                    .autocorrectionDisabled()
                TextField("Pin a version (optional)", text: $app.version)
            case .installer:
                PathField(label: "Installer", path: $app.installerPath)
                SilentSwitchField(arguments: $app.silentArgs, installerPath: app.installerPath)
            case .script:
                TextEditor(text: $app.script)
                    .font(.system(size: 11).monospaced())
                    .frame(height: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.12))
                    )
            }

            Toggle("Fail provisioning if this doesn't install", isOn: $app.required)
            TextField("Notes", text: $app.notes)
        }
        .textFieldStyle(.roundedBorder)
    }
}

struct AppCatalogSheet: View {
    /// winget package IDs already in the template, so the catalog can mark them
    /// instead of letting you pick something you've already got.
    let alreadyAdded: Set<String>
    let onAdd: ([AppCatalog.Entry]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var search = ""
    @State private var selected: Set<String> = []

    /// Grouped once per search term.
    ///
    /// This used to build `Section`s conditionally inside a `ForEach` over
    /// categories, filtering inside the view body. SwiftUI mis-diffed the
    /// conditional sections — headers rendered with no rows beneath them — and
    /// the `List` oscillated vertically as it renegotiated row heights. A
    /// precomputed array and a `LazyVStack` make the layout deterministic.
    private var groups: [(category: String, entries: [AppCatalog.Entry])] {
        let matches = AppCatalog.search(search)
        return AppCatalog.categories.compactMap { category in
            let entries = matches.filter { $0.category == category }
            return entries.isEmpty ? nil : (category: category, entries: entries)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Application catalog")
                    .font(.headline)
                Spacer()
                SearchField(text: $search, prompt: "Search packages")
            }
            .padding(14)

            Divider()

            if groups.isEmpty {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "No matches",
                    message: "Nothing in the catalog matches “\(search)”. Any winget package ID can still be typed in by hand — the catalog is only a shortcut."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.category) { group in
                            Text(group.category)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.top, 14)
                                .padding(.bottom, 6)

                            ForEach(group.entries) { entry in
                                row(entry)
                                if entry.id != group.entries.last?.id {
                                    Divider().padding(.leading, 44)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }
            }

            Divider()

            HStack {
                Text(selected.isEmpty ? "Nothing selected" : "\(selected.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    onAdd(AppCatalog.entries.filter { selected.contains($0.id) })
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 580, height: 540)
    }

    private func row(_ entry: AppCatalog.Entry) -> some View {
        let added = alreadyAdded.contains(entry.id)
        let isSelected = selected.contains(entry.id)
        return Button {
            guard !added else { return }
            if isSelected { selected.remove(entry.id) } else { selected.insert(entry.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: added || isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(
                        added
                            ? AnyShapeStyle(.green)
                            : isSelected ? AnyShapeStyle(theme.primary) : AnyShapeStyle(.tertiary)
                    )
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.callout)
                    Text(entry.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if added {
                    Chip(text: "In template", tint: .green)
                } else if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 190, alignment: .trailing)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(added ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .disabled(added)
        .help(added ? "Already in this template" : "")
    }
}

// MARK: - System configuration

struct SystemTab: View {
    @Binding var draft: DeploymentTemplate

    var body: some View {
        Form {
            Section {
                Picker("Time zone", selection: $draft.system.timeZone) {
                    ForEach(WindowsTimeZones.all, id: \.self) { zone in
                        Text(zone).tag(zone)
                    }
                }
                Picker("Power plan", selection: $draft.system.powerPlan) {
                    ForEach(SystemSpec.PowerPlan.allCases) { plan in
                        Text(plan.label).tag(plan)
                    }
                }
                Toggle("Never sleep on mains power", isOn: $draft.system.disableSleepOnAC)
                Toggle("Disable fast startup", isOn: $draft.system.disableFastStartup)
                Toggle("Disable hibernation (reclaims hiberfil.sys)", isOn: $draft.system.disableHibernation)
            } header: {
                Text("Machine")
            }

            Section {
                Toggle("Enable Remote Desktop", isOn: $draft.system.enableRemoteDesktop)
                Toggle("Allow ping (ICMP echo) through the firewall", isOn: $draft.system.allowPing)
            } header: {
                Text("Remote access")
            } footer: {
                SectionCaption(
                    text: "Remote Desktop is enabled in the answer file and the firewall rule is opened during provisioning."
                )
            }

            Section {
                Toggle("Show file extensions", isOn: $draft.system.showFileExtensions)
                Toggle("Show hidden files", isOn: $draft.system.showHiddenFiles)
                Toggle("Restore the classic right-click menu", isOn: $draft.system.classicContextMenu)
                Toggle("Align the taskbar left", isOn: $draft.system.taskbarAlignLeft)
                Toggle("Remove Widgets", isOn: $draft.system.disableWidgets)
                Toggle("Turn off web results in Search", isOn: $draft.system.disableWebSearch)
            } header: {
                Text("Desktop defaults")
            } footer: {
                SectionCaption(
                    text: "Applied to the default user profile, so every account created afterwards inherits them."
                )
            }

            Section {
                Toggle("Turn off telemetry and diagnostic data", isOn: $draft.system.disableTelemetry)
                Toggle("Turn off consumer features and suggested apps", isOn: $draft.system.disableConsumerFeatures)
                Toggle("Remove preinstalled consumer apps", isOn: $draft.system.removeBloatware)
                if draft.system.removeBloatware {
                    BloatwareEditor(list: $draft.system.bloatwareList)
                }
            } header: {
                Text("Debloat")
            }

            Section {
                Picker("Windows Update", selection: $draft.system.windowsUpdate) {
                    ForEach(SystemSpec.UpdatePolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                Toggle("Install available updates during provisioning", isOn: $draft.system.installUpdatesDuringProvisioning)
                SectionCaption(
                    text: "Installing updates during provisioning can add half an hour or more, but the machine is fully patched when it's handed over."
                )
            } header: {
                Text("Updates")
            }

            Section {
                ForEach(SystemSpec.availableFeatures, id: \.id) { feature in
                    Toggle(feature.label, isOn: Binding(
                        get: { draft.system.optionalFeatures.contains(feature.id) },
                        set: { isOn in
                            if isOn {
                                if !draft.system.optionalFeatures.contains(feature.id) {
                                    draft.system.optionalFeatures.append(feature.id)
                                }
                            } else {
                                draft.system.optionalFeatures.removeAll { $0 == feature.id }
                            }
                        }
                    ))
                }
            } header: {
                Text("Optional Windows features")
            }

            Section {
                Picker("BitLocker", selection: $draft.system.bitLocker) {
                    ForEach(SystemSpec.BitLockerMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                if draft.system.bitLocker != .off {
                    Toggle(
                        "Back the recovery key up to Active Directory",
                        isOn: $draft.system.enableBitLockerRecoveryToAD
                    )
                    NoticeBanner(
                        kind: .warning,
                        title: "Keep the recovery key somewhere you can reach it",
                        messages: [
                            "Provisioning writes the recovery key to C:\\ImageHub\\logs so you can collect it before handover. Move it into your key escrow and delete the log."
                        ]
                    )
                }
            } header: {
                Text("Encryption")
            }

            Section {
                Toggle("Provision a Wi-Fi profile", isOn: $draft.system.wifi.enabled)
                if draft.system.wifi.enabled {
                    TextField("SSID", text: $draft.system.wifi.ssid)
                    Picker("Security", selection: $draft.system.wifi.security) {
                        Text("WPA2 Personal").tag("WPA2PSK")
                        Text("WPA3 Personal").tag("WPA3SAE")
                        Text("Open").tag("open")
                    }
                    if draft.system.wifi.security != "open" {
                        SecretPasswordField(
                            label: "Password",
                            templateID: draft.id,
                            slot: .wifiPassword
                        )
                    }
                    Toggle("Hidden network", isOn: $draft.system.wifi.hidden)
                    Toggle("Connect automatically", isOn: $draft.system.wifi.connectAutomatically)
                }
            } header: {
                Text("Wi-Fi")
            } footer: {
                SectionCaption(
                    text: "The profile is imported before apps install, so winget can reach the internet on a machine with no Ethernet."
                )
            }

            Section {
                TextField("Organisation name", text: $draft.system.organizationName)
                PathField(
                    label: "Logo",
                    path: $draft.system.logoPath,
                    prompt: "None",
                    types: [.image]
                )
                TextField("Support phone", text: $draft.system.supportPhone)
                TextField("Support URL", text: $draft.system.supportURL)
                SectionCaption(
                    text: "Written into Windows' OEM information, so it shows in Settings → About, and used on the setup screen below."
                )
            } header: {
                Text("Organisation")
            }

            Section {
                Toggle("Show a branded setup screen while provisioning", isOn: $draft.system.showProvisioningScreen)
                SectionCaption(
                    text: "Provisioning takes 10–40 minutes and otherwise runs in a bare PowerShell window. This replaces it with a full-screen screen showing your logo, the current step, and a progress bar. It runs as its own process, so it can't slow provisioning down or hang it."
                )
                if draft.system.showProvisioningScreen {
                    NoticeBanner(
                        kind: .info,
                        title: "What it can and can't cover",
                        messages: [
                            "This appears once Windows is installed and provisioning starts — the part someone actually sits and watches.",
                            "The earlier screens can't be branded from a Mac: the logo before Windows loads comes from the target machine's own firmware, and Windows Setup's UI isn't themable."
                        ]
                    )
                }
            } header: {
                Text("Setup screen")
            }

            Section {
                PathField(
                    label: "Desktop wallpaper",
                    path: $draft.system.wallpaperPath,
                    prompt: "Windows default",
                    types: [.image]
                )
                PathField(
                    label: "Lock screen",
                    path: $draft.system.lockScreenPath,
                    prompt: "Windows default",
                    types: [.image]
                )
                PathField(
                    label: "Start menu layout",
                    path: $draft.system.startLayoutPath,
                    prompt: "Windows default",
                    types: [.json]
                )
                SectionCaption(
                    text: "Export a Start layout on a reference machine with “Export-StartLayout -Path layout.json”."
                )
            } header: {
                Text("Branding")
            }

            Section {
                RegistryTweakEditor(tweaks: $draft.system.registryTweaks)
            } header: {
                Text("Registry")
            } footer: {
                SectionCaption(
                    text: "Applied with Set-ItemProperty during provisioning, after everything else. Use PowerShell paths (HKLM:\\…)."
                )
            }
        }
        .formStyle(.grouped)
    }
}

struct BloatwareEditor: View {
    @Binding var list: [String]
    @State private var newEntry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(list.count) packages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to defaults") {
                    list = SystemSpec.defaultBloatware
                }
                .controlSize(.small)
                .disabled(list == SystemSpec.defaultBloatware)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(list, id: \.self) { entry in
                        HStack {
                            Text(entry)
                                .font(.caption.monospaced())
                            Spacer()
                            Button {
                                list.removeAll { $0 == entry }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(6)
            }
            .frame(height: 130)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                TextField("Add an AppX package name", text: $newEntry)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let trimmed = newEntry.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, !list.contains(trimmed) else { return }
                    list.append(trimmed)
                    newEntry = ""
                }
                .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

struct RegistryTweakEditor: View {
    @Binding var tweaks: [RegistryTweak]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tweaks.isEmpty {
                Text("No registry changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($tweaks) { $tweak in
                    VStack(spacing: 5) {
                        HStack(spacing: 6) {
                            Toggle("", isOn: $tweak.enabled)
                                .labelsHidden()
                            TextField("HKLM:\\SOFTWARE\\…", text: $tweak.path)
                            Button {
                                tweaks.removeAll { $0.id == tweak.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        HStack(spacing: 6) {
                            TextField("Value name", text: $tweak.name)
                            Picker("", selection: $tweak.type) {
                                ForEach(RegistryTweak.ValueType.allCases) { type in
                                    Text(type.label).tag(type)
                                }
                            }
                            .frame(width: 120)
                            TextField("Data", text: $tweak.value)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(.vertical, 4)
                    Divider()
                }
            }

            Button {
                tweaks.append(RegistryTweak())
            } label: {
                Label("Add registry value", systemImage: "plus")
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Scripts

struct ScriptsTab: View {
    @Binding var draft: DeploymentTemplate
    @State private var selectedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Custom PowerShell")
                    .font(.headline)
                Spacer()
                Button {
                    var script = CustomScript()
                    script.name = "Script \(draft.scripts.count + 1)"
                    draft.scripts.append(script)
                    selectedID = script.id
                } label: {
                    Label("Add script", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if draft.scripts.isEmpty {
                EmptyStateView(
                    symbol: "terminal",
                    title: "No custom scripts",
                    message: "Drop in PowerShell for anything the template can't express — mapped drives, printers, line-of-business config, agent enrolment."
                )
                .frame(height: 240)
            } else {
                ForEach($draft.scripts) { $script in
                    ScriptCard(script: $script) {
                        draft.scripts.removeAll { $0.id == script.id }
                    }
                }
            }

            NoticeBanner(
                kind: .info,
                title: "How scripts run",
                messages: [
                    "Setup (specialize) runs before any user signs in, as SYSTEM, with no network guarantee.",
                    "Provisioning runs after apps and configuration, as the admin account.",
                    "Finalize runs last, just before the completion screen.",
                    "Everything is logged to C:\\ImageHub\\logs on the target machine."
                ]
            )
        }
    }
}

struct ScriptCard: View {
    @Binding var script: CustomScript
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: $script.enabled)
                    .labelsHidden()
                TextField("Name", text: $script.name)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $script.phase) {
                    ForEach(CustomScript.Phase.allCases) { phase in
                        Text(phase.label).tag(phase)
                    }
                }
                .frame(width: 170)
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            TextEditor(text: $script.body)
                .font(.system(size: 11).monospaced())
                .frame(height: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.12))
                )

            Toggle("Carry on if this script fails", isOn: $script.continueOnError)
                .font(.callout)
        }
        .opacity(script.enabled ? 1 : 0.55)
        .glassCard()
    }
}


/// Picks silent-install switches from named presets instead of asking the
/// operator to remember them.
///
/// The free-text field this replaces let a template ship `/S` to an installer
/// that wanted `--quiet`. The installer then showed a modal dialog and the whole
/// provisioning run stopped on it, which is a lot of consequence for a two-
/// character mistake with no feedback.
struct SilentSwitchField: View {
    @Binding var arguments: String
    let installerPath: String

    @State private var preset: SilentSwitchPreset = .none
    @State private var custom: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Silent install", selection: $preset) {
                ForEach(SilentSwitchPreset.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .onChange(of: preset) { _, new in
                if let args = new.arguments { arguments = args } else { arguments = custom }
            }

            if preset == .custom {
                TextField("Switches", text: $custom)
                    .autocorrectionDisabled()
                    .onChange(of: custom) { _, new in arguments = new }
            }

            HStack(spacing: 6) {
                Text(preset.detail)
                if !arguments.isEmpty {
                    Text(arguments)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: sync)
        .onChange(of: installerPath) { _, _ in
            // A newly chosen installer gets the guess for its file type, but only
            // when nothing has been set yet — never clobber a deliberate choice.
            guard arguments.isEmpty else { return }
            let ext = (installerPath as NSString).pathExtension
            preset = SilentSwitchPreset.suggested(forExtension: ext)
        }
    }

    private func sync() {
        preset = SilentSwitchPreset.matching(arguments)
        if preset == .custom { custom = arguments }
    }
}
