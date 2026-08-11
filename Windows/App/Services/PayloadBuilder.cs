using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.Json.Serialization;
using ImageHub.Models;
using ImageHub.Support;

namespace ImageHub.Services;

/// <summary>
/// Writes the ImageHub\ folder that rides along on the USB drive and is staged to
/// C:\ImageHub during Setup: the provisioning scripts, a resolved config.json,
/// bundled installers, and any assets the template references.
///
/// A port of Sources/ImageHub/Services/PayloadBuilder.swift. The config is what
/// Provision.ps1 parses, so the key names here are the contract with
/// Shared/payload/Provision.ps1 as much as with the macOS app — any change needs
/// all three updated together.
/// </summary>
public static class PayloadBuilder
{
    public const string FolderName = "ImageHub";

    public const string ConfigFileName = "config.json";

    // MARK: - Config written next to the scripts

    public sealed class PayloadConfig
    {
        public int SchemaVersion { get; set; } = 1;

        public string GeneratedBy { get; set; } = string.Empty;

        public string GeneratedAt { get; set; } = string.Empty;

        [JsonPropertyName("templateID")]
        public string TemplateId { get; set; } = string.Empty;

        public string TemplateName { get; set; } = string.Empty;

        public AdminConfig Admin { get; set; } = new();

        public EndUserConfig EndUser { get; set; } = new();

        public IdentityConfig Identity { get; set; } = new();

        public List<AppConfig> Apps { get; set; } = new();

        public Microsoft365Config Microsoft365 { get; set; } = new();

        public SystemConfig System { get; set; } = new();

        public List<ScriptConfig> Scripts { get; set; } = new();
    }

    public sealed class AdminConfig
    {
        public string Username { get; set; } = string.Empty;

        public string DisplayName { get; set; } = string.Empty;

        public string AccountDescription { get; set; } = string.Empty;

        public bool HideFromLoginScreen { get; set; }

        public bool PasswordNeverExpires { get; set; }
    }

    public sealed class EndUserConfig
    {
        public string Mode { get; set; } = string.Empty;

        public string Username { get; set; } = string.Empty;

        public string DisplayName { get; set; } = string.Empty;

        public bool Administrator { get; set; }

        public bool MustChangePassword { get; set; }

        public string WelcomeNote { get; set; } = string.Empty;

        public int PromptTimeoutMinutes { get; set; }
    }

    public sealed class IdentityConfig
    {
        public string JoinMode { get; set; } = string.Empty;

        public string Workgroup { get; set; } = string.Empty;

        public string Domain { get; set; } = string.Empty;
    }

    public sealed class AppConfig
    {
        public string Name { get; set; } = string.Empty;

        public string Source { get; set; } = string.Empty;

        [JsonPropertyName("packageID")]
        public string PackageId { get; set; } = string.Empty;

        public string Version { get; set; } = string.Empty;

        public string Installer { get; set; } = string.Empty;

        public string SilentArgs { get; set; } = string.Empty;

        public string Script { get; set; } = string.Empty;

        public bool Required { get; set; }
    }

    public sealed class WifiConfig
    {
        public bool Enabled { get; set; }

        [JsonPropertyName("ssid")]
        public string Ssid { get; set; } = string.Empty;

        public string Password { get; set; } = string.Empty;

        public string Security { get; set; } = string.Empty;

        public bool Hidden { get; set; }

        public bool ConnectAutomatically { get; set; }
    }

    public sealed class Microsoft365Config
    {
        public bool Enabled { get; set; }

        public string Setup { get; set; } = string.Empty;

        public string Configuration { get; set; } = string.Empty;

        public int TimeoutMinutes { get; set; }
    }

    public sealed class ActivationConfig
    {
        public string Mode { get; set; } = string.Empty;

        [JsonPropertyName("kmsHost")]
        public string KmsHost { get; set; } = string.Empty;
    }

    public sealed class RegistryConfig
    {
        public string Path { get; set; } = string.Empty;

        public string Name { get; set; } = string.Empty;

        public string Type { get; set; } = string.Empty;

        public string Value { get; set; } = string.Empty;
    }

    public sealed class SystemConfig
    {
        public string ComputerNameTemplate { get; set; } = string.Empty;

        public string TimeZone { get; set; } = string.Empty;

        public bool EnableRemoteDesktop { get; set; }

        public bool AllowPing { get; set; }

        [JsonPropertyName("powerPlanGUID")]
        public string PowerPlanGuid { get; set; } = string.Empty;

