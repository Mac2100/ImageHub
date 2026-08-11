using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Serialization;
using ImageHub.Services;
using ImageHub.Support;

namespace ImageHub.Models;

// A port of Sources/ImageHub/Models/Template.swift. The two have to agree
// exactly: Shared/schema/template.schema.json is the documented contract, a
// template written by either app is opened by the other, and Provision.ps1 reads
// the payload both of them generate.
//
// Reading is lenient in the same way the Swift side is — a missing key takes the
// default written here, so a three-line template is as valid as a fully specified
// one. See Support/Json.cs for how a malformed value is handled.

// MARK: - Windows

public static class WindowsEditions
{
    /// <summary>The /IMAGE/NAME value Windows Setup matches against inside install.wim.</summary>
    public static string ImageName(WindowsEdition edition, WindowsRelease release)
    {
        string product = release == WindowsRelease.Win11 ? "Windows 11" : "Windows 10";
        return product + " " + Labels.Of(edition);
    }

    /// <summary>
    /// Microsoft's publicly documented generic KMS client setup keys. These do not
    /// activate anything on their own — they only tell Setup which edition to
    /// install and let it reach the KMS host / MAK afterwards.
    /// </summary>
    public static string? GenericKey(WindowsEdition edition, WindowsRelease release) => edition switch
    {
        WindowsEdition.Pro => "W269N-WFGWX-YVC9B-4J6C9-T83GX",
        WindowsEdition.ProWorkstations => "NRG8B-VKK3Q-CXVCJ-9G2XF-6Q84J",
        WindowsEdition.Enterprise => "NPPR9-FWDCX-D2C8J-H872K-2YT43",
        WindowsEdition.Education => "NW6C2-QMPVW-D7KKK-3GKT6-VCFB2",
        WindowsEdition.ProEducation => "6TP4R-GNPTD-KYYHQ-7B7DP-J447Y",
        WindowsEdition.Home => "TX9XD-98N7V-6WMQ6-BX7FG-H8Q99",
        _ => null,
    };
}

/// <summary>
/// What provisioning does about activation once Windows is up. Separate from the
/// key: a firmware key needs a nudge on some machines, and a KMS client key needs
/// to be told where the host is.
/// </summary>
public sealed class ActivationSpec : Observable
{
    private ActivationMode _mode = ActivationMode.Automatic;
    private string _kmsHost = string.Empty;

    public ActivationMode Mode { get => _mode; set => Set(ref _mode, value); }

    [JsonPropertyName("kmsHost")]
    public string KmsHost { get => _kmsHost; set => Set(ref _kmsHost, value); }
}

public sealed class WindowsSpec : Observable
{
    private WindowsRelease _release = WindowsRelease.Win11;
    private WindowsEdition _edition = WindowsEdition.Pro;
    private string _language = "en-US";
    private string _architecture = "x64";
    private Guid? _libraryImageId;
    private string _customWimPath = string.Empty;
    private int? _imageIndex;
    private ProductKeyMode _productKeyMode = ProductKeyMode.Firmware;
    private bool _acceptEula = true;

    public WindowsRelease Release { get => _release; set => Set(ref _release, value); }

    public WindowsEdition Edition { get => _edition; set => Set(ref _edition, value); }

    public string Language { get => _language; set => Set(ref _language, value); }

    public string Architecture { get => _architecture; set => Set(ref _architecture, value); }

    /// <summary>Pins the template to one ISO in the library. Null means "ask at build time".</summary>
    [JsonPropertyName("libraryImageID")]
    public Guid? LibraryImageId { get => _libraryImageId; set => Set(ref _libraryImageId, value); }

    /// <summary>
    /// A sysprepped image installed instead of the one inside the ISO. Empty means
    /// use Microsoft's. Independent of <see cref="LibraryImageId"/>: the ISO always
    /// supplies Setup and the boot files either way.
    /// </summary>
    public string CustomWimPath { get => _customWimPath; set => Set(ref _customWimPath, value); }

    /// <summary>Overrides edition-name matching when a captured image uses custom names.</summary>
    public int? ImageIndex { get => _imageIndex; set => Set(ref _imageIndex, value); }

    /// <summary>
    /// Firmware by default: business-class PCs carry their Windows licence in an
    /// ACPI table, and writing *any* key into the answer file overrides it. That is
    /// how a machine that would have activated by itself ends up wearing an
    /// "Activate Windows" watermark — the generic key is a KMS client key and only
    /// activates against a KMS host.
    /// </summary>
    public ProductKeyMode ProductKeyMode { get => _productKeyMode; set => Set(ref _productKeyMode, value); }

    [JsonPropertyName("acceptEULA")]
    public bool AcceptEula { get => _acceptEula; set => Set(ref _acceptEula, value); }

    public ActivationSpec Activation { get; set; } = new();

    /// <summary>True when the OS comes from a captured image rather than the ISO's.</summary>
    [JsonIgnore]
    public bool UsesCapturedImage => CustomWimPath.Length > 0;

    /// <summary>True when this template always builds from one specific ISO.</summary>
    [JsonIgnore]
    public bool PinsLibraryImage => LibraryImageId.HasValue;
}

// MARK: - Disk

public sealed class DiskSpec : Observable
{
    private bool _wipeTargetDisk = true;
    private int _diskNumber;
    private PartitionStyle _partitionStyle = PartitionStyle.Gpt;
    private int _efiSizeMb = 300;
    private int _msrSizeMb = 16;
    private bool _recoveryPartition = true;
    private int _recoverySizeMb = 1000;
    private bool _wipeAllDisks;

    /// <summary>
    /// When true the answer file wipes the target disk before installing — this is
    /// what makes "wipe an existing computer" a single unattended step.
    /// </summary>
    public bool WipeTargetDisk { get => _wipeTargetDisk; set => Set(ref _wipeTargetDisk, value); }

