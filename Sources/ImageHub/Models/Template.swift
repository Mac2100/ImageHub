import Foundation

// MARK: - Lenient decoding

/// Templates are plain JSON files on disk that people are expected to hand-edit,
/// copy between Macs, and keep in git. Every field therefore decodes leniently:
/// a missing or malformed key falls back to its default instead of failing the
/// whole file, so a three-line template is as valid as a fully specified one.
extension KeyedDecodingContainer {
    func v<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)).flatMap { $0 } ?? fallback
    }

    func opt<T: Decodable>(_ key: Key, _ type: T.Type = T.self) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)).flatMap { $0 }
    }
}

// MARK: - Windows

enum WindowsRelease: String, Codable, CaseIterable, Identifiable, Hashable {
    case win11, win10
    var id: String { rawValue }

    var label: String {
        switch self {
        case .win11: return "Windows 11"
        case .win10: return "Windows 10"
        }
    }
}

enum WindowsEdition: String, Codable, CaseIterable, Identifiable, Hashable {
    case pro, proWorkstations, enterprise, education, proEducation, home

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pro: return "Pro"
        case .proWorkstations: return "Pro for Workstations"
        case .enterprise: return "Enterprise"
        case .education: return "Education"
        case .proEducation: return "Pro Education"
        case .home: return "Home"
        }
    }

    /// The `/IMAGE/NAME` value Windows Setup matches against inside install.wim.
    func imageName(for release: WindowsRelease) -> String {
        let product = release == .win11 ? "Windows 11" : "Windows 10"
        switch self {
        case .pro: return "\(product) Pro"
        case .proWorkstations: return "\(product) Pro for Workstations"
        case .enterprise: return "\(product) Enterprise"
        case .education: return "\(product) Education"
        case .proEducation: return "\(product) Pro Education"
        case .home: return "\(product) Home"
        }
    }

    /// Microsoft's publicly documented generic KMS client setup keys. These do
    /// not activate anything on their own — they only tell Setup which edition
    /// to install and let it reach the KMS host / MAK afterwards.
    func genericKey(for release: WindowsRelease) -> String? {
        switch self {
        case .pro: return "W269N-WFGWX-YVC9B-4J6C9-T83GX"
        case .proWorkstations: return "NRG8B-VKK3Q-CXVCJ-9G2XF-6Q84J"
        case .enterprise: return "NPPR9-FWDCX-D2C8J-H872K-2YT43"
        case .education: return "NW6C2-QMPVW-D7KKK-3GKT6-VCFB2"
        case .proEducation: return "6TP4R-GNPTD-KYYHQ-7B7DP-J447Y"
        case .home: return "TX9XD-98N7V-6WMQ6-BX7FG-H8Q99"
        }
    }
}

struct WindowsSpec: Codable, Equatable, Hashable {
    var release: WindowsRelease = .win11
    var edition: WindowsEdition = .pro
    var language: String = "en-US"
    var architecture: String = "x64"

    /// Pins the template to one ISO in the library. Nil means "ask at build
    /// time", which is what the build sheet already does.
    var libraryImageID: UUID?
    /// A sysprepped image installed instead of the one inside the ISO. Empty
    /// means use Microsoft's. Independent of `libraryImageID`: the ISO always
    /// supplies Setup and the boot files either way.
    var customWimPath: String = ""
    /// Overrides edition-name matching when a captured image uses custom names.
    var imageIndex: Int?

    /// True when the OS comes from a captured image rather than the ISO's.
    var usesCapturedImage: Bool { !customWimPath.isEmpty }
    /// True when this template always builds from one specific ISO.
    var pinsLibraryImage: Bool { libraryImageID != nil }

    /// Firmware by default: business-class PCs carry their Windows licence in an
    /// ACPI table, and writing *any* key into the answer file overrides it. That
    /// is how a machine that would have activated by itself ends up wearing an
    /// "Activate Windows" watermark — the generic key is a KMS client key and
    /// only activates against a KMS host.
    var productKeyMode: ProductKeyMode = .firmware
    var acceptEULA: Bool = true
    var activation: ActivationSpec = ActivationSpec()

