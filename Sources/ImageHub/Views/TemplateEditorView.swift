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

    /// Where a validation issue lives in this editor. The model deliberately
    /// names parts of the template rather than tabs, so the mapping is here.
    static func tab(for field: TemplateField) -> Tab {
        switch field {
        case .windows: return .windows
        case .disk: return .disk
        case .accounts: return .accounts
        case .apps: return .apps
        case .system: return .system
        case .firstBoot: return .oobe
        case .scripts: return .scripts
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
            CapsuleSegments(options: Self.segments, selection: $tab)
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
                // Default state is one read-only row and nothing to decide.
                // Which ISO to use is a per-build choice the build sheet already
                // makes; duplicating it here as an "Image source" picker was the
                // confusing part.
                LabeledContent("Windows image") {
                    Text(imageSummary)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                DisclosureGroup("Advanced") {
                    Toggle("Always build from one specific image", isOn: Binding(
                        get: { draft.windows.pinsLibraryImage },
                        set: { pin in
                            draft.windows.libraryImageID = pin
                                ? appState.library.images.first(where: { $0.fileExists })?.id
                                : nil
                        }
                    ))
                    if draft.windows.pinsLibraryImage {
                        Picker("Image", selection: Binding(
                            get: { draft.windows.libraryImageID },
                            set: { draft.windows.libraryImageID = $0 }
                        )) {
                            ForEach(appState.library.images) { image in
                                Text(image.displayName).tag(Optional(image.id))
                            }
                        }
                        SectionCaption(
                            text: "Every build of this template uses that exact ISO, so the result is byte-for-byte repeatable."
                        )
                    }

                    Divider()

                    PathField(
                        label: "Install a captured image",
                        path: $draft.windows.customWimPath,
                        prompt: "Use the one in the ISO",
                        types: [.wim, .data]
                    )
                    SectionCaption(
                        text: "The true golden-image route. Setup and the boot files still come from the ISO; only the installed OS comes from your image. Sysprep the reference machine with /generalize /oobe before capturing."
                    )

                    if draft.windows.usesCapturedImage {
                        LabeledContent("Image index") {
                            HStack(spacing: 6) {
                                TextField("Auto", text: Binding(
                                    get: { draft.windows.imageIndex.map(String.init) ?? "" },
                                    set: { draft.windows.imageIndex = Int($0) }
                                ))
                                .frame(width: 70)
                                Text("Only needed if your image uses custom edition names")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
                }
                if draft.windows.productKeyMode == .custom {
                    SecretPasswordField(
                        label: "Product key",
                        templateID: draft.id,
                        slot: .productKey,
                        footer: "Written into autounattend.xml at build time"
                    )
                }
                SectionCaption(text: draft.windows.productKeyMode.detail)
                Toggle("Accept the Windows licence terms automatically", isOn: $draft.windows.acceptEULA)
            } header: {
                Text("Licensing")
            }

            Section {
                Picker("Activate Windows", selection: $draft.windows.activation.mode) {
                    ForEach(WindowsSpec.ActivationSpec.Mode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                if draft.windows.activation.mode == .kms {
                    LabeledContent("KMS host") {
                        TextField("kms.example.com:1688", text: $draft.windows.activation.kmsHost)
                            .frame(maxWidth: 260)
                    }
                }
                SectionCaption(text: draft.windows.activation.mode.detail)
            } header: {
                Text("Activation")
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
                    SecretPasswordField(
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
                    SecretPasswordField(
                        label: "Password",
                        templateID: draft.id,
                        slot: .userPassword
                    )
                    Toggle("Administrator", isOn: $draft.endUser.administrator)
                    Toggle("Must change password at first sign-in", isOn: $draft.endUser.mustChangePassword)
                case .promptAtFirstBoot:
                    // These are the values the on-screen prompt opens with. The
                    // technician can change any of them; leaving them blank just
                    // means an empty dialog.
                    TextField("Suggested username", text: $draft.endUser.username)
                    TextField("Suggested display name", text: $draft.endUser.displayName)
                    Toggle("Administrator", isOn: $draft.endUser.administrator)
                    Toggle("Must change password at first sign-in", isOn: $draft.endUser.mustChangePassword)
                    LabeledContent("Give up after") {
                        HStack(spacing: 6) {
                            TextField("15", value: $draft.endUser.promptTimeoutMinutes, format: .number)
                                .frame(width: 60)
                            Text("minutes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    SectionCaption(
                        text: "Provisioning shows a dialog asking for the account details, prefilled with whatever you set above. If nobody answers within the time limit it carries on without creating the account and says so on the finish screen — it never waits indefinitely."
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
                    SecretPasswordField(
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
            if draft.issues.isEmpty {
                NoticeBanner(
                    kind: .success,
                    title: "This template is ready to build",
                    messages: []
                )
            } else {
                IssueBanner(
                    kind: .error,
                    title: "Fix before building — click one to go there",
                    issues: draft.issues,
                    destination: { Self.tab(for: $0.field).label },
                    action: { tab = Self.tab(for: $0.field) }
                )
            }

            if !draft.warnings.isEmpty {
                IssueBanner(
                    kind: .warning,
                    title: "Worth knowing",
                    issues: draft.warnings,
                    destination: { Self.tab(for: $0.field).label },
                    action: { tab = Self.tab(for: $0.field) }
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
            summaryRow("Image from", imageSummary)
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
            summaryRow("Licence", activationSummary)
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

    /// Key source plus what provisioning does about activation, because those two
    /// together decide whether the machine ends up wearing an "Activate Windows"
    /// watermark on someone's desk.
    private var activationSummary: String {
        let key: String
        switch draft.windows.productKeyMode {
        case .firmware: key = "The PC's built-in key"
        case .generic: key = "Generic KMS client key"
        case .custom: key = "A key of your own"
        case .none: key = "Setup asks for a key"
        }
        switch draft.windows.activation.mode {
        case .automatic: return "\(key) · activates during provisioning"
        case .kms:
            let host = draft.windows.activation.kmsHost.isEmpty
                ? "no host set" : draft.windows.activation.kmsHost
            return "\(key) · activates against \(host)"
        case .skip: return "\(key) · activation left alone"
        }
    }

    /// One line describing where the image comes from, for the header row and
    /// the Review tab.
    private var imageSummary: String {
        var parts: [String] = []
        if let id = draft.windows.libraryImageID,
           let pinned = appState.library.image(id: id) {
            parts.append(pinned.displayName)
        } else if draft.windows.pinsLibraryImage {
            parts.append("A pinned image that is no longer in the library")
        } else {
            parts.append("Chosen when you build")
        }
        if draft.windows.usesCapturedImage {
            parts.append("installing \((draft.windows.customWimPath as NSString).lastPathComponent)")
        }
        return parts.joined(separator: ", ")
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

    /// Explicitly typed: `CapsuleSegments` takes labelled tuples with an
    /// optional symbol, and a bare `.map` wouldn't convert to that.
    static let segments: [(value: Tab, label: String, symbol: String?)] =
        Tab.allCases.map { (value: $0, label: $0.label, symbol: Optional($0.symbol)) }

    static let symbolChoices = [
        "desktopcomputer", "laptopcomputer", "display", "pc",
        "building.2", "briefcase", "graduationcap", "cross.case",
        "wrench.and.screwdriver", "shield.lefthalf.filled", "person.2.badge.gearshape", "cube.box"
    ]
}
