import Foundation

/// Writes the `ImageHub\` folder that rides along on the USB drive and is staged
/// to `C:\ImageHub` during Setup: the provisioning scripts, a resolved
/// `config.json`, bundled installers, and any assets the template references.
enum PayloadBuilder {
    static let folderName = "ImageHub"
    static let configFileName = "config.json"

    struct PayloadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Config written next to the scripts

    /// Mirror of `Shared/schema/config.schema.json`. `Provision.ps1` reads exactly
    /// these keys, so any change here needs the PowerShell side updated too.
    struct Config: Encodable {
        struct Admin: Encodable {
            var username: String
            var displayName: String
            var accountDescription: String
            var hideFromLoginScreen: Bool
            var passwordNeverExpires: Bool
        }

        struct EndUser: Encodable {
            var mode: String
            var username: String
            var displayName: String
            var administrator: Bool
            var mustChangePassword: Bool
            var welcomeNote: String
        }

        struct Identity: Encodable {
            var joinMode: String
            var workgroup: String
            var domain: String
        }

        struct App: Encodable {
            var name: String
            var source: String
            var packageID: String
            var version: String
            var installer: String
            var silentArgs: String
            var script: String
            var required: Bool
        }

        struct Wifi: Encodable {
            var enabled: Bool
            var ssid: String
            var password: String
            var security: String
            var hidden: Bool
            var connectAutomatically: Bool
        }

        struct Registry: Encodable {
            var path: String
            var name: String
            var type: String
            var value: String
        }

        struct System: Encodable {
            var computerNameTemplate: String
            var timeZone: String
            var enableRemoteDesktop: Bool
            var allowPing: Bool
            var powerPlanGUID: String
            var disableSleepOnAC: Bool
            var disableFastStartup: Bool
            var disableHibernation: Bool
            var showFileExtensions: Bool
            var showHiddenFiles: Bool
            var classicContextMenu: Bool
            var taskbarAlignLeft: Bool
            var disableWidgets: Bool
            var disableWebSearch: Bool
            var disableTelemetry: Bool
            var disableConsumerFeatures: Bool
            var removeBloatware: Bool
            var bloatware: [String]
            var windowsUpdate: String
            var installUpdates: Bool
            var optionalFeatures: [String]
            var bitLocker: String
            var bitLockerRecoveryToAD: Bool
            var disableRecoveryEnvironment: Bool
            var wallpaper: String
            var lockScreen: String
            var startLayout: String
            var wifi: Wifi
            var registryTweaks: [Registry]
        }

        struct Script: Encodable {
            var name: String
            var phase: String
            var file: String
            var continueOnError: Bool
        }

        var schemaVersion = 1
        var generatedBy: String
        var generatedAt: String
        var templateID: String
        var templateName: String
        var admin: Admin
        var endUser: EndUser
        var identity: Identity
        var apps: [App]
        var system: System
        var scripts: [Script]
    }

    // MARK: - Build

    /// Assembles the payload at `<volume>/ImageHub`.
    @discardableResult
    static func write(
        template: DeploymentTemplate,
        secrets: AnswerFileBuilder.ResolvedSecrets,
        to volume: URL,
        log: @escaping @Sendable (String) -> Void
    ) throws -> URL {
        let fm = FileManager.default
        let root = volume.appendingPathComponent(folderName, isDirectory: true)

        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // 1. Provisioning scripts, shared verbatim with the Windows-side builder.
        let source = try payloadSourceDirectory()
        log("Copying provisioning scripts from \(source.lastPathComponent)…")
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            guard item.lastPathComponent != ".DS_Store" else { continue }
            try fm.copyItem(at: item, to: root.appendingPathComponent(item.lastPathComponent))
        }

