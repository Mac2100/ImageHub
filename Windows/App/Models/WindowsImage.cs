using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Serialization;
using ImageHub.Support;

namespace ImageHub.Models;

/// <summary>One edition inside an ISO's install.wim / install.esd.</summary>
public sealed class ImageEdition
{
    public int Index { get; set; }

    public string Name { get; set; } = string.Empty;

    public string EditionDescription { get; set; } = string.Empty;

    public long SizeBytes { get; set; }
}

/// <summary>
/// An ISO in the local library. The file lives under the image folder; this is the
/// metadata record, written to images.json.
/// </summary>
public sealed class WindowsImage : Observable
{
    /// <summary>
    /// install.wim above this size cannot be copied onto a FAT32 boot volume and has
    /// to be split into install.swm parts. On Windows that is DISM's job, so unlike
    /// the Mac there is nothing to install for it.
    /// </summary>
    public const long Fat32FileLimit = 4_294_967_295;

    private Guid _id = Guid.NewGuid();
    private string _name = string.Empty;
    private WindowsRelease _release = WindowsRelease.Win11;
    private string _buildLabel = string.Empty;
    private string _language = "en-US";
    private string _architecture = "x64";
    private string _path = string.Empty;
    private bool _managed = true;
    private long _sizeBytes;
    private string _sha256 = string.Empty;
    private ImageOrigin _origin = ImageOrigin.Imported;
    private string _sourceUrl = string.Empty;
    private DateTime _addedAt = DateTime.UtcNow;
    private DateTime? _lastVerifiedAt;
    private string _installImageName = string.Empty;
    private long _installImageSizeBytes;

    public Guid Id { get => _id; set => Set(ref _id, value); }

    public string Name { get => _name; set => Set(ref _name, value); }

    public WindowsRelease Release { get => _release; set => Set(ref _release, value); }

    /// <summary>Feature update label such as "24H2", when known.</summary>
    public string BuildLabel { get => _buildLabel; set => Set(ref _buildLabel, value); }

    public string Language { get => _language; set => Set(ref _language, value); }

    public string Architecture { get => _architecture; set => Set(ref _architecture, value); }

    /// <summary>
    /// Absolute path to the ISO. Managed copies live in the library directory; linked
    /// images can point anywhere (a file share, an external drive).
    /// </summary>
    public string Path { get => _path; set => Set(ref _path, value); }

    /// <summary>False when the ISO was linked in place rather than copied into the library.</summary>
    public bool Managed { get => _managed; set => Set(ref _managed, value); }

    public long SizeBytes { get => _sizeBytes; set => Set(ref _sizeBytes, value); }

    [JsonPropertyName("sha256")]
    public string Sha256 { get => _sha256; set => Set(ref _sha256, value); }

    public ImageOrigin Origin { get => _origin; set => Set(ref _origin, value); }

    [JsonPropertyName("sourceURL")]
    public string SourceUrl { get => _sourceUrl; set => Set(ref _sourceUrl, value); }

    public DateTime AddedAt { get => _addedAt; set => Set(ref _addedAt, value); }

    public DateTime? LastVerifiedAt { get => _lastVerifiedAt; set => Set(ref _lastVerifiedAt, value); }

    /// <summary>Populated after the ISO is mounted once and its WIM metadata read.</summary>
    public List<ImageEdition> Editions { get; set; } = new();

    public string InstallImageName { get => _installImageName; set => Set(ref _installImageName, value); }

    public long InstallImageSizeBytes
    {
        get => _installImageSizeBytes;
        set => Set(ref _installImageSizeBytes, value);
    }

    [JsonIgnore]
    public bool FileExists => Path.Length > 0 && File.Exists(Path);

    [JsonIgnore]
    public string DisplayName
    {
        get
        {
            if (Name.Length > 0) { return Name; }
            var parts = new List<string> { Labels.Of(Release) };
            if (BuildLabel.Length > 0) { parts.Add(BuildLabel); }
            parts.Add($"({Language}, {Architecture})");
            return string.Join(" ", parts);
        }
    }

    [JsonIgnore]
    public bool InstallImageNeedsSplit => InstallImageSizeBytes >= Fat32FileLimit;

    [JsonIgnore]
    public string Subtitle
    {
        get
        {
            var parts = new List<string> { Formatting.ByteSize(SizeBytes), Labels.Of(Origin) };
            if (Editions.Count > 0) { parts.Add($"{Editions.Count} editions"); }
            return string.Join(" · ", parts);
        }
    }

    public ImageEdition? Edition(string wanted) =>
        Editions.FirstOrDefault(e => string.Equals(e.Name, wanted, StringComparison.OrdinalIgnoreCase));
}

/// <summary>A release Microsoft is currently offering for download.</summary>
public sealed class AvailableDownload
{
    public string ProductId { get; init; } = string.Empty;

    public string Title { get; init; } = string.Empty;

    public WindowsRelease Release { get; init; }

    public string BuildLabel { get; init; } = string.Empty;

    public string Language { get; init; } = "en-US";

    public string Architecture { get; init; } = "x64";

    public string DownloadUrl { get; init; } = string.Empty;

    public long SizeBytes { get; init; }

    /// <summary>Microsoft's download links are time-limited; after this the URL 403s.</summary>
    public DateTime? ExpiresAt { get; init; }
}
