using System;
using System.Reflection;

namespace ImageHub.Support;

/// <summary>
/// The app version, which is the macOS app's <c>AppVersion.marketing</c>.
///
/// Both platforms check the same GitHub release and compare it against their own
/// version, so they have to agree on what "1.6.3" means. ImageHub.csproj reads
/// that Swift constant at build time and stamps it here as the assembly's
/// informational version; CI then asserts that <c>ImageHub.exe --version</c>
/// matches the same file, so the two can't drift apart unnoticed.
/// </summary>
public static class AppVersion
{
    private static string? _current;

    public static string Current
    {
        get
        {
            if (_current is not null) { return _current; }
            string? raw = Assembly.GetExecutingAssembly()
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            if (string.IsNullOrWhiteSpace(raw))
            {
                raw = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3);
            }
            // A source build can carry a "+<commit>" suffix; the update check
            // compares dotted numbers, so drop anything after it.
            int plus = raw?.IndexOf('+') ?? -1;
            if (plus > 0) { raw = raw!.Substring(0, plus); }
            _current = string.IsNullOrWhiteSpace(raw) ? "0.0.0" : raw!;
            return _current;
        }
    }

    /// <summary>
    /// Numeric dotted-version comparison ("1.2.10" &gt; "1.2.9"). Deliberately the
    /// same algorithm as UpdateChecker.isVersion(_:newerThan:) on macOS.
    /// </summary>
    public static bool IsNewer(string candidate, string current)
    {
        int[] a = Parse(candidate);
        int[] b = Parse(current);
        for (int i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            int x = i < a.Length ? a[i] : 0;
            int y = i < b.Length ? b[i] : 0;
            if (x != y) { return x > y; }
        }
        return false;
    }

    private static int[] Parse(string version)
    {
        string[] parts = (version ?? string.Empty).Split('.');
        int[] numbers = new int[parts.Length];
        for (int i = 0; i < parts.Length; i++)
        {
            int digits = 0;
            while (digits < parts[i].Length && char.IsDigit(parts[i][digits])) { digits++; }
            _ = int.TryParse(parts[i].Substring(0, digits), out numbers[i]);
        }
        return numbers;
    }
}