    enum ProductKeyMode: String, Codable, CaseIterable, Identifiable, Hashable {
        // Declaration order is picker order, so the mode that needs no extra
        // infrastructure comes first and "no key at all" comes last.
        case firmware, generic, custom, none
        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "None (choose at Setup)"
            case .firmware: return "The PC's built-in key (OEM)"
            case .generic: return "Generic edition key (KMS)"
            case .custom: return "Specific key"
            }
        }

        var detail: String {
            switch self {
            case .none:
                return """
                    No key goes into the answer file and Setup asks for one. Only \
                    useful if a technician is standing there.
                    """
            case .firmware:
                return """
                    Nothing is written into the answer file, so Windows uses the OEM \
                    key in the PC's firmware or its digital licence and activates on \
                    its own. Right for machines that came with Windows preinstalled. \
                    The edition is still pinned by image name, not by the key.
                    """
            case .generic:
                return """
                    Microsoft's public KMS client key for this edition. It selects the \
                    edition during Setup but never activates by itself — without a \
                    reachable KMS host the machine shows "Activate Windows".
                    """
            case .custom:
                return """
                    A MAK or retail key of your own, written into the answer file. \
                    These activate over the internet without a KMS host.
                    """
            }
        }

        /// True when this mode puts a key in the answer file that will not
        /// activate unless something else is configured.
        var needsKMSHost: Bool { self == .generic }
    }

    /// What provisioning does about activation once Windows is up. Separate from
    /// the key: a firmware key needs a nudge on some machines, and a KMS client
    /// key needs to be told where the host is.
    struct ActivationSpec: Codable, Equatable, Hashable {
        var mode: Mode = .automatic
        var kmsHost: String = ""

        enum Mode: String, Codable, CaseIterable, Identifiable, Hashable {
            case automatic, kms, skip
            var id: String { rawValue }

            var label: String {
                switch self {
                case .automatic: return "Automatic"
                case .kms: return "Against a KMS host"
                case .skip: return "Leave it alone"
                }
            }

            var detail: String {
                switch self {
                case .automatic:
                    return """
                        Installs the OEM key from the PC's firmware if there is one, \
                        then activates online. Clears the "Activate Windows" watermark \
                        without anyone touching Settings.
                        """
                case .kms:
                    return "Points the machine at your KMS host and activates against it."
                case .skip:
                    return "Provisioning does not touch activation."
                }
            }
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = c.v(.mode, Mode.automatic)
            kmsHost = c.v(.kmsHost, "")
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        release = c.v(.release, WindowsRelease.win11)
        edition = c.v(.edition, WindowsEdition.pro)
        language = c.v(.language, "en-US")
        architecture = c.v(.architecture, "x64")
        libraryImageID = c.opt(.libraryImageID)
        customWimPath = c.v(.customWimPath, "")
        imageIndex = c.opt(.imageIndex)
        // Templates written before activation was configurable have no key mode
        // recorded only if they predate it entirely; those get .firmware, which is
        // the behaviour they most likely wanted. An explicitly saved .generic is
        // preserved and flagged in Review instead of being changed underneath the
        // operator.
        productKeyMode = c.v(.productKeyMode, ProductKeyMode.firmware)
        acceptEULA = c.v(.acceptEULA, true)
        activation = c.v(.activation, ActivationSpec())
    }
}

// MARK: - Disk

struct DiskSpec: Codable, Equatable, Hashable {
    /// When true the answer file wipes the target disk before installing — this
    /// is what makes "wipe an existing computer" a single unattended step.
    var wipeTargetDisk: Bool = true
    var diskNumber: Int = 0
    var partitionStyle: PartitionStyle = .gpt
    var efiSizeMB: Int = 300
    var msrSizeMB: Int = 16
    var recoveryPartition: Bool = true
    var recoverySizeMB: Int = 1000
    /// Wipe every attached disk, not just `diskNumber`. Off by default because
    /// it destroys secondary data drives too.
    var wipeAllDisks: Bool = false

    enum PartitionStyle: String, Codable, CaseIterable, Identifiable, Hashable {
        case gpt, mbr
        var id: String { rawValue }
        var label: String { self == .gpt ? "GPT (UEFI)" : "MBR (Legacy BIOS)" }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wipeTargetDisk = c.v(.wipeTargetDisk, true)
        diskNumber = c.v(.diskNumber, 0)
        partitionStyle = c.v(.partitionStyle, PartitionStyle.gpt)
        efiSizeMB = c.v(.efiSizeMB, 300)
        msrSizeMB = c.v(.msrSizeMB, 16)
        recoveryPartition = c.v(.recoveryPartition, true)
        recoverySizeMB = c.v(.recoverySizeMB, 1000)
        wipeAllDisks = c.v(.wipeAllDisks, false)
    }
}

// MARK: - Accounts

struct AdminSpec: Codable, Equatable, Hashable {
    var enabled: Bool = true
    var username: String = "ITAdmin"
    var displayName: String = "IT Administrator"
    var accountDescription: String = "Managed by IT — do not remove"
    var autoLogonCount: Int = 1
    var passwordNeverExpires: Bool = true
    /// Hides the admin account from the sign-in screen once end-user setup is done.
    var hideFromLoginScreen: Bool = false
    /// Enables the built-in `Administrator` account as well (usually unnecessary).
    var enableBuiltInAdministrator: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.v(.enabled, true)
        username = c.v(.username, "ITAdmin")
        displayName = c.v(.displayName, "IT Administrator")
        accountDescription = c.v(.accountDescription, "Managed by IT — do not remove")
        autoLogonCount = c.v(.autoLogonCount, 1)
        passwordNeverExpires = c.v(.passwordNeverExpires, true)
        hideFromLoginScreen = c.v(.hideFromLoginScreen, false)
        enableBuiltInAdministrator = c.v(.enableBuiltInAdministrator, false)
    }
}