        // 2. Bundled installers.
        var apps: [Config.App] = []
        let installers = root.appendingPathComponent("Installers", isDirectory: true)
        for app in template.enabledApps {
            var relativeInstaller = ""
            if app.source == .installer {
                let origin = URL(fileURLWithPath: app.installerPath)
                guard fm.fileExists(atPath: origin.path) else {
                    throw PayloadError(
                        message: "Installer for “\(app.displayName)” is missing: \(app.installerPath)"
                    )
                }
                if !fm.fileExists(atPath: installers.path) {
                    try fm.createDirectory(at: installers, withIntermediateDirectories: true)
                }
                let destination = installers.appendingPathComponent(origin.lastPathComponent)
                if !fm.fileExists(atPath: destination.path) {
                    log("Copying installer \(origin.lastPathComponent)…")
                    try fm.copyItem(at: origin, to: destination)
                }
                relativeInstaller = "Installers\\\(origin.lastPathComponent)"
            }
            apps.append(
                Config.App(
                    name: app.displayName,
                    source: app.source.rawValue,
                    packageID: app.packageID,
                    version: app.version,
                    installer: relativeInstaller,
                    silentArgs: app.silentArgs,
                    script: app.script,
                    required: app.required
                )
            )
        }

        // 3. Assets referenced by the template.
        let assets = root.appendingPathComponent("Assets", isDirectory: true)
        func copyAsset(_ path: String, as name: String) throws -> String {
            guard !path.isEmpty else { return "" }
            let origin = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: origin.path) else {
                log("⚠︎ Asset not found, skipping: \(path)")
                return ""
            }
            if !fm.fileExists(atPath: assets.path) {
                try fm.createDirectory(at: assets, withIntermediateDirectories: true)
            }
            let ext = origin.pathExtension
            let fileName = ext.isEmpty ? name : "\(name).\(ext)"
            try fm.copyItem(at: origin, to: assets.appendingPathComponent(fileName))
            return "Assets\\\(fileName)"
        }

        let wallpaper = try copyAsset(template.system.wallpaperPath, as: "Wallpaper")
        let lockScreen = try copyAsset(template.system.lockScreenPath, as: "LockScreen")
        let startLayout = try copyAsset(template.system.startLayoutPath, as: "StartLayout")

        // 4. Custom scripts.
        var scripts: [Config.Script] = []
        let scriptsDirectory = root.appendingPathComponent("Scripts", isDirectory: true)
        for script in template.scripts where script.enabled && !script.body.isEmpty {
            if !fm.fileExists(atPath: scriptsDirectory.path) {
                try fm.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
            }
            let name = scriptFileName(script)
            try Data(script.body.utf8)
                .write(to: scriptsDirectory.appendingPathComponent(name))
            scripts.append(
                Config.Script(
                    name: script.name,
                    phase: script.phase.rawValue,
                    file: "Scripts\\\(name)",
                    continueOnError: script.continueOnError
                )
            )
        }

        // 5. Resolved config + an audit copy of the template itself.
        let config = makeConfig(
            template: template,
            secrets: secrets,
            apps: apps,
            scripts: scripts,
            wallpaper: wallpaper,
            lockScreen: lockScreen,
            startLayout: startLayout
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: root.appendingPathComponent(configFileName))

        let templateEncoder = JSONEncoder()
        templateEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        templateEncoder.dateEncodingStrategy = .iso8601
        try templateEncoder.encode(template)
            .write(to: root.appendingPathComponent("template.json"))

        log("Payload written to \(root.path)")
        return root
    }

    static func scriptFileName(_ script: CustomScript) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let slug = String(script.name.compactMap { allowed.contains($0) ? $0 : "-" }.prefix(40))
        return "\(slug.isEmpty ? "script" : slug)-\(script.id.uuidString.prefix(8)).ps1"
    }

    private static func makeConfig(
        template: DeploymentTemplate,
        secrets: AnswerFileBuilder.ResolvedSecrets,
        apps: [Config.App],
        scripts: [Config.Script],
        wallpaper: String,
        lockScreen: String,
        startLayout: String
    ) -> Config {
        let system = template.system
        return Config(
            generatedBy: "ImageHub \(AppVersion.current)",
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            templateID: template.id.uuidString,
            templateName: template.name,
            admin: Config.Admin(
                username: template.admin.enabled ? template.admin.username : "",
                displayName: template.admin.displayName,
                accountDescription: template.admin.accountDescription,
                hideFromLoginScreen: template.admin.hideFromLoginScreen,
                passwordNeverExpires: template.admin.passwordNeverExpires
            ),
            endUser: Config.EndUser(
                mode: template.endUser.mode.rawValue,
                username: template.endUser.username,
                displayName: template.endUser.displayName,
                administrator: template.endUser.administrator,
                mustChangePassword: template.endUser.mustChangePassword,
                welcomeNote: template.endUser.welcomeNote
            ),
            identity: Config.Identity(
                joinMode: template.identity.joinMode.rawValue,
                workgroup: template.identity.workgroup,
                domain: template.identity.domain
            ),
            apps: apps,
            system: Config.System(
                computerNameTemplate: system.computerNameTemplate,
                timeZone: system.timeZone,
                enableRemoteDesktop: system.enableRemoteDesktop,
                allowPing: system.allowPing,
                powerPlanGUID: system.powerPlan.guid,
                disableSleepOnAC: system.disableSleepOnAC,
                disableFastStartup: system.disableFastStartup,
                disableHibernation: system.disableHibernation,
                showFileExtensions: system.showFileExtensions,
                showHiddenFiles: system.showHiddenFiles,
                classicContextMenu: system.classicContextMenu,
                taskbarAlignLeft: system.taskbarAlignLeft,
                disableWidgets: system.disableWidgets,
                disableWebSearch: system.disableWebSearch,
                disableTelemetry: system.disableTelemetry,
                disableConsumerFeatures: system.disableConsumerFeatures,
                removeBloatware: system.removeBloatware,
                bloatware: system.removeBloatware ? system.bloatwareList : [],
                windowsUpdate: system.windowsUpdate.rawValue,
                installUpdates: system.installUpdatesDuringProvisioning,
                optionalFeatures: system.optionalFeatures,
                bitLocker: system.bitLocker.rawValue,
                bitLockerRecoveryToAD: system.enableBitLockerRecoveryToAD,
                disableRecoveryEnvironment: !template.disk.recoveryPartition,
                wallpaper: wallpaper,
                lockScreen: lockScreen,
                startLayout: startLayout,
                wifi: Config.Wifi(
                    enabled: system.wifi.enabled,
                    ssid: system.wifi.ssid,
                    password: system.wifi.enabled ? secrets.wifiPassword : "",
                    security: system.wifi.security,
                    hidden: system.wifi.hidden,
                    connectAutomatically: system.wifi.connectAutomatically
                ),
                registryTweaks: system.registryTweaks
                    .filter { $0.enabled && !$0.name.isEmpty }
                    .map {
                        Config.Registry(path: $0.path, name: $0.name, type: $0.type.rawValue, value: $0.value)
                    }
            ),
            scripts: scripts
        )
    }

    // MARK: - Locating the shared payload

    static let payloadPathOverrideKey = "payloadSourcePath"

    /// The provisioning scripts live in `Shared/payload/` in the repository and
    /// are copied into `ImageHub.app/Contents/Resources/payload` at build time.
    /// Development runs (`swift run`) fall back to the checkout.
    static func payloadSourceDirectory() throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let override = UserDefaults.standard.string(forKey: payloadPathOverrideKey), !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("payload", isDirectory: true) {
            candidates.append(bundled)
        }

        // Walk up from the executable (…/.build/<config>/ImageHub) looking for the checkout.
        var directory = Bundle.main.bundleURL
        for _ in 0..<8 {
            candidates.append(
                directory.appendingPathComponent("Shared/payload", isDirectory: true)
            )
            directory = directory.deletingLastPathComponent()
        }
        candidates.append(
            URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Shared/payload", isDirectory: true)
        )

        for candidate in candidates {
            if fm.fileExists(atPath: candidate.appendingPathComponent("Provision.ps1").path) {
                return candidate
            }
        }

        throw PayloadError(
            message: """
                Couldn't find the provisioning scripts (Shared/payload/Provision.ps1). \
                If you're running a development build, launch it from the repository \
                checkout, or set the payload path in Settings → Tools.
                """
        )
    }
}
