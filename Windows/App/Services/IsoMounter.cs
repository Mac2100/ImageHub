using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using ImageHub.Models;
using ImageHub.Support;

namespace ImageHub.Services;

/// <summary>
/// Mounting an ISO so its files can be read.
///
/// Windows has this built in — Mount-DiskImage, the same thing double-clicking an
/// ISO in Explorer does — but from a script it needs administrator rights. That is
/// why importing an image can report "editions unknown" when ImageHub is running
/// unelevated: the import still works, the edition list just has to wait until
/// something needs elevation anyway.
///
/// An ISO already attached (by an earlier failed build, or by Explorer) is reused
/// rather than re-mounted, since attaching the same file twice fails.
/// </summary>
public static class IsoMounter
{
    public sealed class Mounted : IAsyncDisposable
    {
        internal Mounted(string isoPath, string driveLetter)
        {
            IsoPath = isoPath;
            DriveLetter = driveLetter;
        }

        public string IsoPath { get; }

        /// <summary>"E:"</summary>
        public string DriveLetter { get; }

        /// <summary>"E:\"</summary>
        public string Root => DriveLetter + "\\";

        public ValueTask DisposeAsync() => new(DismountAsync(IsoPath));
    }

    private const string MountScript = """
        $path = __PATH__
        $image = Get-DiskImage -ImagePath $path -ErrorAction SilentlyContinue
        if (-not $image -or -not $image.Attached) {
            Mount-DiskImage -ImagePath $path -StorageType ISO -PassThru | Out-Null
        }
        $letter = ''
        for ($i = 0; $i -lt 25; $i++) {
            $volume = $null
            try {
                $volume = Get-DiskImage -ImagePath $path -ErrorAction Stop | Get-Volume -ErrorAction Stop
            } catch { }
            if ($volume -and $volume.DriveLetter) { $letter = [string]$volume.DriveLetter; break }
            Start-Sleep -Milliseconds 400
        }
        ConvertTo-Json -InputObject ([ordered]@{ driveLetter = $letter }) -Compress
        """;

    private const string DismountScript = """
        $path = __PATH__
        try {
            $image = Get-DiskImage -ImagePath $path -ErrorAction SilentlyContinue
            if ($image -and $image.Attached) { Dismount-DiskImage -ImagePath $path | Out-Null }
        } catch { }
        """;

    public static async Task<Mounted> MountAsync(
        string isoPath,
        Action<string> log,
        CancellationToken cancellation = default)
    {
        if (!File.Exists(isoPath))
        {
            throw new BuildException($"The ISO is missing: {isoPath}");
        }

        log($"Mounting {Path.GetFileName(isoPath)}…");
        string script = MountScript.Replace("__PATH__", DiskService.PsQuote(Path.GetFullPath(isoPath)));
        ProcessResult result = await ProcessRunner
            .PowerShellAsync(script, null, cancellation).ConfigureAwait(false);

        if (!result.Succeeded)
        {
            throw new BuildException(Explain(result.FailureMessage, isoPath));
        }

        string letter = ReadLetter(result.StandardOutput);
        if (letter.Length == 0)
        {
            throw new BuildException(
                $"{Path.GetFileName(isoPath)} attached but no volume appeared. The usual cause is a "
                + "truncated or still-downloading file — check its size against the source and "
                + "re-import it.");
        }

        log($"Mounted at {letter}\\");
        return new Mounted(Path.GetFullPath(isoPath), letter);
    }

    public static async Task DismountAsync(string isoPath, CancellationToken cancellation = default)
    {
        string script = DismountScript.Replace("__PATH__", DiskService.PsQuote(Path.GetFullPath(isoPath)));
        try
        {
            _ = await ProcessRunner.PowerShellAsync(script, null, cancellation).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // A mount left behind is a nuisance, not a failure worth surfacing on top of
            // whatever else went wrong.
        }
    }

    private static string Explain(string raw, string isoPath)
    {
        string name = Path.GetFileName(isoPath);
        if (raw.Contains("Access is denied", StringComparison.OrdinalIgnoreCase)
            || raw.Contains("requires elevation", StringComparison.OrdinalIgnoreCase)
            || raw.Contains("privilege", StringComparison.OrdinalIgnoreCase))
        {
            return "Mounting an ISO needs administrator rights. Restart ImageHub as administrator "
                + "and try again.";
        }
        if (raw.Contains("not recognized", StringComparison.OrdinalIgnoreCase)
            || raw.Contains("not a valid", StringComparison.OrdinalIgnoreCase)
            || raw.Contains("virtual disk", StringComparison.OrdinalIgnoreCase))
        {
            return $"{name} isn't a readable disk image. The usual cause is a truncated or "
                + "still-downloading file — check its size against the source and re-import it.";
        }
        return $"Couldn't mount {name}: {raw}";
    }

    private static string ReadLetter(string output)
    {
        foreach (string line in (output ?? string.Empty).Split('\n'))
        {
            string trimmed = line.Trim();
            if (!trimmed.StartsWith("{", StringComparison.Ordinal)) { continue; }
            try
            {
                using JsonDocument document = JsonDocument.Parse(trimmed);
                if (document.RootElement.TryGetProperty("driveLetter", out JsonElement value)
                    && value.ValueKind == JsonValueKind.String)
                {
                    string letter = (value.GetString() ?? string.Empty).Trim().TrimEnd(':');
                    if (letter.Length == 1 && char.IsLetter(letter[0]))
                    {
                        return letter.ToUpperInvariant() + ":";
                    }
                }
            }
            catch (JsonException)
            {
            }
        }
        return string.Empty;
    }
}
