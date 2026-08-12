using System;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using ImageHub.Models;
using ImageHub.Support;

namespace ImageHub.Services;

/// <summary>
/// Everything that touches physical disks, through Windows' own storage cmdlets.
///
/// The destructive footprint is one method, <see cref="EraseToFat32Async"/>, and it
/// re-checks the target immediately before erasing rather than trusting the model
/// the UI was holding — an operator may have unplugged and replugged, and Windows
/// reuses disk numbers. Enumeration drops anything that isn't removable external
/// media before the list reaches the UI, so an internal disk is never offered.
///
/// The scripts below use __TOKEN__ placeholders rather than string interpolation:
/// PowerShell is full of braces, C# interpolation is too, and mixing them is how a
/// script that erases disks would get quietly mangled.
/// </summary>
public static class DiskService
{
    /// <summary>
    /// Windows' FAT32 formatter refuses a volume larger than 32 GB, so on a bigger
    /// stick ImageHub formats the first 31 GB and leaves the rest unallocated. Setup
    /// media has to be FAT32 (UEFI firmware is only guaranteed to read FAT) and a
    /// split install image needs about 7 GB, so nothing is lost but capacity nobody
    /// was going to use. A drive built on a Mac spans the whole stick because
    /// newfs_msdos has no such limit; both boot identically.
    /// </summary>
    public const long MaxFat32PartitionBytes = 31L * 1024 * 1024 * 1024;

    // MARK: - Enumeration

    private const string ScanScript = """
        $disks = @()
        foreach ($d in (Get-Disk | Sort-Object Number)) {
            $letters = @()
            $labels = @()
            try {
                foreach ($p in (Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)) {
                    if ($p.DriveLetter) { $letters += ([string]$p.DriveLetter + ':') }
                    $v = $null
                    try { $v = $p | Get-Volume -ErrorAction SilentlyContinue } catch { }
                    if ($v -and $v.FileSystemLabel) { $labels += [string]$v.FileSystemLabel }
                }
            } catch { }
            $disks += [ordered]@{
                number         = [int]$d.Number
                friendlyName   = [string]$d.FriendlyName
                size           = [int64]$d.Size
                busType        = [string]$d.BusType
                isSystem       = [bool]$d.IsSystem
                isBoot         = [bool]$d.IsBoot
                isOffline      = [bool]$d.IsOffline
                isReadOnly     = [bool]$d.IsReadOnly
                partitionStyle = [string]$d.PartitionStyle
                serialNumber   = ([string]$d.SerialNumber).Trim()
                driveLetters   = @($letters)
                volumeLabels   = @($labels)
                mediaType      = ''
            }
        }
        # Get-Disk has no removable flag. Win32_DiskDrive's MediaType is where
        # "Removable Media" actually comes from, and it catches an enclosure that
        # reports a bus type of neither USB nor SD.
        try {
            $media = @{}
            foreach ($drive in (Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue)) {
                $media[[int]$drive.Index] = [string]$drive.MediaType
            }
            foreach ($disk in $disks) {
                if ($media.ContainsKey([int]$disk.number)) { $disk.mediaType = $media[[int]$disk.number] }
            }
        } catch { }
        ConvertTo-Json -InputObject ([ordered]@{ disks = @($disks) }) -Depth 6 -Compress
        """;

    /// <summary>
    /// Returns the drives ImageHub is willing to write to: removable external media.
    /// Everything else — internal disks above all — is dropped here and never
    /// surfaces, so there is no way to pick one by mistake.
    /// </summary>
    public static async Task<List<UsbDisk>> ScanAsync(CancellationToken cancellation = default)
    {
        ProcessResult result = await ProcessRunner
            .PowerShellAsync(ScanScript, null, cancellation).ConfigureAwait(false);

        var found = new List<UsbDisk>();
        if (!result.Succeeded) { return found; }

        try
        {
            string output = result.StandardOutput.Trim();
            if (output.Length == 0) { return found; }
            using JsonDocument document = JsonDocument.Parse(output);
            if (!document.RootElement.TryGetProperty("disks", out JsonElement disks)
                || disks.ValueKind != JsonValueKind.Array)
            {
                return found;
            }
            foreach (JsonElement entry in disks.EnumerateArray())
            {
                string mediaType = Text(entry, "mediaType");
                var disk = new UsbDisk
                {
                    Number = Number(entry, "number"),
                    FriendlyName = Text(entry, "friendlyName"),
                    SizeBytes = Long(entry, "size"),
                    BusType = Text(entry, "busType"),
                    IsSystem = Flag(entry, "isSystem"),
                    IsBoot = Flag(entry, "isBoot"),
                    IsOffline = Flag(entry, "isOffline"),
                    IsReadOnly = Flag(entry, "isReadOnly"),
                    PartitionStyle = Text(entry, "partitionStyle"),
                    SerialNumber = Text(entry, "serialNumber"),
                    IsRemovable = mediaType.Contains("Removable", StringComparison.OrdinalIgnoreCase),
                    DriveLetters = Strings(entry, "driveLetters"),
                    VolumeLabels = Strings(entry, "volumeLabels"),
                };
                if (disk.Number >= 0 && disk.IsEligibleTarget) { found.Add(disk); }
            }
        }
        catch (JsonException)
        {
            return found;
        }

        found.Sort((a, b) => a.Number.CompareTo(b.Number));
        return found;
    }