    public int DiskNumber { get => _diskNumber; set => Set(ref _diskNumber, value); }

    public PartitionStyle PartitionStyle { get => _partitionStyle; set => Set(ref _partitionStyle, value); }

    [JsonPropertyName("efiSizeMB")]
    public int EfiSizeMb { get => _efiSizeMb; set => Set(ref _efiSizeMb, value); }

    [JsonPropertyName("msrSizeMB")]
    public int MsrSizeMb { get => _msrSizeMb; set => Set(ref _msrSizeMb, value); }

    public bool RecoveryPartition { get => _recoveryPartition; set => Set(ref _recoveryPartition, value); }

    [JsonPropertyName("recoverySizeMB")]
    public int RecoverySizeMb { get => _recoverySizeMb; set => Set(ref _recoverySizeMb, value); }

    /// <summary>
    /// Wipe every attached disk, not just <see cref="DiskNumber"/>. Off by default
    /// because it destroys secondary data drives too.
    /// </summary>
    public bool WipeAllDisks { get => _wipeAllDisks; set => Set(ref _wipeAllDisks, value); }
}

// MARK: - Accounts

public sealed class AdminSpec : Observable
{
    private bool _enabled = true;
    private string _username = "ITAdmin";
    private string _displayName = "IT Administrator";
    private string _accountDescription = "Managed by IT — do not remove";
    private int _autoLogonCount = 1;
    private bool _passwordNeverExpires = true;
    private bool _hideFromLoginScreen;
    private bool _enableBuiltInAdministrator;

    public bool Enabled { get => _enabled; set => Set(ref _enabled, value); }

    public string Username { get => _username; set => Set(ref _username, value); }

    public string DisplayName { get => _displayName; set => Set(ref _displayName, value); }

    public string AccountDescription { get => _accountDescription; set => Set(ref _accountDescription, value); }

    public int AutoLogonCount { get => _autoLogonCount; set => Set(ref _autoLogonCount, value); }

    public bool PasswordNeverExpires { get => _passwordNeverExpires; set => Set(ref _passwordNeverExpires, value); }

    /// <summary>Hides the admin account from the sign-in screen once end-user setup is done.</summary>
    public bool HideFromLoginScreen { get => _hideFromLoginScreen; set => Set(ref _hideFromLoginScreen, value); }

    /// <summary>Enables the built-in Administrator account as well (usually unnecessary).</summary>
    public bool EnableBuiltInAdministrator
    {
        get => _enableBuiltInAdministrator;
        set => Set(ref _enableBuiltInAdministrator, value);
    }
}

public sealed class EndUserSpec : Observable
{
    private EndUserMode _mode = EndUserMode.LeaveOobe;
    private string _username = string.Empty;
    private string _displayName = string.Empty;
    private bool _administrator;
    private bool _mustChangePassword = true;
    private string _welcomeNote = string.Empty;
    private int _promptTimeoutMinutes = 15;

    public EndUserMode Mode { get => _mode; set => Set(ref _mode, value); }

    public string Username { get => _username; set => Set(ref _username, value); }

    public string DisplayName { get => _displayName; set => Set(ref _displayName, value); }

    public bool Administrator { get => _administrator; set => Set(ref _administrator, value); }

    public bool MustChangePassword { get => _mustChangePassword; set => Set(ref _mustChangePassword, value); }

    /// <summary>Shown on first boot so whoever receives the machine knows what to do.</summary>
    public string WelcomeNote { get => _welcomeNote; set => Set(ref _welcomeNote, value); }

    /// <summary>
    /// How long the first-boot prompt waits before giving up and letting
    /// provisioning finish. Never unbounded: a dialog nobody answers used to stop
    /// the whole run indefinitely.
    /// </summary>
    public int PromptTimeoutMinutes
    {
        get => _promptTimeoutMinutes;
        set => Set(ref _promptTimeoutMinutes, Math.Max(1, value));
    }
}

// MARK: - Microsoft 365

/// <summary>
/// Installs Office through the Office Deployment Tool rather than winget.
///
/// winget's Microsoft.Office fails on nearly every run with "Installer hash does
/// not match; this cannot be overridden when running as admin" — winget pins a
/// hash and Microsoft ships a new installer behind the same URL, so the manifest
/// is stale more often than not and there is nothing a caller can do about it.
///
/// Deliberately one decision wide: which apps to install. Everything else the
/// Deployment Tool can be told is fixed below, because every one of those knobs
/// had a right answer for this use and offering the wrong answers alongside it
/// only invited someone to pick one.
/// </summary>
public sealed class Microsoft365Spec : Observable
{
    private bool _enabled;
    private string _setupPath = string.Empty;

    public bool Enabled { get => _enabled; set => Set(ref _enabled, value); }

    /// <summary>
    /// The apps to install. The Deployment Tool only speaks in exclusions, so
    /// OfficeConfigBuilder inverts this — but "what do I want" is the question a
    /// technician is actually answering.
    /// </summary>
    public List<string> IncludedApps { get; set; } =
        new() { "Word", "Excel", "PowerPoint", "Outlook", "OneNote" };

    /// <summary>
    /// Pins a specific setup.exe instead of the copy ImageHub downloads from
    /// Microsoft. No UI: the automatic download is the answer for everyone, and
    /// this exists for a machine whose network will not reach Microsoft's CDN.
    /// </summary>
    public string SetupPath { get => _setupPath; set => Set(ref _setupPath, value); }

    /// <summary>Offered as checkboxes, in the order they appear on screen.</summary>
    public static readonly (string Id, string Label)[] AvailableApps =
    {
        ("Word", "Word"),
        ("Excel", "Excel"),
        ("PowerPoint", "PowerPoint"),
        ("Outlook", "Outlook"),
        ("OneNote", "OneNote"),
        ("Access", "Access"),
        ("Publisher", "Publisher"),
    };

