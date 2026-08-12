using System;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using ImageHub.Support;

namespace ImageHub.Services;

/// <summary>
/// Progress-reporting downloads with SHA-256 verification.
///
/// ISOs are 5–7 GB, so progress and a cancel button are not optional, and the
/// checksum matters: an ISO that silently truncated will fail two hours later
/// halfway through a reimage instead of here.
/// </summary>
public sealed class Downloader : Observable
{
    /// <summary>
    /// One client for the process. A fresh HttpClient per download exhausts sockets,
    /// and the timeout has to be infinite because the per-request timeout applies to
    /// the whole transfer, not to idle time — a 6 GB ISO would fail at 100 seconds.
    /// </summary>
    private static readonly HttpClient Client = CreateClient();

    private bool _isDownloading;
    private double _progress;
    private long _bytesReceived;
    private long _totalBytes;
    private string _statusText = string.Empty;
    private CancellationTokenSource? _cancellation;

    public bool IsDownloading { get => _isDownloading; private set => Set(ref _isDownloading, value); }

    public double Progress { get => _progress; private set => Set(ref _progress, value); }

    public long BytesReceived { get => _bytesReceived; private set => Set(ref _bytesReceived, value); }

    public long TotalBytes { get => _totalBytes; private set => Set(ref _totalBytes, value); }

    public string StatusText { get => _statusText; private set => Set(ref _statusText, value); }

    public bool CanCancel => _cancellation is not null;

    private static HttpClient CreateClient()
    {
        var handler = new HttpClientHandler { AllowAutoRedirect = true };
        var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        // Microsoft's CDN is picky about clients it doesn't recognise.
        client.DefaultRequestHeaders.TryAddWithoutValidation(
            "User-Agent",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Chrome/124.0.0.0 Safari/537.36");
        return client;
    }

    /// <summary>A client for small JSON/HTML requests, shared with the update check.</summary>
    public static HttpClient Shared => Client;

    /// <summary>Downloads <paramref name="url"/> to <paramref name="destination"/>.</summary>
    public async Task DownloadAsync(string url, string destination, CancellationToken outer = default)
    {
        if (IsDownloading) { throw new BuildException("A download is already running."); }

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(outer);
        _cancellation = linked;
        IsDownloading = true;
        Progress = 0;
        BytesReceived = 0;
        TotalBytes = 0;
        StatusText = "Connecting…";
        Raise(nameof(CanCancel));

        // Downloaded beside the target and moved into place, so an interrupted download
        // never leaves a truncated file looking like a finished one.
        string partial = destination + ".partial";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            if (File.Exists(partial)) { File.Delete(partial); }

            using HttpResponseMessage response = await Client
                .GetAsync(url, HttpCompletionOption.ResponseHeadersRead, linked.Token)
                .ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                throw new BuildException(
                    $"The server refused the download (HTTP {(int)response.StatusCode}).");
            }

            long total = response.Content.Headers.ContentLength ?? 0;
            TotalBytes = total;

            await using Stream source = await response.Content.ReadAsStreamAsync(linked.Token)
                .ConfigureAwait(false);
            await using (FileStream target = new(partial, FileMode.Create, FileAccess.Write,
                             FileShare.None, 1 << 20, useAsync: true))
            {
                var buffer = new byte[1 << 20];
                long received = 0;
                DateTime lastUpdate = DateTime.MinValue;
                while (true)
                {
                    int read = await source.ReadAsync(buffer, linked.Token).ConfigureAwait(false);
                    if (read <= 0) { break; }
                    await target.WriteAsync(buffer.AsMemory(0, read), linked.Token).ConfigureAwait(false);
                    received += read;

                    // Publishing every megabyte would be thousands of UI updates; a few a
                    // second is what a person can read.
                    if ((DateTime.Now - lastUpdate).TotalMilliseconds > 200)
                    {
                        lastUpdate = DateTime.Now;
                        BytesReceived = received;
                        Progress = total > 0 ? Math.Min(1, (double)received / total) : 0;
                        StatusText = total > 0
                            ? $"{Formatting.ByteSize(received)} of {Formatting.ByteSize(total)}"
                            : Formatting.ByteSize(received);
                    }
                }
                BytesReceived = received;
                Progress = total > 0 ? 1 : 0;
            }

            StatusText = "Moving into the library…";
            if (File.Exists(destination)) { File.Delete(destination); }
            File.Move(partial, destination);
            StatusText = "Done";
        }
        catch (OperationCanceledException)
        {
            StatusText = "Cancelled";
            TryDelete(partial);
            throw;
        }
        catch (HttpRequestException error)
        {
            TryDelete(partial);
            throw new BuildException($"The download failed: {error.Message}");
        }
        finally
        {
            IsDownloading = false;
            _cancellation = null;
            Raise(nameof(CanCancel));
        }
    }

    public void Cancel()
    {
        try { _cancellation?.Cancel(); } catch (ObjectDisposedException) { }
        StatusText = "Cancelled";
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) { File.Delete(path); } }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    // MARK: - Checksums

    /// <summary>Streams the file through SHA-256 so a 6 GB ISO doesn't land in memory.</summary>
    public static async Task<string> Sha256Async(
        string path,
        Action<double>? progress = null,
        CancellationToken cancellation = default)
    {
        long total = 0;
        try { total = new FileInfo(path).Length; } catch (IOException) { }

        using SHA256 hasher = SHA256.Create();
        await using FileStream stream = new(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            1 << 22, FileOptions.SequentialScan | FileOptions.Asynchronous);

        var buffer = new byte[1 << 22];
        long processed = 0;
        while (true)
        {
            int read = await stream.ReadAsync(buffer, cancellation).ConfigureAwait(false);
            if (read <= 0) { break; }
            hasher.TransformBlock(buffer, 0, read, null, 0);
            processed += read;
            if (total > 0) { progress?.Invoke(Math.Min(1, (double)processed / total)); }
        }
        hasher.TransformFinalBlock(Array.Empty<byte>(), 0, 0);

        return Convert.ToHexString(hasher.Hash ?? Array.Empty<byte>()).ToLowerInvariant();
    }
}
