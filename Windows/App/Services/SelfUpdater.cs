using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using ImageHub.Support;

namespace ImageHub.Services;

/// <summary>
/// In-place self-update: downloads the release .exe, swaps it for the running one,
/// and relaunches.
///
/// The same shape as the macOS updater (download, replace, relaunch, roll back on
/// failure) using the one Windows trick that makes it possible: a running executable
/// cannot be deleted or overwritten, but it *can* be renamed. So the current .exe
/// moves aside to ImageHub.exe.old, the new one takes its place, the new process
/// starts, and the next launch deletes the leftover.
///
/// No installer and no updater service, which is the point: a single .exe that
/// replaces itself has nothing to get out of step.
/// </summary>
public sealed class SelfUpdater : Observable
{
    public static SelfUpdater Shared { get; } = new();

    public enum Phase
    {
        Idle,
        Downloading,
        Installing,
        Relaunching,
        Failed,
    }

    private Phase _stage = Phase.Idle;
    private double _downloadProgress;
    private string _failureMessage = string.Empty;

    private SelfUpdater()
    {
    }

    public Phase Stage { get => _stage; private set => Set(ref _stage, value); }

    /// <summary>0…1 while <see cref="Stage"/> is Downloading.</summary>
    public double DownloadProgress
    {
        get => _downloadProgress;
        private set => Set(ref _downloadProgress, value);
    }

    public string FailureMessage { get => _failureMessage; private set => Set(ref _failureMessage, value); }

    public bool IsBusy => Stage is Phase.Downloading or Phase.Installing or Phase.Relaunching;

    /// <summary>Raised when the new version is in place and the app is about to restart.</summary>
    public event EventHandler? ReadyToRelaunch;

    /// <summary>
    /// Deletes the previous version left behind by an update. Called at startup, when
    /// the process that was using it has certainly exited.
    /// </summary>
    public static void CleanUpAfterUpdate()
    {
        try
        {
            string exe = AppPaths.Executable;
            if (exe.Length == 0) { return; }
            string directory = Path.GetDirectoryName(exe) ?? string.Empty;
            if (directory.Length == 0) { return; }
            foreach (string stale in Directory.GetFiles(directory, "*.exe.old"))
            {
                try { File.Delete(stale); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        }
        catch (Exception)
        {
        }
    }

    /// <summary>
    /// Downloads and installs an update. Falls back to opening the URL in the browser
    /// when the release has no .exe to swap — a zip or a release page needs a human.
    /// </summary>
    public async Task InstallAsync(string url, CancellationToken cancellation = default)
    {
        if (IsBusy) { return; }
        if (!url.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            AppPaths.OpenUrl(url);
            return;
        }

        string target = AppPaths.Executable;
        if (target.Length == 0)
        {
            Fail("ImageHub couldn't work out where it is running from, so it can't replace itself.");
            return;
        }

        Stage = Phase.Downloading;
        DownloadProgress = 0;
        FailureMessage = string.Empty;

        string downloaded = Path.Combine(Path.GetTempPath(),
            "ImageHub-update-" + Guid.NewGuid().ToString("N") + ".exe");

        try
        {
            await DownloadAsync(url, downloaded, cancellation).ConfigureAwait(true);

            // A release asset that is not a Windows executable would replace ImageHub
            // with something that cannot start, and the only clue would be a dead
            // shortcut. Two cheap checks close that off.
            long size = new FileInfo(downloaded).Length;
            if (size < 5_000_000 || !LooksLikeExecutable(downloaded))
            {
                throw new BuildException(
                    $"The downloaded file is not a Windows program ({Formatting.ByteSize(size)}). "
                    + "Nothing was changed. Download the release from GitHub instead.");
            }

            Stage = Phase.Installing;
            string parked = target + ".old";
            await Task.Run(() => Swap(downloaded, target, parked), cancellation).ConfigureAwait(true);

            Stage = Phase.Relaunching;
            Relaunch(target);
            ReadyToRelaunch?.Invoke(this, EventArgs.Empty);
        }
        catch (OperationCanceledException)
        {
            Stage = Phase.Idle;
            TryDelete(downloaded);
        }
        catch (Exception error)
        {
            TryDelete(downloaded);
            Fail(Explain(error, target));
        }
    }

    private async Task DownloadAsync(string url, string destination, CancellationToken cancellation)
    {
        using HttpResponseMessage response = await Downloader.Shared
            .GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancellation).ConfigureAwait(true);
        if (!response.IsSuccessStatusCode)
        {
            throw new BuildException($"Download failed (HTTP {(int)response.StatusCode}).");
        }

        long total = response.Content.Headers.ContentLength ?? 0;
        await using Stream source = await response.Content.ReadAsStreamAsync(cancellation)
            .ConfigureAwait(true);
        await using FileStream target = File.Create(destination);

        var buffer = new byte[1 << 20];
        long received = 0;
        DateTime lastUpdate = DateTime.MinValue;
        while (true)
        {
            int read = await source.ReadAsync(buffer, cancellation).ConfigureAwait(true);
            if (read <= 0) { break; }
            await target.WriteAsync(buffer.AsMemory(0, read), cancellation).ConfigureAwait(true);
            received += read;
            if (total > 0 && (DateTime.Now - lastUpdate).TotalMilliseconds > 150)
            {
                lastUpdate = DateTime.Now;
                DownloadProgress = Math.Min(1, (double)received / total);
            }
        }
        DownloadProgress = 1;
    }

    /// <summary>
    /// Moves the running .exe aside, puts the new one in its place, and rolls back if
    /// that second step fails — the state in between is the only moment where a failure
    /// would leave no ImageHub at all.
    /// </summary>
    private static void Swap(string downloaded, string target, string parked)
    {
        TryDelete(parked);
        File.Move(target, parked);
        try
        {
            File.Move(downloaded, target);
        }
        catch (Exception)
        {
            try { File.Move(parked, target); } catch (Exception) { }
            throw;
        }
    }

    private static void Relaunch(string target)
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = target,
                UseShellExecute = true,
            });
        }
        catch (Exception)
        {
            // The new version is in place either way; the operator can start it.
        }
    }

    private static bool LooksLikeExecutable(string path)
    {
        try
        {
            using FileStream stream = File.OpenRead(path);
            int first = stream.ReadByte();
            int second = stream.ReadByte();
            return first == 'M' && second == 'Z';
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static string Explain(Exception error, string target)
    {
        if (error is BuildException) { return error.Message; }
        if (error is UnauthorizedAccessException or IOException)
        {
            string directory = Path.GetDirectoryName(target) ?? target;
            return $"ImageHub couldn't replace itself in {directory}: {error.Message} "
                + "Either restart ImageHub as administrator and try again, or move ImageHub.exe "
                + "somewhere you can write to.";
        }
        return error.Message;
    }

    private void Fail(string message)
    {
        FailureMessage = message;
        Stage = Phase.Failed;
        Notifier.Banner("Update failed", message, BannerKind.Error);
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) { File.Delete(path); } }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
