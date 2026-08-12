using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using ImageHub.Models;
using ImageHub.Support;

namespace ImageHub.Services;

/// <summary>
/// Asks Microsoft's own software-download service for a current retail ISO link.
///
/// This is the same public flow the Windows download page uses in a browser:
/// register a session, look up the SKUs for a product edition, then ask for that
/// SKU's download links. ImageHub never mirrors or redistributes anything — the link
/// it hands to <see cref="Downloader"/> points at Microsoft's CDN.
///
/// Microsoft rate-limits and geo/IP-filters this endpoint, and the download URLs
/// expire after roughly 24 hours. When it refuses, the error explains what happened
/// and the Images view offers importing an ISO by hand instead. A port of
/// Sources/ImageHub/Services/MicrosoftISOService.swift.
/// </summary>
public static class MicrosoftIsoService
{
    private const string Profile = "606624d44113";

    private const string UserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/124.0.0.0 Safari/537.36";

    /// <summary>
    /// Product edition IDs move with each feature update, so the page is scraped first
    /// and these are only the fallback.
    /// </summary>
    private static string[] FallbackEditionIds(WindowsRelease release) => release switch
    {
        WindowsRelease.Win10 => new[] { "2618", "2033" },
        _ => new[] { "3113", "3131", "2935" },
    };

    public static string PageUrl(WindowsRelease release) => release switch
    {
        WindowsRelease.Win10 => "https://www.microsoft.com/en-us/software-download/windows10ISO",
        _ => "https://www.microsoft.com/en-us/software-download/windows11",
    };

    /// <summary>Resolves a downloadable ISO for the given release and language.</summary>
    public static async Task<AvailableDownload> FindDownloadAsync(
        WindowsRelease release,
        string language,
        Action<string>? log = null,
        CancellationToken cancellation = default)
    {
        log?.Invoke($"Looking up the current {Labels.Of(release)} product edition…");
        List<string> editionIds = await EditionIdsAsync(release, cancellation).ConfigureAwait(false);
        if (editionIds.Count == 0)
        {
            throw new BuildException(
                $"Microsoft's download page didn't list any {Labels.Of(release)} editions.");
        }

        Exception? lastError = null;
        foreach (string editionId in editionIds)
        {
            cancellation.ThrowIfCancellationRequested();
            try
            {
                // A rejected request burns the session, so each edition attempt gets a
                // freshly registered one — reusing it guarantees that every attempt after
                // the first is refused.
                string session = Guid.NewGuid().ToString("D").ToLowerInvariant();
                log?.Invoke("Registering a download session with Microsoft…");
                await RegisterSessionAsync(session, release, log, cancellation).ConfigureAwait(false);

                Sku sku = await FindSkuAsync(editionId, language, session, release, cancellation)
                    .ConfigureAwait(false);
                log?.Invoke($"Requesting download links for “{sku.ProductName}”…");
                return await DownloadLinkAsync(sku, release, session, log, cancellation)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception error)
            {
                lastError = error;
                log?.Invoke($"Edition {editionId} didn't work: {error.Message}");
            }
        }

        throw lastError ?? new BuildException(
            $"Microsoft didn't offer a download for {Labels.Of(release)}.");
    }

    // MARK: - Steps

    /// <summary>
    /// Registers the anti-abuse ("Sentinel") token the connector API checks for.
    ///
    /// A failure here is the most likely cause of the final request being rejected, so
    /// it is reported rather than swallowed — when this was silent, the rejection
    /// looked like an IP block.
    /// </summary>
    private static async Task RegisterSessionAsync(
        string session,
        WindowsRelease release,
        Action<string>? log,
        CancellationToken cancellation)
    {
        string url = "https://vlscppe.microsoft.com/fp/tags?org_id=y6jn8c31&session_id=" + session;
        try
        {
            _ = await GetStringAsync(url, PageUrl(release), cancellation).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            log?.Invoke($"Session registration didn't succeed ({error.Message}) — the download "
                + "request will probably be refused.");
        }
        // Microsoft's fraud service needs a moment to associate the session before the
        // connector API will honour it.
        await Task.Delay(1500, cancellation).ConfigureAwait(false);
    }