struct EndUserSpec: Codable, Equatable, Hashable {
    var mode: Mode = .leaveOOBE
    var username: String = ""
    var displayName: String = ""
    var administrator: Bool = false
    var mustChangePassword: Bool = true
    /// Shown on first boot so whoever receives the machine knows what to do.
    var welcomeNote: String = ""
    /// How long the first-boot prompt waits before giving up and letting
    /// provisioning finish. Never unbounded: a dialog nobody answers used to
    /// stop the whole run indefinitely.
    var promptTimeoutMinutes: Int = 15

    enum Mode: String, Codable, CaseIterable, Identifiable, Hashable {
        /// Let the person who receives the machine complete Windows OOBE themselves.
        case leaveOOBE
        /// Pre-create a named local account from the template.
        case createLocalAccount
        /// Pause at a small ImageHub prompt on first boot and create the account
        /// from whatever the technician types.
        case promptAtFirstBoot

        var id: String { rawValue }

        var label: String {
            switch self {
            case .leaveOOBE: return "Leave Windows OOBE to the user"
            case .createLocalAccount: return "Pre-create a local account"
            case .promptAtFirstBoot: return "Prompt the technician on first boot"
            }
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.v(.mode, Mode.leaveOOBE)
        username = c.v(.username, "")
        displayName = c.v(.displayName, "")
        administrator = c.v(.administrator, false)
        mustChangePassword = c.v(.mustChangePassword, true)
        welcomeNote = c.v(.welcomeNote, "")
        promptTimeoutMinutes = max(1, c.v(.promptTimeoutMinutes, 15))
    }
}

// MARK: - Identity

struct IdentitySpec: Codable, Equatable, Hashable {
    var joinMode: JoinMode = .workgroup
    var workgroup: String = "WORKGROUP"
    var domain: String = ""
    var organizationalUnit: String = ""
    var domainJoinUser: String = ""

    enum JoinMode: String, Codable, CaseIterable, Identifiable, Hashable {
        case workgroup
        case activeDirectory
        /// Leave the device unjoined so Entra ID / Intune enrolment happens at OOBE.
        case entraAtOOBE

        var id: String { rawValue }

        var label: String {
            switch self {
            case .workgroup: return "Workgroup"
            case .activeDirectory: return "Active Directory domain"
            case .entraAtOOBE: return "Entra ID / Intune at OOBE"
            }
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        joinMode = c.v(.joinMode, JoinMode.workgroup)
        workgroup = c.v(.workgroup, "WORKGROUP")
        domain = c.v(.domain, "")
        organizationalUnit = c.v(.organizationalUnit, "")
        domainJoinUser = c.v(.domainJoinUser, "")
    }
}

// MARK: - Applications

struct AppSelection: Codable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var source: Source = .winget
    /// winget package identifier, e.g. `Google.Chrome`.
    var packageID: String = ""
    /// Empty means "latest".
    var version: String = ""
    /// For `.installer`: a file on this Mac that gets copied into the payload.
    var installerPath: String = ""
    /// Silent switches for `.installer`, e.g. `/qn /norestart`.
    var silentArgs: String = ""
    /// For `.script`: inline PowerShell run during provisioning.
    var script: String = ""
    var enabled: Bool = true
    /// Fail the whole provisioning run if this app doesn't install.
    var required: Bool = false
    var notes: String = ""

    enum Source: String, Codable, CaseIterable, Identifiable, Hashable {
        case winget
        case installer
        case script

        var id: String { rawValue }

        var label: String {
            switch self {
            case .winget: return "winget"
            case .installer: return "Bundled installer"
            case .script: return "PowerShell"
            }
        }

        var symbol: String {
            switch self {
            case .winget: return "shippingbox"
            case .installer: return "arrow.down.app"
            case .script: return "terminal"
            }
        }
    }

    init() {}

    init(name: String, packageID: String, notes: String = "") {
        self.name = name
        self.packageID = packageID
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, UUID())
        name = c.v(.name, "")
        source = c.v(.source, Source.winget)
        packageID = c.v(.packageID, "")
        version = c.v(.version, "")
        installerPath = c.v(.installerPath, "")
        silentArgs = c.v(.silentArgs, "")
        script = c.v(.script, "")
        enabled = c.v(.enabled, true)
        required = c.v(.required, false)
        notes = c.v(.notes, "")
    }

