using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using ImageHub.Models;
using ImageHub.Support;
using Microsoft.Win32;

namespace ImageHub.Services;

/// <summary>
/// Moves the app into a permanent home, on request.
///
/// ImageHub ships as one self-contained .exe, which is what lets the updater swap a
/// single file and needs no runtime installed. The cost is that a freshly downloaded
/// copy runs from wherever the browser put it: no Start Menu entry, nothing in
/// Programs and Features, and in-app updates quietly rewriting a file in Downloads.
/// Someone who double-clicks the download and gets a running app reasonably concludes
/// that installing did not happen.
///
/// So the app offers to install itself the first time it runs from a folder that looks
/// like a download rather than a home: it copies itself to
/// %LOCALAPPDATA%\Programs\ImageHub, adds a Start Menu shortcut, registers an
/// uninstaller, and relaunches from there. All per-user, so there is no UAC prompt,
/// and declining leaves it genuinely portable.
/// </summary>
public static class Installer
{
    public const string DisplayName = "ImageHub";

    /// <summary>Per-user, so installing needs no administrator rights.</summary>
    private const string UninstallKey =
        @"Software\Microsoft\Windows\CurrentVersion\Uninstall\ImageHub";

    public static string InstallDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Programs", "ImageHub");

    public static string InstalledExePath => Path.Combine(InstallDirectory, "ImageHub.exe");