    /// <summary>
    /// Never installed by the Deployment Tool, and never offered as a choice.
    ///
    /// Teams and OneDrive are here because something else already owns them, and
    /// letting Office install its own copy is how a machine ends up with two. Teams
    /// comes from the app catalog's Microsoft.Teams, which is the current client and
    /// installs reliably; the copy Office would lay down is the retired one.
    /// OneDrive ships inbox with Windows 11 and is in the catalog as
    /// Microsoft.OneDrive for anyone who wants it installed or updated explicitly —
    /// so excluding it here removes a duplicate, not a capability.
    ///
    /// Groove is the retired OneDrive for Business client, Lync is Skype for
    /// Business, and Bing is the search hijacker nobody has ever asked for.
    /// </summary>
    public static readonly string[] AlwaysExcluded = { "Bing", "Groove", "Lync", "OneDrive", "Teams" };

    /// <summary>
    /// Microsoft 365 Apps for enterprise — what an organisation with E3/E5 or
    /// "Apps for enterprise" licences is entitled to.
    /// </summary>
    public const string ProductId = "O365ProPlusRetail";

    /// <summary>Current is the default channel Microsoft ships and gets security fixes soonest.</summary>
    public const string ChannelId = "Current";

    /// <summary>32-bit Office is a legacy choice for old COM add-ins; nothing being imaged now wants it.</summary>
    public const string Architecture = "64";

    /// <summary>Office pulls several GB from Microsoft's CDN, so it gets triple an ordinary install.</summary>
    public const int TimeoutMinutes = 90;
}

// MARK: - Identity

public sealed class IdentitySpec : Observable
{
    private JoinMode _joinMode = JoinMode.Workgroup;
    private string _workgroup = "WORKGROUP";
    private string _domain = string.Empty;
    private string _organizationalUnit = string.Empty;
    private string _domainJoinUser = string.Empty;

    public JoinMode JoinMode { get => _joinMode; set => Set(ref _joinMode, value); }

    public string Workgroup { get => _workgroup; set => Set(ref _workgroup, value); }

    public string Domain { get => _domain; set => Set(ref _domain, value); }

    public string OrganizationalUnit { get => _organizationalUnit; set => Set(ref _organizationalUnit, value); }

    public string DomainJoinUser { get => _domainJoinUser; set => Set(ref _domainJoinUser, value); }
}

// MARK: - Applications

public sealed class AppSelection : Observable
{
    private Guid _id = Guid.NewGuid();
    private string _name = string.Empty;
    private AppSource _source = AppSource.Winget;
    private string _packageId = string.Empty;
    private string _version = string.Empty;
    private string _installerPath = string.Empty;
    private string _silentArgs = string.Empty;
    private string _script = string.Empty;
    private bool _enabled = true;
    private bool _required;
    private string _notes = string.Empty;

    public AppSelection()
    {
    }

    public AppSelection(string name, string packageId, string notes = "")
    {
        _name = name;
        _packageId = packageId;
        _notes = notes;
    }

    public Guid Id { get => _id; set => Set(ref _id, value); }

    public string Name { get => _name; set => Set(ref _name, value); }

    public AppSource Source { get => _source; set => Set(ref _source, value); }

    /// <summary>winget package identifier, e.g. Google.Chrome.</summary>
    [JsonPropertyName("packageID")]
    public string PackageId { get => _packageId; set => Set(ref _packageId, value); }

    /// <summary>Empty means "latest".</summary>
    public string Version { get => _version; set => Set(ref _version, value); }

    /// <summary>For Installer: a file on this PC that gets copied into the payload.</summary>
    public string InstallerPath { get => _installerPath; set => Set(ref _installerPath, value); }

    /// <summary>Silent switches for Installer, e.g. /qn /norestart.</summary>
    public string SilentArgs { get => _silentArgs; set => Set(ref _silentArgs, value); }

    /// <summary>For Script: inline PowerShell run during provisioning.</summary>
    public string Script { get => _script; set => Set(ref _script, value); }

    public bool Enabled { get => _enabled; set => Set(ref _enabled, value); }

    /// <summary>Fail the whole provisioning run if this app doesn't install.</summary>
    public bool Required { get => _required; set => Set(ref _required, value); }

    public string Notes { get => _notes; set => Set(ref _notes, value); }

    [JsonIgnore]
    public string DisplayName
    {
        get
        {
            if (Name.Length > 0) { return Name; }
            if (PackageId.Length > 0) { return PackageId; }
            if (InstallerPath.Length > 0) { return Path.GetFileName(InstallerPath); }
            return "Untitled app";
        }
    }

    /// <summary>Whether this entry has enough information to do anything on the target.</summary>
    [JsonIgnore]
    public bool IsActionable => Source switch
    {
        AppSource.Winget => PackageId.Length > 0,
        AppSource.Installer => InstallerPath.Length > 0,
        AppSource.Script => Script.Trim().Length > 0,
        _ => false,
    };
}

/// <summary>
/// Ready-made silent-install switches, because the difference between /S and
/// --quiet is the difference between an unattended install and a provisioning run
/// stopped dead on a modal dialog — which is exactly what a real build hit when
/// Sophos answered /S with "Non-option passed: /S".
/// </summary>
public enum SilentSwitchPreset
{
    Msi,
    Nsis,
    Inno,
    InstallShield,
    Sophos,
    QuietDouble,
    SilentSingle,
    NoSwitches,
    Custom,
}

