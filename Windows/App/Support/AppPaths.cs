using System;
using System.IO;

namespace ImageHub.Support;

/// <summary>
/// Where ImageHub keeps its files.
///
/// Split across roaming and local on purpose, which is the Windows convention the
/// macOS app has no equivalent for: templates and settings are small and worth
/// following a user between machines, so they live in %APPDATA%. Multi-gigabyte
/// ISOs, logs and caches must never be roamed, so they live in %LOCALAPPDATA%.
/// Secrets are local too — DPAPI ties them to this user on this machine, so a
/// roamed copy could not be decrypted anywhere else anyway.
/// </summary>
public static class AppPaths
{
    private const string FolderName = "ImageHub";

    public static string Roaming => Ensure(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), FolderName));

    public static string Local => Ensure(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), FolderName));

    public static string Templates => Ensure(Path.Combine(Roaming, "Templates"));

    public static string Images => Ensure(Path.Combine(Local, "Images"));

    public static string Logs => Ensure(Path.Combine(Local, "Logs"));

    public static string Cache => Ensure(Path.Combine(Local, "Cache"));

    public static string ImageIndex => Path.Combine(Local, "images.json");

    public static string SettingsFile => Path.Combine(Roaming, "settings.json");

    public static string SecretsFile => Path.Combine(Local, "secrets.dat");

    public static string OfficeDeploymentTool => Path.Combine(Cache, "OfficeDeploymentTool", "setup.exe");

    /// <summary>The running ImageHub.exe. Assembly.Location is empty in a single-file build.</summary>
    public static string Executable => Environment.ProcessPath ?? string.Empty;

    private static string Ensure(string path)
    {
        try { Directory.CreateDirectory(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        return path;
    }

    public static void Reveal(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = path,
                    UseShellExecute = true,
                });
            }
            else if (File.Exists(path))
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = "/select,\"" + path + "\"",
                    UseShellExecute = true,
                });
            }
        }
        catch (Exception)
        {
            // Opening Explorer is a convenience; never worth an error dialog.
        }
    }

    public static void OpenUrl(string url)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = url,
                UseShellExecute = true,
            });
        }
        catch (Exception)
        {
        }
    }
}
