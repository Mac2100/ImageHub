using System;
using System.Globalization;

namespace ImageHub.Support;

/// <summary>Display helpers shared by the views.</summary>
public static class Formatting
{
    /// <summary>
    /// "5.36 GB". Decimal units, matching what the macOS app shows and what drive
    /// manufacturers print on the box — a 16 GB stick should read as about 16 GB,
    /// not 14.9.
    /// </summary>
    public static string ByteSize(long bytes)
    {
        if (bytes < 0) { return "—"; }
        if (bytes < 1000) { return bytes == 1 ? "1 byte" : $"{bytes} bytes"; }

        string[] units = { "KB", "MB", "GB", "TB", "PB" };
        double value = bytes;
        int unit = -1;
        while (value >= 1000 && unit < units.Length - 1)
        {
            value /= 1000;
            unit++;
        }

        string number = value >= 100 ? value.ToString("0", CultureInfo.CurrentCulture)
            : value >= 10 ? value.ToString("0.0", CultureInfo.CurrentCulture)
            : value.ToString("0.00", CultureInfo.CurrentCulture);
        return $"{number} {units[unit]}";
    }

    /// <summary>"1h 4m", "4m 12s", "9s".</summary>
    public static string ShortDuration(TimeSpan span)
    {
        int total = (int)Math.Round(span.TotalSeconds);
        if (total < 0) { total = 0; }
        int hours = total / 3600;
        int minutes = (total % 3600) / 60;
        int seconds = total % 60;
        if (hours > 0) { return $"{hours}h {minutes}m"; }
        if (minutes > 0) { return $"{minutes}m {seconds}s"; }
        return $"{seconds}s";
    }

    /// <summary>
    /// " — 4.2 MB/s", or "" until enough has elapsed for the number to mean
    /// anything. USB sticks vary by more than an order of magnitude, and the
    /// difference between "this drive is slow" and "something is wrong" is a rate.
    /// </summary>
    public static string Rate(double bytes, DateTime since)
    {
        double seconds = (DateTime.Now - since).TotalSeconds;
        if (seconds <= 2 || bytes <= 0) { return string.Empty; }
        return string.Format(CultureInfo.CurrentCulture, " — {0:0.0} MB/s", bytes / seconds / 1_000_000);
    }

    public static string Brief(DateTime moment) =>
        moment.ToString("d MMM yyyy, HH:mm", CultureInfo.CurrentCulture);

    public static string Clock(DateTime moment) =>
        moment.ToString("HH:mm:ss", CultureInfo.CurrentCulture);

    /// <summary>Trims a string for a one-line label without cutting mid-word.</summary>
    public static string Ellipsize(string text, int limit)
    {
        if (string.IsNullOrEmpty(text) || text.Length <= limit) { return text; }
        return text.Substring(0, Math.Max(1, limit - 1)).TrimEnd() + "…";
    }

    public static string Plural(int count, string singular, string? plural = null) =>
        count == 1 ? $"{count} {singular}" : $"{count} {plural ?? singular + "s"}";
}
