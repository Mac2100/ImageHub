import SwiftUI
import UniformTypeIdentifiers

struct TemplateEditorView: View {
    let template: DeploymentTemplate

    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    @State private var draft: DeploymentTemplate
    @State private var tab: Tab = .windows
    @State private var saveTask: Task<Void, Never>?
    @State private var lastSaved: Date?

    init(template: DeploymentTemplate) {
        self.template = template
        _draft = State(initialValue: template)
    }

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case windows, disk, accounts, apps, system, oobe, scripts, review
        var id: String { rawValue }

        var label: String {
            switch self {
            case .windows: return "Windows"
            case .disk: return "Disk"
            case .accounts: return "Accounts"
            case .apps: return "Apps"
            case .system: return "Configuration"
            case .oobe: return "First Boot"
            case .scripts: return "Scripts"
            case .review: return "Review"
            }
        }

        var symbol: String {
            switch self {
            case .windows: return "window.casement"
            case .disk: return "internaldrive"
            case .accounts: return "person.2"
            case .apps: return "shippingbox"
            case .system: return "slider.horizontal.3"
            case .oobe: return "sparkles"
            case .scripts: return "terminal"
            case .review: return "checkmark.seal"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()

            ScrollView {
                content
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
            }
        }
        .onChange(of: draft) { _, _ in scheduleSave() }
        .onDisappear { flushSave() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(Self.symbolChoices, id: \.self) { symbol in
                    Button {
                        draft.symbol = symbol
                    } label: {
                        Label(symbol, systemImage: symbol)
                    }
                }
            } label: {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(theme.gradient)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: draft.symbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                    }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change icon")

            VStack(alignment: .leading, spacing: 3) {
                TextField("Template name", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                TextField("One-line description", text: $draft.summary)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Button {
                    flushSave()
                    appState.startBuild(template: draft)
                } label: {
                    Label("Build USB…", systemImage: "externaldrive.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isBuildable || appState.isBuilding)
                .help(
                    draft.isBuildable
                        ? "Write this template to a USB drive"
                        : draft.validationErrors.joined(separator: "\n")
                )

                Text(savedLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var savedLabel: String {
        guard let lastSaved else { return "Saved automatically" }
        return "Saved \(lastSaved.formatted(date: .omitted, time: .standard))"
    }

    private var tabBar: some View {
        HStack {
            CapsuleSegments(
                options: Tab.allCases.map { ($0, $0.label, $0.symbol) },
                selection: $tab
            )
            Spacer()
            if !draft.isBuildable {
                Chip(
                    text: "\(draft.validationErrors.count) to fix",
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange
                )
                .onTapGesture { tab = .review }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .windows: windowsTab
        case .disk: diskTab
        case .accounts: accountsTab
        case .apps: AppsTab(draft: $draft)
        case .system: SystemTab(draft: $draft)
        case .oobe: oobeTab
        case .scripts: ScriptsTab(draft: $draft)
        case .review: reviewTab
        }
    }

    // MARK: - Windows

    private var windowsTab: some View {
        Form {
            Section {
                Picker("Release", selection: $draft.windows.release) {
                    ForEach(WindowsRelease.allCases) { release in
                        Text(release.label).tag(release)
                    }
                }
                Picker("Edition", selection: $draft.windows.edition) {
                    ForEach(WindowsEdition.allCases) { edition in
                        Text(edition.label).tag(edition)
                    }
                }
                Picker("Architecture", selection: $draft.windows.architecture) {
                    Text("x64 (Intel/AMD)").tag("x64")
                    Text("ARM64").tag("arm64")
                }
            } header: {
                Text("Product")
            } footer: {
                SectionCaption(
                    text: "Setup matches the edition by its image name inside install.wim. If your captured image uses custom names, set an explicit index below."
                )
            }

            Section {
                Picker("Image source", selection: $draft.windows.imageSource) {
                    ForEach(ImageSourceKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                SectionCaption(text: draft.windows.imageSource.help)

                switch draft.windows.imageSource {
                case .latestFromMicrosoft:
                    EmptyView()
                case .libraryImage:
                    Picker("Image", selection: Binding(
                        get: { draft.windows.libraryImageID },
                        set: { draft.windows.libraryImageID = $0 }
                    )) {
                        Text("Newest matching image").tag(UUID?.none)
                        ForEach(appState.library.images) { image in
                            Text(image.displayName).tag(Optional(image.id))
                        }
                    }
                case .customWim:
                    PathField(
                        label: "Captured image",
                        path: $draft.windows.customWimPath,
                        prompt: "Choose an install.wim or .esd",
                        types: [.wim, .data]
                    )
                    SectionCaption(
                        text: "ImageHub still boots Microsoft's Setup from the ISO; only the install image is replaced. Sysprep the reference machine with /generalize /oobe before capturing."
                    )
                }

                LabeledContent("Image index") {
                    HStack(spacing: 6) {
                        TextField(
                            "Auto",
                            value: Binding(
                                get: { draft.windows.imageIndex },
                                set: { draft.windows.imageIndex = $0 }
                            ),
                            format: .number
                        )
                        .frame(width: 70)
                        Text("Leave empty to match by edition name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Image")
            }

            Section {
                Picker("Product key", selection: $draft.windows.productKeyMode) {
                    ForEach(WindowsSpec.ProductKeyMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                if draft.windows.productKeyMode == .generic,
                   let key = draft.windows.edition.genericKey(for: draft.windows.release) {
                    LabeledContent("Key") {
                        Text(key)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    SectionCaption(
                        text: "Microsoft's public generic key for this edition. It selects the edition during Setup; activation still happens against your KMS host or MAK afterwards."
                    )
                }
                if draft.windows.productKeyMode == .custom {
                    KeychainPasswordField(
                        label: "Product key",
                        templateID: draft.id,
                        slot: .productKey,
                        footer: "Written into autounattend.xml at build time"
                    )
                }
                Toggle("Accept the Windows licence terms automatically", isOn: $draft.windows.acceptEULA)
            } header: {
                Text("Licensing")
            }

            Section {
                Picker("Display language", selection: Binding(
                    get: { draft.system.locale },
                    set: { newValue in
                        draft.system.locale = newValue
                        draft.system.inputLocale = WindowsLocales.input(for: newValue)
                        draft.windows.language = newValue
                    }
                )) {
                    ForEach(WindowsLocales.all, id: \.locale) { entry in
                        Text(entry.label).tag(entry.locale)
                    }
                }
                LabeledContent("Keyboard layout") {
                    TextField("0409:00000409", text: $draft.system.inputLocale)
                        .frame(width: 160)
                }
            } header: {
                Text("Language & input")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Disk

    private var diskTab: some View {
        Form {
            Section {
                Toggle("Wipe the target disk during Setup", isOn: $draft.disk.wipeTargetDisk)
                SectionCaption(
                    text: "This is what makes reimaging a used machine a single unattended step: Setup destroys the existing partition table before installing. Turn it off to install alongside what's already there (Setup will then ask where to install)."
                )
            } header: {
                Text("Wipe")
            }

            if draft.disk.wipeTargetDisk {
                Section {
                    Picker("Partition style", selection: $draft.disk.partitionStyle) {
                        ForEach(DiskSpec.PartitionStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    Stepper(value: $draft.disk.diskNumber, in: 0...15) {
                        LabeledContent("Target disk number", value: "Disk \(draft.disk.diskNumber)")
                    }
                    SectionCaption(
                        text: "Disk 0 is the machine's primary drive on almost every laptop and desktop. Change it only if the target has a layout you know differs."
                    )

                    if draft.disk.partitionStyle == .gpt {
                        Stepper(value: $draft.disk.efiSizeMB, in: 100...1024, step: 100) {
                            LabeledContent("EFI system partition", value: "\(draft.disk.efiSizeMB) MB")
                        }
                        Stepper(value: $draft.disk.msrSizeMB, in: 16...128, step: 16) {
                            LabeledContent("Microsoft reserved", value: "\(draft.disk.msrSizeMB) MB")
                        }
                    }

                    Toggle("Keep the Windows recovery environment", isOn: $draft.disk.recoveryPartition)
                    SectionCaption(
                        text: "Setup creates the WinRE partition itself. Unticking this runs “reagentc /disable” during provisioning to reclaim the space instead."
                    )
                } header: {
                    Text("Layout")
                }

                Section {
                    Toggle("Wipe every disk in the machine", isOn: $draft.disk.wipeAllDisks)
                    if draft.disk.wipeAllDisks {
                        NoticeBanner(
                            kind: .error,
                            title: "This destroys secondary drives too",
                            messages: [
                                "Every attached disk (0–3) is wiped, including data drives and external disks that happen to be plugged into the target machine."
                            ]
                        )
                    }
                } header: {
                    Text("Danger zone")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Accounts

    private var accountsTab: some View {
        Form {
            Section {
                Toggle("Create a local IT admin account", isOn: $draft.admin.enabled)
                if draft.admin.enabled {
                    TextField("Username", text: $draft.admin.username)
                    TextField("Display name", text: $draft.admin.displayName)
                    TextField("Description", text: $draft.admin.accountDescription)
                    KeychainPasswordField(
                        label: "Password",
                        templateID: draft.id,
                        slot: .adminPassword,
                        footer: "Required to build"
                    )
                    Stepper(value: $draft.admin.autoLogonCount, in: 0...9) {
                        LabeledContent(
                            "Automatic sign-ins",
                            value: draft.admin.autoLogonCount == 0
                                ? "Off" : "\(draft.admin.autoLogonCount)"
                        )
                    }
                    SectionCaption(
                        text: "Provisioning needs at least one automatic sign-in to run. Windows clears the auto-logon once the count is used up."
                    )
                    Toggle("Password never expires", isOn: $draft.admin.passwordNeverExpires)
                    Toggle("Hide from the sign-in screen after provisioning", isOn: $draft.admin.hideFromLoginScreen)
                    Toggle("Also enable the built-in Administrator account", isOn: $draft.admin.enableBuiltInAdministrator)
                }
            } header: {
                Text("IT admin profile")
            } footer: {
                SectionCaption(
                    text: "Passwords live in your macOS Keychain, never in the template JSON. They are written in clear text into the answer file on the USB stick at build time — that is how Windows Setup consumes them, so treat a built drive as a credential."
                )
            }

            Section {
                Picker("End-user setup", selection: $draft.endUser.mode) {
                    ForEach(EndUserSpec.Mode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                switch draft.endUser.mode {
                case .leaveOOBE:
                    SectionCaption(
                        text: "The machine finishes at the Windows welcome screen and whoever receives it creates their own account."
                    )
                case .createLocalAccount:
                    TextField("Username", text: $draft.endUser.username)
                    TextField("Display name", text: $draft.endUser.displayName)
                    KeychainPasswordField(
                        label: "Password",
                        templateID: draft.id,
                        slot: .userPassword
                    )
                    Toggle("Administrator", isOn: $draft.endUser.administrator)
                    Toggle("Must change password at first sign-in", isOn: $draft.endUser.mustChangePassword)
                case .promptAtFirstBoot:
                    SectionCaption(
                        text: "Provisioning pauses and asks the technician for a username and password, then creates the account. Useful when one template serves many people."
                    )
                }

                TextField(
                    "Note shown on the finish screen",
                    text: $draft.endUser.welcomeNote,
                    axis: .vertical
                )
                .lineLimit(2...4)
            } header: {
                Text("End user")
            }

            Section {
                Picker("Join", selection: $draft.identity.joinMode) {
                    ForEach(IdentitySpec.JoinMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                switch draft.identity.joinMode {
                case .workgroup:
                    TextField("Workgroup", text: $draft.identity.workgroup)
                case .activeDirectory:
                    TextField("Domain (corp.example.com)", text: $draft.identity.domain)
                    TextField("Computer OU (optional)", text: $draft.identity.organizationalUnit)
                    TextField("Join account", text: $draft.identity.domainJoinUser)
                    KeychainPasswordField(
                        label: "Join password",
                        templateID: draft.id,
                        slot: .domainPassword
                    )
                    SectionCaption(
                        text: "The machine joins during Setup's specialize pass, before first sign-in. It needs a working network connection at that point."
                    )
                case .entraAtOOBE:
                    SectionCaption(
                        text: "The device is left unjoined so it can enrol into Entra ID / Intune (or Autopilot) at the welcome screen."
                    )
                }
                LabeledContent("Computer name") {
                    TextField("IT-%SERIAL4%", text: $draft.system.computerNameTemplate)
                }
                SectionCaption(
                    text: "Tokens: %SERIAL% and %SERIAL4% (BIOS serial, full or last four), %MODEL%, %RANDOM4%, %TEMPLATE%."
                )
            } header: {
                Text("Identity")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - First boot

    private var oobeTab: some View {
        Form {
            Section {
                Toggle("Hide the licence terms page", isOn: $draft.oobe.hideEULA)
                Toggle("Hide OEM registration", isOn: $draft.oobe.hideOEMRegistration)
                Toggle("Hide Microsoft account screens", isOn: $draft.oobe.hideOnlineAccountScreens)
                Toggle("Hide wireless setup", isOn: $draft.oobe.hideWirelessSetup)
                Picker("Express settings", selection: $draft.oobe.protectYourPC) {
                    Text("Recommended settings").tag(1)
                    Text("Critical updates only").tag(3)
                }
            } header: {
                Text("Welcome screens")
            }

            Section {
                Toggle("Skip machine setup screens", isOn: $draft.oobe.skipMachineOOBE)
                Toggle("Skip user setup screens", isOn: $draft.oobe.skipUserOOBE)
                SectionCaption(
                    text: "Skipping user screens only makes sense when the template also creates an account — otherwise the machine boots to a sign-in screen with no usable user."
                )
                if draft.oobe.skipUserOOBE && draft.endUser.mode == .leaveOOBE && !draft.admin.enabled {
                    NoticeBanner(
                        kind: .warning,
                        title: "No account will exist",
                        messages: [
                            "User setup is skipped, no admin account is created, and no end-user account is pre-created."
                        ]
                    )
                }
            } header: {
                Text("Unattended")
            }

            Section {
                Toggle("Allow finishing setup without a network or Microsoft account", isOn: $draft.system.bypassNetworkRequirement)
                Toggle("Bypass the Windows 11 hardware checks", isOn: $draft.system.bypassWin11Requirements)
                if draft.system.bypassWin11Requirements {
                    NoticeBanner(
                        kind: .warning,
                        title: "Unsupported configuration",
                        messages: [
                            "Setting the LabConfig bypasses lets Windows 11 install without TPM 2.0, Secure Boot, or the CPU/RAM floor. Microsoft does not support the result, and future updates may refuse to install."
                        ]
                    )
                }
            } header: {
                Text("Requirement bypasses")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Review

    private var reviewTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            if draft.validationErrors.isEmpty {
                NoticeBanner(
                    kind: .success,
                    title: "This template is ready to build",
                    messages: []
                )
            } else {
                NoticeBanner(
                    kind: .error,
                    title: "Fix before building",
                    messages: draft.validationErrors
                )
            }

            if !draft.validationWarnings.isEmpty {
                NoticeBanner(
                    kind: .warning,
                    title: "Worth knowing",
                    messages: draft.validationWarnings
                )
            }

            summaryCard

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Generated answer file")
                        .font(.headline)
                    Spacer()
                    Button {
                        let xml = AnswerFileBuilder(
                            template: draft,
                            secrets: .init()
                        ).build()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(xml, forType: .string)
                        ToastCenter.shared.show("Copied autounattend.xml")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }
                Text("Passwords are shown as empty here — they're injected from the Keychain only when a drive is written.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(AnswerFileBuilder(template: draft, secrets: .init()).build())
                        .font(.system(size: 11).monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 260)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .glassCard()
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What this template does")
                .font(.headline)

            summaryRow("Installs", "\(draft.windows.release.label) \(draft.windows.edition.label) (\(draft.windows.architecture))")
            summaryRow("Image from", draft.windows.imageSource.label)
            summaryRow(
                "Target disk",
                draft.disk.wipeTargetDisk
                    ? "Wipes disk \(draft.disk.diskNumber) · \(draft.disk.partitionStyle.label)"
                    : "Leaves the existing partitions alone"
            )
            summaryRow(
                "Admin account",
                draft.admin.enabled ? "\(draft.admin.username) (Administrators)" : "None"
            )
            summaryRow("End user", draft.endUser.mode.label)
            summaryRow("Identity", identitySummary)
            summaryRow(
                "Applications",
                draft.enabledApps.isEmpty
                    ? "None"
                    : draft.enabledApps.map { $0.displayName }.joined(separator: ", ")
            )
            summaryRow("Time zone", draft.system.timeZone)
            if draft.system.removeBloatware {
                summaryRow("Removes", "\(draft.system.bloatwareList.count) preinstalled apps")
            }
            if !draft.system.optionalFeatures.isEmpty {
                summaryRow("Enables", draft.system.optionalFeatures.joined(separator: ", "))
            }
            if !draft.scripts.filter({ $0.enabled }).isEmpty {
                summaryRow(
                    "Custom scripts",
                    draft.scripts.filter { $0.enabled }.map { $0.name }.joined(separator: ", ")
                )
            }
        }
        .glassCard()
    }

    private var identitySummary: String {
        switch draft.identity.joinMode {
        case .workgroup: return "Workgroup \(draft.identity.workgroup)"
        case .activeDirectory:
            return draft.identity.domain.isEmpty ? "Domain join (not configured)" : "Joins \(draft.identity.domain)"
        case .entraAtOOBE: return "Left for Entra ID / Intune enrolment"
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .trailing)
            Text(value)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        persist()
    }

    private func persist() {
        guard draft != template || lastSaved == nil else { return }
        if appState.templates.save(draft) {
            lastSaved = Date()
        }
    }

    static let symbolChoices = [
        "desktopcomputer", "laptopcomputer", "display", "pc",
        "building.2", "briefcase", "graduationcap", "cross.case",
        "wrench.and.screwdriver", "shield.lefthalf.filled", "person.2.badge.gearshape", "cube.box"
    ]
}