        [JsonPropertyName("disableSleepOnAC")]
        public bool DisableSleepOnAc { get; set; }

        public bool DisableFastStartup { get; set; }

        public bool DisableHibernation { get; set; }

        // Minutes on this side, seconds in the registry. Provision.ps1 does the
        // conversion, so the config stays readable.
        public int ScreenLockMinutes { get; set; }

        public bool ManagePowerTimeouts { get; set; }

        [JsonPropertyName("displayOffMinutesAC")]
        public int DisplayOffMinutesAc { get; set; }

        [JsonPropertyName("displayOffMinutesDC")]
        public int DisplayOffMinutesDc { get; set; }

        [JsonPropertyName("sleepMinutesAC")]
        public int SleepMinutesAc { get; set; }

        [JsonPropertyName("sleepMinutesDC")]
        public int SleepMinutesDc { get; set; }

        // Resolved to the numeric LIDACTION values here so the payload needs no
        // lookup table of its own.
        [JsonPropertyName("lidCloseActionAC")]
        public int LidCloseActionAc { get; set; }

        [JsonPropertyName("lidCloseActionDC")]
        public int LidCloseActionDc { get; set; }

        public bool ShowFileExtensions { get; set; }

        public bool ShowHiddenFiles { get; set; }

        public bool ClassicContextMenu { get; set; }

        public bool TaskbarAlignLeft { get; set; }

        public bool DisableWidgets { get; set; }

        public bool DisableWebSearch { get; set; }

        public bool DisableTelemetry { get; set; }

        public bool DisableConsumerFeatures { get; set; }

        public bool RemoveBloatware { get; set; }

        public List<string> Bloatware { get; set; } = new();

        public string WindowsUpdate { get; set; } = string.Empty;

        public bool InstallUpdates { get; set; }

        public List<string> OptionalFeatures { get; set; } = new();

        public string BitLocker { get; set; } = string.Empty;

        [JsonPropertyName("bitLockerRecoveryToAD")]
        public bool BitLockerRecoveryToAd { get; set; }

        public bool DisableRecoveryEnvironment { get; set; }

        public string Wallpaper { get; set; } = string.Empty;

        public string LockScreen { get; set; } = string.Empty;

        public string StartLayout { get; set; } = string.Empty;

        public string OrganizationName { get; set; } = string.Empty;

        public string Logo { get; set; } = string.Empty;

        public string SupportPhone { get; set; } = string.Empty;

        [JsonPropertyName("supportURL")]
        public string SupportUrl { get; set; } = string.Empty;

        public bool ShowProvisioningScreen { get; set; }

        public WifiConfig Wifi { get; set; } = new();

        public ActivationConfig Activation { get; set; } = new();

        public List<RegistryConfig> RegistryTweaks { get; set; } = new();
    }

    public sealed class ScriptConfig
    {
        public string Name { get; set; } = string.Empty;

        public string Phase { get; set; } = string.Empty;

        public string File { get; set; } = string.Empty;

        public bool ContinueOnError { get; set; }
    }

    // MARK: - Build

