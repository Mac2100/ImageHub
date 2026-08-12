using System;
using System.IO;
using System.Text.Json.Serialization;
using ImageHub.Support;

namespace ImageHub.Services;

[JsonConverter(typeof(RawEnumConverter<AppearanceMode>))]
public enum AppearanceMode
{
    [Raw("system")] System,
    [Raw("light")] Light,
    [Raw("dark")] Dark,
}

/// <summary>
/// User preferences, in one JSON file next to the templates.
///
/// The macOS app keeps these in UserDefaults; a plain file is the equivalent that
/// does not need the registry, roams with the rest of ImageHub's roaming data, and
/// can be inspected when something looks wrong. Every write is immediate — these
/// are a few hundred bytes and a setting that silently failed to persist is worse
/// than the write.
/// </summary>
public sealed class Settings : Observable
{
    private static Settings? _current;

    public static Settings Current
    {
        get
        {
            _current ??= Load();
            return _current;
        }
    }

    // Appearance
    public string ThemeId { get; set; } = "hub";

    public AppearanceMode Appearance { get; set; } = AppearanceMode.System;

    // Media
    public string DefaultVolumeLabel { get; set; } = "IMAGEHUB";

    public bool EjectAfterBuild { get; set; }

    // Downloads
    public string DefaultLanguage { get; set; } = "en-US";

    /// <summary>
    /// Whether an imported ISO is copied into the library by default. Linking is the
    /// better answer for a file that already lives somewhere permanent, so the import
    /// dialog asks each time and this only seeds which button is highlighted.
    /// </summary>
    public bool CopyImportedIsos { get; set; }

    // In-app
    public bool ShowBanners { get; set; } = true;

    // Secrets
    public SecretBackend SecretBackend { get; set; } = SecretBackend.Dpapi;

    // Updates
    public bool AutoCheckUpdates { get; set; } = true;

    // Notifications
    public bool NotifyBuildFinished { get; set; } = true;

    public bool NotifyBuildFailed { get; set; } = true;

    public bool NotifyDownloadFinished { get; set; }

    public bool NotifyUpdateAvailable { get; set; } = true;

    /// <summary>
    /// Points the payload writer at a checkout's Shared/payload folder instead of the
    /// copy embedded in the .exe, for testing a change to Provision.ps1 without
    /// rebuilding ImageHub.
    /// </summary>
    public string PayloadSourcePath { get; set; } = string.Empty;

    /// <summary>
    /// Seeded once, on genuine first run. Keying off "the folder is empty" would
    /// silently recreate the starter templates after someone deleted the last one,
    /// which reads as deletion not working.
    /// </summary>
    public bool DidSeedStarterTemplates { get; set; }

    // Window placement, so the app opens where it was left.
    public double WindowWidth { get; set; } = 1180;

    public double WindowHeight { get; set; } = 780;

    public bool WindowMaximized { get; set; }

    public void Save()
    {
        try
        {
            string path = AppPaths.SettingsFile;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, Json.Serialize(this));
        }
        catch (Exception)
        {
            // A preference that could not be written is not worth interrupting the
            // operator; it will be written again on the next change.
        }
    }

    private static Settings Load()
    {
        try
        {
            string path = AppPaths.SettingsFile;
            if (File.Exists(path))
            {
                Settings? loaded = Json.Deserialize<Settings>(File.ReadAllText(path));
                if (loaded is not null) { return loaded; }
            }
        }
        catch (Exception)
        {
        }
        return new Settings();
    }
}
