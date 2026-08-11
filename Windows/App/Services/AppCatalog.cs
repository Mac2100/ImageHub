using System;
using System.Collections.Generic;
using System.Linq;
using ImageHub.Models;

namespace ImageHub.Services;

/// <summary>
/// A curated shortlist of winget packages IT departments actually deploy, so the
/// common case is a click instead of typing a package ID from memory.
///
/// This is a convenience list, not a limit — any winget ID can be typed in, and
/// bundled installers cover everything winget doesn't have.
///
/// The entries are the same, in the same order, as
/// Sources/ImageHub/Services/AppCatalog.swift. CI compares the two ID lists, so a
/// package added on one platform cannot quietly go missing on the other.
/// </summary>
public static class AppCatalog
{
    public sealed class Entry
    {
        public Entry(string id, string name, string category, string note = "")
        {
            Id = id;
            Name = name;
            Category = category;
            Note = note;
        }

        public string Id { get; }

        public string Name { get; }

        public string Category { get; }

        public string Note { get; }

        public AppSelection ToSelection() => new(Name, Id, Note);
    }

    /// <summary>
    /// winget package IDs that have changed since a template might have stored one.
    ///
    /// A template records the ID it was created with, so correcting the catalog does
    /// nothing for templates already on disk — they keep installing a package that no
    /// longer exists. Slack made this concrete: the catalog was fixed to
    /// SlackTechnologies.Slack two releases before a real run was still sending
    /// Slack.Slack and failing with "No package found matching input criteria".
    /// </summary>
    public static readonly Dictionary<string, string> RenamedPackageIds = new()
    {
        ["Slack.Slack"] = "SlackTechnologies.Slack",
    };

    /// <summary>The winget package that has been replaced by a first-class feature.</summary>
    public const string OfficePackageId = "Microsoft.Office";

    /// <summary>
    /// Packages that no longer exist to install.
    ///
    /// Microsoft retired consumer Skype in May 2025, so the entry could only ever
    /// fail now. Dropped from a template on load for the same reason it is gone from
    /// the catalog: a step that cannot succeed is not worth a warning, it is worth
    /// removing. (The inbox Skype app is separately in the debloat list.)
    /// </summary>
    public static readonly HashSet<string> RetiredPackageIds = new() { "Microsoft.Skype" };

    /// <summary>
    /// Moves a template off the winget Office package and onto the Deployment Tool.
    ///
    /// The intent either way was "install Office", and one of the two routes actually
    /// manages it, so this changes the outcome rather than the wish. A template that
    /// had it disabled just loses a dead entry.
    /// </summary>
    public static void MigrateOffice(DeploymentTemplate template)
    {
        template.Apps.RemoveAll(app =>
            app.Source == AppSource.Winget && RetiredPackageIds.Contains(app.PackageId));

        List<AppSelection> matches = template.Apps
            .Where(app => app.Source == AppSource.Winget && app.PackageId == OfficePackageId)
            .ToList();
        if (matches.Count == 0) { return; }

        template.Apps.RemoveAll(app =>
            app.Source == AppSource.Winget && app.PackageId == OfficePackageId);
        if (matches.Any(app => app.Enabled))
        {
            template.Microsoft365.Enabled = true;
        }
    }

    /// <summary>Rewrites stored selections whose package ID has since been renamed.</summary>
    public static void CorrectRenames(DeploymentTemplate template)
    {
        foreach (AppSelection app in template.Apps)
        {
            if (app.Source != AppSource.Winget) { continue; }
            if (RenamedPackageIds.TryGetValue(app.PackageId, out string? corrected))
            {
                app.PackageId = corrected;
            }
        }
    }

