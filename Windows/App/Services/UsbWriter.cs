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
/// Turns (template + ISO + USB drive) into bootable Windows install media.
///
/// The media it produces is a stock Windows Setup USB with three additions:
/// autounattend.xml at the root, an ImageHub\ payload folder, and — when the image
/// demands it — a split install*.swm instead of install.wim.
///
/// The eight stages are the same as the macOS app's, in the same order, because they
/// describe the work rather than the platform. What differs underneath is only the
/// tooling: Windows' storage cmdlets instead of diskutil, Mount-DiskImage instead of
/// hdiutil, DISM instead of wimlib.
/// </summary>
public static class UsbWriter
{
    /// <summary>Files Windows Setup will not boot without.</summary>
    private static readonly string[] RequiredBootFiles =
    {
        "bootmgr",
        "boot\\bcd",
        "sources\\boot.wim",
    };

    public static async Task BuildAsync(
        DeploymentTemplate template,
        WindowsImage image,
        UsbDisk drive,
        BuildJob job)
    {
        job.Start();
        CancellationToken cancellation = job.CancellationToken;

        void Log(string line) => job.Append(line);

        IsoMounter.Mounted? mounted = null;
        string volume = string.Empty;

        try
        {
            // 1 — Validate ------------------------------------------------------
            job.Begin(BuildJob.Stage.Validate);
            if (!Elevation.IsElevated)
            {
                throw new BuildException(
                    "Building a drive needs administrator rights: erasing the disk and mounting the "
                    + "ISO both do. Close this, choose Tools → Restart as Administrator, and run the "
                    + "build again. Nothing has been changed.");
            }
            IReadOnlyList<string> errors = template.ValidationErrors;
            if (errors.Count > 0)
            {
                throw new BuildException(string.Join(" ", errors));
            }
            if (!image.FileExists)
            {
                throw new BuildException($"The ISO for this image is missing: {image.Path}");
            }
            if (!drive.HasRoom(image.SizeBytes))
            {
                throw new BuildException(
                    $"{drive.DisplayName} holds {Formatting.ByteSize(drive.SizeBytes)} but this image "
                    + $"needs about {Formatting.ByteSize(image.SizeBytes + 512_000_000)} including the "
                    + "payload.");
            }
            job.Append($"Template “{template.Name}” → {drive.DisplayName} (disk {drive.Number})");
            foreach (string warning in template.ValidationWarnings)
            {
                job.Append("⚠ " + warning);
            }
            job.Finish(BuildJob.Stage.Validate);
            cancellation.ThrowIfCancellationRequested();

            // 2 — The image is already local at this point; record what we're using.
            job.Begin(BuildJob.Stage.AcquireImage, $"Using {image.DisplayName}");
            job.Append($"ISO: {image.Path} ({Formatting.ByteSize(image.SizeBytes)})");
            job.Finish(BuildJob.Stage.AcquireImage);

            // 3 — Erase ---------------------------------------------------------
            job.Begin(BuildJob.Stage.Erase, $"Wiping {drive.DisplayName}");
            volume = await DiskService
                .EraseToFat32Async(drive, Settings.Current.DefaultVolumeLabel, Log, cancellation)
                .ConfigureAwait(true);
            job.Append($"New volume mounted at {volume}\\");
            job.Finish(BuildJob.Stage.Erase);
            cancellation.ThrowIfCancellationRequested();

            // 4 — Copy everything except the install image -----------------------
            mounted = await IsoMounter.MountAsync(image.Path, Log, cancellation).ConfigureAwait(true);
            job.Begin(BuildJob.Stage.CopyBootFiles, "Copying Windows Setup files");
            await CopyBootFilesAsync(mounted.Root, volume + "\\", job, cancellation).ConfigureAwait(true);
            job.Finish(BuildJob.Stage.CopyBootFiles);
            cancellation.ThrowIfCancellationRequested();

            // 5 — install.wim, split if it can't fit on FAT32 ---------------------
            job.Begin(BuildJob.Stage.InstallImage);
            await WriteInstallImageAsync(template, mounted.Root, volume + "\\", job, cancellation)
                .ConfigureAwait(true);
            job.Finish(BuildJob.Stage.InstallImage);
            cancellation.ThrowIfCancellationRequested();

            // 6 — Answer file ----------------------------------------------------
            job.Begin(BuildJob.Stage.AnswerFile);
            ResolvedSecrets secrets = ResolvedSecrets.Load(template);
            string xml = new AnswerFileBuilder(template, secrets).Build();
            // UTF-8 without a BOM, and \n line endings, exactly as the macOS app writes
            // it — Setup accepts either, but the two files should be comparable.
            var encoding = new System.Text.UTF8Encoding(false);
            File.WriteAllText(Path.Combine(volume + "\\", "autounattend.xml"), xml, encoding);
            // A copy under sources\ is what Setup looks for when booting from some
            // firmware; harmless duplication, one less way to fail.
            try
            {
                Directory.CreateDirectory(Path.Combine(volume + "\\", "sources"));
                File.WriteAllText(Path.Combine(volume + "\\", "sources", "autounattend.xml"), xml, encoding);
            }
            catch (IOException)
            {
            }
            job.Append($"Wrote autounattend.xml ({xml.Length} bytes)");
            job.Finish(BuildJob.Stage.AnswerFile);

            // 7 — Payload --------------------------------------------------------
            job.Begin(BuildJob.Stage.Payload);

            // Office needs the Deployment Tool's setup.exe on the drive. Resolving it
            // here rather than inside PayloadBuilder keeps the download in async code and
            // out of a synchronous file-copying routine — and means an operator who never
            // went and found one still gets a working build.
            DeploymentTemplate resolved = template;
            if (template.Microsoft365.Enabled)
            {
                string tool = await OfficeDeploymentTool
                    .ResolveAsync(template.Microsoft365.SetupPath, Log, cancellation)
                    .ConfigureAwait(true);
                resolved = template.DeepCopy();
                resolved.Microsoft365.SetupPath = tool;
            }

            string payload = await Task.Run(
                () => PayloadBuilder.Write(resolved, secrets, volume + "\\", Log),
                cancellation).ConfigureAwait(true);
            job.Append($"Payload: {Path.GetFileName(payload)}\\");
            job.Finish(BuildJob.Stage.Payload);

            // 8 — Verify ---------------------------------------------------------
            job.Begin(BuildJob.Stage.Verify);
            VerifyMedia(volume + "\\", job);
            job.Finish(BuildJob.Stage.Verify);

            await IsoMounter.DismountAsync(image.Path, CancellationToken.None).ConfigureAwait(true);
            mounted = null;

            if (Settings.Current.EjectAfterBuild)
            {
                job.Append($"Ejecting {volume}…");
                await DiskService.EjectAsync(volume, CancellationToken.None).ConfigureAwait(true);
            }

            job.Succeed();
            Notifier.BuildFinished(template.Name, drive.DisplayName, success: true);
            Notifier.Banner("USB ready", $"{template.Name} → {drive.DisplayName}");
        }
        catch (OperationCanceledException)
        {
            if (mounted is not null)
            {
                await IsoMounter.DismountAsync(image.Path, CancellationToken.None).ConfigureAwait(true);
            }
            job.MarkCancelled();
            Notifier.Banner("Build cancelled", drive.DisplayName, BannerKind.Info);
        }
        catch (Exception error)
        {
            if (mounted is not null)
            {
                await IsoMounter.DismountAsync(image.Path, CancellationToken.None).ConfigureAwait(true);
            }
            job.Fail(job.CurrentStage, error.Message);
            Notifier.BuildFinished(template.Name, drive.DisplayName, success: false);
            Notifier.Banner("Build failed", error.Message, BannerKind.Error);
        }
    }