public static class SilentSwitches
{
    /// <summary>The switches themselves. Null means "leave it to the operator".</summary>
    public static string? Arguments(SilentSwitchPreset preset) => preset switch
    {
        SilentSwitchPreset.Msi => "/qn /norestart",
        SilentSwitchPreset.Nsis => "/S",
        SilentSwitchPreset.Inno => "/VERYSILENT /NORESTART",
        SilentSwitchPreset.InstallShield => "/s /v\"/qn\"",
        SilentSwitchPreset.Sophos => "--quiet",
        SilentSwitchPreset.QuietDouble => "--quiet",
        SilentSwitchPreset.SilentSingle => "/silent",
        SilentSwitchPreset.NoSwitches => string.Empty,
        _ => null,
    };

    public static string Label(SilentSwitchPreset preset) => preset switch
    {
        SilentSwitchPreset.Msi => "MSI installer",
        SilentSwitchPreset.Nsis => "NSIS installer",
        SilentSwitchPreset.Inno => "Inno Setup",
        SilentSwitchPreset.InstallShield => "InstallShield",
        SilentSwitchPreset.Sophos => "Sophos",
        SilentSwitchPreset.QuietDouble => "Modern CLI (--quiet)",
        SilentSwitchPreset.SilentSingle => "Legacy (/silent)",
        SilentSwitchPreset.NoSwitches => "No switches",
        _ => "Custom…",
    };

    public static string Detail(SilentSwitchPreset preset) => preset switch
    {
        SilentSwitchPreset.Msi => "/qn /norestart — msiexec's own silent flags.",
        SilentSwitchPreset.Nsis => "/S — Nullsoft. Common for small open-source tools.",
        SilentSwitchPreset.Inno => "/VERYSILENT /NORESTART — Inno Setup, no progress window.",
        SilentSwitchPreset.InstallShield => "/s /v\"/qn\" — InstallShield wrapping an MSI.",
        SilentSwitchPreset.Sophos => "--quiet — what Sophos Endpoint expects; it rejects /S.",
        SilentSwitchPreset.QuietDouble => "--quiet — most installers built on modern CLI conventions.",
        SilentSwitchPreset.SilentSingle => "/silent — older InstallShield and some vendor stubs.",
        SilentSwitchPreset.NoSwitches => "Runs the installer as-is. It will show its own UI.",
        _ => "Type the switches yourself.",
    };

    /// <summary>Which preset a given argument string corresponds to.</summary>
    public static SilentSwitchPreset Matching(string arguments)
    {
        string trimmed = (arguments ?? string.Empty).Trim();
        if (trimmed.Length == 0) { return SilentSwitchPreset.NoSwitches; }
        foreach (SilentSwitchPreset preset in Labels.All<SilentSwitchPreset>())
        {
            if (preset is SilentSwitchPreset.Custom or SilentSwitchPreset.NoSwitches) { continue; }
            if (Arguments(preset) == trimmed) { return preset; }
        }
        return SilentSwitchPreset.Custom;
    }

    /// <summary>Best guess from the installer's file extension.</summary>
    public static SilentSwitchPreset Suggested(string extension) =>
        extension.TrimStart('.').Equals("msi", StringComparison.OrdinalIgnoreCase)
            ? SilentSwitchPreset.Msi
            : SilentSwitchPreset.Nsis;
}

// MARK: - System configuration

public sealed class RegistryTweak : Observable
{
    private Guid _id = Guid.NewGuid();
    private string _path = "HKLM:\\SOFTWARE\\";
    private string _name = string.Empty;
    private RegistryValueType _type = RegistryValueType.DWord;
    private string _value = string.Empty;
    private bool _enabled = true;

    public Guid Id { get => _id; set => Set(ref _id, value); }

    public string Path { get => _path; set => Set(ref _path, value); }

    public string Name { get => _name; set => Set(ref _name, value); }

    public RegistryValueType Type { get => _type; set => Set(ref _type, value); }

    public string Value { get => _value; set => Set(ref _value, value); }

    public bool Enabled { get => _enabled; set => Set(ref _enabled, value); }
}

public sealed class WifiSpec : Observable
{
    private bool _enabled;
    private string _ssid = string.Empty;
    private bool _hidden;
    private string _security = "WPA2PSK";
    private bool _connectAutomatically = true;

    public bool Enabled { get => _enabled; set => Set(ref _enabled, value); }

    [JsonPropertyName("ssid")]
    public string Ssid { get => _ssid; set => Set(ref _ssid, value); }

    public bool Hidden { get => _hidden; set => Set(ref _hidden, value); }

    /// <summary>WPA2PSK / WPA3SAE / open</summary>
    public string Security { get => _security; set => Set(ref _security, value); }

    public bool ConnectAutomatically { get => _connectAutomatically; set => Set(ref _connectAutomatically, value); }
}

public sealed class SystemSpec : Observable
{
    private string _computerNameTemplate = "IT-%SERIAL4%";
    private string _timeZone = "Pacific Standard Time";
    private string _locale = "en-US";
    private string _inputLocale = "0409:00000409";
    private bool _enableRemoteDesktop;
    private bool _allowPing;
    private PowerPlan _powerPlan = PowerPlan.Balanced;
    private bool _disableSleepOnAc = true;
    private bool _disableFastStartup;
    private bool _disableHibernation;
    private int _screenLockMinutes;
    private bool _managePowerTimeouts;
    private int _displayOffMinutesAc = 15;
    private int _displayOffMinutesDc = 5;
    private int _sleepMinutesAc;
    private int _sleepMinutesDc = 30;
    private LidAction _lidCloseActionAc = LidAction.Sleep;
    private LidAction _lidCloseActionDc = LidAction.Sleep;
    private bool _showFileExtensions = true;
    private bool _showHiddenFiles;
    private bool _classicContextMenu;
    private bool _taskbarAlignLeft;
    private bool _disableWidgets;
    private bool _disableWebSearch;
    private bool _disableTelemetry = true;
    private bool _disableConsumerFeatures = true;
    private bool _removeBloatware = true;
    private UpdatePolicy _windowsUpdate = UpdatePolicy.Automatic;
    private bool _installUpdatesDuringProvisioning;
    private BitLockerMode _bitLocker = BitLockerMode.Off;
    private bool _enableBitLockerRecoveryToAd;
    private string _wallpaperPath = string.Empty;
    private string _lockScreenPath = string.Empty;
    private string _startLayoutPath = string.Empty;
    private string _organizationName = string.Empty;
    private string _logoPath = string.Empty;
    private string _supportPhone = string.Empty;
    private string _supportUrl = string.Empty;
    private bool _showProvisioningScreen = true;
    private bool _bypassWin11Requirements;
    private bool _bypassNetworkRequirement = true;