    var displayName: String {
        if !name.isEmpty { return name }
        if !packageID.isEmpty { return packageID }
        if !installerPath.isEmpty { return (installerPath as NSString).lastPathComponent }
        return "Untitled app"
    }

    /// Whether this entry has enough information to do anything on the target.
    var isActionable: Bool {
        switch source {
        case .winget: return !packageID.isEmpty
        case .installer: return !installerPath.isEmpty
        case .script: return !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

// MARK: - System configuration

struct RegistryTweak: Codable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    var path: String = "HKLM:\\SOFTWARE\\"
    var name: String = ""
    var type: ValueType = .dword
    var value: String = ""
    var enabled: Bool = true

    enum ValueType: String, Codable, CaseIterable, Identifiable, Hashable {
        case dword = "DWord"
        case qword = "QWord"
        case string = "String"
        case expandString = "ExpandString"
        case multiString = "MultiString"

        var id: String { rawValue }
        var label: String { rawValue }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, UUID())
        path = c.v(.path, "HKLM:\\SOFTWARE\\")
        name = c.v(.name, "")
        type = c.v(.type, ValueType.dword)
        value = c.v(.value, "")
        enabled = c.v(.enabled, true)
    }
}

struct WifiSpec: Codable, Equatable, Hashable {
    var enabled: Bool = false
    var ssid: String = ""
    var hidden: Bool = false
    /// `WPA2PSK` / `WPA3SAE` / `open`
    var security: String = "WPA2PSK"
    var connectAutomatically: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.v(.enabled, false)
        ssid = c.v(.ssid, "")
        hidden = c.v(.hidden, false)
        security = c.v(.security, "WPA2PSK")
        connectAutomatically = c.v(.connectAutomatically, true)
    }
}

struct SystemSpec: Codable, Equatable, Hashable {
    /// Tokens: `%SERIAL%`, `%SERIAL4%`, `%RANDOM4%`, `%MODEL%`, `%TEMPLATE%`.
    var computerNameTemplate: String = "IT-%SERIAL4%"
    var timeZone: String = "Pacific Standard Time"
    var locale: String = "en-US"
    var inputLocale: String = "0409:00000409"

    var enableRemoteDesktop: Bool = false
    var allowPing: Bool = false
    var powerPlan: PowerPlan = .balanced
    var disableSleepOnAC: Bool = true
    var disableFastStartup: Bool = false
    var disableHibernation: Bool = false

    var showFileExtensions: Bool = true
    var showHiddenFiles: Bool = false
    var classicContextMenu: Bool = false
    var taskbarAlignLeft: Bool = false
    var disableWidgets: Bool = false
    var disableWebSearch: Bool = false

    var disableTelemetry: Bool = true
    var disableConsumerFeatures: Bool = true
    var removeBloatware: Bool = true
    var bloatwareList: [String] = SystemSpec.defaultBloatware

    var windowsUpdate: UpdatePolicy = .automatic
    var installUpdatesDuringProvisioning: Bool = false
    var optionalFeatures: [String] = []

    var bitLocker: BitLockerMode = .off
    var enableBitLockerRecoveryToAD: Bool = false

    var wifi: WifiSpec = WifiSpec()
    var registryTweaks: [RegistryTweak] = []

    /// Files on this Mac copied into the payload and applied on first boot.
    var wallpaperPath: String = ""
    var lockScreenPath: String = ""
    var startLayoutPath: String = ""

    // MARK: Branding
    /// Shown on the provisioning screen and written into Windows' OEM
    /// information, which surfaces in Settings → About.
    var organizationName: String = ""
    var logoPath: String = ""

    var supportPhone: String = ""
    var supportURL: String = ""
    /// Replaces the bare PowerShell console during provisioning with a
    /// full-screen branded progress window.
    var showProvisioningScreen: Bool = true

    /// Skips the TPM 2.0 / Secure Boot / RAM / CPU checks so Windows 11 installs
    /// on older fleet hardware.
    var bypassWin11Requirements: Bool = false
    /// Allows finishing OOBE without a network / Microsoft account.
    var bypassNetworkRequirement: Bool = true

    enum PowerPlan: String, Codable, CaseIterable, Identifiable, Hashable {
        case balanced, highPerformance, powerSaver
        var id: String { rawValue }

        var label: String {
            switch self {
            case .balanced: return "Balanced"
            case .highPerformance: return "High performance"
            case .powerSaver: return "Power saver"
            }
        }

        /// Built-in Windows power scheme GUIDs.
        var guid: String {
            switch self {
            case .balanced: return "381b4222-f694-41f0-9685-ff5bb260df2e"
            case .highPerformance: return "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
            case .powerSaver: return "a1841308-3541-4fab-bc81-f71556f20b4a"
            }
        }
    }

