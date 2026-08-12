using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using ImageHub.Models;
using ImageHub.Support;

namespace ImageHub.Services;

/// <summary>
/// The local ISO library: what's on this PC, where it came from, and whether it is
/// still intact.
///
/// Downloaded ISOs are copied into %LOCALAPPDATA%\ImageHub\Images; imported ones can
/// be linked in place so a 6 GB file on a file share isn't duplicated.
///
/// One difference from the macOS app, and it is Windows' rather than a choice:
/// reading the edition list means mounting the ISO, and Mount-DiskImage needs
/// administrator rights. Unelevated, an import still succeeds and is usable — the
/// edition list is simply left empty with a note, and "Read editions" fills it in
/// later.
/// </summary>
public sealed class ImageLibrary : Observable
{
    private readonly List<WindowsImage> _images = new();
    private bool _isBusy;
    private string _busyMessage = string.Empty;
    private double? _hashProgress;
    private double? _copyProgress;

    public ImageLibrary()
    {
        Load();
        Downloader.PropertyChanged += (_, _) => Raise(nameof(Downloader));
    }

    public IReadOnlyList<WindowsImage> Images => _images;

    public Downloader Downloader { get; } = new();

    public bool IsBusy { get => _isBusy; private set => Set(ref _isBusy, value); }

    public string BusyMessage { get => _busyMessage; private set => Set(ref _busyMessage, value); }

    public double? HashProgress { get => _hashProgress; private set => Set(ref _hashProgress, value); }

    public double? CopyProgress { get => _copyProgress; private set => Set(ref _copyProgress, value); }

    public event EventHandler? Changed;

    // MARK: - Persistence