    /// <summary>Tokens: %SERIAL%, %SERIAL4%, %RANDOM4%, %MODEL%, %TEMPLATE%.</summary>
    public string ComputerNameTemplate { get => _computerNameTemplate; set => Set(ref _computerNameTemplate, value); }

    public string TimeZone { get => _timeZone; set => Set(ref _timeZone, value); }

    public string Locale { get => _locale; set => Set(ref _locale, value); }

    public string InputLocale { get => _inputLocale; set => Set(ref _inputLocale, value); }

    public bool EnableRemoteDesktop { get => _enableRemoteDesktop; set => Set(ref _enableRemoteDesktop, value); }

    public bool AllowPing { get => _allowPing; set => Set(ref _allowPing, value); }

    public PowerPlan PowerPlan { get => _powerPlan; set => Set(ref _powerPlan, value); }

    [JsonPropertyName("disableSleepOnAC")]
    public bool DisableSleepOnAc { get => _disableSleepOnAc; set => Set(ref _disableSleepOnAc, value); }

    public bool DisableFastStartup { get => _disableFastStartup; set => Set(ref _disableFastStartup, value); }

    public bool DisableHibernation { get => _disableHibernation; set => Set(ref _disableHibernation, value); }

    // Screen lock and power timeouts.
    //
    // Both land as machine policy, and deliberately not through powercfg. Power
    // schemes are per-user: a powercfg call during provisioning configures ITAdmin
    // and leaves the account the machine is actually handed to sitting on Windows'
    // defaults. The Power Management keys under HKLM\SOFTWARE\Policies are what
    // Group Policy itself writes, they cover every account, and they take
    // precedence over a user's own scheme.

    /// <summary>
    /// Minutes of user inactivity before the session locks. 0 leaves Windows alone
    /// rather than setting a limit of zero, which means "never" to Windows and would
    /// read as a deliberate choice in the log when it was not one.
    /// </summary>
    public int ScreenLockMinutes { get => _screenLockMinutes; set => Set(ref _screenLockMinutes, value); }

    /// <summary>
    /// Whether the display, sleep and lid settings below are applied at all. Off
    /// leaves the machine on Windows' defaults, which is what every template written
    /// before these existed expects.
    /// </summary>
    public bool ManagePowerTimeouts { get => _managePowerTimeouts; set => Set(ref _managePowerTimeouts, value); }

    /// <summary>Minutes before the display turns off. 0 means never.</summary>
    [JsonPropertyName("displayOffMinutesAC")]
    public int DisplayOffMinutesAc { get => _displayOffMinutesAc; set => Set(ref _displayOffMinutesAc, value); }

    [JsonPropertyName("displayOffMinutesDC")]
    public int DisplayOffMinutesDc { get => _displayOffMinutesDc; set => Set(ref _displayOffMinutesDc, value); }

    /// <summary>Minutes before the machine sleeps. 0 means never.</summary>
    [JsonPropertyName("sleepMinutesAC")]
    public int SleepMinutesAc { get => _sleepMinutesAc; set => Set(ref _sleepMinutesAc, value); }

    [JsonPropertyName("sleepMinutesDC")]
    public int SleepMinutesDc { get => _sleepMinutesDc; set => Set(ref _sleepMinutesDc, value); }

    [JsonPropertyName("lidCloseActionAC")]
    public LidAction LidCloseActionAc { get => _lidCloseActionAc; set => Set(ref _lidCloseActionAc, value); }

    [JsonPropertyName("lidCloseActionDC")]
    public LidAction LidCloseActionDc { get => _lidCloseActionDc; set => Set(ref _lidCloseActionDc, value); }

    public bool ShowFileExtensions { get => _showFileExtensions; set => Set(ref _showFileExtensions, value); }

    public bool ShowHiddenFiles { get => _showHiddenFiles; set => Set(ref _showHiddenFiles, value); }

    public bool ClassicContextMenu { get => _classicContextMenu; set => Set(ref _classicContextMenu, value); }

    public bool TaskbarAlignLeft { get => _taskbarAlignLeft; set => Set(ref _taskbarAlignLeft, value); }

    public bool DisableWidgets { get => _disableWidgets; set => Set(ref _disableWidgets, value); }

    public bool DisableWebSearch { get => _disableWebSearch; set => Set(ref _disableWebSearch, value); }

    public bool DisableTelemetry { get => _disableTelemetry; set => Set(ref _disableTelemetry, value); }

    public bool DisableConsumerFeatures
    {
        get => _disableConsumerFeatures;
        set => Set(ref _disableConsumerFeatures, value);
    }

    public bool RemoveBloatware { get => _removeBloatware; set => Set(ref _removeBloatware, value); }

    public List<string> BloatwareList { get; set; } = new(DefaultBloatware);

    public UpdatePolicy WindowsUpdate { get => _windowsUpdate; set => Set(ref _windowsUpdate, value); }

    public bool InstallUpdatesDuringProvisioning
    {
        get => _installUpdatesDuringProvisioning;
        set => Set(ref _installUpdatesDuringProvisioning, value);
    }

    public List<string> OptionalFeatures { get; set; } = new();

    public BitLockerMode BitLocker { get => _bitLocker; set => Set(ref _bitLocker, value); }