    enum UpdatePolicy: String, Codable, CaseIterable, Identifiable, Hashable {
        case automatic, notifyBeforeDownload, disableAutomaticRestart
        var id: String { rawValue }

        var label: String {
            switch self {
            case .automatic: return "Install automatically"
            case .notifyBeforeDownload: return "Notify before download"
            case .disableAutomaticRestart: return "Auto-install, never auto-restart"
            }
        }
    }

    enum BitLockerMode: String, Codable, CaseIterable, Identifiable, Hashable {
        case off, tpmOnly, tpmWithPin
        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: return "Off"
            case .tpmOnly: return "Enable (TPM only)"
            case .tpmWithPin: return "Enable (TPM + PIN)"
            }
        }
    }

    static let defaultBloatware: [String] = [
        "Microsoft.549981C3F5F10",
        "Microsoft.BingNews",
        "Microsoft.BingWeather",
        "Microsoft.GamingApp",
        "Microsoft.GetHelp",
        "Microsoft.Getstarted",
        "Microsoft.MicrosoftOfficeHub",
        "Microsoft.MicrosoftSolitaireCollection",
        "Microsoft.MixedReality.Portal",
        "Microsoft.People",
        "Microsoft.SkypeApp",
        "Microsoft.Todos",
        "Microsoft.WindowsFeedbackHub",
        "Microsoft.WindowsMaps",
        "Microsoft.Xbox.TCUI",
        "Microsoft.XboxGameOverlay",
        "Microsoft.XboxGamingOverlay",
        "Microsoft.XboxSpeechToTextOverlay",
        "Microsoft.ZuneMusic",
        "Microsoft.ZuneVideo",
        "MicrosoftTeams",
        "Clipchamp.Clipchamp"
    ]

    /// Optional Windows features offered in the editor, keyed by DISM name.
    static let availableFeatures: [(id: String, label: String)] = [
        ("NetFx3", ".NET Framework 3.5"),
        ("Microsoft-Hyper-V-All", "Hyper-V"),
        ("Microsoft-Windows-Subsystem-Linux", "WSL"),
        ("VirtualMachinePlatform", "Virtual Machine Platform"),
        ("TelnetClient", "Telnet Client"),
        ("TFTP", "TFTP Client"),
        ("Client-ProjFS", "Windows Projected File System"),
        ("Microsoft-Windows-Client-EmbeddedExp-Package", "Shell Launcher")
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        computerNameTemplate = c.v(.computerNameTemplate, "IT-%SERIAL4%")
        timeZone = c.v(.timeZone, "Pacific Standard Time")
        locale = c.v(.locale, "en-US")
        inputLocale = c.v(.inputLocale, "0409:00000409")
        enableRemoteDesktop = c.v(.enableRemoteDesktop, false)
        allowPing = c.v(.allowPing, false)
        powerPlan = c.v(.powerPlan, PowerPlan.balanced)
        disableSleepOnAC = c.v(.disableSleepOnAC, true)
        disableFastStartup = c.v(.disableFastStartup, false)
        disableHibernation = c.v(.disableHibernation, false)
        showFileExtensions = c.v(.showFileExtensions, true)
        showHiddenFiles = c.v(.showHiddenFiles, false)
        classicContextMenu = c.v(.classicContextMenu, false)
        taskbarAlignLeft = c.v(.taskbarAlignLeft, false)
        disableWidgets = c.v(.disableWidgets, false)
        disableWebSearch = c.v(.disableWebSearch, false)
        disableTelemetry = c.v(.disableTelemetry, true)
        disableConsumerFeatures = c.v(.disableConsumerFeatures, true)
        removeBloatware = c.v(.removeBloatware, true)
        bloatwareList = c.v(.bloatwareList, SystemSpec.defaultBloatware)
        windowsUpdate = c.v(.windowsUpdate, UpdatePolicy.automatic)
        installUpdatesDuringProvisioning = c.v(.installUpdatesDuringProvisioning, false)
        optionalFeatures = c.v(.optionalFeatures, [])
        bitLocker = c.v(.bitLocker, BitLockerMode.off)
        enableBitLockerRecoveryToAD = c.v(.enableBitLockerRecoveryToAD, false)
        wifi = c.v(.wifi, WifiSpec())
        registryTweaks = c.v(.registryTweaks, [])
        wallpaperPath = c.v(.wallpaperPath, "")
        lockScreenPath = c.v(.lockScreenPath, "")
        startLayoutPath = c.v(.startLayoutPath, "")
        organizationName = c.v(.organizationName, "")
        logoPath = c.v(.logoPath, "")
        supportPhone = c.v(.supportPhone, "")
        supportURL = c.v(.supportURL, "")
        showProvisioningScreen = c.v(.showProvisioningScreen, true)
        bypassWin11Requirements = c.v(.bypassWin11Requirements, false)
        bypassNetworkRequirement = c.v(.bypassNetworkRequirement, true)
    }
}

