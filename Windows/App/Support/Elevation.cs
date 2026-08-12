using System;
using System.Diagnostics;
using System.Security.Principal;

namespace ImageHub.Support;

/// <summary>
/// Whether this process can do the things that need administrator rights, and how
/// to get them.
///
/// Erasing a disk, mounting an ISO and writing boot files all need elevation;
/// editing templates and checking for updates do not. The app therefore runs
/// asInvoker (see app.manifest) and asks only when it has to, which is why this
/// has to be checkable rather than assumed.
/// </summary>
public static class Elevation
{
    private static bool? _isElevated;

    public static bool IsElevated
    {
        get
        {
            if (_isElevated.HasValue) { return _isElevated.Value; }
            try
            {
                using WindowsIdentity identity = WindowsIdentity.GetCurrent();
                _isElevated = new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
            }
            catch (Exception)
            {
                _isElevated = false;
            }
            return _isElevated.Value;
        }
    }

    public const string Explanation =
        "Erasing a drive, mounting an ISO and writing boot files need administrator "
        + "rights. Everything else — templates, the image library, updates — does not, "
        + "which is why ImageHub doesn't ask for them at launch.";

    /// <summary>
    /// Relaunches ImageHub through the UAC prompt. Returns false if the user
    /// dismissed the prompt, in which case nothing has changed and the caller
    /// should carry on unelevated.
    /// </summary>
    public static bool RelaunchElevated(string? arguments = null)
    {
        string exe = AppPaths.Executable;
        if (string.IsNullOrEmpty(exe)) { return false; }
        try
        {
            var start = new ProcessStartInfo
            {
                FileName = exe,
                Arguments = arguments ?? string.Empty,
                UseShellExecute = true,
                Verb = "runas",
            };
            Process.Start(start);
            return true;
        }
        catch (Exception)
        {
            // ERROR_CANCELLED when the prompt is dismissed. Not an error worth
            // reporting — the operator said no.
            return false;
        }
    }
}
