using System;
using System.Windows.Threading;
using ImageHub.Support;

namespace ImageHub.Services;

public enum BannerKind
{
    Info,
    Success,
    Warning,
    Error,
}

public sealed class BannerMessage
{
    public string Title { get; init; } = string.Empty;

    public string Detail { get; init; } = string.Empty;

    public BannerKind Kind { get; init; }
}

/// <summary>Events a system notification can be asked for, each with its own setting.</summary>
public enum NotificationEvent
{
    BuildFinished,
    BuildFailed,
    DownloadFinished,
    UpdateAvailable,
}

/// <summary>
/// Telling the operator something happened, by two routes.
///
/// * An in-app banner, which is Windows' InfoBar rather than the macOS app's corner
///   toast: it appears at the top of the content area, says one thing, and goes
///   away. This is for outcomes of something the operator just did.
/// * A notification-area balloon, which Windows 10 and 11 surface as a real toast.
///   This is for things that finish while they are somewhere else — and a build
///   takes tens of minutes, so "the drive is ready" is the notification that
///   actually matters.
///
/// The balloon needs a notification-area icon to come from, so one is added just
/// long enough to deliver it and then removed. A tool that is not running in the
/// background has no business leaving an icon in the tray.
/// </summary>
public static class Notifier
{
    private static Dispatcher? _dispatcher;
    private static System.Windows.Forms.NotifyIcon? _trayIcon;
    private static DispatcherTimer? _hideTimer;

    /// <summary>Called once from App.OnStartup, so background threads can marshal here.</summary>
    public static void Attach(Dispatcher dispatcher) => _dispatcher = dispatcher;

    public static event EventHandler<BannerMessage>? BannerRaised;

    /// <summary>
    /// Shows an in-app banner. Safe from any thread, and a no-op before the window
    /// exists or when banners are switched off, so callers never have to check.
    /// </summary>
    public static void Banner(string title, string detail = "", BannerKind kind = BannerKind.Success)
    {
        if (!Settings.Current.ShowBanners && kind != BannerKind.Error) { return; }
        var message = new BannerMessage { Title = title, Detail = detail, Kind = kind };
        Post(() => BannerRaised?.Invoke(null, message));
    }

    public static bool IsEnabled(NotificationEvent which) => which switch
    {
        NotificationEvent.BuildFinished => Settings.Current.NotifyBuildFinished,
        NotificationEvent.BuildFailed => Settings.Current.NotifyBuildFailed,
        NotificationEvent.DownloadFinished => Settings.Current.NotifyDownloadFinished,
        NotificationEvent.UpdateAvailable => Settings.Current.NotifyUpdateAvailable,
        _ => false,
    };

    public static string Label(NotificationEvent which) => which switch
    {
        NotificationEvent.BuildFinished => "A drive finishes building",
        NotificationEvent.BuildFailed => "A build fails",
        NotificationEvent.DownloadFinished => "An image finishes downloading",
        NotificationEvent.UpdateAvailable => "An ImageHub update is available",
        _ => which.ToString(),
    };

    public static void Post(NotificationEvent which, string title, string body)
    {
        if (!IsEnabled(which)) { return; }
        Post(() => ShowBalloon(title, body, which == NotificationEvent.BuildFailed));
    }

    // MARK: - Convenience

    public static void BuildFinished(string template, string drive, bool success)
    {
        Post(
            success ? NotificationEvent.BuildFinished : NotificationEvent.BuildFailed,
            success ? "USB drive ready" : "Build failed",
            success
                ? $"{template} was written to {drive}."
                : $"{template} → {drive} didn't complete. Check the build log.");
    }

    public static void DownloadFinished(string name) =>
        Post(NotificationEvent.DownloadFinished, "Image downloaded", $"{name} is in your image library.");

    public static void UpdateAvailable(string version) =>
        Post(NotificationEvent.UpdateAvailable, $"ImageHub {version} is available",
            "Install it from Help → Check for Updates.");

    // MARK: - Plumbing

    private static void Post(Action action)
    {
        Dispatcher? dispatcher = _dispatcher;
        if (dispatcher is null) { return; }
        if (dispatcher.CheckAccess()) { action(); }
        else { dispatcher.BeginInvoke(action); }
    }

    private static void ShowBalloon(string title, string body, bool isError)
    {
        try
        {
            _trayIcon ??= new System.Windows.Forms.NotifyIcon
            {
                Icon = LoadIcon(),
                Text = "ImageHub",
            };
            _trayIcon.BalloonTipTitle = title;
            _trayIcon.BalloonTipText = body;
            _trayIcon.BalloonTipIcon = isError
                ? System.Windows.Forms.ToolTipIcon.Warning
                : System.Windows.Forms.ToolTipIcon.Info;
            _trayIcon.Visible = true;
            _trayIcon.ShowBalloonTip(10000);

            // Take the icon away once the balloon has had its time. ImageHub is not a
            // background agent, so a permanent tray icon would be a lie.
            _hideTimer ??= new DispatcherTimer { Interval = TimeSpan.FromSeconds(20) };
            _hideTimer.Stop();
            _hideTimer.Tick -= OnHideTick;
            _hideTimer.Tick += OnHideTick;
            _hideTimer.Start();
        }
        catch (Exception)
        {
            // A notification is never worth failing a build over.
        }
    }

    private static void OnHideTick(object? sender, EventArgs e)
    {
        _hideTimer?.Stop();
        if (_trayIcon is not null) { _trayIcon.Visible = false; }
    }

    private static System.Drawing.Icon LoadIcon()
    {
        try
        {
            string exe = AppPaths.Executable;
            if (exe.Length > 0)
            {
                System.Drawing.Icon? extracted = System.Drawing.Icon.ExtractAssociatedIcon(exe);
                if (extracted is not null) { return extracted; }
            }
        }
        catch (Exception)
        {
        }
        return System.Drawing.SystemIcons.Application;
    }

    /// <summary>Called on shutdown so the icon never outlives the process.</summary>
    public static void Dispose()
    {
        try
        {
            _hideTimer?.Stop();
            if (_trayIcon is not null)
            {
                _trayIcon.Visible = false;
                _trayIcon.Dispose();
                _trayIcon = null;
            }
        }
        catch (Exception)
        {
        }
    }
}