    /// <summary>Assembles the payload at &lt;volume&gt;\ImageHub.</summary>
    public static string Write(
        DeploymentTemplate template,
        ResolvedSecrets secrets,
        string volumeRoot,
        Action<string> log)
    {
        string root = Path.Combine(volumeRoot, FolderName);
        if (Directory.Exists(root)) { Directory.Delete(root, recursive: true); }
        Directory.CreateDirectory(root);

        // 1. Provisioning scripts, shared verbatim with the macOS app and the
        //    PowerShell builder.
        PayloadSource.CopyTo(root, log);

        // 2. Bundled installers.
        var apps = new List<AppConfig>();
        string installers = Path.Combine(root, "Installers");
        foreach (AppSelection app in template.EnabledApps)
        {
            string relativeInstaller = string.Empty;
            if (app.Source == AppSource.Installer)
            {
                if (!File.Exists(app.InstallerPath))
                {
                    throw new BuildException(
                        $"Installer for “{app.DisplayName}” is missing: {app.InstallerPath}");
                }
                Directory.CreateDirectory(installers);
                string fileName = Path.GetFileName(app.InstallerPath);
                string destination = Path.Combine(installers, fileName);
                if (!File.Exists(destination))
                {
                    log($"Copying installer {fileName}…");
                    File.Copy(app.InstallerPath, destination);
                }
                relativeInstaller = "Installers\\" + fileName;
            }
            apps.Add(new AppConfig
            {
                Name = app.DisplayName,
                Source = RawEnum.Of(app.Source),
                PackageId = app.PackageId,
                Version = app.Version,
                Installer = relativeInstaller,
                SilentArgs = app.SilentArgs,
                Script = app.Script,
                Required = app.Required,
            });
        }

        // 3. Microsoft 365 through the Office Deployment Tool.
        //
        // setup.exe is resolved by UsbWriter before this runs — downloaded from
        // Microsoft or the operator's pinned copy — and configuration.xml is generated
        // here so a mistake in it surfaces on this PC, not on a bench.
        var office = new Microsoft365Config
        {
            Enabled = false,
            TimeoutMinutes = Microsoft365Spec.TimeoutMinutes,
        };
        if (template.Microsoft365.Enabled)
        {
            if (!File.Exists(template.Microsoft365.SetupPath))
            {
                throw new BuildException(
                    "Microsoft 365 is enabled but the Office Deployment Tool setup.exe is missing: "
                    + template.Microsoft365.SetupPath);
            }
            string officeDirectory = Path.Combine(root, "Office");
            Directory.CreateDirectory(officeDirectory);

            log($"Copying the Office Deployment Tool ({Path.GetFileName(template.Microsoft365.SetupPath)})…");
            File.Copy(template.Microsoft365.SetupPath, Path.Combine(officeDirectory, "setup.exe"), overwrite: true);

            File.WriteAllText(
                Path.Combine(officeDirectory, OfficeConfigBuilder.FileName),
                OfficeConfigBuilder.Xml(template),
                new UTF8Encoding(false));

            office.Enabled = true;
            office.Setup = "Office\\setup.exe";
            office.Configuration = "Office\\" + OfficeConfigBuilder.FileName;
            log($"Wrote {OfficeConfigBuilder.FileName} for Microsoft 365.");
        }

        // 4. Assets referenced by the template.
        string assets = Path.Combine(root, "Assets");
        string CopyAsset(string path, string name)
        {
            if (path.Length == 0) { return string.Empty; }
            if (!File.Exists(path))
            {
                log($"⚠ Asset not found, skipping: {path}");
                return string.Empty;
            }
            Directory.CreateDirectory(assets);
            string extension = Path.GetExtension(path);
            string fileName = extension.Length == 0 ? name : name + extension;
            File.Copy(path, Path.Combine(assets, fileName), overwrite: true);
            return "Assets\\" + fileName;
        }

        string wallpaper = CopyAsset(template.System.WallpaperPath, "Wallpaper");
        string lockScreen = CopyAsset(template.System.LockScreenPath, "LockScreen");
        string startLayout = CopyAsset(template.System.StartLayoutPath, "StartLayout");
        string logo = CopyAsset(template.System.LogoPath, "Logo");

        // 5. Custom scripts.
        var scripts = new List<ScriptConfig>();
        string scriptsDirectory = Path.Combine(root, "Scripts");
        foreach (CustomScript script in template.Scripts)
        {
            if (!script.Enabled || script.Body.Length == 0) { continue; }
            Directory.CreateDirectory(scriptsDirectory);
            string name = ScriptFileName(script);
            // No BOM and the body verbatim, exactly as the macOS side writes it.
            File.WriteAllText(Path.Combine(scriptsDirectory, name), script.Body, new UTF8Encoding(false));
            scripts.Add(new ScriptConfig
            {
                Name = script.Name,
                Phase = RawEnum.Of(script.Phase),
                File = "Scripts\\" + name,
                ContinueOnError = script.ContinueOnError,
            });
        }

        // 6. Resolved config + an audit copy of the template itself.
        PayloadConfig config = MakeConfig(
            template, secrets, apps, office, scripts, wallpaper, lockScreen, startLayout, logo);

        File.WriteAllText(Path.Combine(root, ConfigFileName), Json.Serialize(config), new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(root, "template.json"), Json.Serialize(template), new UTF8Encoding(false));

        log($"Payload written to {root}");
        return root;
    }

    public static string ScriptFileName(CustomScript script)
    {
        const string allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_";
        var slug = new StringBuilder();
        foreach (char c in script.Name)
        {
            slug.Append(allowed.IndexOf(c) >= 0 ? c : '-');
            if (slug.Length == 40) { break; }
        }
        string stem = slug.Length == 0 ? "script" : slug.ToString();
        string shortId = script.Id.ToString("D").ToUpperInvariant().Substring(0, 8);
        return $"{stem}-{shortId}.ps1";
    }

