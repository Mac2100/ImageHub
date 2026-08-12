using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using ImageHub.Services;
using ImageHub.Support;

namespace ImageHub.Views;

/// <summary>One of the six accent themes, matching the macOS app's set by name and hue.</summary>
public sealed class AccentTheme
{
    public AccentTheme(string id, string name, Color primary, Color secondary)
    {
        Id = id;
        Name = name;
        Primary = primary;
        Secondary = secondary;
    }

    public string Id { get; }

    public string Name { get; }

    public Color Primary { get; }

    public Color Secondary { get; }

    public LinearGradientBrush Gradient => new(Primary, Secondary, 45);
}

/// <summary>
/// Light/dark appearance and the accent theme.
///
/// Windows' own convention is that an app follows the system setting unless told
/// otherwise, so "System" is the default and reads
/// HKCU\...\Themes\Personalize\AppsUseLightTheme. The Light/Dark override exists
/// because the macOS app has one, and because a technician working next to a bench
/// lamp sometimes wants to overrule the system.
///
/// The palette is swapped as a merged dictionary, and every control style reaches its
/// colours through DynamicResource, so this takes effect on a running window.
/// </summary>
public static class ThemeManager
{
    public static readonly AccentTheme[] Themes =
    {
        new("hub", "Hub", Rgb(0.16, 0.40, 0.92), Rgb(0.36, 0.74, 0.96)),
        new("deploy", "Deploy", Rgb(0.05, 0.60, 0.55), Rgb(0.36, 0.83, 0.60)),
        new("ember", "Ember", Rgb(0.94, 0.42, 0.16), Rgb(0.90, 0.20, 0.50)),
        new("violet", "Violet", Rgb(0.48, 0.28, 0.88), Rgb(0.85, 0.38, 0.72)),
        new("steel", "Steel", Rgb(0.28, 0.35, 0.46), Rgb(0.52, 0.62, 0.72)),
        new("graphite", "Graphite", Rgb(0.35, 0.37, 0.42), Rgb(0.55, 0.58, 0.64)),
    };

    private static ResourceDictionary? _palette;

    public static AccentTheme Current => Find(Settings.Current.ThemeId);

    public static bool IsDark { get; private set; }

    public static event EventHandler? Changed;

    public static AccentTheme Find(string id)
    {
        foreach (AccentTheme theme in Themes)
        {
            if (theme.Id == id) { return theme; }
        }
        return Themes[0];
    }

    public static void Apply()
    {
        Application? app = Application.Current;
        if (app is null) { return; }

        bool dark = Settings.Current.Appearance switch
        {
            AppearanceMode.Light => false,
            AppearanceMode.Dark => true,
            _ => SystemPrefersDark(),
        };
        IsDark = dark;

        var wanted = new ResourceDictionary
        {
            Source = new Uri(
                dark ? "pack://application:,,,/Themes/Dark.xaml" : "pack://application:,,,/Themes/Light.xaml"),
        };

        if (_palette is not null) { app.Resources.MergedDictionaries.Remove(_palette); }
        // Inserted first so Controls.xaml, which is merged after it, still wins for
        // anything it defines itself.
        app.Resources.MergedDictionaries.Insert(0, wanted);
        _palette = wanted;

        ApplyAccent(Current, dark);

        foreach (Window window in app.Windows)
        {
            ApplyTitleBar(window, dark);
        }

        Changed?.Invoke(null, EventArgs.Empty);
    }

    private static void ApplyAccent(AccentTheme theme, bool dark)
    {
        ResourceDictionary resources = Application.Current.Resources;
        // On a dark background the accent is lightened a little; a saturated mid-blue
        // that reads well on white is muddy on #202020.
        Color primary = dark ? Mix(theme.Primary, Colors.White, 0.16) : theme.Primary;
        resources["AccentBrush"] = new SolidColorBrush(primary);
        resources["AccentHoverBrush"] = new SolidColorBrush(Mix(primary, Colors.White, 0.12));
        resources["AccentPressedBrush"] = new SolidColorBrush(Mix(primary, Colors.Black, 0.12));
        resources["AccentSubtleBrush"] = new SolidColorBrush(
            Color.FromArgb((byte)(dark ? 40 : 28), primary.R, primary.G, primary.B));
        resources["AccentSecondaryBrush"] = new SolidColorBrush(
            dark ? Mix(theme.Secondary, Colors.White, 0.1) : theme.Secondary);
        // White text on every one of the six accents clears 4.5:1 except the lightest,
        // so the foreground is picked from the accent's luminance rather than assumed.
        resources["OnAccentBrush"] = new SolidColorBrush(
            Luminance(primary) > 0.62 ? Color.FromRgb(0x1B, 0x1B, 0x1B) : Colors.White);
    }

    /// <summary>
    /// Paints the title bar to match, which is what makes a dark window look like a
    /// Windows 11 dark window rather than a dark page in a light frame. Available from
    /// Windows 10 20H1; older builds ignore it.
    /// </summary>
    public static void ApplyTitleBar(Window window, bool? dark = null)
    {
        try
        {
            IntPtr handle = new WindowInteropHelper(window).Handle;
            if (handle == IntPtr.Zero) { return; }
            int value = (dark ?? IsDark) ? 1 : 0;
            // 20 is the documented attribute; 19 is the pre-20H1 spelling. Trying both
            // costs nothing and covers every build that supports it at all.
            _ = DwmSetWindowAttribute(handle, 20, ref value, sizeof(int));
            _ = DwmSetWindowAttribute(handle, 19, ref value, sizeof(int));
        }
        catch (Exception)
        {
        }
    }

    private static bool SystemPrefersDark()
    {
        try
        {
            object? value = Microsoft.Win32.Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme",
                1);
            return value is int light && light == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static Color Rgb(double r, double g, double b) => Color.FromRgb(
        (byte)Math.Round(Math.Clamp(r, 0, 1) * 255),
        (byte)Math.Round(Math.Clamp(g, 0, 1) * 255),
        (byte)Math.Round(Math.Clamp(b, 0, 1) * 255));

    private static Color Mix(Color a, Color b, double amount) => Color.FromRgb(
        (byte)Math.Round(a.R + (b.R - a.R) * amount),
        (byte)Math.Round(a.G + (b.G - a.G) * amount),
        (byte)Math.Round(a.B + (b.B - a.B) * amount));

    private static double Luminance(Color color) =>
        (0.2126 * color.R + 0.7152 * color.G + 0.0722 * color.B) / 255.0;

    [DllImport("dwmapi.dll", PreserveSig = true)]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
}
