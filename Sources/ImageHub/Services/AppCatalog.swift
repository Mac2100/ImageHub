import Foundation

/// A curated shortlist of winget packages IT departments actually deploy, so the
/// common case is a click instead of typing a package ID from memory.
///
/// This is a convenience list, not a limit — any winget ID can be typed in, and
/// bundled installers cover everything winget doesn't have.
enum AppCatalog {
    struct Entry: Identifiable, Hashable {
        let id: String
        let name: String
        let category: String
        var note: String = ""

        var selection: AppSelection {
            AppSelection(name: name, packageID: id, notes: note)
        }
    }

    /// winget package IDs that have changed since a template might have stored one.
    ///
    /// A template records the ID it was created with, so correcting the catalog
    /// does nothing for templates already on disk — they keep installing a package
    /// that no longer exists. Slack made this concrete: the catalog was fixed to
    /// `SlackTechnologies.Slack` two releases before a real run was still sending
    /// `Slack.Slack` and failing with "No package found matching input criteria".
    static let renamedPackageIDs: [String: String] = [
        "Slack.Slack": "SlackTechnologies.Slack",
    ]

    /// The winget package that has been replaced by a first-class feature.
    ///
    /// Dropping it from the catalog does nothing for templates already on disk --
    /// they keep the ID they were created with. Slack taught that lesson: the
    /// catalog was corrected two releases before a real run was still sending the
    /// old ID.
    static let officePackageID = "Microsoft.Office"

    /// Packages that no longer exist to install.
    ///
    /// Microsoft retired consumer Skype in May 2025, so the entry could only ever
    /// fail now. Dropped from a template on load for the same reason it is gone
    /// from the catalog: a step that cannot succeed is not worth a warning, it is
    /// worth removing. (The inbox Skype app is separately in the debloat list.)
    static let retiredPackageIDs: Set<String> = ["Microsoft.Skype"]

    /// Moves a template off the winget Office package and onto the Deployment Tool.
    ///
    /// The intent either way was "install Office", and one of the two routes
    /// actually manages it, so this changes the outcome rather than the wish. A
    /// template that had it disabled just loses a dead entry.
    static func migratingOffice(
        apps: inout [AppSelection],
        office: inout Microsoft365Spec
    ) {
        apps.removeAll { $0.source == .winget && retiredPackageIDs.contains($0.packageID) }

        let matches = apps.filter { $0.source == .winget && $0.packageID == officePackageID }
        guard !matches.isEmpty else { return }
        apps.removeAll { $0.source == .winget && $0.packageID == officePackageID }
        if matches.contains(where: { $0.enabled }) {
            office.enabled = true
        }
    }

    /// Rewrites a stored selection whose package ID has since been renamed.
    static func correctingRenames(_ selection: AppSelection) -> AppSelection {
        guard selection.source == .winget,
              let corrected = renamedPackageIDs[selection.packageID]
        else { return selection }
        var updated = selection
        updated.packageID = corrected
        return updated
    }