    private static PayloadConfig MakeConfig(
        DeploymentTemplate template,
        ResolvedSecrets secrets,
        List<AppConfig> apps,
        Microsoft365Config office,
        List<ScriptConfig> scripts,
        string wallpaper,
        string lockScreen,
        string startLayout,
        string logo)
    {
        SystemSpec system = template.System;
        return new PayloadConfig
        {
            GeneratedBy = "ImageHub " + AppVersion.Current,
            GeneratedAt = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture),
            TemplateId = template.Id.ToString("D").ToUpperInvariant(),
            TemplateName = template.Name,
            Admin = new AdminConfig
            {
                Username = template.Admin.Enabled ? template.Admin.Username : string.Empty,
                DisplayName = template.Admin.DisplayName,
                AccountDescription = template.Admin.AccountDescription,
                HideFromLoginScreen = template.Admin.HideFromLoginScreen,
                PasswordNeverExpires = template.Admin.PasswordNeverExpires,
            },
            EndUser = new EndUserConfig
            {
                Mode = RawEnum.Of(template.EndUser.Mode),
                Username = template.EndUser.Username,
                DisplayName = template.EndUser.DisplayName,
                Administrator = template.EndUser.Administrator,
                MustChangePassword = template.EndUser.MustChangePassword,
                WelcomeNote = template.EndUser.WelcomeNote,
                PromptTimeoutMinutes = template.EndUser.PromptTimeoutMinutes,
            },
            Identity = new IdentityConfig
            {
                JoinMode = RawEnum.Of(template.Identity.JoinMode),
                Workgroup = template.Identity.Workgroup,
                Domain = template.Identity.Domain,
            },
            Apps = apps,
            Microsoft365 = office,
            System = new SystemConfig
            {
                ComputerNameTemplate = system.ComputerNameTemplate,
                TimeZone = system.TimeZone,
                EnableRemoteDesktop = system.EnableRemoteDesktop,
                AllowPing = system.AllowPing,
                PowerPlanGuid = Labels.Guid(system.PowerPlan),
                DisableSleepOnAc = system.DisableSleepOnAc,
                DisableFastStartup = system.DisableFastStartup,
                DisableHibernation = system.DisableHibernation,
                ScreenLockMinutes = system.ScreenLockMinutes,
                ManagePowerTimeouts = system.ManagePowerTimeouts,
                DisplayOffMinutesAc = system.DisplayOffMinutesAc,
                DisplayOffMinutesDc = system.DisplayOffMinutesDc,
                SleepMinutesAc = system.SleepMinutesAc,
                SleepMinutesDc = system.SleepMinutesDc,
                LidCloseActionAc = Labels.Index(system.LidCloseActionAc),
                LidCloseActionDc = Labels.Index(system.LidCloseActionDc),
                ShowFileExtensions = system.ShowFileExtensions,
                ShowHiddenFiles = system.ShowHiddenFiles,
                ClassicContextMenu = system.ClassicContextMenu,
                TaskbarAlignLeft = system.TaskbarAlignLeft,
                DisableWidgets = system.DisableWidgets,
                DisableWebSearch = system.DisableWebSearch,
                DisableTelemetry = system.DisableTelemetry,
                DisableConsumerFeatures = system.DisableConsumerFeatures,
                RemoveBloatware = system.RemoveBloatware,
                Bloatware = system.RemoveBloatware ? new List<string>(system.BloatwareList) : new List<string>(),
                WindowsUpdate = RawEnum.Of(system.WindowsUpdate),
                InstallUpdates = system.InstallUpdatesDuringProvisioning,
                OptionalFeatures = new List<string>(system.OptionalFeatures),
                BitLocker = RawEnum.Of(system.BitLocker),
                BitLockerRecoveryToAd = system.EnableBitLockerRecoveryToAd,
                DisableRecoveryEnvironment = !template.Disk.RecoveryPartition,
                Wallpaper = wallpaper,
                LockScreen = lockScreen,
                StartLayout = startLayout,
                OrganizationName = system.OrganizationName,
                Logo = logo,
                SupportPhone = system.SupportPhone,
                SupportUrl = system.SupportUrl,
                ShowProvisioningScreen = system.ShowProvisioningScreen,
                Wifi = new WifiConfig
                {
                    Enabled = system.Wifi.Enabled,
                    Ssid = system.Wifi.Ssid,
                    Password = system.Wifi.Enabled ? secrets.WifiPassword : string.Empty,
                    Security = system.Wifi.Security,
                    Hidden = system.Wifi.Hidden,
                    ConnectAutomatically = system.Wifi.ConnectAutomatically,
                },
                Activation = new ActivationConfig
                {
                    Mode = RawEnum.Of(template.Windows.Activation.Mode),
                    KmsHost = template.Windows.Activation.KmsHost,
                },
                RegistryTweaks = system.RegistryTweaks
                    .Where(tweak => tweak.Enabled && tweak.Name.Length > 0)
                    .Select(tweak => new RegistryConfig
                    {
                        Path = tweak.Path,
                        Name = tweak.Name,
                        Type = RawEnum.Of(tweak.Type),
                        Value = tweak.Value,
                    })
                    .ToList(),
            },
            Scripts = scripts,
        };
    }
}

