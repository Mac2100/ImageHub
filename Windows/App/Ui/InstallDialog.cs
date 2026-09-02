using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using ImageHub.Services;
using ImageHub.Support;

namespace ImageHub.Views;

/// <summary>
/// Offers to move a freshly downloaded copy into a permanent home.
///
/// Shown before the main window on a launch from Downloads, the desktop or a temp
/// folder. Declining is a first-class answer, not a nag to be repeated: it is
/// remembered, and the offer moves to Tools → Install ImageHub on This PC.
/// </summary>
public sealed class InstallDialog : ThemedWindow
{
    private readonly TextBlock _status = Ui.Caption(string.Empty);
    private readonly Button _install;
    private readonly Button _portable;

    /// <summary>Where to relaunch from, once installed. Null if the app should carry on here.</summary>
    public string? InstalledExePath { get; private set; }

    public InstallDialog(Window? owner)
    {
        Title = "Install ImageHub";
        ConfigureAsDialog(owner, 560, 430);
        ResizeMode = ResizeMode.NoResize;

        _install = Ui.Button("Install", () => _ = InstallAsync(), "AccentButton");
        _install.IsDefault = true;
        _install.MinWidth = 120;

        _portable = Ui.Button("Just run it", DeclineAndClose, "SubtleButton");
        _portable.IsCancel = true;
        _portable.MinWidth = 120;

        var mark = new System.Windows.Shapes.Path
        {
            Data = Glyphs.Drive,
            Stretch = System.Windows.Media.Stretch.Uniform,
            Width = 44,
            Height = 44,
            StrokeThickness = 1.1,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        mark.Themed(System.Windows.Shapes.Path.StrokeProperty, "AccentBrush");

        _status.Visibility = Visibility.Collapsed;

        StackPanel buttons = Ui.Row(10, _install, _portable);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;

        StackPanel column = Ui.Column(14,
            mark,
            Ui.Heading("Install ImageHub on this PC?"),
            Ui.Text("ImageHub is a single file with nothing to install, so it is running from "
                + "the folder you downloaded it to. Installing gives it a permanent home and a "
                + "Start Menu entry."),
            Ui.Inset(Ui.Column(7,
                Detail("Move to", CompactPath(Installer.InstallDirectory)),
                Detail("Start Menu", "an ImageHub shortcut"),
                Detail("Uninstall", "listed in Programs and Features")), 12),
            Ui.Hint("No administrator rights needed — this installs for your account only. "
                + "Your templates and settings stay where they are either way."),
            _status,
            buttons);
        column.Margin = new Thickness(26, 22, 26, 22);

        Content = column;
    }

    private static UIElement Detail(string label, string value)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(96) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        TextBlock name = Ui.Caption(label);
        Grid.SetColumn(name, 0);
        grid.Children.Add(name);

        TextBlock detail = Ui.Text(value);
        detail.TextWrapping = TextWrapping.Wrap;
        Grid.SetColumn(detail, 1);
        grid.Children.Add(detail);

        return grid;
    }

    /// <summary>%LOCALAPPDATA% rather than the expanded path: shorter, and recognisable.</summary>
    private static string CompactPath(string path)
    {
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return local.Length > 0 && path.StartsWith(local, StringComparison.OrdinalIgnoreCase)
            ? "%LOCALAPPDATA%" + path.Substring(local.Length)
            : path;
    }

    private async Task InstallAsync()
    {
        _install.IsEnabled = false;
        _portable.IsEnabled = false;
        _status.Visibility = Visibility.Visible;
        _status.Text = "Installing…";

        try
        {
            Installer.InstallOutcome outcome = await Installer.InstallAsync();

            // Said here rather than as a banner afterwards: the app is about to relaunch
            // from the installed copy, and a banner raised in this process would go with
            // it. This is the last moment the message can be seen.
            if (outcome.Warning is string warning)
            {
                MessageBox.Show(this, warning, "Install ImageHub",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }

            // Close() rather than DialogResult: the caller reads InstalledExePath, and
            // assigning DialogResult throws if this window was ever shown non-modally.
            // OnClosed records that the offer was answered.
            InstalledExePath = outcome.ExePath;
            Close();
        }
        catch (Exception error)
        {
            // A failed install must not block the app: it is perfectly usable from
            // where it is, which is the state it was already in.
            _status.Visibility = Visibility.Collapsed;
            _install.IsEnabled = true;
            _portable.IsEnabled = true;

            MessageBox.Show(
                this,
                "ImageHub couldn't install itself:\n\n" + error.Message
                + "\n\nYou can carry on using it from "
                + (Path.GetDirectoryName(Installer.CurrentExePath) ?? "this folder")
                + ", or move the .exe there yourself.",
                "Install ImageHub",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
    }

    private void DeclineAndClose() => Close();

    /// <summary>
    /// However this was dismissed — the button, Esc, or the title bar's X — the offer
    /// has been made and is not made again. It stays available under Tools, so nothing
    /// is lost by not asking, whereas asking on every launch would be a nag.
    /// </summary>
    protected override void OnClosed(EventArgs e)
    {
        if (!Settings.Current.InstallPromptAnswered)
        {
            Settings.Current.InstallPromptAnswered = true;
            Settings.Current.Save();
        }
        base.OnClosed(e);
    }
}
