using System;
using System.Text;
using System.Windows;
using System.Windows.Threading;
using ImageHub.Services;
using ImageHub.Support;
using ImageHub.Views;

namespace ImageHub;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        // The command-line modes must run before any window exists: they are how CI
        // checks the generated answer file and payload, and they have to be able to
        // print and exit on a machine with no display session.
        int? exitCode = CommandLineTools.Run(e.Args);
        if (exitCode is int code)
        {
            Environment.Exit(code);
            return;
        }

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

        // Fully qualified: inside App, the simple name MainWindow binds to
        // Application.MainWindow, the property this assigns to just below.
        var window = new ImageHub.Views.MainWindow();
        MainWindow = window;
        window.Show();
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