    // MARK: - Steps

    private static async Task CopyBootFilesAsync(
        string isoRoot,
        string volumeRoot,
        BuildJob job,
        CancellationToken cancellation)
    {
        // install.wim/.esd are handled separately — they may need splitting.
        var excluded = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "sources/install.wim",
            "sources/install.esd",
        };

        FileCopier.Plan plan = await Task.Run(
            () => FileCopier.BuildPlan(isoRoot, excluded), cancellation).ConfigureAwait(true);

        job.Append($"Copying {plan.FileCount} files ({Formatting.ByteSize(plan.TotalBytes)})…");

        DateTime started = DateTime.Now;
        await Task.Run(
            () => FileCopier.Copy(plan, volumeRoot, (fraction, copied) =>
            {
                job.Progress(fraction,
                    $"Copying Windows Setup files — {(int)(fraction * 100)}%"
                    + Formatting.Rate(copied, started));
            }, cancellation),
            cancellation).ConfigureAwait(true);

        job.Progress(1);
    }

    private static async Task WriteInstallImageAsync(
        DeploymentTemplate template,
        string isoRoot,
        string volumeRoot,
        BuildJob job,
        CancellationToken cancellation)
    {
        string destinationSources = Path.Combine(volumeRoot, "sources");
        Directory.CreateDirectory(destinationSources);

        // A template can override the install image with its own captured WIM.
        string source;
        if (template.Windows.UsesCapturedImage)
        {
            source = template.Windows.CustomWimPath;
            if (!File.Exists(source))
            {
                throw new BuildException(
                    $"The captured image this template points at is missing: {source}");
            }
            job.Append($"Using captured image {Path.GetFileName(source)} instead of the one in the ISO.");
        }
        else if (File.Exists(Path.Combine(isoRoot, "sources", "install.wim")))
        {
            source = Path.Combine(isoRoot, "sources", "install.wim");
        }
        else if (File.Exists(Path.Combine(isoRoot, "sources", "install.esd")))
        {
            source = Path.Combine(isoRoot, "sources", "install.esd");
        }
        else
        {
            throw new BuildException(
                "This ISO has no sources\\install.wim or install.esd — it may not be Windows "
                + "install media.");
        }

        long size = 0;
        try { size = new FileInfo(source).Length; } catch (IOException) { }
        string name = Path.GetFileName(source);
        job.Append($"{name} is {Formatting.ByteSize(size)}");

        if (size < WindowsImage.Fat32FileLimit)
        {
            job.Progress(0, $"Copying {name}");
            DateTime started = DateTime.Now;
            await Task.Run(
                () => FileCopier.CopyFile(source, Path.Combine(destinationSources, name), fraction =>
                {
                    job.Progress(fraction,
                        $"Writing {name} — {(int)(fraction * 100)}%"
                        + Formatting.Rate(size * fraction, started));
                }, cancellation),
                cancellation).ConfigureAwait(true);
            job.Progress(1);
            job.Append($"Wrote {name} ({Formatting.ByteSize(size)}) in "
                + Formatting.ShortDuration(DateTime.Now - started)
                + Formatting.Rate(size, started));
            return;
        }

        // Too big for FAT32 — split into install.swm + install2.swm + …
        job.Progress(0, $"Splitting {name} for FAT32");
        DateTime splitStarted = DateTime.Now;
        await WimSplitter.SplitAsync(
            source,
            Path.Combine(destinationSources, "install.swm"),
            line => job.Append(line),
            fraction => job.Progress(fraction,
                $"Splitting {name} for FAT32 — {(int)(fraction * 100)}%"
                + Formatting.Rate(size * fraction, splitStarted)),
            cancellation).ConfigureAwait(true);

        List<string> parts = Directory
            .GetFiles(destinationSources, "*.swm")
            .Select(Path.GetFileName)
            .Where(part => part is not null)
            .Select(part => part!)
            .OrderBy(part => part, StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (parts.Count == 0)
        {
            throw new BuildException("DISM reported success but no .swm parts were written.");
        }
        job.Append($"Wrote {Formatting.Plural(parts.Count, "split part")}: {string.Join(", ", parts)}");
    }

    private static void VerifyMedia(string volumeRoot, BuildJob job)
    {
        var missing = new List<string>();

        foreach (string relative in RequiredBootFiles)
        {
            // The ISO's casing varies (BOOTMGR vs bootmgr); FAT32 is case-insensitive,
            // so a plain existence check is enough.
            if (!File.Exists(Path.Combine(volumeRoot, relative))) { missing.Add(relative); }
        }

        string sources = Path.Combine(volumeRoot, "sources");
        bool hasInstall = new[] { "install.wim", "install.esd", "install.swm" }
            .Any(candidate => File.Exists(Path.Combine(sources, candidate)));
        if (!hasInstall) { missing.Add("sources\\install.wim (or .swm)"); }

        if (!File.Exists(Path.Combine(volumeRoot, "autounattend.xml")))
        {
            missing.Add("autounattend.xml");
        }
        if (!File.Exists(Path.Combine(volumeRoot, PayloadBuilder.FolderName, "Provision.ps1")))
        {
            missing.Add("ImageHub\\Provision.ps1");
        }

        // EFI boot loader — warn rather than fail, since MBR/BIOS-only media
        // legitimately lacks it.
        if (!File.Exists(Path.Combine(volumeRoot, "efi", "boot", "bootx64.efi")))
        {
            job.Append("⚠ No efi\\boot\\bootx64.efi — this media will only boot in legacy BIOS mode.");
        }

        if (missing.Count > 0)
        {
            throw new BuildException(
                "The finished drive is missing: " + string.Join(", ", missing));
        }
        job.Append("Verified boot files, install image, answer file, and payload.");
    }
}