    private static string ShortcutPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
        "Programs", "ImageHub.lnk");

    /// <summary>The running .exe. Empty if that cannot be determined.</summary>
    public static string CurrentExePath
    {
        get
        {
            // Not Assembly.Location: that is empty for a single-file publish, because
            // there is no assembly on disk to point at.
            try { return Environment.ProcessPath ?? string.Empty; }
            catch (Exception) { return string.Empty; }
        }
    }

    public static bool IsInstalled =>
        File.Exists(InstalledExePath) && Registry.CurrentUser.OpenSubKey(UninstallKey) is not null;

    /// <summary>True when this process is the installed copy.</summary>
    public static bool IsRunningInstalled =>
        CurrentExePath.Length > 0
        && Path.GetDirectoryName(CurrentExePath) is string directory
        && string.Equals(
            Path.TrimEndingDirectorySeparator(directory),
            Path.TrimEndingDirectorySeparator(InstallDirectory),
            StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Whether to offer installing on this launch.
    ///
    /// Only from somewhere that looks transient — a download, the desktop, a temp
    /// folder. Running deliberately from a stick or a share is a portable use, and
    /// being asked to install every time would be an irritation rather than a help.
    /// </summary>
    public static bool ShouldOffer()
    {
        if (Settings.Current.InstallPromptAnswered) { return false; }
        if (IsRunningInstalled) { return false; }

        string exe = CurrentExePath;
        if (exe.Length == 0) { return false; }

        string? directory = Path.GetDirectoryName(exe);
        if (directory is null) { return false; }

        // A removable or network drive means "run me from here", not "install me".
        try
        {
            var drive = new DriveInfo(Path.GetPathRoot(exe) ?? string.Empty);
            if (drive.DriveType is DriveType.Removable or DriveType.Network) { return false; }
        }
        catch (Exception)
        {
            // An unrecognisable root is not a reason to nag.
            return false;
        }

        foreach (string transient in TransientFolders())
        {
            if (transient.Length > 0 && IsInside(directory, transient)) { return true; }
        }
        return false;
    }

    private static string[] TransientFolders()
    {
        string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return new[]
        {
            // No SpecialFolder for Downloads, and this is where every browser puts it.
            profile.Length > 0 ? Path.Combine(profile, "Downloads") : string.Empty,
            Environment.GetFolderPath(Environment.SpecialFolder.Desktop),
            Path.GetTempPath(),
        };
    }

    private static bool IsInside(string candidate, string parent)
    {
        try
        {
            string a = Path.TrimEndingDirectorySeparator(Path.GetFullPath(candidate));
            string b = Path.TrimEndingDirectorySeparator(Path.GetFullPath(parent));
            return a.Equals(b, StringComparison.OrdinalIgnoreCase)
                || a.StartsWith(b + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>
    /// The result of an install: where the app now lives, and anything that did not
    /// work but was not worth abandoning the install over.
    /// </summary>
    public sealed record InstallOutcome(string ExePath, string? Warning);

    /// <summary>
    /// Copies this .exe into the install directory, adds the Start Menu shortcut and
    /// the uninstall entry.
    ///
    /// Only the copy is essential — it is what puts the app somewhere permanent, and
    /// what makes in-app updates land there instead of in Downloads. If that fails
    /// there is no install and this throws. The shortcut and the Programs and Features
    /// entry are conveniences: failing either would leave a copied .exe stranded with
    /// no record of it, which is worse than an install that reports what it missed.
    /// </summary>
    public static async Task<InstallOutcome> InstallAsync()
    {
        string source = CurrentExePath;
        if (source.Length == 0)
        {
            throw new BuildException("Couldn't work out where ImageHub is running from.");
        }

        Directory.CreateDirectory(InstallDirectory);
        string target = InstalledExePath;

        if (!string.Equals(source, target, StringComparison.OrdinalIgnoreCase))
        {
            // An older installed copy may be sitting there. It cannot be overwritten
            // while running, but it is not running: this process is the one from the
            // download folder. Same rename-aside trick the updater uses, so a locked
            // file still gets replaced rather than failing the install.
            if (File.Exists(target))
            {
                string aside = target + ".old";
                try
                {
                    if (File.Exists(aside)) { File.Delete(aside); }
                    File.Move(target, aside);
                }
                catch (IOException)
                {
                    // Leave it; the copy below will fail with a clearer message.
                }
            }

            await Task.Run(() => File.Copy(source, target, overwrite: true)).ConfigureAwait(false);
        }

        var missed = new System.Collections.Generic.List<string>();

        try
        {
            await CreateShortcutAsync(target).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            missed.Add("the Start Menu shortcut (" + error.Message + ")");
        }

        try
        {
            RegisterUninstall(target);
        }
        catch (Exception error)
        {
            missed.Add("the Programs and Features entry (" + error.Message + ")");
        }

        string? warning = missed.Count == 0
            ? null
            : "ImageHub was installed to " + InstallDirectory
                + ", but couldn't create " + string.Join(" or ", missed)
                + ". The app itself is fine — you can start it from that folder.";

        return new InstallOutcome(target, warning);
    }

    /// <summary>
    /// Writes the Start Menu shortcut through WScript.Shell.
    ///
    /// A .lnk is a binary structure with no supported way to write it from .NET
    /// directly; the alternatives are ~80 lines of IShellLink COM interop or this. The
    /// app already requires PowerShell for every disk operation, so this adds no
    /// dependency and far less that can go subtly wrong.
    /// </summary>
    private static async Task CreateShortcutAsync(string exePath)
    {
        string? folder = Path.GetDirectoryName(ShortcutPath);
        if (folder is not null) { Directory.CreateDirectory(folder); }

        // Not interpolated: the script has braces, and the paths go in as tokens so a
        // folder with a quote or a $ in it cannot break out of the string.
        const string script = """
            $shell = New-Object -ComObject WScript.Shell
            $link = $shell.CreateShortcut('__LNK__')
            $link.TargetPath = '__EXE__'
            $link.WorkingDirectory = '__DIR__'
            $link.Description = 'Build bootable Windows golden-image USB drives'
            $link.IconLocation = '__EXE__,0'
            $link.Save()
            """;

        string filled = script
            .Replace("__LNK__", Escape(ShortcutPath))
            .Replace("__EXE__", Escape(exePath))
            .Replace("__DIR__", Escape(Path.GetDirectoryName(exePath) ?? InstallDirectory));

        ProcessResult result = await ProcessRunner.PowerShellAsync(filled).ConfigureAwait(false);
        if (!result.Succeeded)
        {
            throw new BuildException(
                "Couldn't create the Start Menu shortcut: " + result.FailureMessage);
        }
    }

    /// <summary>Doubles single quotes, which is how PowerShell escapes them.</summary>
    private static string Escape(string value) => value.Replace("'", "''");

    private static void RegisterUninstall(string exePath)
    {
        using RegistryKey key = Registry.CurrentUser.CreateSubKey(UninstallKey, writable: true);
        key.SetValue("DisplayName", DisplayName);
        key.SetValue("DisplayVersion", AppVersion.Current);
        key.SetValue("Publisher", "ImageHub");
        key.SetValue("DisplayIcon", exePath + ",0");
        key.SetValue("InstallLocation", InstallDirectory);
        key.SetValue("UninstallString", "\"" + exePath + "\" --uninstall");
        key.SetValue("QuietUninstallString", "\"" + exePath + "\" --uninstall");
        key.SetValue("NoModify", 1, RegistryValueKind.DWord);
        key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        key.SetValue("URLInfoAbout", "https://github.com/" + UpdateChecker.Repo);

        try
        {
            // Programs and Features shows this; in KB, by its own convention.
            var info = new FileInfo(exePath);
            key.SetValue("EstimatedSize", (int)(info.Length / 1024), RegistryValueKind.DWord);
        }
        catch (Exception)
        {
            // A missing size is cosmetic.
        }
    }

    /// <summary>
    /// Undoes an install: removes the shortcut and the Programs and Features entry,
    /// then deletes the installed copy.
    ///
    /// Templates, settings and the image library are deliberately left alone. They live
    /// under %APPDATA% and %LOCALAPPDATA%, they represent real work, and an uninstall
    /// that silently destroyed a technician's templates would be indefensible. The
    /// summary says where they are so they can be removed by hand.
    /// </summary>
    public static string Uninstall()
    {
        try { File.Delete(ShortcutPath); } catch (Exception) { }
        try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, throwOnMissingSubKey: false); }
        catch (Exception) { }

        string exe = CurrentExePath;
        if (exe.Length > 0) { ScheduleSelfDelete(exe); }

        return "ImageHub has been removed. Your templates and settings were left in:\r\n"
            + AppPaths.Roaming + "\r\n" + AppPaths.Local;
    }

    /// <summary>
    /// A running .exe cannot delete itself, so a short-lived cmd outlives this process
    /// and does it. The directory removal is deliberately non-recursive: it goes only
    /// if nothing else was put there.
    /// </summary>
    private static void ScheduleSelfDelete(string exePath)
    {
        string command = "timeout /t 3 /nobreak >nul & del /f /q \"" + exePath + "\""
            + " & rmdir \"" + InstallDirectory + "\"";
        try
        {
            Process.Start(new ProcessStartInfo("cmd.exe", "/c " + command)
            {
                CreateNoWindow = true,
                UseShellExecute = false,
            });
        }
        catch (Exception)
        {
            // Nothing sensible left to do; the entry and shortcut are already gone.
        }
    }

    /// <summary>Relaunches from <paramref name="exePath"/> and returns true if started.</summary>
    public static bool Relaunch(string exePath)
    {
        try
        {
            Process.Start(new ProcessStartInfo(exePath)
            {
                UseShellExecute = true,
                WorkingDirectory = Path.GetDirectoryName(exePath) ?? InstallDirectory,
            });
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