    static let entries: [Entry] = [
        // Browsers
        Entry(id: "Google.Chrome", name: "Google Chrome", category: "Browsers"),
        Entry(id: "Mozilla.Firefox", name: "Mozilla Firefox", category: "Browsers"),
        Entry(id: "Microsoft.Edge", name: "Microsoft Edge", category: "Browsers", note: "Preinstalled on Windows 11"),

        // Productivity
        //
        // Microsoft.Office is deliberately absent. It failed on every real run with
        // "Installer hash does not match; this cannot be overridden when running as
        // admin", and offering a package that does not work -- then warning people
        // away from it -- is worse than not offering it. The Microsoft 365 section
        // on the Apps tab does the job properly.
        Entry(id: "Adobe.Acrobat.Reader.64-bit", name: "Adobe Acrobat Reader", category: "Productivity"),
        Entry(id: "Microsoft.Teams", name: "Microsoft Teams", category: "Productivity"),
        Entry(id: "Zoom.Zoom", name: "Zoom", category: "Productivity"),
        Entry(id: "SlackTechnologies.Slack", name: "Slack", category: "Productivity"),
        Entry(id: "Notion.Notion", name: "Notion", category: "Productivity"),
        Entry(id: "Libreoffice.Libreoffice", name: "LibreOffice", category: "Productivity"),
        Entry(id: "Anthropic.Claude", name: "Claude", category: "Productivity",
              note: "Package ID not verified from macOS - the log names the right one if this misses"),
        Entry(id: "Anthropic.ClaudeCode", name: "Claude Code", category: "Developer",
              note: "Package ID not verified from macOS - the log names the right one if this misses"),

        // Utilities
        Entry(id: "7zip.7zip", name: "7-Zip", category: "Utilities"),
        Entry(id: "Microsoft.PowerToys", name: "PowerToys", category: "Utilities"),
        Entry(id: "Notepad++.Notepad++", name: "Notepad++", category: "Utilities"),
        Entry(id: "VideoLAN.VLC", name: "VLC", category: "Utilities"),
        Entry(id: "voidtools.Everything", name: "Everything", category: "Utilities"),
        Entry(id: "WinDirStat.WinDirStat", name: "WinDirStat", category: "Utilities"),
        Entry(id: "CrystalDewWorld.CrystalDiskInfo", name: "CrystalDiskInfo", category: "Utilities"),

        // Remote support
        Entry(id: "TeamViewer.TeamViewer", name: "TeamViewer", category: "Remote support"),
        Entry(id: "RealVNC.VNCViewer", name: "RealVNC Viewer", category: "Remote support"),
        Entry(id: "AnyDeskSoftwareGmbH.AnyDesk", name: "AnyDesk", category: "Remote support"),

        // Runtimes
        Entry(id: "Microsoft.EdgeWebView2Runtime", name: "Edge WebView2 Runtime", category: "Runtimes"),
        Entry(id: "Microsoft.VCRedist.2015+.x64", name: "Visual C++ Redistributable", category: "Runtimes"),
        Entry(id: "Microsoft.DotNet.DesktopRuntime.8", name: ".NET 8 Desktop Runtime", category: "Runtimes"),
        Entry(id: "Oracle.JavaRuntimeEnvironment", name: "Java Runtime", category: "Runtimes"),

        // Developer
        Entry(id: "Microsoft.VisualStudioCode", name: "Visual Studio Code", category: "Developer"),
        Entry(id: "Git.Git", name: "Git", category: "Developer"),
        Entry(id: "Python.Python.3.12", name: "Python 3.12", category: "Developer"),
        Entry(id: "Microsoft.WindowsTerminal", name: "Windows Terminal", category: "Developer"),
        Entry(id: "PuTTY.PuTTY", name: "PuTTY", category: "Developer"),

        // Security
        Entry(id: "Bitwarden.Bitwarden", name: "Bitwarden", category: "Security"),
        Entry(id: "1Password.1Password", name: "1Password", category: "Security"),
        Entry(id: "Malwarebytes.Malwarebytes", name: "Malwarebytes", category: "Security"),
        Entry(id: "KeePassXCTeam.KeePassXC", name: "KeePassXC", category: "Security"),
        Entry(id: "Cisco.Secure-Client", name: "Cisco Secure Client", category: "Security",
              note: "AnyConnect VPN"),
        Entry(id: "OpenVPNTechnologies.OpenVPNConnect", name: "OpenVPN Connect", category: "Security"),
        Entry(id: "WireGuard.WireGuard", name: "WireGuard", category: "Security"),

        // Productivity
        Entry(id: "Microsoft.OneDrive", name: "OneDrive", category: "Productivity",
              note: "Windows 11 preinstalls it; add this to install or update the sync client explicitly"),
        Entry(id: "Google.GoogleDrive", name: "Google Drive", category: "Productivity"),
        Entry(id: "Dropbox.Dropbox", name: "Dropbox", category: "Productivity"),
        Entry(id: "Adobe.Acrobat.Reader.32-bit", name: "Acrobat Reader (32-bit)", category: "Productivity"),
        Entry(id: "Foxit.FoxitReader", name: "Foxit PDF Reader", category: "Productivity"),
        Entry(id: "PDFgear.PDFgear", name: "PDFgear", category: "Productivity",
              note: "Free PDF editor - read, edit, sign, convert"),
        Entry(id: "Microsoft.OneNote", name: "OneNote", category: "Productivity"),
        Entry(id: "Mozilla.Thunderbird", name: "Thunderbird", category: "Productivity"),

        // Communication
        Entry(id: "Cisco.Webex", name: "Webex", category: "Communication"),
        Entry(id: "GoTo.GoToMeeting", name: "GoTo Meeting", category: "Communication"),
        Entry(id: "RingCentral.RingCentral", name: "RingCentral", category: "Communication"),
        Entry(id: "Discord.Discord", name: "Discord", category: "Communication"),

        // Utilities
        Entry(id: "Rufus.Rufus", name: "Rufus", category: "Utilities",
              note: "Makes bootable USB media on Windows"),
        Entry(id: "Greenshot.Greenshot", name: "Greenshot", category: "Utilities"),
        Entry(id: "ShareX.ShareX", name: "ShareX", category: "Utilities"),
        Entry(id: "WinSCP.WinSCP", name: "WinSCP", category: "Utilities"),
        Entry(id: "FileZilla.Client", name: "FileZilla", category: "Utilities"),
        Entry(id: "Balena.Etcher", name: "balenaEtcher", category: "Utilities"),
        Entry(id: "CPUID.CPU-Z", name: "CPU-Z", category: "Utilities"),
        Entry(id: "TechPowerUp.GPU-Z", name: "GPU-Z", category: "Utilities"),
        Entry(id: "Piriform.CCleaner", name: "CCleaner", category: "Utilities"),
        Entry(id: "Microsoft.Sysinternals.Suite", name: "Sysinternals Suite", category: "Utilities",
              note: "Autoruns, Process Explorer, PsExec and the rest"),

        // Remote support
        Entry(id: "Splashtop.SplashtopBusiness", name: "Splashtop Business", category: "Remote support"),
        Entry(id: "Google.ChromeRemoteDesktop", name: "Chrome Remote Desktop", category: "Remote support"),
        Entry(id: "Microsoft.RemoteDesktopClient", name: "Remote Desktop client", category: "Remote support"),

        // Runtimes
        Entry(id: "Microsoft.VCRedist.2013.x64", name: "VC++ 2013 Redistributable", category: "Runtimes"),
        Entry(id: "Microsoft.DotNet.Runtime.8", name: ".NET 8 Runtime", category: "Runtimes"),
        Entry(id: "Microsoft.DotNet.Framework.DeveloperPack_4", name: ".NET Framework 4", category: "Runtimes"),
        Entry(id: "Adoptium.Temurin.21.JRE", name: "Temurin 21 JRE", category: "Runtimes",
              note: "Open-source Java, no Oracle licensing"),

        // Developer
        Entry(id: "Microsoft.PowerShell", name: "PowerShell 7", category: "Developer"),
        Entry(id: "Microsoft.SQLServerManagementStudio", name: "SQL Server Management Studio", category: "Developer"),
        Entry(id: "WinMerge.WinMerge", name: "WinMerge", category: "Developer"),
        Entry(id: "Postman.Postman", name: "Postman", category: "Developer"),
        Entry(id: "Docker.DockerDesktop", name: "Docker Desktop", category: "Developer"),
        Entry(id: "GitHub.GitHubDesktop", name: "GitHub Desktop", category: "Developer"),
        Entry(id: "Insecure.Nmap", name: "Nmap", category: "Developer"),
        Entry(id: "WiresharkFoundation.Wireshark", name: "Wireshark", category: "Developer")
    ]