/// <summary>
/// Where the provisioning scripts come from.
///
/// Shared/payload is the canonical copy; it is embedded in ImageHub.exe at build
/// time so a single .exe carries everything it needs to write a drive, the way the
/// macOS app carries them in its bundle. The Settings override points at a
/// checkout's Shared/payload so a change to Provision.ps1 can be tested without
/// rebuilding ImageHub.
///
/// Files are copied byte for byte and never rewritten. Provision.ps1 has to keep
/// its UTF-8 BOM: Windows PowerShell 5.1 decodes a BOM-less file as ANSI, and CI
/// checks the repository copies for exactly that.
/// </summary>
public static class PayloadSource
{
    private const string ResourcePrefix = "payload/";

    /// <summary>A folder holding Provision.ps1, or null when the embedded copy is used.</summary>
    public static string? OverrideDirectory
    {
        get
        {
            string path = Settings.Current.PayloadSourcePath;
            if (path.Length == 0) { return null; }
            return File.Exists(Path.Combine(path, "Provision.ps1")) ? path : null;
        }
    }

    public static string Describe()
    {
        string? over = OverrideDirectory;
        if (over is not null) { return over; }
        int count = Names().Count;
        return count > 0
            ? $"{count} files embedded in ImageHub.exe"
            : "missing — this build has no provisioning scripts";
    }

    public static IReadOnlyList<string> Names()
    {
        var names = new List<string>();
        foreach (string resource in Assembly.GetExecutingAssembly().GetManifestResourceNames())
        {
            if (resource.StartsWith(ResourcePrefix, StringComparison.Ordinal))
            {
                names.Add(resource.Substring(ResourcePrefix.Length));
            }
        }
        names.Sort(StringComparer.OrdinalIgnoreCase);
        return names;
    }

    public static void CopyTo(string destination, Action<string> log)
    {
        string? over = OverrideDirectory;
        if (over is not null)
        {
            log($"Copying provisioning scripts from {over}…");
            foreach (string file in Directory.GetFiles(over))
            {
                string name = Path.GetFileName(file);
                if (name.Equals(".DS_Store", StringComparison.OrdinalIgnoreCase)) { continue; }
                File.Copy(file, Path.Combine(destination, name), overwrite: true);
            }
            return;
        }

        IReadOnlyList<string> names = Names();
        if (names.Count == 0 || !names.Any(n => n.Equals("Provision.ps1", StringComparison.OrdinalIgnoreCase)))
        {
            throw new BuildException(
                "This build of ImageHub has no provisioning scripts embedded (Shared/payload/Provision.ps1). "
                + "Point Options → Advanced at a repository checkout's Shared\\payload folder, or "
                + "reinstall ImageHub.");
        }

        log($"Writing {names.Count} provisioning script(s) from the app…");
        Assembly assembly = Assembly.GetExecutingAssembly();
        foreach (string name in names)
        {
            using Stream? source = assembly.GetManifestResourceStream(ResourcePrefix + name);
            if (source is null) { continue; }
            using FileStream target = File.Create(Path.Combine(destination, name));
            source.CopyTo(target);
        }
    }

    /// <summary>Reads one embedded script, for the Options page's "what shipped" list.</summary>
    public static byte[]? Read(string name)
    {
        using Stream? source = Assembly.GetExecutingAssembly()
            .GetManifestResourceStream(ResourcePrefix + name);
        if (source is null) { return null; }
        using var buffer = new MemoryStream();
        source.CopyTo(buffer);
        return buffer.ToArray();
    }
}