    [JsonPropertyName("enableBitLockerRecoveryToAD")]
    public bool EnableBitLockerRecoveryToAd
    {
        get => _enableBitLockerRecoveryToAd;
        set => Set(ref _enableBitLockerRecoveryToAd, value);
    }

    public WifiSpec Wifi { get; set; } = new();

    public List<RegistryTweak> RegistryTweaks { get; set; } = new();

    /// <summary>Files on this PC copied into the payload and applied on first boot.</summary>
    public string WallpaperPath { get => _wallpaperPath; set => Set(ref _wallpaperPath, value); }

    public string LockScreenPath { get => _lockScreenPath; set => Set(ref _lockScreenPath, value); }

    public string StartLayoutPath { get => _startLayoutPath; set => Set(ref _startLayoutPath, value); }

    /// <summary>
    /// Shown on the provisioning screen and written into Windows' OEM information,
    /// which surfaces in Settings → About.
    /// </summary>
    public string OrganizationName { get => _organizationName; set => Set(ref _organizationName, value); }

    public string LogoPath { get => _logoPath; set => Set(ref _logoPath, value); }

    public string SupportPhone { get => _supportPhone; set => Set(ref _supportPhone, value); }

    [JsonPropertyName("supportURL")]
    public string SupportUrl { get => _supportUrl; set => Set(ref _supportUrl, value); }

    /// <summary>
    /// Replaces the bare PowerShell console during provisioning with a full-screen
    /// branded progress window.
    /// </summary>
    public bool ShowProvisioningScreen
    {
        get => _showProvisioningScreen;
        set => Set(ref _showProvisioningScreen, value);
    }

    /// <summary>
    /// Skips the TPM 2.0 / Secure Boot / RAM / CPU checks so Windows 11 installs on
    /// older fleet hardware.
    /// </summary>
    public bool BypassWin11Requirements
    {
        get => _bypassWin11Requirements;
        set => Set(ref _bypassWin11Requirements, value);
    }

    /// <summary>Allows finishing OOBE without a network / Microsoft account.</summary>
    public bool BypassNetworkRequirement
    {
        get => _bypassNetworkRequirement;
        set => Set(ref _bypassNetworkRequirement, value);
    }

    public static readonly string[] DefaultBloatware =
    {
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
        "Clipchamp.Clipchamp",
    };

    /// <summary>Optional Windows features offered in the editor, keyed by DISM name.</summary>
    public static readonly (string Id, string Label)[] AvailableFeatures =
    {
        ("NetFx3", ".NET Framework 3.5"),
        ("Microsoft-Hyper-V-All", "Hyper-V"),
        ("Microsoft-Windows-Subsystem-Linux", "WSL"),
        ("VirtualMachinePlatform", "Virtual Machine Platform"),
        ("TelnetClient", "Telnet Client"),
        ("TFTP", "TFTP Client"),
        ("Client-ProjFS", "Windows Projected File System"),
        ("Microsoft-Windows-Client-EmbeddedExp-Package", "Shell Launcher"),
    };
}

// MARK: - OOBE

public sealed class OobeSpec : Observable
{
    private bool _hideEula = true;
    private bool _hideOemRegistration = true;
    private bool _hideOnlineAccountScreens = true;
    private bool _hideWirelessSetup;
    private bool _skipMachineOobe = true;
    private bool _skipUserOobe;
    private int _protectYourPc = 3;

    [JsonPropertyName("hideEULA")]
    public bool HideEula { get => _hideEula; set => Set(ref _hideEula, value); }

    [JsonPropertyName("hideOEMRegistration")]
    public bool HideOemRegistration { get => _hideOemRegistration; set => Set(ref _hideOemRegistration, value); }

    public bool HideOnlineAccountScreens
    {
        get => _hideOnlineAccountScreens;
        set => Set(ref _hideOnlineAccountScreens, value);
    }

    public bool HideWirelessSetup { get => _hideWirelessSetup; set => Set(ref _hideWirelessSetup, value); }

    [JsonPropertyName("skipMachineOOBE")]
    public bool SkipMachineOobe { get => _skipMachineOobe; set => Set(ref _skipMachineOobe, value); }

    [JsonPropertyName("skipUserOOBE")]
    public bool SkipUserOobe { get => _skipUserOobe; set => Set(ref _skipUserOobe, value); }

    /// <summary>1 = recommended settings, 3 = only critical updates.</summary>
    [JsonPropertyName("protectYourPC")]
    public int ProtectYourPc { get => _protectYourPc; set => Set(ref _protectYourPc, value); }
}

// MARK: - Custom scripts

public sealed class CustomScript : Observable
{
    private Guid _id = Guid.NewGuid();
    private string _name = "New script";
    private ScriptPhase _phase = ScriptPhase.Provision;
    private string _body = string.Empty;
    private bool _enabled = true;
    private bool _continueOnError = true;

    public Guid Id { get => _id; set => Set(ref _id, value); }

    public string Name { get => _name; set => Set(ref _name, value); }

    public ScriptPhase Phase { get => _phase; set => Set(ref _phase, value); }

    public string Body { get => _body; set => Set(ref _body, value); }

    public bool Enabled { get => _enabled; set => Set(ref _enabled, value); }

    public bool ContinueOnError { get => _continueOnError; set => Set(ref _continueOnError, value); }
}

// MARK: - Validation

/// <summary>One problem with a template, and where in the editor to fix it.</summary>
public sealed class ValidationIssue
{
    public ValidationIssue(string message, TemplateField field)
    {
        Message = message;
        Field = field;
    }

    public string Message { get; }

    public TemplateField Field { get; }
}

// MARK: - Template

public sealed class DeploymentTemplate : Observable
{
    /// <summary>Bumped when the on-disk shape changes in a way readers must know about.</summary>
    public const int CurrentSchemaVersion = 1;