// MARK: - OOBE

struct OOBESpec: Codable, Equatable, Hashable {
    var hideEULA: Bool = true
    var hideOEMRegistration: Bool = true
    var hideOnlineAccountScreens: Bool = true
    var hideWirelessSetup: Bool = false
    var skipMachineOOBE: Bool = true
    var skipUserOOBE: Bool = false
    /// 1 = recommended settings, 3 = only critical updates.
    var protectYourPC: Int = 3

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hideEULA = c.v(.hideEULA, true)
        hideOEMRegistration = c.v(.hideOEMRegistration, true)
        hideOnlineAccountScreens = c.v(.hideOnlineAccountScreens, true)
        hideWirelessSetup = c.v(.hideWirelessSetup, false)
        skipMachineOOBE = c.v(.skipMachineOOBE, true)
        skipUserOOBE = c.v(.skipUserOOBE, false)
        protectYourPC = c.v(.protectYourPC, 3)
    }
}

// MARK: - Custom scripts

struct CustomScript: Codable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String = "New script"
    var phase: Phase = .provision
    var body: String = ""
    var enabled: Bool = true
    var continueOnError: Bool = true

    enum Phase: String, Codable, CaseIterable, Identifiable, Hashable {
        /// Runs inside Windows Setup's `specialize` pass, before first logon.
        case specialize
        /// Runs during ImageHub provisioning, after apps and config.
        case provision
        /// Runs at the very end, right before the completion screen.
        case finalize

        var id: String { rawValue }

        var label: String {
            switch self {
            case .specialize: return "Setup (specialize)"
            case .provision: return "Provisioning"
            case .finalize: return "Finalize"
            }
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, UUID())
        name = c.v(.name, "New script")
        phase = c.v(.phase, Phase.provision)
        body = c.v(.body, "")
        enabled = c.v(.enabled, true)
        continueOnError = c.v(.continueOnError, true)
    }
}

// MARK: - Validation

/// Which part of a template an issue belongs to, so the editor can jump there.
/// Named for the model rather than the UI's tabs — the editor does the mapping.
enum TemplateField: String, Hashable {
    case windows, disk, accounts, apps, system, firstBoot, scripts
}

/// One problem with a template, and where in the editor to fix it.
///
/// `issues` is recomputed on every view update, so the identity has to come from
/// the contents rather than a fresh UUID — otherwise `ForEach` treats every row
/// as new each time and the list flickers.
/// Ready-made silent-install switches, because the difference between `/S` and
/// `--quiet` is the difference between an unattended install and a provisioning
/// run stopped dead on a modal dialog — which is exactly what a real build hit
/// when Sophos answered `/S` with "Non-option passed: /S".
enum SilentSwitchPreset: String, CaseIterable, Identifiable, Codable {
    case msi
    case nsis
    case inno
    case installShield
    case sophos
    case quietDouble
    case silentSingle
    case none
    case custom

    var id: String { rawValue }

    /// The switches themselves. `nil` means "leave it to the operator".
    var arguments: String? {
        switch self {
        case .msi: return "/qn /norestart"
        case .nsis: return "/S"
        case .inno: return "/VERYSILENT /NORESTART"
        case .installShield: return #"/s /v"/qn""#
        case .sophos: return "--quiet"
        case .quietDouble: return "--quiet"
        case .silentSingle: return "/silent"
        case .none: return ""
        case .custom: return nil
        }
    }

    var label: String {
        switch self {
        case .msi: return "MSI installer"
        case .nsis: return "NSIS installer"
        case .inno: return "Inno Setup"
        case .installShield: return "InstallShield"
        case .sophos: return "Sophos"
        case .quietDouble: return "Modern CLI (--quiet)"
        case .silentSingle: return "Legacy (/silent)"
        case .none: return "No switches"
        case .custom: return "Custom…"
        }
    }

    var detail: String {
        switch self {
        case .msi: return "/qn /norestart — msiexec's own silent flags."
        case .nsis: return "/S — Nullsoft. Common for small open-source tools."
        case .inno: return "/VERYSILENT /NORESTART — Inno Setup, no progress window."
        case .installShield: return #"/s /v"/qn" — InstallShield wrapping an MSI."#
        case .sophos: return "--quiet — what Sophos Endpoint expects; it rejects /S."
        case .quietDouble: return "--quiet — most installers built on modern CLI conventions."
        case .silentSingle: return "/silent — older InstallShield and some vendor stubs."
        case .none: return "Runs the installer as-is. It will show its own UI."
        case .custom: return "Type the switches yourself."
        }
    }