    private static async Task<List<string>> EditionIdsAsync(
        WindowsRelease release,
        CancellationToken cancellation)
    {
        var found = new List<string>();
        try
        {
            string html = await GetStringAsync(PageUrl(release), null, cancellation).ConfigureAwait(false);
            // The page renders the edition list as <option value="3113">…</option>.
            foreach (Match match in Regex.Matches(html, "value=\"(\\d{4})\""))
            {
                string id = match.Groups[1].Value;
                if (!found.Contains(id)) { found.Add(id); }
            }
        }
        catch (Exception)
        {
            // Scraping failing is routine; the fallback list is why it is not fatal.
        }
        foreach (string id in FallbackEditionIds(release))
        {
            if (!found.Contains(id)) { found.Add(id); }
        }
        return found;
    }

    private sealed record Sku(string Id, string Language, string ProductName);

    private static async Task<Sku> FindSkuAsync(
        string editionId,
        string language,
        string session,
        WindowsRelease release,
        CancellationToken cancellation)
    {
        string url = "https://www.microsoft.com/software-download-connector/api/"
            + "getskuinformationbyproductedition"
            + $"?profile={Profile}&ProductEditionId={Uri.EscapeDataString(editionId)}"
            + "&SKU=undefined&friendlyFileName=undefined&Locale=en-US"
            + $"&sessionID={Uri.EscapeDataString(session)}";

        using JsonDocument json = await GetJsonAsync(url, PageUrl(release), cancellation)
            .ConfigureAwait(false);
        ThrowIfErrors(json.RootElement);

        if (!json.RootElement.TryGetProperty("Skus", out JsonElement skus)
            || skus.ValueKind != JsonValueKind.Array
            || skus.GetArrayLength() == 0)
        {
            throw new BuildException($"Microsoft returned no SKUs for edition {editionId}.");
        }

        // Prefer an exact language match, then a prefix match, then English.
        string wanted = language.ToLowerInvariant();
        string prefix = wanted.Split('-')[0];
        JsonElement? chosen = null;
        foreach (JsonElement sku in skus.EnumerateArray())
        {
            if (StringOf(sku, "Language").ToLowerInvariant() == wanted) { chosen = sku; break; }
        }
        if (chosen is null)
        {
            foreach (JsonElement sku in skus.EnumerateArray())
            {
                if (StringOf(sku, "LocalizedLanguage").ToLowerInvariant()
                    .StartsWith(prefix, StringComparison.Ordinal))
                {
                    chosen = sku;
                    break;
                }
            }
        }
        if (chosen is null)
        {
            foreach (JsonElement sku in skus.EnumerateArray())
            {
                if (StringOf(sku, "LocalizedLanguage").Contains("English (United States)",
                        StringComparison.Ordinal))
                {
                    chosen = sku;
                    break;
                }
            }
        }
        chosen ??= skus[0];

        string id = StringOf(chosen.Value, "Id");
        if (id.Length == 0)
        {
            throw new BuildException("Microsoft's SKU response was missing an ID.");
        }
        string skuLanguage = StringOf(chosen.Value, "Language");
        string productName = StringOf(chosen.Value, "ProductDisplayName");
        if (productName.Length == 0) { productName = StringOf(chosen.Value, "LocalizedLanguage"); }
        if (productName.Length == 0) { productName = "Windows"; }

        return new Sku(id, skuLanguage.Length == 0 ? language : skuLanguage, productName);
    }