    public static readonly Entry[] Entries =
    {
        // Browsers
        new("Google.Chrome", "Google Chrome", "Browsers"),
        new("Mozilla.Firefox", "Mozilla Firefox", "Browsers"),
        new("Microsoft.Edge", "Microsoft Edge", "Browsers", "Preinstalled on Windows 11"),

        // Productivity
        //
        // Microsoft.Office is deliberately absent. It failed on every real run with
        // "Installer hash does not match; this cannot be overridden when running as
        // admin", and offering a package that does not work -- then warning people
        // away from it -- is worse than not offering it. The Microsoft 365 section on
        // the Apps tab does the job properly.
        new("Adobe.Acrobat.Reader.64-bit", "Adobe Acrobat Reader", "Productivity"),
        new("Microsoft.Teams", "Microsoft Teams", "Productivity"),
        new("Zoom.Zoom", "Zoom", "Productivity"),
        new("SlackTechnologies.Slack", "Slack", "Productivity"),
        new("Notion.Notion", "Notion", "Productivity"),
        new("Libreoffice.Libreoffice", "LibreOffice", "Productivity"),
        new("Anthropic.Claude", "Claude", "Productivity"),
        new("Anthropic.ClaudeCode", "Claude Code", "Developer"),

        // Utilities
        new("7zip.7zip", "7-Zip", "Utilities"),
        new("Microsoft.PowerToys", "PowerToys", "Utilities"),
        new("Notepad++.Notepad++", "Notepad++", "Utilities"),
        new("VideoLAN.VLC", "VLC", "Utilities"),
        new("voidtools.Everything", "Everything", "Utilities"),
        new("WinDirStat.WinDirStat", "WinDirStat", "Utilities"),
        new("CrystalDewWorld.CrystalDiskInfo", "CrystalDiskInfo", "Utilities"),

        // Remote support
        new("TeamViewer.TeamViewer", "TeamViewer", "Remote support"),
        new("RealVNC.VNCViewer", "RealVNC Viewer", "Remote support"),
        new("AnyDeskSoftwareGmbH.AnyDesk", "AnyDesk", "Remote support"),

        // Runtimes
        new("Microsoft.EdgeWebView2Runtime", "Edge WebView2 Runtime", "Runtimes"),
        new("Microsoft.VCRedist.2015+.x64", "Visual C++ Redistributable", "Runtimes"),
        new("Microsoft.DotNet.DesktopRuntime.8", ".NET 8 Desktop Runtime", "Runtimes"),
        new("Oracle.JavaRuntimeEnvironment", "Java Runtime", "Runtimes"),

        // Developer
        new("Microsoft.VisualStudioCode", "Visual Studio Code", "Developer"),
        new("Git.Git", "Git", "Developer"),
        new("Python.Python.3.12", "Python 3.12", "Developer"),
        new("Microsoft.WindowsTerminal", "Windows Terminal", "Developer"),
        new("PuTTY.PuTTY", "PuTTY", "Developer"),

        // Security
        new("Bitwarden.Bitwarden", "Bitwarden", "Security"),
        new("1Password.1Password", "1Password", "Security"),
        new("Malwarebytes.Malwarebytes", "Malwarebytes", "Security"),
        new("KeePassXCTeam.KeePassXC", "KeePassXC", "Security"),
        new("Cisco.Secure-Client", "Cisco Secure Client", "Security", "AnyConnect VPN"),
        new("OpenVPNTechnologies.OpenVPNConnect", "OpenVPN Connect", "Security"),
        new("WireGuard.WireGuard", "WireGuard", "Security"),
        new("Ubiquiti.IdentityDesktop.Endpoint", "UniFi Endpoint", "Security",
            "UniFi Identity client - one-click Wi-Fi and VPN. Needs an invitation link per user afterwards"),

        // Productivity
        new("Microsoft.OneDrive", "OneDrive", "Productivity",
            "Windows 11 preinstalls it; add this to install or update the sync client explicitly"),
        new("Google.GoogleDrive", "Google Drive", "Productivity"),
        new("Dropbox.Dropbox", "Dropbox", "Productivity"),
        new("Adobe.Acrobat.Reader.32-bit", "Acrobat Reader (32-bit)", "Productivity"),
        new("Foxit.FoxitReader", "Foxit PDF Reader", "Productivity"),
        new("PDFgear.PDFgear", "PDFgear", "Productivity",
            "Free PDF editor - read, edit, sign, convert"),
        new("Microsoft.OneNote", "OneNote", "Productivity"),
        new("Mozilla.Thunderbird", "Thunderbird", "Productivity"),

        // Communication
        new("Cisco.Webex", "Webex", "Communication"),
        new("GoTo.GoToMeeting", "GoTo Meeting", "Communication"),
        new("RingCentral.RingCentral", "RingCentral", "Communication"),
        new("Discord.Discord", "Discord", "Communication"),

        // Utilities
        new("Rufus.Rufus", "Rufus", "Utilities", "Makes bootable USB media on Windows"),
        new("Greenshot.Greenshot", "Greenshot", "Utilities"),
        new("ShareX.ShareX", "ShareX", "Utilities"),
        new("WinSCP.WinSCP", "WinSCP", "Utilities"),
        new("FileZilla.Client", "FileZilla", "Utilities"),
        new("Balena.Etcher", "balenaEtcher", "Utilities"),
        new("CPUID.CPU-Z", "CPU-Z", "Utilities"),
        new("TechPowerUp.GPU-Z", "GPU-Z", "Utilities"),
        new("Piriform.CCleaner", "CCleaner", "Utilities"),
        new("Microsoft.Sysinternals.Suite", "Sysinternals Suite", "Utilities",
            "Autoruns, Process Explorer, PsExec and the rest"),

        // Remote support
        new("Splashtop.SplashtopBusiness", "Splashtop Business", "Remote support"),
        new("Google.ChromeRemoteDesktop", "Chrome Remote Desktop", "Remote support"),
        new("Microsoft.RemoteDesktopClient", "Remote Desktop client", "Remote support"),

        // Runtimes
        new("Microsoft.VCRedist.2013.x64", "VC++ 2013 Redistributable", "Runtimes"),
        new("Microsoft.DotNet.Runtime.8", ".NET 8 Runtime", "Runtimes"),
        new("Microsoft.DotNet.Framework.DeveloperPack_4", ".NET Framework 4", "Runtimes"),
        new("Adoptium.Temurin.21.JRE", "Temurin 21 JRE", "Runtimes",
            "Open-source Java, no Oracle licensing"),

        // Developer
        new("Microsoft.PowerShell", "PowerShell 7", "Developer"),
        new("Microsoft.SQLServerManagementStudio", "SQL Server Management Studio", "Developer"),
        new("WinMerge.WinMerge", "WinMerge", "Developer"),
        new("Postman.Postman", "Postman", "Developer"),
        new("Docker.DockerDesktop", "Docker Desktop", "Developer"),
        new("GitHub.GitHubDesktop", "GitHub Desktop", "Developer"),
        new("Insecure.Nmap", "Nmap", "Developer"),
        new("WiresharkFoundation.Wireshark", "Wireshark", "Developer"),
    };