    /// Which preset a given argument string corresponds to, for showing the
    /// current value in a picker.
    static func matching(_ arguments: String) -> SilentSwitchPreset {
        let trimmed = arguments.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .none }
        for preset in allCases where preset != .custom && preset != .none {
            if preset.arguments == trimmed { return preset }
        }
        return .custom
    }

    /// Best guess from the installer's file extension.
    static func suggested(forExtension ext: String) -> SilentSwitchPreset {
        ext.lowercased() == "msi" ? .msi : .nsis
    }
}

struct ValidationIssue: Identifiable, Hashable {
    let message: String
    let field: TemplateField

    var id: String { "\(field.rawValue)|\(message)" }
}

// MARK: - Template

struct DeploymentTemplate: Codable, Equatable, Hashable, Identifiable {
    /// Bumped when the on-disk shape changes in a way readers must know about.
    static let currentSchemaVersion = 1

    var schemaVersion: Int = DeploymentTemplate.currentSchemaVersion
    var id: UUID = UUID()
    var name: String = "New Template"
    var summary: String = ""
    var symbol: String = "desktopcomputer"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var windows: WindowsSpec = WindowsSpec()
    var disk: DiskSpec = DiskSpec()
    var admin: AdminSpec = AdminSpec()
    var endUser: EndUserSpec = EndUserSpec()
    var identity: IdentitySpec = IdentitySpec()
    var apps: [AppSelection] = []
    var system: SystemSpec = SystemSpec()
    var oobe: OOBESpec = OOBESpec()
    var scripts: [CustomScript] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.v(.schemaVersion, DeploymentTemplate.currentSchemaVersion)
        id = c.v(.id, UUID())
        name = c.v(.name, "New Template")
        summary = c.v(.summary, "")
        symbol = c.v(.symbol, "desktopcomputer")
        createdAt = c.v(.createdAt, Date())
        updatedAt = c.v(.updatedAt, Date())
        windows = c.v(.windows, WindowsSpec())
        disk = c.v(.disk, DiskSpec())
        admin = c.v(.admin, AdminSpec())
        endUser = c.v(.endUser, EndUserSpec())
        identity = c.v(.identity, IdentitySpec())
        // Templates keep the package ID they were created with, so a catalog
        // correction has to be applied on the way in or it never reaches them.
        apps = c.v(.apps, []).map(AppCatalog.correctingRenames)
        system = c.v(.system, SystemSpec())
        oobe = c.v(.oobe, OOBESpec())
        scripts = c.v(.scripts, [])
    }

    var enabledApps: [AppSelection] {
        apps.filter { $0.enabled && $0.isActionable }
    }

    /// Human-readable one-liner used in lists and the build wizard.
    var subtitle: String {
        var parts: [String] = ["\(windows.release.label) \(windows.edition.label)"]
        let count = enabledApps.count
        if count > 0 { parts.append("\(count) app\(count == 1 ? "" : "s")") }
        switch identity.joinMode {
        case .activeDirectory where !identity.domain.isEmpty:
            parts.append(identity.domain)
        case .entraAtOOBE:
            parts.append("Entra ID")
        default:
            break
        }
        return parts.joined(separator: " · ")
    }

    /// Blocking problems that must be fixed before a drive can be built.
    /// Each carries the part of the template it came from so the Review tab can
    /// take you straight there.
    var issues: [ValidationIssue] {
        var found: [ValidationIssue] = []
        func add(_ message: String, _ field: TemplateField) {
            found.append(ValidationIssue(message: message, field: field))
        }

        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            add("Template needs a name.", .windows)
        }
        if admin.enabled {
            if admin.username.trimmingCharacters(in: .whitespaces).isEmpty {
                add("Admin account is enabled but has no username.", .accounts)
            }
            if !SecretStore.has(id, slot: .adminPassword) {
                add("Admin account has no password set.", .accounts)
            }
        }
        if windows.usesCapturedImage,
           !FileManager.default.fileExists(atPath: windows.customWimPath) {
            add("The captured image this template points at is missing.", .windows)
        }
        if windows.productKeyMode == .custom && !SecretStore.has(id, slot: .productKey) {
            add("Product key mode is “Specific key” but no key is stored.", .windows)
        }
        // The pairing that leaves a technician activating by hand in Settings: a
        // KMS client key installed with nothing to activate against. Worth saying
        // out loud, because the machine images and boots perfectly and only shows
        // its watermark once it is on someone's desk.
        if windows.productKeyMode.needsKMSHost && windows.activation.mode != .kms {
            add(
                "The generic key is a KMS client key and never activates on its own — "
                    + "Windows will show “Activate Windows”. Use the PC's built-in key, "
                    + "or point Activation at a KMS host.",
                .windows
            )
        }
        if windows.activation.mode == .kms
            && windows.activation.kmsHost.trimmingCharacters(in: .whitespaces).isEmpty {
            add("Activation is set to use a KMS host but no host is set.", .windows)
        }
        if endUser.mode == .createLocalAccount {
            if endUser.username.trimmingCharacters(in: .whitespaces).isEmpty {
                add("End-user account is enabled but has no username.", .accounts)
            }
            if endUser.username.lowercased() == admin.username.lowercased() {
                add("End-user account cannot reuse the admin username.", .accounts)
            }
        }
        if identity.joinMode == .activeDirectory {
            if identity.domain.isEmpty {
                add("Domain join is selected but no domain is set.", .accounts)
            }
            if identity.domainJoinUser.isEmpty || !SecretStore.has(id, slot: .domainPassword) {
                add("Domain join needs a username and password.", .accounts)
            }
        }
        if system.wifi.enabled && system.wifi.ssid.isEmpty {
            add("Wi-Fi provisioning is on but no SSID is set.", .system)
        }
        for (label, path) in [
            ("Logo", system.logoPath),
            ("Wallpaper", system.wallpaperPath),
            ("Lock screen", system.lockScreenPath),
            ("Start layout", system.startLayoutPath)
        ] where !path.isEmpty && !FileManager.default.fileExists(atPath: path) {
            add("\(label) image is missing: \((path as NSString).lastPathComponent)", .system)
        }
        for app in apps where app.enabled && !app.isActionable {
            add("“\(app.displayName)” is enabled but incomplete.", .apps)
        }
        return found
    }

    /// Non-blocking things worth telling the operator about.
    var warnings: [ValidationIssue] {
        var found: [ValidationIssue] = []
        func add(_ message: String, _ field: TemplateField) {
            found.append(ValidationIssue(message: message, field: field))
        }

        if disk.wipeAllDisks {
            add(
                "This template wipes every disk in the target machine, including secondary data drives.",
                .disk
            )
        }
        if enabledApps.contains(where: { $0.source == .winget }) && !system.wifi.enabled {
            add(
                "winget apps need internet on first boot — either wire the machine up or add a Wi-Fi profile.",
                .apps
            )
        }
        if system.bypassWin11Requirements {
            add(
                "Windows 11 hardware checks are bypassed; Microsoft does not support the resulting installs.",
                .firstBoot
            )
        }
        if admin.autoLogonCount > 1 {
            add(
                "Admin auto-logon runs \(admin.autoLogonCount) times — the machine signs in unattended until that count is used up.",
                .accounts
            )
        }
        if windows.edition == .enterprise {
            add(
                "Enterprise isn't offered on Microsoft's public download — the image you build from has to be volume-licence media.",
                .windows
            )
        }
        return found
    }

    /// Plain strings, for callers that only need the text.
    var validationErrors: [String] { issues.map { $0.message } }
    var validationWarnings: [String] { warnings.map { $0.message } }

    var isBuildable: Bool { validationErrors.isEmpty }
}