    public void Load()
    {
        _images.Clear();
        try
        {
            if (File.Exists(AppPaths.ImageIndex))
            {
                List<WindowsImage>? loaded =
                    Json.Deserialize<List<WindowsImage>>(File.ReadAllText(AppPaths.ImageIndex));
                if (loaded is not null) { _images.AddRange(loaded); }
            }
        }
        catch (Exception)
        {
            // A damaged index is not worth blocking the app; the ISOs are still there and
            // can be imported again.
        }
        _images.Sort((a, b) => b.AddedAt.CompareTo(a.AddedAt));
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void Persist()
    {
        try
        {
            File.WriteAllText(AppPaths.ImageIndex, Json.Serialize(_images));
        }
        catch (Exception)
        {
        }
        Changed?.Invoke(this, EventArgs.Empty);
        Raise(nameof(Images));
        Raise(nameof(TotalBytesOnDisk));
    }

    public WindowsImage? Image(Guid? id) =>
        id is null ? null : _images.FirstOrDefault(image => image.Id == id.Value);

    /// <summary>Newest usable image matching a template's release/edition wishes.</summary>
    public WindowsImage? BestMatch(DeploymentTemplate template)
    {
        WindowsImage? pinned = Image(template.Windows.LibraryImageId);
        if (pinned is not null && pinned.FileExists) { return pinned; }
        return _images
            .Where(image => image.FileExists && image.Release == template.Windows.Release)
            .OrderByDescending(image => image.AddedAt)
            .FirstOrDefault();
    }

    public long TotalBytesOnDisk =>
        _images.Where(image => image.Managed && image.FileExists).Sum(image => image.SizeBytes);

    // MARK: - Import

    /// <summary>
    /// Adds an ISO already on disk. <paramref name="copyIntoLibrary"/> false links it
    /// in place.
    /// </summary>
    public async Task<WindowsImage?> ImportAsync(
        string path,
        bool copyIntoLibrary,
        CancellationToken cancellation = default)
    {
        IsBusy = true;
        BusyMessage = $"Adding {Path.GetFileName(path)}…";
        try
        {
            if (!File.Exists(path))
            {
                Notifier.Banner("Not found", path, BannerKind.Error);
                return null;
            }

            long sourceSize = SizeOf(path);
            var image = new WindowsImage
            {
                Origin = ImageOrigin.Imported,
                SourceUrl = path,
                Managed = copyIntoLibrary,
            };

            string finalPath = path;
            if (copyIntoLibrary)
            {
                try
                {
                    string destination = Path.Combine(AppPaths.Images,
                        image.Id.ToString("N").ToUpperInvariant() + "-" + Path.GetFileName(path));
                    BusyMessage = $"Copying {Path.GetFileName(path)} into the library…";

                    // Copied on a background thread with a verified byte count. An
                    // interrupted copy must not leave a truncated file that gets added to
                    // the library and only fails much later with "not recognized".
                    long copied = await Task.Run(
                        () => FileCopier.CopyVerified(path, destination,
                            fraction => CopyProgress = fraction, cancellation),
                        cancellation).ConfigureAwait(true);

                    if (copied != sourceSize)
                    {
                        TryDelete(destination);
                        Notifier.Banner("The copy didn't complete",
                            $"Copied {Formatting.ByteSize(copied)} of {Formatting.ByteSize(sourceSize)}. "
                            + "Nothing was added.", BannerKind.Error);
                        return null;
                    }
                    finalPath = destination;
                }
                catch (OperationCanceledException)
                {
                    return null;
                }
                catch (Exception error)
                {
                    Notifier.Banner("Couldn't copy the ISO", error.Message, BannerKind.Error);
                    return null;
                }
            }

            image.Path = finalPath;
            image.SizeBytes = SizeOf(finalPath);
            image.Name = Path.GetFileNameWithoutExtension(path);
            image.BuildLabel = MicrosoftIsoService.BuildLabel(Path.GetFileName(path));
            if (Path.GetFileName(path).Contains("win10", StringComparison.OrdinalIgnoreCase))
            {
                image.Release = WindowsRelease.Win10;
            }

            string? problem = await InspectAsync(image, cancellation).ConfigureAwait(true);
            if (problem is not null)
            {
                if (image.Managed) { TryDelete(finalPath); }
                Notifier.Banner("Couldn't read that ISO", problem, BannerKind.Error);
                return null;
            }

            _images.Insert(0, image);
            Persist();
            Notifier.Banner("Image added", image.DisplayName);
            return image;
        }
        finally
        {
            IsBusy = false;
            BusyMessage = string.Empty;
            HashProgress = null;
            CopyProgress = null;
        }
    }

    /// <summary>Downloads the newest ISO Microsoft is publishing for a release.</summary>
    public async Task<WindowsImage?> DownloadLatestAsync(
        WindowsRelease release,
        string language,
        Action<string>? log = null,
        CancellationToken cancellation = default)
    {
        IsBusy = true;
        BusyMessage = $"Asking Microsoft for the latest {Labels.Of(release)} ISO…";
        try
        {
            AvailableDownload offer = await MicrosoftIsoService
                .FindDownloadAsync(release, language, log, cancellation).ConfigureAwait(true);
            return await DownloadAsync(offer, cancellation).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (Exception error)
        {
            // Deliberately no banner: Microsoft refusing an automated request is a
            // routine outcome with a known workaround, and the Images view shows an
            // inline notice offering it. A red banner every attempt just reads as the app
            // being broken.
            log?.Invoke(error.Message);
            return null;
        }
        finally
        {
            IsBusy = false;
            BusyMessage = string.Empty;
            HashProgress = null;
        }
    }

    /// <summary>Downloads a resolved offer into the library.</summary>
    public async Task<WindowsImage?> DownloadAsync(
        AvailableDownload offer,
        CancellationToken cancellation = default)
    {
        var image = new WindowsImage
        {
            Origin = ImageOrigin.Microsoft,
            Release = offer.Release,
            BuildLabel = offer.BuildLabel,
            Language = offer.Language,
            Architecture = offer.Architecture,
            SourceUrl = offer.DownloadUrl,
            Name = offer.Title.Replace(".iso", string.Empty, StringComparison.OrdinalIgnoreCase),
            Managed = true,
        };

        string destination = Path.Combine(AppPaths.Images,
            image.Id.ToString("N").ToUpperInvariant() + "-" + SafeFileName(offer.Title));

        IsBusy = true;
        BusyMessage = $"Downloading {offer.Title}…";
        try
        {
            await Downloader.DownloadAsync(offer.DownloadUrl, destination, cancellation)
                .ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (Exception error)
        {
            Notifier.Banner("Download failed", error.Message, BannerKind.Error);
            return null;
        }
        finally
        {
            IsBusy = false;
            BusyMessage = string.Empty;
        }

        image.Path = destination;
        image.SizeBytes = SizeOf(destination);
        await InspectAsync(image, cancellation).ConfigureAwait(true);
        _images.Insert(0, image);
        Persist();

        Notifier.DownloadFinished(image.DisplayName);
        Notifier.Banner("Image downloaded", image.DisplayName);
        return image;
    }

    /// <summary>
    /// Adds an ISO from an internal HTTPS URL, optionally checking it against a known
    /// SHA-256 so everyone on the team builds from the same bytes.
    /// </summary>
    public async Task<WindowsImage?> DownloadFromUrlAsync(
        string url,
        string expectedSha256,
        WindowsRelease release,
        CancellationToken cancellation = default)
    {
        IsBusy = true;
        string fileName = SafeFileName(LastPathSegment(url));
        BusyMessage = $"Downloading {fileName}…";
        try
        {
            var image = new WindowsImage
            {
                Origin = ImageOrigin.RemoteUrl,
                Release = release,
                SourceUrl = url,
                Name = Path.GetFileNameWithoutExtension(fileName),
                BuildLabel = MicrosoftIsoService.BuildLabel(fileName),
                Managed = true,
            };

            string destination = Path.Combine(AppPaths.Images,
                image.Id.ToString("N").ToUpperInvariant() + "-" + fileName);
            try
            {
                await Downloader.DownloadAsync(url, destination, cancellation).ConfigureAwait(true);
            }
            catch (OperationCanceledException)
            {
                return null;
            }
            catch (Exception error)
            {
                Notifier.Banner("Download failed", error.Message, BannerKind.Error);
                return null;
            }

            image.Path = destination;
            image.SizeBytes = SizeOf(destination);

            if (expectedSha256.Length > 0)
            {
                BusyMessage = "Verifying checksum…";
                string actual = await ComputeHashAsync(destination, cancellation).ConfigureAwait(true);
                if (!string.Equals(actual, expectedSha256, StringComparison.OrdinalIgnoreCase))
                {
                    TryDelete(destination);
                    Notifier.Banner("Checksum mismatch",
                        "The download didn't match the expected SHA-256 and was discarded.",
                        BannerKind.Error);
                    return null;
                }
                image.Sha256 = actual;
                image.LastVerifiedAt = DateTime.UtcNow;
            }

            await InspectAsync(image, cancellation).ConfigureAwait(true);
            _images.Insert(0, image);
            Persist();
            Notifier.Banner("Image added", image.DisplayName);
            return image;
        }
        finally
        {
            IsBusy = false;
            BusyMessage = string.Empty;
            HashProgress = null;
        }
    }

    // MARK: - Inspection & verification

    /// <summary>
    /// Mounts the ISO once to read its edition list out of install.wim. Returns a
    /// problem description when the image genuinely can't be used, and null when it
    /// can — including the unelevated case, where the edition list is simply left for
    /// later.
    /// </summary>
    private async Task<string?> InspectAsync(WindowsImage image, CancellationToken cancellation)
    {
        BusyMessage = $"Reading editions from {Path.GetFileName(image.Path)}…";

        IsoMounter.Mounted mounted;
        try
        {
            mounted = await IsoMounter.MountAsync(image.Path, _ => { }, cancellation).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error)
        {
            if (!Elevation.IsElevated)
            {
                // Not a defect in the image: Windows will not let an unelevated process
                // mount one. Keep it and say so rather than refusing a perfectly good ISO.
                Notifier.Banner(
                    "Added without reading its editions",
                    "Mounting an ISO needs administrator rights. Use “Read editions” after "
                    + "restarting as administrator, or just build — the build needs elevation anyway.",
                    BannerKind.Info);
                return null;
            }
            return error.Message;
        }

        try
        {
            foreach (string candidate in new[] { "install.wim", "install.esd" })
            {
                string file = Path.Combine(mounted.Root, "sources", candidate);
                if (!File.Exists(file)) { continue; }
                image.InstallImageName = candidate;
                image.InstallImageSizeBytes = SizeOf(file);
                try
                {
                    image.Editions = WimReader.Editions(file);
                }
                catch (Exception)
                {
                    // An unreadable metadata blob is not a reason to reject the ISO; the
                    // edition list is a convenience and Setup matches by name at install time.
                }
                break;
            }

            if (image.Editions.Any(edition => edition.Name.Contains("Windows 10", StringComparison.Ordinal)))
            {
                image.Release = WindowsRelease.Win10;
            }

            if (image.InstallImageName.Length == 0)
            {
                return $"{Path.GetFileName(image.Path)} mounted but has no sources\\install.wim or "
                    + "install.esd, so it isn't Windows installation media.";
            }
            return null;
        }
        finally
        {
            // Awaited rather than fired and forgotten: a leaked attachment makes every
            // later build fail to mount the same ISO.
            await IsoMounter.DismountAsync(image.Path, CancellationToken.None).ConfigureAwait(true);
        }
    }

    /// <summary>Re-reads the edition list for an image already in the library.</summary>
    public async Task ReinspectAsync(WindowsImage image, CancellationToken cancellation = default)
    {
        IsBusy = true;
        try
        {
            string? problem = await InspectAsync(image, cancellation).ConfigureAwait(true);
            if (problem is not null)
            {
                Notifier.Banner("Couldn't read that ISO", problem, BannerKind.Error);
            }
            else if (image.Editions.Count > 0)
            {
                Notifier.Banner("Editions read", Formatting.Plural(image.Editions.Count, "edition"));
            }
            Persist();
        }
        finally
        {
            IsBusy = false;
            BusyMessage = string.Empty;
        }
    }

    /// <summary>Hashes an image and stores the result so future builds can verify it.</summary>
    public async Task VerifyAsync(WindowsImage image, CancellationToken cancellation = default)
    {
        if (!image.FileExists)
        {
            Notifier.Banner("File missing", image.Path, BannerKind.Error);
            return;
        }
        IsBusy = true;
        BusyMessage = $"Hashing {Path.GetFileName(image.Path)}…";
        try
        {
            string actual = await ComputeHashAsync(image.Path, cancellation).ConfigureAwait(true);
            if (image.Sha256.Length == 0)
            {
                image.Sha256 = actual;
                image.LastVerifiedAt = DateTime.UtcNow;
                Persist();
                Notifier.Banner("Checksum recorded", actual.Substring(0, 16) + "…");
            }
            else if (string.Equals(image.Sha256, actual, StringComparison.OrdinalIgnoreCase))
            {
                image.LastVerifiedAt = DateTime.UtcNow;
                Persist();
                Notifier.Banner("Image verified", image.DisplayName);
            }
            else
            {
                Notifier.Banner("Checksum mismatch",
                    $"{image.DisplayName} no longer matches the recorded SHA-256.", BannerKind.Error);
            }
        }
        catch (OperationCanceledException)
        {
        }
        finally
        {
            IsBusy = false;
            BusyMessage = string.Empty;
            HashProgress = null;
        }
    }

    private async Task<string> ComputeHashAsync(string path, CancellationToken cancellation)
    {
        HashProgress = 0;
        try
        {
            return await Downloader.Sha256Async(path, fraction => HashProgress = fraction, cancellation)
                .ConfigureAwait(true);
        }
        finally
        {
            HashProgress = null;
        }
    }

    // MARK: - Mutation

    public void Touch() => Persist();

    public void Rename(WindowsImage image, string name)
    {
        image.Name = name;
        Persist();
    }

    /// <summary>Removes the record; deletes the file too when ImageHub owns it.</summary>
    public void Remove(WindowsImage image, bool deleteFile)
    {
        if (deleteFile && image.Managed && image.FileExists) { TryDelete(image.Path); }
        _images.RemoveAll(candidate => candidate.Id == image.Id);
        Persist();
    }

    private static long SizeOf(string path)
    {
        try { return new FileInfo(path).Length; }
        catch (Exception) { return 0; }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) { File.Delete(path); } }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static string LastPathSegment(string url)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out Uri? parsed) && parsed.Segments.Length > 0)
        {
            return Uri.UnescapeDataString(parsed.Segments[^1]).TrimEnd('/');
        }
        return "image.iso";
    }

    private static string SafeFileName(string name)
    {
        var cleaned = new System.Text.StringBuilder();
        foreach (char c in name)
        {
            cleaned.Append(Path.GetInvalidFileNameChars().Contains(c) ? '_' : c);
        }
        string result = cleaned.ToString().Trim();
        return result.Length == 0 ? "image.iso" : result;
    }
}