    public static IReadOnlyList<string> Categories
    {
        get
        {
            var seen = new List<string>();
            foreach (Entry entry in Entries)
            {
                if (!seen.Contains(entry.Category)) { seen.Add(entry.Category); }
            }
            return seen;
        }
    }

    public static IEnumerable<Entry> InCategory(string category) =>
        Entries.Where(entry => entry.Category == category);

    public static IReadOnlyList<Entry> Search(string query)
    {
        if (string.IsNullOrWhiteSpace(query)) { return Entries; }
        return Entries.Where(entry =>
            entry.Name.Contains(query, StringComparison.OrdinalIgnoreCase)
            || entry.Id.Contains(query, StringComparison.OrdinalIgnoreCase)
            || entry.Category.Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();
    }
}

/// <summary>
/// Windows time zone IDs (the tzutil names an answer file needs) for the regions
/// most fleets sit in.
/// </summary>
public static class WindowsTimeZones
{
    public static readonly string[] All =
    {
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
        "UTC",
    };
}

/// <summary>Locale / keyboard pairs offered in the editor.</summary>
public static class WindowsLocales
{
    public static readonly (string Locale, string Input, string Label)[] All =
    {
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
        ("zh-TW", "0404:00000404", "Chinese (Traditional)"),
    };

    public static string Input(string locale)
    {
        foreach ((string candidate, string input, string _) in All)
        {
            if (candidate == locale) { return input; }
        }
        return "0409:00000409";
    }

    public static string Label(string locale)
    {
        foreach ((string candidate, string _, string label) in All)
        {
            if (candidate == locale) { return label; }
        }
        return locale;
    }
}