    static var categories: [String] {
        var seen: [String] = []
        for entry in entries where !seen.contains(entry.category) {
            seen.append(entry.category)
        }
        return seen
    }

    static func entries(in category: String) -> [Entry] {
        entries.filter { $0.category == category }
    }

    static func search(_ query: String) -> [Entry] {
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || $0.category.localizedCaseInsensitiveContains(query)
        }
    }
}

/// Windows time zone IDs (the `tzutil` names an answer file needs) for the
/// regions most fleets sit in.
enum WindowsTimeZones {
    static let all: [String] = [
        "Dateline Standard Time",
        "Hawaiian Standard Time",
        "Alaskan Standard Time",
        "Pacific Standard Time",
        "Mountain Standard Time",
        "Central Standard Time",
        "Eastern Standard Time",
        "Atlantic Standard Time",
        "SA Pacific Standard Time",
        "E. South America Standard Time",
        "GMT Standard Time",
        "Greenwich Standard Time",
        "W. Europe Standard Time",
        "Central Europe Standard Time",
        "Romance Standard Time",
        "E. Europe Standard Time",
        "FLE Standard Time",
        "Israel Standard Time",
        "Arabian Standard Time",
        "Russian Standard Time",
        "India Standard Time",
        "China Standard Time",
        "Singapore Standard Time",
        "W. Australia Standard Time",
        "Tokyo Standard Time",
        "Korea Standard Time",
        "AUS Eastern Standard Time",
        "New Zealand Standard Time",
        "UTC"
    ]
}

/// Locale / keyboard pairs offered in the editor.
enum WindowsLocales {
    static let all: [(locale: String, input: String, label: String)] = [
        ("en-US", "0409:00000409", "English (United States)"),
        ("en-GB", "0809:00000809", "English (United Kingdom)"),
        ("en-CA", "1009:00000409", "English (Canada)"),
        ("en-AU", "0c09:00000409", "English (Australia)"),
        ("fr-FR", "040c:0000040c", "French (France)"),
        ("fr-CA", "0c0c:00001009", "French (Canada)"),
        ("de-DE", "0407:00000407", "German (Germany)"),
        ("es-ES", "0c0a:0000040a", "Spanish (Spain)"),
        ("es-MX", "080a:0000080a", "Spanish (Mexico)"),
        ("it-IT", "0410:00000410", "Italian (Italy)"),
        ("nl-NL", "0413:00020409", "Dutch (Netherlands)"),
        ("pt-BR", "0416:00000416", "Portuguese (Brazil)"),
        ("sv-SE", "041d:0000041d", "Swedish (Sweden)"),
        ("da-DK", "0406:00000406", "Danish (Denmark)"),
        ("nb-NO", "0414:00000414", "Norwegian (Bokmål)"),
        ("fi-FI", "040b:0000040b", "Finnish (Finland)"),
        ("pl-PL", "0415:00000415", "Polish (Poland)"),
        ("ja-JP", "0411:00000411", "Japanese (Japan)"),
        ("ko-KR", "0412:00000412", "Korean (Korea)"),
        ("zh-CN", "0804:00000804", "Chinese (Simplified)"),
        ("zh-TW", "0404:00000404", "Chinese (Traditional)")
    ]

    static func input(for locale: String) -> String {
        all.first { $0.locale == locale }?.input ?? "0409:00000409"
    }
}
