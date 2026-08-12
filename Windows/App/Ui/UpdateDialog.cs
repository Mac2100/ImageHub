using System;
using System.Windows;
using System.Windows.Controls;
using ImageHub.Services;
using ImageHub.Support;

namespace ImageHub.Views;

/// <summary>
/// Offers an update, then shows it installing.
///
/// The download is the long part, so it gets a real progress bar — the macOS app
/// learnt that the hard way, where "Check for Updates…" from the menu with no window
/// open looked like nothing had happened for the length of a multi-megabyte download.
/// </summary>
public sealed class UpdateDialog : ThemedWindow
{
    private readonly SelfUpdater _updater = SelfUpdater.Shared;
    private readonly string _version;
    private readonly string _url;
    private readonly TextBlock _headline = new();
    private readonly TextBlock _detail = new();
    private readonly ProgressBar _progress = Ui.Progress();
    private readonly ContentControl _actions = new();

    public UpdateDialog(Window owner, string version, string url)
    {
        _version = version;
        _url = url;

        Title = "ImageHub update";
        ConfigureAsDialog(owner, 470, 300);
        ResizeMode = ResizeMode.NoResize;

        _headline.FontSize = 16;
        _headline.FontWeight = FontWeights.SemiBold;
        _headline.TextAlignment = TextAlignment.Center;
        _headline.TextWrapping = TextWrapping.Wrap;

        _detail.TextAlignment = TextAlignment.Center;
        _detail.TextWrapping = TextWrapping.Wrap;
        _detail.Themed(TextBlock.ForegroundProperty, "TextSecondary");
        _detail.MaxWidth = 380;

        _progress.Visibility = Visibility.Collapsed;
        _progress.Width = 340;

        var mark = new System.Windows.Shapes.Path
        {
            Data = Glyphs.Drive,
            Stretch = System.Windows.Media.Stretch.Uniform,
            Width = 40,
            Height = 40,
            StrokeThickness = 1.2,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        mark.Themed(System.Windows.Shapes.Path.StrokeProperty, "AccentBrush");

        StackPanel column = Ui.Column(12, mark, _headline, _detail, _progress, _actions);
        column.VerticalAlignment = VerticalAlignment.Center;
        column.HorizontalAlignment = HorizontalAlignment.Center;
        column.Margin = new Thickness(24);
        Content = column;

        _updater.PropertyChanged += OnUpdaterChanged;
        _updater.ReadyToRelaunch += OnReadyToRelaunch;
        Closed += (_, _) =>
        {
            _updater.PropertyChanged -= OnUpdaterChanged;
            _updater.ReadyToRelaunch -= OnReadyToRelaunch;
        };

        Render();
    }

    private void OnUpdaterChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e) =>
        Dispatcher.BeginInvoke(new Action(Render));

    private void OnReadyToRelaunch(object? sender, EventArgs e) =>
        Dispatcher.BeginInvoke(new Action(() => Application.Current.Shutdown()));

    private void Render()
    {
        switch (_updater.Stage)
        {
            case SelfUpdater.Phase.Downloading:
                _headline.Text = $"Downloading ImageHub {_version}";
                _detail.Text = _updater.DownloadProgress > 0
                    ? $"{(int)(_updater.DownloadProgress * 100)}% complete"
                    : "Starting the download…";
                _progress.Visibility = Visibility.Visible;
                _progress.Value = _updater.DownloadProgress;
                _actions.Content = null;
                break;

            case SelfUpdater.Phase.Installing:
                _headline.Text = "Installing…";
                _detail.Text = "Replacing ImageHub.exe in place.";
                _progress.Visibility = Visibility.Visible;
                _progress.Value = 1;
                _actions.Content = null;
                break;

            case SelfUpdater.Phase.Relaunching:
                _headline.Text = "Restarting…";
                _detail.Text = "ImageHub will reopen in a moment.";
                _progress.Visibility = Visibility.Visible;
                _progress.Value = 1;
                _actions.Content = null;
                break;

            case SelfUpdater.Phase.Failed:
                _headline.Text = "Update failed";
                _detail.Text = _updater.FailureMessage;
                _progress.Visibility = Visibility.Collapsed;
                _actions.Content = Ui.Row(8,
                    Ui.Button("Open Releases", () => AppPaths.OpenUrl(UpdateChecker.ReleasesPage)),
                    Ui.Button("Close", Close, "AccentButton"));
                break;

            default:
                _headline.Text = $"ImageHub {_version} is available";
                _detail.Text = $"You're running {AppVersion.Current}. Installing downloads the "
                    + "update, replaces ImageHub.exe in place, and restarts it.";
                _progress.Visibility = Visibility.Collapsed;
                _actions.Content = Ui.Row(8,
                    Ui.Button("Release Notes", () => AppPaths.OpenUrl(UpdateChecker.ReleasesPage)),
                    Ui.Button("Later", Close),
                    Ui.Button("Install & Restart", () => _ = _updater.InstallAsync(_url), "AccentButton")
                        .Also(button => button.IsDefault = true));
                break;
        }
    }
}
