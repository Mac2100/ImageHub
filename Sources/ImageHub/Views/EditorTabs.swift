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
            AppCatalogSheet { entries in
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
        app.silentArgs = url.pathExtension.lowercased() == "msi" ? "/qn /norestart" : "/S"
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

                Button {
                    onToggleExpand()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onToggleExpand)

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
                TextField("Silent switches", text: $app.silentArgs)
                Text("MSI usually takes “/qn /norestart”; most NSIS installers take “/S”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    let onAdd: ([AppCatalog.Entry]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selected: Set<String> = []

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

            List {
                ForEach(AppCatalog.categories, id: \.self) { category in
                    let entries = AppCatalog.search(search).filter { $0.category == category }
                    if !entries.isEmpty {
                        Section(category) {
                            ForEach(entries) { entry in
                                HStack(spacing: 10) {
                                    Toggle("", isOn: Binding(
                                        get: { selected.contains(entry.id) },
                                        set: { isOn in
                                            if isOn { selected.insert(entry.id) }
                                            else { selected.remove(entry.id) }
                                        }
                                    ))
                                    .labelsHidden()

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.name)
                                            .font(.callout)
                                        Text(entry.id)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if !entry.note.isEmpty {
                                        Text(entry.note)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

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
        .frame(width: 560, height: 520)
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
                        KeychainPasswordField(
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
