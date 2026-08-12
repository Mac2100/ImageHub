using System;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using ImageHub.Models;
using ImageHub.Support;

namespace ImageHub.Services;

/// <summary>
/// Gets hold of the Office Deployment Tool's setup.exe so nobody has to.
///
/// The alternative was making every operator find the ODT on Microsoft's download
/// centre, run the self-extractor, and remember where they put the result — before
/// their first build could even start.
///
/// It is fetched from Microsoft's own CDN rather than committed to this repo and
/// shipped inside ImageHub. Partly size, mostly licence: the ODT ships under
/// Microsoft terms that are not ImageHub's to redistribute under, and downloading it
/// from source at build time sidesteps the question entirely. Office itself is never
/// bundled for the same reason, more emphatically — it is a licensed product.
/// </summary>
public static class OfficeDeploymentTool
{
    /// <summary>
    /// Microsoft's evergreen copy. Versioned download-centre URLs rot every release;
    /// this one is the Click-to-Run bootstrapper Microsoft themselves point deployment
    /// tooling at, and it is the same binary the ODT extracts.
    /// </summary>
    public const string DownloadUrl = "https://officecdn.microsoft.com/pr/wsus/setup.exe";

    /// <summary>Cached under ImageHub's own folder, so it is fetched once per PC rather than per build.</summary>
    public static string CachedPath => AppPaths.OfficeDeploymentTool;

    public static bool IsCached => File.Exists(CachedPath);

    /// <summary>
    /// Returns a usable setup.exe, downloading it if this PC has not got one.
    /// <paramref name="preferred"/> is the operator's own copy when a template names
    /// one; it wins, because somebody who pinned a version meant it.
    /// </summary>
    public static async Task<string> ResolveAsync(
        string preferred,
        Action<string> log,
        CancellationToken cancellation = default)
    {
        if (preferred.Length > 0)
        {
            if (!File.Exists(preferred))
            {
                throw new BuildException(
                    "The Office Deployment Tool this template points at is missing: " + preferred);
            }
            return preferred;
        }

        string destination = CachedPath;
        if (File.Exists(destination))
        {
            log("Using the cached Office Deployment Tool.");
            return destination;
        }

        log("Downloading the Office Deployment Tool from Microsoft…");
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);

        string partial = destination + ".partial";
        try { if (File.Exists(partial)) { File.Delete(partial); } } catch (IOException) { }

        try
        {
            using HttpResponseMessage response = await Downloader.Shared
                .GetAsync(DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancellation)
                .ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                throw new BuildException(
                    $"Microsoft's CDN returned HTTP {(int)response.StatusCode} for the Deployment Tool.");
            }
            await using (Stream source = await response.Content.ReadAsStreamAsync(cancellation)
                             .ConfigureAwait(false))
            await using (FileStream target = File.Create(partial))
            {
                await source.CopyToAsync(target, cancellation).ConfigureAwait(false);
            }
        }
        catch (BuildException)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new BuildException(
                $"Couldn't download the Office Deployment Tool: {error.Message}. Choose a setup.exe "
                + "by hand on the Apps tab, or check this PC's connection.");
        }

        // A 7 MB binary that arrives far smaller is a captive-portal login page or an
        // error document, and it would fail much later and less clearly.
        long size = 0;
        try { size = new FileInfo(partial).Length; } catch (IOException) { }
        if (size <= 1_000_000)
        {
            try { File.Delete(partial); } catch (IOException) { }
            throw new BuildException(
                $"The Office Deployment Tool downloaded as only {Formatting.ByteSize(size)}, which is "
                + "not a real setup.exe — usually a captive portal or a proxy error page. Check this "
                + "PC's connection, or choose a setup.exe by hand on the Apps tab.");
        }

        try { if (File.Exists(destination)) { File.Delete(destination); } } catch (IOException) { }
        File.Move(partial, destination);
        log($"Office Deployment Tool ready ({Formatting.ByteSize(size)}).");
        return destination;
    }
}