    /// <summary>Re-reads one disk, so an erase can verify what it is about to destroy.</summary>
    public static async Task<UsbDisk?> ReloadAsync(int number, CancellationToken cancellation = default)
    {
        foreach (UsbDisk disk in await ScanAsync(cancellation).ConfigureAwait(false))
        {
            if (disk.Number == number) { return disk; }
        }
        return null;
    }

    // MARK: - Destructive operations

    private const string EraseScript = """
        $n = __DISK__
        $disk = Get-Disk -Number $n

        # Two independent refusals, because this is the one irreversible thing
        # ImageHub does and the caller's copy of the disk list may be stale.
        if ($disk.IsSystem -or $disk.IsBoot) { throw 'Refusing to erase the system disk.' }
        if ($disk.BusType -ne 'USB' -and $disk.BusType -ne 'SD' -and $disk.BusType -ne 'MMC') {
            $entry = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue |
                Where-Object { [int]$_.Index -eq $n } | Select-Object -First 1
            $media = [string]$entry.MediaType
            if ($media -notlike '*Removable*') {
                throw "Disk $n is $($disk.BusType) fixed media - refusing to erase it."
            }
        }

        if ($disk.IsOffline) { Set-Disk -Number $n -IsOffline $false }
        if ($disk.IsReadOnly) { Set-Disk -Number $n -IsReadOnly $false }

        # Clear-Disk fails on a disk that was already RAW, which is not a problem;
        # it failing while partitions are still there is.
        try {
            Clear-Disk -Number $n -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
        } catch {
            $left = @(Get-Partition -DiskNumber $n -ErrorAction SilentlyContinue)
            if ($left.Count -gt 0) { throw }
        }

        $disk = Get-Disk -Number $n
        if ($disk.PartitionStyle -ne 'MBR') {
            # MBR is the most widely bootable layout for Setup media, and it is what
            # the macOS side writes too. Failing here is not fatal: FAT32 on GPT still
            # boots UEFI, so the build carries on and says so.
            try { Initialize-Disk -Number $n -PartitionStyle MBR -ErrorAction Stop } catch { }
        }
        $disk = Get-Disk -Number $n
        if ($disk.PartitionStyle -eq 'RAW') {
            throw "Disk $n could not be initialised, so no partition can be created on it."
        }
        if ($disk.PartitionStyle -ne 'MBR') {
            Write-Host "note: the drive stayed $($disk.PartitionStyle) rather than MBR; it will still boot UEFI."
        }

        $partition = __NEWPARTITION__
        Start-Sleep -Milliseconds 800
        $partition = Get-Partition -DiskNumber $n -PartitionNumber $partition.PartitionNumber
        if (-not $partition.DriveLetter) {
            Add-PartitionAccessPath -DiskNumber $n -PartitionNumber $partition.PartitionNumber -AssignDriveLetter
            Start-Sleep -Milliseconds 800
            $partition = Get-Partition -DiskNumber $n -PartitionNumber $partition.PartitionNumber
        }

        Format-Volume -Partition $partition -FileSystem FAT32 -NewFileSystemLabel __LABEL__ -Force -Confirm:$false | Out-Null
        Start-Sleep -Milliseconds 400
        $partition = Get-Partition -DiskNumber $n -PartitionNumber $partition.PartitionNumber
        ConvertTo-Json -InputObject ([ordered]@{ driveLetter = ([string]$partition.DriveLetter) }) -Compress
        """;