// MARK: - Starter templates

extension DeploymentTemplate {
    /// Seeded on first launch so the app is never an empty shell.
    static func starterPack() -> [DeploymentTemplate] {
        [standardWorkstation(), kioskLite()]
    }

    static func standardWorkstation() -> DeploymentTemplate {
        var t = DeploymentTemplate()
        t.name = "Standard Workstation"
        t.summary = "Windows 11 Pro, IT admin profile, core apps, telemetry trimmed."
        t.symbol = "desktopcomputer"
        t.apps = [
            AppSelection(name: "Google Chrome", packageID: "Google.Chrome"),
            AppSelection(name: "Microsoft 365 Apps", packageID: "Microsoft.Office"),
            AppSelection(name: "Adobe Acrobat Reader", packageID: "Adobe.Acrobat.Reader.64-bit"),
            AppSelection(name: "7-Zip", packageID: "7zip.7zip"),
            AppSelection(name: "Zoom", packageID: "Zoom.Zoom"),
            AppSelection(name: "Notepad++", packageID: "Notepad++.Notepad++")
        ]
        t.system.enableRemoteDesktop = true
        t.system.showFileExtensions = true
        t.system.disableWidgets = true
        return t
    }

    static func kioskLite() -> DeploymentTemplate {
        var t = DeploymentTemplate()
        t.name = "Shared / Kiosk PC"
        t.summary = "Locked-down shared machine: browser only, auto-updates, no consumer apps."
        t.symbol = "display"
        t.apps = [
            AppSelection(name: "Microsoft Edge WebView2", packageID: "Microsoft.EdgeWebView2Runtime"),
            AppSelection(name: "Google Chrome", packageID: "Google.Chrome")
        ]
        t.system.removeBloatware = true
        t.system.disableConsumerFeatures = true
        t.system.disableWebSearch = true
        t.system.powerPlan = .highPerformance
        t.system.disableSleepOnAC = true
        t.endUser.mode = .leaveOOBE
        return t
    }
}
