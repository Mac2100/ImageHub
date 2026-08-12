using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using ImageHub.Support;

namespace ImageHub.Services;

/// <summary>
/// Checks GitHub Releases for a newer version of ImageHub.
///
/// The same release, the same API call and the same version comparison as the macOS
/// app — one release carries both platforms' downloads, and each app picks the asset
/// for the OS it is running on. See <see cref="PickAsset"/> for that choice, and
/// UpdateChecker.swift for the Mac's.
/// </summary>
public sealed class UpdateChecker : Observable
{
    public const string Repo = "Mac2100/ImageHub";

    public static string ReleasesPage => $"https://github.com/{Repo}/releases/latest";

    public enum State
    {
        Idle,
        Checking,
        UpToDate,

        /// <summary>
        /// GitHub answered 404: either no release exists yet, or the repository is
        /// private and anonymous API calls cannot see its releases.
        /// </summary>
        NoReleasesVisible,
        UpdateAvailable,
        Failed,
    }

    private State _status = State.Idle;
    private string _availableVersion = string.Empty;
    private string _downloadUrl = string.Empty;
    private string _failureMessage = string.Empty;
    private DateTime? _lastChecked;

    public State Status { get => _status; private set => Set(ref _status, value); }

    public string AvailableVersion { get => _availableVersion; private set => Set(ref _availableVersion, value); }

    public string DownloadUrl { get => _downloadUrl; private set => Set(ref _downloadUrl, value); }

    public string FailureMessage { get => _failureMessage; private set => Set(ref _failureMessage, value); }

    public DateTime? LastChecked { get => _lastChecked; private set => Set(ref _lastChecked, value); }

    /// <summary>Raised when a user-initiated check found something to install.</summary>
    public event EventHandler<(string Version, string Url)>? UpdateOffered;

    public void CheckOnLaunchIfEnabled()
    {
        if (!Settings.Current.AutoCheckUpdates) { return; }
        _ = CheckAsync(userInitiated: false);
    }

    /// <summary>
    /// Runs a check and, for user-initiated checks, always reports the outcome —
    /// including the one that matters. Silent launch checks stay silent apart from the
    /// system notification.
    /// </summary>
    public async Task CheckAsync(bool userInitiated, CancellationToken cancellation = default)
    {
        await CheckCoreAsync(cancellation).ConfigureAwait(true);
        if (!userInitiated) { return; }

        switch (Status)
        {
            case State.UpToDate:
                Notifier.Banner("No updates available",
                    $"ImageHub {AppVersion.Current} is the latest version");
                break;
            case State.NoReleasesVisible:
                Notifier.Banner("No releases visible",
                    "Private repositories can't be checked anonymously", BannerKind.Info);
                break;
            case State.Failed:
                Notifier.Banner("Update check failed", FailureMessage, BannerKind.Error);
                break;
            case State.UpdateAvailable:
                UpdateOffered?.Invoke(this, (AvailableVersion, DownloadUrl));
                break;
        }
    }

    private async Task CheckCoreAsync(CancellationToken cancellation)
    {
        Status = State.Checking;
        FailureMessage = string.Empty;
        try
        {
            using var request = new HttpRequestMessage(
                HttpMethod.Get, $"https://api.github.com/repos/{Repo}/releases/latest");
            request.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json");
            request.Headers.TryAddWithoutValidation("User-Agent", "ImageHub/" + AppVersion.Current);

            using HttpResponseMessage response = await Downloader.Shared
                .SendAsync(request, cancellation).ConfigureAwait(true);

            if ((int)response.StatusCode == 404)
            {
                Status = State.NoReleasesVisible;
                return;
            }
            if (!response.IsSuccessStatusCode)
            {
                Status = State.Failed;
                FailureMessage = $"GitHub answered HTTP {(int)response.StatusCode}.";
                return;
            }

            string body = await response.Content.ReadAsStringAsync(cancellation).ConfigureAwait(true);
            using JsonDocument document = JsonDocument.Parse(body);
            JsonElement root = document.RootElement;

            string tag = root.TryGetProperty("tag_name", out JsonElement tagName)
                ? tagName.GetString() ?? string.Empty
                : string.Empty;
            string latest = tag.StartsWith("v", StringComparison.OrdinalIgnoreCase)
                ? tag.Substring(1)
                : tag;

            if (!AppVersion.IsNewer(latest, AppVersion.Current))
            {
                Status = State.UpToDate;
                return;
            }

            string htmlUrl = root.TryGetProperty("html_url", out JsonElement html)
                ? html.GetString() ?? ReleasesPage
                : ReleasesPage;

            var assets = new List<(string Name, string Url)>();
            if (root.TryGetProperty("assets", out JsonElement list)
                && list.ValueKind == JsonValueKind.Array)
            {
                foreach (JsonElement asset in list.EnumerateArray())
                {
                    string name = asset.TryGetProperty("name", out JsonElement n)
                        ? n.GetString() ?? string.Empty : string.Empty;
                    string url = asset.TryGetProperty("browser_download_url", out JsonElement u)
                        ? u.GetString() ?? string.Empty : string.Empty;
                    if (name.Length > 0 && url.Length > 0) { assets.Add((name, url)); }
                }
            }

            AvailableVersion = latest;
            DownloadUrl = PickAsset(assets) ?? htmlUrl;
            Status = State.UpdateAvailable;
            Notifier.UpdateAvailable(latest);
        }
        catch (OperationCanceledException)
        {
            Status = State.Idle;
        }
        catch (Exception error)
        {
            Status = State.Failed;
            FailureMessage = error.Message;
        }
        finally
        {
            LastChecked = DateTime.Now;
        }
    }

    /// <summary>
    /// Picks this platform's download out of a release that carries both.
    ///
    /// A release has a .dmg and a .zip for macOS and an .exe and a .zip for Windows,
    /// so matching on "the first .zip" would install the wrong one. The .exe is
    /// preferred because it is the whole app in one file and the updater can swap it in
    /// place; the zip is the fallback for a release that predates the single-file
    /// build. Anything unrecognised falls through to opening the release page, which is
    /// what the macOS app does too.
    /// </summary>
    public static string? PickAsset(IReadOnlyList<(string Name, string Url)> assets)
    {
        foreach ((string name, string url) in assets)
        {
            if (name.EndsWith("-win-x64.exe", StringComparison.OrdinalIgnoreCase)) { return url; }
        }
        foreach ((string name, string url) in assets)
        {
            if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                && name.Contains("win", StringComparison.OrdinalIgnoreCase))
            {
                return url;
            }
        }
        foreach ((string name, string url) in assets)
        {
            if (name.EndsWith("-win-x64.zip", StringComparison.OrdinalIgnoreCase)) { return url; }
        }
        return null;
    }
}