    /// <summary>
    /// Wipes a drive and lays down a single active FAT32 volume, then returns its
    /// drive letter (as "E:").
    ///
    /// FAT32 is not a preference — UEFI firmware is only required to read FAT, so it
    /// is the one filesystem a Windows Setup USB can reliably boot from. The 4 GB
    /// per-file ceiling that comes with it is why install.wim gets split.
    ///
    /// The stick itself is always MBR. The template's partition style describes the
    /// layout of the *target machine's* disk, which the answer file applies during
    /// Setup.
    /// </summary>
    public static async Task<string> EraseToFat32Async(
        UsbDisk drive,
        string label,
        Action<string> log,
        CancellationToken cancellation = default)
    {
        UsbDisk fresh = await ReloadAsync(drive.Number, cancellation).ConfigureAwait(false)
            ?? throw new BuildException($"Disk {drive.Number} is no longer attached.");

        if (!fresh.IsEligibleTarget)
        {
            throw new BuildException(
                $"{fresh.DisplayName} is not removable external media — refusing to erase it.");
        }
        // Disk numbers are reused as sticks come and go, so the serial is what proves
        // this is still the same piece of hardware the operator picked.
        if (drive.SerialNumber.Length > 0 && fresh.SerialNumber.Length > 0
            && !string.Equals(drive.SerialNumber, fresh.SerialNumber, StringComparison.OrdinalIgnoreCase))
        {
            throw new BuildException(
                $"Disk {drive.Number} is now a different device ({fresh.DisplayName}) than the one "
                + "selected. Nothing was erased — pick the drive again.");
        }

        string volumeLabel = SanitizeFat32Label(label);
        bool capped = fresh.SizeBytes > MaxFat32PartitionBytes;
        if (capped)
        {
            log($"Formatting the first {Formatting.ByteSize(MaxFat32PartitionBytes)} as FAT32: "
                + "Windows will not create a FAT32 volume larger than 32 GB, and Setup media has to "
                + "be FAT32. The rest of the drive is left unallocated.");
        }

        log($"Erasing {fresh.DisplayName} (disk {fresh.Number}) as FAT32 “{volumeLabel}”…");

        string newPartition = capped
            ? $"New-Partition -DiskNumber $n -Size {MaxFat32PartitionBytes} -IsActive -AssignDriveLetter"
            : "New-Partition -DiskNumber $n -UseMaximumSize -IsActive -AssignDriveLetter";

        string script = EraseScript
            .Replace("__DISK__", fresh.Number.ToString())
            .Replace("__NEWPARTITION__", newPartition)
            .Replace("__LABEL__", PsQuote(volumeLabel));

        ProcessResult result = await ProcessRunner
            .PowerShellAsync(script, line => LogNote(line, log), cancellation)
            .ConfigureAwait(false);

        if (!result.Succeeded) { throw new BuildException(ExplainFailure(result, fresh)); }

        string letter = ReadDriveLetter(result.StandardOutput);
        if (letter.Length == 0)
        {
            // The format succeeded but Windows had not handed out a letter yet. Give it
            // a moment rather than failing a drive that is actually fine.
            letter = await WaitForDriveLetterAsync(fresh.Number, cancellation).ConfigureAwait(false);
        }
        if (letter.Length == 0)
        {
            throw new BuildException(
                $"The new volume on disk {fresh.Number} never got a drive letter, so there is nowhere "
                + "to write the media. Unplug the drive, plug it back in, and try again.");
        }

        log($"Formatted as {volumeLabel} at {letter}");
        return letter;
    }

    private const string LetterScript = """
        $p = Get-Partition -DiskNumber __DISK__ -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter } | Select-Object -First 1
        ConvertTo-Json -InputObject ([ordered]@{ driveLetter = ([string]$p.DriveLetter) }) -Compress
        """;

    /// <summary>Polls for the drive letter of the first lettered partition on a disk.</summary>
    public static async Task<string> WaitForDriveLetterAsync(
        int diskNumber,
        CancellationToken cancellation = default,
        int attempts = 20)
    {
        string script = LetterScript.Replace("__DISK__", diskNumber.ToString());
        for (int attempt = 0; attempt < attempts; attempt++)
        {
            ProcessResult result = await ProcessRunner
                .PowerShellAsync(script, null, cancellation).ConfigureAwait(false);
            string letter = ReadDriveLetter(result.StandardOutput);
            if (letter.Length > 0) { return letter; }
            await Task.Delay(500, cancellation).ConfigureAwait(false);
        }
        return string.Empty;
    }

    /// <summary>FAT32 volume labels are 11 characters, upper case, no punctuation.</summary>
    public static string SanitizeFat32Label(string raw)
    {
        const string allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-";
        var cleaned = new StringBuilder();
        foreach (char c in (raw ?? string.Empty).ToUpperInvariant())
        {
            if (allowed.IndexOf(c) >= 0) { cleaned.Append(c); }
            if (cleaned.Length == 11) { break; }
        }
        return cleaned.Length == 0 ? "IMAGEHUB" : cleaned.ToString();
    }