    private int _schemaVersion = CurrentSchemaVersion;
    private Guid _id = Guid.NewGuid();
    private string _name = "New Template";
    private string _summary = string.Empty;
    private string _symbol = "desktopcomputer";
    private DateTime _createdAt = DateTime.UtcNow;
    private DateTime _updatedAt = DateTime.UtcNow;

    public int SchemaVersion { get => _schemaVersion; set => Set(ref _schemaVersion, value); }

    public Guid Id { get => _id; set => Set(ref _id, value); }

    public string Name { get => _name; set => Set(ref _name, value); }

    public string Summary { get => _summary; set => Set(ref _summary, value); }

    /// <summary>
    /// The macOS app draws the template's icon from this SF Symbol name. Kept and
    /// round-tripped here — a Windows edit must not silently drop a Mac user's icon
    /// choice — and mapped onto a drawn glyph for display. See Ui/Glyphs.cs.
    /// </summary>
    public string Symbol { get => _symbol; set => Set(ref _symbol, value); }

    public DateTime CreatedAt { get => _createdAt; set => Set(ref _createdAt, value); }

    public DateTime UpdatedAt { get => _updatedAt; set => Set(ref _updatedAt, value); }

    public WindowsSpec Windows { get; set; } = new();

    public DiskSpec Disk { get; set; } = new();

    public AdminSpec Admin { get; set; } = new();

    public EndUserSpec EndUser { get; set; } = new();

    public IdentitySpec Identity { get; set; } = new();

    public List<AppSelection> Apps { get; set; } = new();

    public Microsoft365Spec Microsoft365 { get; set; } = new();

    public SystemSpec System { get; set; } = new();

    [JsonPropertyName("oobe")]
    public OobeSpec Oobe { get; set; } = new();

    public List<CustomScript> Scripts { get; set; } = new();

    [JsonIgnore]
    public IReadOnlyList<AppSelection> EnabledApps =>
        Apps.Where(app => app.Enabled && app.IsActionable).ToList();

    /// <summary>Human-readable one-liner used in lists and the build wizard.</summary>
    [JsonIgnore]
    public string Subtitle
    {
        get
        {
            var parts = new List<string> { Labels.Of(Windows.Release) + " " + Labels.Of(Windows.Edition) };
            int count = EnabledApps.Count;
            if (count > 0) { parts.Add(Formatting.Plural(count, "app")); }
            if (Identity.JoinMode == JoinMode.ActiveDirectory && Identity.Domain.Length > 0)
            {
                parts.Add(Identity.Domain);
            }
            else if (Identity.JoinMode == JoinMode.EntraAtOobe)
            {
                parts.Add("Entra ID");
            }
            return string.Join(" · ", parts);
        }
    }

    /// <summary>
    /// Blocking problems that must be fixed before a drive can be built. Each
    /// carries the part of the template it came from so the Review tab can take you
    /// straight there.
    /// </summary>
    [JsonIgnore]
    public IReadOnlyList<ValidationIssue> Issues
    {
        get
        {
            var found = new List<ValidationIssue>();
            void Add(string message, TemplateField field) => found.Add(new ValidationIssue(message, field));

            if (Name.Trim().Length == 0)
            {
                Add("Template needs a name.", TemplateField.Windows);
            }
            if (Admin.Enabled)
            {
                if (Admin.Username.Trim().Length == 0)
                {
                    Add("Admin account is enabled but has no username.", TemplateField.Accounts);
                }
                if (!SecretStore.Has(Id, SecretSlot.AdminPassword))
                {
                    Add("Admin account has no password set.", TemplateField.Accounts);
                }
            }
            if (Windows.UsesCapturedImage && !File.Exists(Windows.CustomWimPath))
            {
                Add("The captured image this template points at is missing.", TemplateField.Windows);
            }
            if (Windows.ProductKeyMode == ProductKeyMode.Custom
                && !SecretStore.Has(Id, SecretSlot.ProductKey))
            {
                Add("Product key mode is “Specific key” but no key is stored.", TemplateField.Windows);
            }
            // The pairing that leaves a technician activating by hand in Settings: a
            // KMS client key installed with nothing to activate against. Worth saying
            // out loud, because the machine images and boots perfectly and only shows
            // its watermark once it is on someone's desk.
            if (Windows.ProductKeyMode == ProductKeyMode.Generic
                && Windows.Activation.Mode != ActivationMode.Kms)
            {
                Add(
                    "The generic key is a KMS client key and never activates on its own — "
                    + "Windows will show “Activate Windows”. Use the PC's built-in key, "
                    + "or point Activation at a KMS host.",
                    TemplateField.Windows);
            }
            if (Windows.Activation.Mode == ActivationMode.Kms
                && Windows.Activation.KmsHost.Trim().Length == 0)
            {
                Add("Activation is set to use a KMS host but no host is set.", TemplateField.Windows);
            }
            if (Microsoft365.Enabled)
            {
                // An empty path is the normal case: the build downloads the Deployment
                // Tool from Microsoft and caches it. Only a path that was set and has
                // since moved is a problem, because that one is a stale pin.
                if (Microsoft365.SetupPath.Length > 0 && !File.Exists(Microsoft365.SetupPath))
                {
                    Add("The Office Deployment Tool setup.exe this template points at is missing.",
                        TemplateField.Apps);
                }
                if (Microsoft365.IncludedApps.Count == 0)
                {
                    Add("Microsoft 365 is on but no Office apps are selected.", TemplateField.Apps);
                }
                // Both would run, one would lose, and which one is not worth finding
                // out on a bench.
                if (Apps.Any(app => app.Enabled && app.PackageId == AppCatalog.OfficePackageId))
                {
                    Add(
                        "Microsoft 365 is set to install twice — once through the Office "
                        + "Deployment Tool and once through winget. Remove the winget entry.",
                        TemplateField.Apps);
                }
            }
            if (EndUser.Mode == EndUserMode.CreateLocalAccount)
            {
                if (EndUser.Username.Trim().Length == 0)
                {
                    Add("End-user account is enabled but has no username.", TemplateField.Accounts);
                }
                if (string.Equals(EndUser.Username, Admin.Username, StringComparison.OrdinalIgnoreCase)
                    && EndUser.Username.Length > 0)
                {
                    Add("End-user account cannot reuse the admin username.", TemplateField.Accounts);
                }
            }
            if (Identity.JoinMode == JoinMode.ActiveDirectory)
            {
                if (Identity.Domain.Length == 0)
                {
                    Add("Domain join is selected but no domain is set.", TemplateField.Accounts);
                }
                if (Identity.DomainJoinUser.Length == 0
                    || !SecretStore.Has(Id, SecretSlot.DomainPassword))
                {
                    Add("Domain join needs a username and password.", TemplateField.Accounts);
                }
            }
            if (System.Wifi.Enabled && System.Wifi.Ssid.Length == 0)
            {
                Add("Wi-Fi provisioning is on but no SSID is set.", TemplateField.System);
            }
            foreach ((string label, string path) in new[]
                     {
                         ("Logo", System.LogoPath),
                         ("Wallpaper", System.WallpaperPath),
                         ("Lock screen", System.LockScreenPath),
                         ("Start layout", System.StartLayoutPath),
                     })
            {
                if (path.Length > 0 && !File.Exists(path))
                {
                    Add($"{label} image is missing: {Path.GetFileName(path)}", TemplateField.System);
                }
            }
            foreach (AppSelection app in Apps)
            {
                if (app.Enabled && !app.IsActionable)
                {
                    Add($"“{app.DisplayName}” is enabled but incomplete.", TemplateField.Apps);
                }
            }
            return found;
        }
    }

