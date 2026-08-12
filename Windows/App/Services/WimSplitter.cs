using System;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using ImageHub.Models;
using ImageHub.Support;

namespace ImageHub.Services;

/// <summary>
/// Splits an oversized install.wim into FAT32-sized install*.swm parts.
///
/// This is the one place where Windows has it easier than the Mac: DISM ships with
/// the OS and does the split itself, so unlike the macOS app there is no bundled
/// wimlib, no Homebrew fallback, and nothing for an operator to install. The
/// resulting parts are identical either way — Setup reads .swm natively.
/// </summary>
public static class WimSplitter
{
    /// <summary>
    /// Part size in MB. Comfortably under FAT32's 4 GiB per-file ceiling, and the same
    /// figure the macOS side passes to wimlib so both produce the same number of parts
    /// from the same image.
    /// </summary>
    public const int SplitPartSizeMb = 3800;

    private static readonly Regex PercentPattern =
        new(@"(\d{1,3}(?:[.,]\d+)?)\s*%", RegexOptions.Compiled);

    /// <summary>
    /// Splits <paramref name="source"/> into <paramref name="firstPart"/>,
    /// install2.swm, … <paramref name="progress"/> receives 0…1 parsed from DISM's own
    /// output, so the longest stage of a build shows real movement instead of a static
    /// bar.
    /// </summary>
    public static async Task SplitAsync(
        string source,
        string firstPart,
        Action<string> log,
        Action<double> progress,
        CancellationToken cancellation = default)
    {
        if (Path.GetExtension(source).Equals(".esd", StringComparison.OrdinalIgnoreCase))
        {
            throw new BuildException(
                "This ISO's install image is an .esd larger than 4 GB. DISM can only split a .wim, "
                + "so the file cannot be made to fit the FAT32 volume UEFI boots from. Use an ISO "
                + "whose sources folder holds install.wim — Microsoft's own retail media does.");
        }

        log($"Splitting {Path.GetFileName(source)} into {SplitPartSizeMb} MB parts with DISM…");

        string[] arguments =
        {
            "/Split-Image",
            "/ImageFile:" + source,
            "/SWMFile:" + firstPart,
            "/FileSize:" + SplitPartSizeMb.ToString(CultureInfo.InvariantCulture),
            // Predictable output regardless of the machine's display language, so the
            // progress parse below is not language-dependent.
            "/English",
        };

        double last = -1;
        ProcessResult result = await ProcessRunner.RunWithProgressAsync(
            ProcessRunner.Dism,
            arguments,
            chunk =>
            {
                double? fraction = Fraction(chunk);
                if (fraction is double value)
                {
                    // DISM redraws its bar constantly; only forward real movement so the
                    // build log does not fill with thousands of identical lines.
                    if (value - last >= 0.005 || value >= 1)
                    {
                        last = value;
                        progress(value);
                    }
                    return;
                }
                string text = chunk.Trim();
                if (text.Length > 0 && !text.StartsWith("[", StringComparison.Ordinal)) { log(text); }
            },
            cancellation).ConfigureAwait(false);

        if (!result.Succeeded)
        {
            throw new BuildException(
                $"DISM couldn't split {Path.GetFileName(source)} (exit code {result.ExitCode}). "
                + result.FailureMessage);
        }

        progress(1);
    }

    /// <summary>
    /// Pulls the fraction out of DISM's progress bar, which looks like
    /// <c>[==========          28.0%                    ]</c>.
    /// </summary>
    public static double? Fraction(string line)
    {
        Match match = PercentPattern.Match(line ?? string.Empty);
        if (!match.Success) { return null; }
        string number = match.Groups[1].Value.Replace(',', '.');
        if (!double.TryParse(number, NumberStyles.Float, CultureInfo.InvariantCulture, out double percent))
        {
            return null;
        }
        return Math.Clamp(percent / 100.0, 0, 1);
    }
}
