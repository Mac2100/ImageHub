using System;
using System.Collections.Generic;
using ImageHub.Support;

namespace ImageHub.Models;

/// <summary>
/// A whole physical disk, as Windows' storage cmdlets report it.
///
/// The eligibility rule is the same promise the macOS app makes: only removable
/// external media is ever offered as a build target, and the filtering happens
/// before the list reaches the UI so there is nothing to pick by mistake.
/// </summary>
public sealed class UsbDisk
{
    /// <summary>The physical disk number diskpart and the storage cmdlets use.</summary>
    public int Number { get; init; }

    /// <summary>"SanDisk Ultra USB 3.0 Device"</summary>
    public string FriendlyName { get; init; } = string.Empty;

    public long SizeBytes { get; init; }

    /// <summary>USB, SD, SATA, NVMe, RAID…</summary>
    public string BusType { get; init; } = string.Empty;

    public bool IsRemovable { get; init; }

    /// <summary>True for the disk Windows itself booted from. Never a target.</summary>
    public bool IsSystem { get; init; }

    public bool IsBoot { get; init; }

    public bool IsOffline { get; init; }

    public bool IsReadOnly { get; init; }

    public string PartitionStyle { get; init; } = string.Empty;

    public IReadOnlyList<string> VolumeLabels { get; init; } = Array.Empty<string>();

    public IReadOnlyList<string> DriveLetters { get; init; } = Array.Empty<string>();

    /// <summary>Stable identity for the UI's selection, since disk numbers are reused.</summary>
    public string Id => Number.ToString() + "|" + SerialNumber;

    public string SerialNumber { get; init; } = string.Empty;

    public string DisplayName => FriendlyName.Length > 0 ? FriendlyName : $"Disk {Number}";

    public string Subtitle
    {
        get
        {
            var parts = new List<string>
            {
                Formatting.ByteSize(SizeBytes),
                BusType.Length > 0 ? BusType : "Unknown bus",
                $"Disk {Number}",
            };
            if (VolumeLabels.Count > 0) { parts.Add(string.Join(", ", VolumeLabels)); }
            else if (DriveLetters.Count > 0) { parts.Add(string.Join(", ", DriveLetters)); }
            return string.Join(" · ", parts);
        }
    }

    /// <summary>
    /// Only removable external media is ever offered — an internal disk must never
    /// show up in the picker. USB and SD cover every stick and card reader; the
    /// system and boot flags are belt and braces for an enclosure that reports
    /// itself as removable.
    /// </summary>
    public bool IsEligibleTarget =>
        !IsSystem
        && !IsBoot
        && !IsReadOnly
        && SizeBytes > 0
        && (IsRemovable
            || BusType.Equals("USB", StringComparison.OrdinalIgnoreCase)
            || BusType.Equals("SD", StringComparison.OrdinalIgnoreCase)
            || BusType.Equals("MMC", StringComparison.OrdinalIgnoreCase));

    /// <summary>Windows install media needs room for the ISO plus the payload.</summary>
    public bool HasRoom(long isoSize) => SizeBytes >= isoSize + 512_000_000;
}