    /// <summary>Non-blocking things worth telling the operator about.</summary>
    [JsonIgnore]
    public IReadOnlyList<ValidationIssue> Warnings
    {
        get
        {
            var found = new List<ValidationIssue>();
            void Add(string message, TemplateField field) => found.Add(new ValidationIssue(message, field));

            if (Disk.WipeAllDisks)
            {
                Add("This template wipes every disk in the target machine, including secondary data drives.",
                    TemplateField.Disk);
            }
            if (EnabledApps.Any(app => app.Source == AppSource.Winget) && !System.Wifi.Enabled)
            {
                Add("winget apps need internet on first boot — either wire the machine up or add a Wi-Fi profile.",
                    TemplateField.Apps);
            }
            if (System.BypassWin11Requirements)
            {
                Add("Windows 11 hardware checks are bypassed; Microsoft does not support the resulting installs.",
                    TemplateField.FirstBoot);
            }
            if (Admin.AutoLogonCount > 1)
            {
                Add($"Admin auto-logon runs {Admin.AutoLogonCount} times — the machine signs in "
                    + "unattended until that count is used up.", TemplateField.Accounts);
            }
            if (Windows.Edition == WindowsEdition.Enterprise)
            {
                Add("Enterprise isn't offered on Microsoft's public download — the image you build "
                    + "from has to be volume-licence media.", TemplateField.Windows);
            }
            return found;
        }
    }

    [JsonIgnore]
    public IReadOnlyList<string> ValidationErrors => Issues.Select(issue => issue.Message).ToList();

    [JsonIgnore]
    public IReadOnlyList<string> ValidationWarnings => Warnings.Select(issue => issue.Message).ToList();

    [JsonIgnore]
    public bool IsBuildable => Issues.Count == 0;

    /// <summary>A deep copy, through JSON so nothing can be shared by accident.</summary>
    public DeploymentTemplate DeepCopy()
    {
        string text = Json.Serialize(this);
        return Json.Deserialize<DeploymentTemplate>(text) ?? new DeploymentTemplate();
    }

    // MARK: - Starter templates

    /// <summary>Seeded on first launch so the app is never an empty shell.</summary>
    public static List<DeploymentTemplate> StarterPack() =>
        new() { StandardWorkstation(), KioskLite() };

    public static DeploymentTemplate StandardWorkstation()
    {
        var t = new DeploymentTemplate
        {
            Name = "Standard Workstation",
            Summary = "Windows 11 Pro, IT admin profile, core apps, telemetry trimmed.",
            Symbol = "desktopcomputer",
        };
        t.Apps = new List<AppSelection>
        {
            new("Google Chrome", "Google.Chrome"),
            new("Microsoft 365 Apps", "Microsoft.Office"),
            new("Adobe Acrobat Reader", "Adobe.Acrobat.Reader.64-bit"),
            new("7-Zip", "7zip.7zip"),
            new("Zoom", "Zoom.Zoom"),
            new("Notepad++", "Notepad++.Notepad++"),
        };
        t.System.EnableRemoteDesktop = true;
        t.System.ShowFileExtensions = true;
        t.System.DisableWidgets = true;
        return t;
    }

    public static DeploymentTemplate KioskLite()
    {
        var t = new DeploymentTemplate
        {
            Name = "Shared / Kiosk PC",
            Summary = "Locked-down shared machine: browser only, auto-updates, no consumer apps.",
            Symbol = "display",
        };
        t.Apps = new List<AppSelection>
        {
            new("Microsoft Edge WebView2", "Microsoft.EdgeWebView2Runtime"),
            new("Google Chrome", "Google.Chrome"),
        };
        t.System.RemoveBloatware = true;
        t.System.DisableConsumerFeatures = true;
        t.System.DisableWebSearch = true;
        t.System.PowerPlan = PowerPlan.HighPerformance;
        t.System.DisableSleepOnAc = true;
        t.EndUser.Mode = EndUserMode.LeaveOobe;
        return t;
    }
}