    private const string EjectScript = """
        $letter = __LETTER__
        try {
            $shell = New-Object -ComObject Shell.Application
            $shell.Namespace(17).ParseName($letter).InvokeVerb('Eject')
        } catch {
            & mountvol.exe $letter /p
        }
        """;

    /// <summary>
    /// Safely removes the drive — the same thing the notification-area icon does — so
    /// pulling the stick out afterwards cannot lose a buffered write.
    /// </summary>
    public static async Task EjectAsync(string driveLetter, CancellationToken cancellation = default)
    {
        string letter = (driveLetter ?? string.Empty).Trim().TrimEnd('\\');
        if (letter.Length == 0) { return; }
        string script = EjectScript.Replace("__LETTER__", PsQuote(letter));
        _ = await ProcessRunner.PowerShellAsync(script, null, cancellation).ConfigureAwait(false);
    }

    // MARK: - Helpers

    private static void LogNote(string line, Action<string> log)
    {
        string trimmed = line.Trim();
        if (trimmed.Length == 0) { return; }
        // The script's own JSON result is not a log line.
        if (trimmed.StartsWith("{", StringComparison.Ordinal)) { return; }
        log(trimmed);
    }

    /// <summary>
    /// Turns a cmdlet failure into something an operator can act on. "Access is
    /// denied" from Clear-Disk means one thing only, and saying so beats echoing the
    /// raw error.
    /// </summary>
    private static string ExplainFailure(ProcessResult result, UsbDisk drive)
    {
        string raw = result.FailureMessage;
        if (raw.Contains("Access is denied", StringComparison.OrdinalIgnoreCase)
            || raw.Contains("requires elevation", StringComparison.OrdinalIgnoreCase))
        {
            return "Erasing a drive needs administrator rights. Restart ImageHub as administrator "
                + "and run the build again.";
        }
        if (raw.Contains("in use", StringComparison.OrdinalIgnoreCase))
        {
            return $"Windows would not release {drive.DisplayName} — something still has a file open "
                + "on it. Close anything using the drive and try again.";
        }
        if (raw.Contains("too big for FAT32", StringComparison.OrdinalIgnoreCase)
            || raw.Contains("volume size is too big", StringComparison.OrdinalIgnoreCase))
        {
            return "Windows refused to make a FAT32 volume this large, which means ImageHub's 31 GB "
                + "cap did not apply. Please report this with the drive's capacity.";
        }
        return $"Couldn't prepare {drive.DisplayName}: {raw}";
    }

    private static string ReadDriveLetter(string json)
    {
        try
        {
            // The script prints notes as well as its JSON result, so take the last line
            // that looks like an object.
            string letter = string.Empty;
            foreach (string line in (json ?? string.Empty).Split('\n'))
            {
                string trimmed = line.Trim();
                if (!trimmed.StartsWith("{", StringComparison.Ordinal)) { continue; }
                using JsonDocument document = JsonDocument.Parse(trimmed);
                if (document.RootElement.TryGetProperty("driveLetter", out JsonElement value)
                    && value.ValueKind == JsonValueKind.String)
                {
                    letter = value.GetString() ?? string.Empty;
                }
            }
            letter = letter.Trim().TrimEnd(':');
            if (letter.Length != 1 || !char.IsLetter(letter[0])) { return string.Empty; }
            return letter.ToUpperInvariant() + ":";
        }
        catch (JsonException)
        {
            return string.Empty;
        }
    }

    /// <summary>Single-quotes a value for a PowerShell script, doubling any quote inside it.</summary>
    public static string PsQuote(string value) => "'" + (value ?? string.Empty).Replace("'", "''") + "'";

    private static string Text(JsonElement entry, string name) =>
        entry.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? string.Empty
            : string.Empty;

    private static int Number(JsonElement entry, string name) =>
        entry.TryGetProperty(name, out JsonElement value) && value.TryGetInt32(out int number) ? number : -1;

    private static long Long(JsonElement entry, string name) =>
        entry.TryGetProperty(name, out JsonElement value) && value.TryGetInt64(out long number) ? number : 0;

    private static bool Flag(JsonElement entry, string name) =>
        entry.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.True;

    private static List<string> Strings(JsonElement entry, string name)
    {
        var values = new List<string>();
        if (entry.TryGetProperty(name, out JsonElement array) && array.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement item in array.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String) { continue; }
                string? text = item.GetString();
                if (!string.IsNullOrEmpty(text)) { values.Add(text); }
            }
        }
        return values;
    }
}