    private static async Task<AvailableDownload> DownloadLinkAsync(
        Sku sku,
        WindowsRelease release,
        string session,
        Action<string>? log,
        CancellationToken cancellation)
    {
        string url = "https://www.microsoft.com/software-download-connector/api/"
            + "GetProductDownloadLinksBySku"
            + $"?profile={Profile}&ProductEditionId=undefined&SKU={Uri.EscapeDataString(sku.Id)}"
            + "&friendlyFileName=undefined&Locale=en-US"
            + $"&sessionID={Uri.EscapeDataString(session)}";

        using JsonDocument json = await GetJsonAsync(url, PageUrl(release), cancellation)
            .ConfigureAwait(false);
        ThrowIfErrors(json.RootElement);

        if (!json.RootElement.TryGetProperty("ProductDownloadOptions", out JsonElement options)
            || options.ValueKind != JsonValueKind.Array
            || options.GetArrayLength() == 0)
        {
            throw new BuildException("Microsoft didn't return any download links for this SKU.");
        }

        // Microsoft only publishes x64 consumer ISOs; ARM64 Windows ships through OEMs,
        // so there is nothing to choose between here.
        JsonElement chosen = options[0];
        foreach (JsonElement option in options.EnumerateArray())
        {
            if (StringOf(option, "Uri").ToLowerInvariant().Contains("x64", StringComparison.Ordinal))
            {
                chosen = option;
                break;
            }
        }

        string uri = StringOf(chosen, "Uri");
        if (uri.Length == 0 || !Uri.TryCreate(uri, UriKind.Absolute, out Uri? parsed))
        {
            throw new BuildException("Microsoft's download link was unreadable.");
        }

        string fileName = parsed.Segments.Length > 0
            ? Uri.UnescapeDataString(parsed.Segments[^1]).TrimEnd('/')
            : string.Empty;
        log?.Invoke($"Microsoft offered {fileName}");

        return new AvailableDownload
        {
            ProductId = sku.Id,
            Title = fileName.Length == 0 ? Labels.Of(release) + " ISO" : fileName,
            Release = release,
            BuildLabel = BuildLabel(fileName),
            Language = sku.Language,
            Architecture = "x64",
            DownloadUrl = uri,
            SizeBytes = 0,
            // Microsoft's signed links are good for about a day.
            ExpiresAt = DateTime.UtcNow.AddHours(24),
        };
    }

    /// <summary>Win11_24H2_English_x64.iso → 24H2.</summary>
    public static string BuildLabel(string fileName)
    {
        Match match = Regex.Match(fileName ?? string.Empty, @"\d{2}H\d", RegexOptions.IgnoreCase);
        return match.Success ? match.Value.ToUpperInvariant() : string.Empty;
    }

    // MARK: - HTTP plumbing

    private static void ThrowIfErrors(JsonElement root)
    {
        if (!root.TryGetProperty("Errors", out JsonElement errors)
            || errors.ValueKind != JsonValueKind.Array
            || errors.GetArrayLength() == 0)
        {
            return;
        }
        var codes = new List<string>();
        foreach (JsonElement error in errors.EnumerateArray())
        {
            string value = StringOf(error, "Value");
            if (value.Length > 0) { codes.Add(value); }
        }
        string suffix = codes.Count == 0 ? string.Empty : $" ({string.Join(", ", codes)})";
        throw new BuildException(
            $"Microsoft's download service declined the request{suffix}. Their anti-abuse check "
            + "refuses clients that aren't a real browser session, and it can't be reliably "
            + "satisfied from an app. Download the ISO in a browser and import it, or point "
            + "ImageHub at an internal URL.");
    }

    private static async Task<string> GetStringAsync(
        string url,
        string? referer,
        CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
        request.Headers.TryAddWithoutValidation("Accept-Language", "en-US,en;q=0.9");
        if (referer is not null) { request.Headers.TryAddWithoutValidation("Referer", referer); }

        using HttpResponseMessage response = await Downloader.Shared
            .SendAsync(request, HttpCompletionOption.ResponseContentRead, cancellation)
            .ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new BuildException(
                $"Microsoft's download service returned HTTP {(int)response.StatusCode}.");
        }
        return await response.Content.ReadAsStringAsync(cancellation).ConfigureAwait(false);
    }

    private static async Task<JsonDocument> GetJsonAsync(
        string url,
        string referer,
        CancellationToken cancellation)
    {
        string text = await GetStringAsync(url, referer, cancellation).ConfigureAwait(false);
        try
        {
            return JsonDocument.Parse(text);
        }
        catch (JsonException)
        {
            // The connector sometimes answers with an HTML error page.
            string head = text.Length > 200 ? text.Substring(0, 200) : text;
            throw new BuildException(
                "Microsoft's download service sent something ImageHub couldn't read."
                + (head.Trim().Length == 0 ? string.Empty : $" It started with: {head}"));
        }
    }

    private static string StringOf(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out JsonElement value)) { return string.Empty; }
        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString() ?? string.Empty,
            JsonValueKind.Number => value.ToString(),
            _ => string.Empty,
        };
    }
}
