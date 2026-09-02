using System;
using System.Text;
using System.Windows;
using System.Windows.Threading;
using ImageHub.Services;
using ImageHub.Support;
using ImageHub.Views;

namespace ImageHub;

/// <summary>
/// The entry point, written by hand rather than generated from App.xaml.
///
/// The command-line modes have to run before WPF is initialised at all. They are how
/// CI checks the generated answer file and payload — and compares them against the
/// macOS app's — so they must work on a machine with no interactive desktop, and must
/// not depend on an Application ever being constructed.
/// </summary>
public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        int? exitCode = CommandLineTools.Run(args);
        if (exitCode is int code) { return code; }

        var app = new App();
        app.InitializeComponent();
        return app.Run();
    }
}

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // A blind crash in a tool that erases disks is unacceptable; say what happened
        // and let the operator decide whether to carry on.
        DispatcherUnhandledException += OnUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception failure) { WriteCrashLog(failure); }
        };

        // A previous version left behind by the in-place updater; the process that was
        // using it has certainly exited by now.
        SelfUpdater.CleanUpAfterUpdate();

        Notifier.Attach(Dispatcher);
        ThemeManager.Apply();

        OfferToInstall();

        // Fully qualified: inside App, the simple name MainWindow binds to
        // Application.MainWindow, the property this assigns to just below.
        var window = new ImageHub.Views.MainWindow();
        MainWindow = window;
        window.Show();
    }

    /// <summary>
    /// On a launch from a download folder, asks whether to install first.
    ///
    /// Two traps live here, both from this running before any other window exists.
    ///
    /// ShutdownMode is OnMainWindowClose, and WPF makes the first window it constructs
    /// the MainWindow — so the offer dialog becomes the main window, and closing it
    /// would end the process before the real window ever appeared. OnExplicitShutdown
    /// for the duration, restored afterwards. (The same fact also made the dialog
    /// resolve itself as its own owner; ThemedWindow.ConfigureAsDialog guards that.)
    ///
    /// And nothing in here may stop the app from starting. Installing is a convenience;
    /// the app is perfectly usable from wherever it is, so a failure is logged, noted,
    /// and stepped over rather than raised. Not doing this cost a release: an exception
    /// building the dialog put a crash box in front of the app on every single launch.
    /// </summary>
    private void OfferToInstall()
    {
        try
        {
            RunInstallOffer();
        }
        catch (Exception error)
        {
            WriteCrashLog(error);
            // Deterministic failures would otherwise repeat at every launch. The offer
            // stays available under Tools, so nothing is permanently lost.
            Settings.Current.InstallPromptAnswered = true;
            Settings.Current.Save();
            Notifier.Banner(
                "Couldn't offer to install ImageHub",
                "ImageHub is running from where you downloaded it, which works fine. "
                + "Tools → Install ImageHub on This PC… tries again.",
                BannerKind.Warning);
        }
    }

    private void RunInstallOffer()
    {
        if (!Installer.ShouldOffer()) { return; }

        ShutdownMode previous = ShutdownMode;
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        try
        {
            var offer = new ImageHub.Views.InstallDialog(null);
            offer.ShowDialog();

            if (offer.InstalledExePath is not string installed) { return; }

            if (Installer.Relaunch(installed))
            {
                // The installed copy is starting; this one has nothing left to do.
                Shutdown(0);
                return;
            }

            // Installed, but starting the new copy failed. Carrying on here is correct —
            // the app works from where it is — but say so, because the Start Menu entry
            // now points somewhere this session is not running from.
            Notifier.Banner(
                "Installed, but couldn't start the installed copy",
                "This window is still running from the file you downloaded. The Start Menu "
                + "entry points at " + Installer.InstalledExePath + ".",
                BannerKind.Warning);
        }
        finally
        {
            ShutdownMode = previous;
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Notifier.Dispose();
        Settings.Current.Save();
        base.OnExit(e);
    }

    private void OnUnhandledException(object? sender, DispatcherUnhandledExceptionEventArgs e)
    {
        WriteCrashLog(e.Exception);

        string message = "ImageHub hit an unexpected problem:\n\n"
            + Trim(e.Exception.Message)
            + "\n\nDetails were written to:\n" + CrashLogPath()
            + "\n\nCarry on anyway? (Anything mid-build should be re-run from scratch.)";

        // No owner before the window exists, and MessageBox rejects a null one.
        MessageBoxResult answer = MainWindow is null
            ? MessageBox.Show(message, "ImageHub", MessageBoxButton.YesNo,
                MessageBoxImage.Error, MessageBoxResult.Yes)
            : MessageBox.Show(MainWindow, message, "ImageHub", MessageBoxButton.YesNo,
                MessageBoxImage.Error, MessageBoxResult.Yes);

        if (answer == MessageBoxResult.Yes)
        {
            e.Handled = true;
            return;
        }
        Shutdown(1);
    }

    private static string Trim(string message) =>
        message.Length > 400 ? message.Substring(0, 400) + "…" : message;

    private static string CrashLogPath() =>
        System.IO.Path.Combine(AppPaths.Logs, "imagehub-errors.log");

    private static void WriteCrashLog(Exception error)
    {
        try
        {
            var text = new StringBuilder();
            text.Append("=== ").Append(DateTime.Now.ToString("u")).Append(" ImageHub ")
                .Append(AppVersion.Current).Append(" ===\r\n");
            text.Append(error).Append("\r\n\r\n");
            System.IO.File.AppendAllText(CrashLogPath(), text.ToString());
        }
        catch (Exception)
        {
            // Nothing useful left to do if even the log cannot be written.
        }
    }
}
