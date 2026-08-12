using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using ImageHub.Models;
using ImageHub.Services;
using ImageHub.Support;
using ImageHub.ViewModels;

namespace ImageHub.Views;

/// <summary>
/// Options.
///
/// A category list on the left and a page on the right, which is how Windows has laid
/// out application options since long before Settings looked like this — and which
/// keeps the same six groupings the macOS app puts in its Settings tabs.
/// </summary>
public sealed class OptionsDialog : ThemedWindow
{
    private readonly AppState _state = AppState.Shared;
    private readonly ListBox _categories = new();
    private readonly ContentControl _page = new();
    private readonly List<(string Name, Func<UIElement> Build)> _pages;

    public OptionsDialog(Window owner)
    {
        Title = "ImageHub Options";
        ConfigureAsDialog(owner, 760, 620);

        _pages = new List<(string, Func<UIElement>)>
        {
            ("Appearance", AppearancePage),
            ("General", GeneralPage),
            ("Passwords", PasswordsPage),
            ("Notifications", NotificationsPage),
            ("Updates", UpdatesPage),
            ("Advanced", AdvancedPage),
        };

        foreach ((string name, Func<UIElement> _) in _pages)
        {
            _categories.Items.Add(new ListBoxItem { Content = name });
        }
        _categories.SelectedIndex = 0;
        _categories.Margin = new Thickness(6, 8, 6, 8);
        _categories.SelectionChanged += (_, e) =>
        {
            if (!ReferenceEquals(e.OriginalSource, _categories)) { return; }
            ShowPage(_categories.SelectedIndex);
        };

        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(186) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var pane = new Border { Child = _categories };
        pane.Themed(Border.BackgroundProperty, "SidebarBg");
        Grid.SetColumn(pane, 0);
        body.Children.Add(pane);

        var line = new Border { Width = 1 };
        line.Themed(Border.BackgroundProperty, "DividerBrush");
        Grid.SetColumn(line, 1);
        body.Children.Add(line);

        Grid.SetColumn(_page, 2);
        body.Children.Add(_page);

        var footer = new Border
        {
            Padding = new Thickness(14, 11, 14, 12),
            BorderThickness = new Thickness(0, 1, 0, 0),
            Child = Ui.Button("Close", Close, "AccentButton")
                .Also(button =>
                {
                    button.HorizontalAlignment = HorizontalAlignment.Right;
                    button.IsDefault = true;
                }),
        };
        footer.Themed(Border.BackgroundProperty, "BarBg");
        footer.Themed(Border.BorderBrushProperty, "DividerBrush");

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(body, 0);
        grid.Children.Add(body);
        Grid.SetRow(footer, 1);
        grid.Children.Add(footer);

        Content = grid;
        ShowPage(0);
    }

    private void ShowPage(int index)
    {
        if (index < 0 || index >= _pages.Count) { return; }
        _page.Content = Ui.Scroll(_pages[index].Build(), 18);
    }

    private static void Save() => Settings.Current.Save();

    // MARK: - Appearance

    private UIElement AppearancePage()
    {
        var panel = new StackPanel();

        panel.Children.Add(Ui.Group("Appearance",
            Ui.Setting("Light or dark", Ui.Combo(
                    new[] { AppearanceMode.System, AppearanceMode.Light, AppearanceMode.Dark },
                    mode => mode switch
                    {
                        AppearanceMode.Light => "Light",
                        AppearanceMode.Dark => "Dark",
                        _ => "Use system setting",
                    },
                    () => Settings.Current.Appearance,
                    mode =>
                    {
                        Settings.Current.Appearance = mode;
                        Save();
                        ThemeManager.Apply();
                    }, 220),
                "System follows Windows' own app theme, which is what most Windows apps do.")));

        var swatches = new WrapPanel();
        foreach (AccentTheme theme in ThemeManager.Themes)
        {
            AccentTheme captured = theme;
            bool selected = Settings.Current.ThemeId == theme.Id;

            var dot = new System.Windows.Shapes.Ellipse
            {
                Width = 34,
                Height = 34,
                Fill = theme.Gradient,
                HorizontalAlignment = HorizontalAlignment.Center,
            };
            var tile = new Border
            {
                Child = Ui.Column(7, dot, Ui.Caption(theme.Name)
                    .Also(text => text.TextAlignment = TextAlignment.Center)),
                Padding = new Thickness(12, 11, 12, 10),
                Margin = new Thickness(0, 0, 8, 8),
                CornerRadius = new CornerRadius(8),
                Cursor = System.Windows.Input.Cursors.Hand,
                BorderThickness = new Thickness(selected ? 1.6 : 1),
                Background = selected ? Ui.Tint("AccentBrush", 0.10) : Ui.Brush("SubtleBg"),
                BorderBrush = selected ? Ui.Brush("AccentBrush") : Ui.Brush("DividerBrush"),
                Width = 96,
            };
            tile.MouseLeftButtonUp += (_, _) =>
            {
                Settings.Current.ThemeId = captured.Id;
                Save();
                ThemeManager.Apply();
                ShowPage(0);
            };
            swatches.Children.Add(tile);
        }
        panel.Children.Add(Ui.Wide("Accent colour", swatches,
            "Used for the selected tab, the primary button, and the progress bar."));

        return panel;
    }

    // MARK: - General

    private UIElement GeneralPage()
    {
        var panel = new StackPanel();

        var labelPreview = Ui.Caption(string.Empty);
        void UpdatePreview()
        {
            string cleaned = DiskService.SanitizeFat32Label(Settings.Current.DefaultVolumeLabel);
            labelPreview.Text = $"Saved as “{cleaned}” ({cleaned.Length}/11). FAT32 labels are at most "
                + "11 characters, upper case, letters and digits only.";
        }
        UpdatePreview();

        panel.Children.Add(Ui.Group("Media",
            Ui.Setting("USB volume label", Ui.Field(
                () => Settings.Current.DefaultVolumeLabel,
                value =>
                {
                    Settings.Current.DefaultVolumeLabel = value;
                    UpdatePreview();
                    Save();
                }, "IMAGEHUB", 180)),
            Ui.Wide(null, labelPreview),
            Ui.Setting("Eject the drive when a build finishes", Ui.Switch(
                () => Settings.Current.EjectAfterBuild,
                on => { Settings.Current.EjectAfterBuild = on; Save(); }))));

        panel.Children.Add(Ui.Group("Downloads",
            Ui.Setting("Default image language", Ui.Combo(
                WindowsLocales.All.Select(entry => entry.Locale), WindowsLocales.Label,
                () => Settings.Current.DefaultLanguage,
                value => { Settings.Current.DefaultLanguage = value; Save(); }, 260))));

        panel.Children.Add(Ui.Group("In-app",
            Ui.Setting("Show notification banners", Ui.Switch(
                    () => Settings.Current.ShowBanners,
                    on => { Settings.Current.ShowBanners = on; Save(); }),
                "The strip at the top of the window that confirms what just happened. Errors are "
                + "always shown.")));

        panel.Children.Add(Ui.Group("Storage",
            Ui.Setting("Templates", Ui.Button("Open Folder",
                () => AppPaths.Reveal(AppPaths.Templates))),
            Ui.Setting("Image library", Ui.Button("Open Folder",
                () => AppPaths.Reveal(AppPaths.Images))),
            Ui.Setting("Images on disk",
                Ui.Caption(Formatting.ByteSize(_state.Library.TotalBytesOnDisk)))));

        return panel;
    }

    // MARK: - Passwords

    private UIElement PasswordsPage()
    {
        var panel = new StackPanel();
        var help = Ui.Caption(SecretStore.Help(SecretStore.Backend));

        panel.Children.Add(Ui.Group("Template passwords",
            Ui.Setting("Store passwords in", Ui.Combo(
                new[] { SecretBackend.Dpapi, SecretBackend.CredentialManager },
                backend => SecretStore.Label(backend),
                () => SecretStore.Backend,
                backend =>
                {
                    // Setting this moves every stored secret across.
                    SecretStore.Backend = backend;
                    help.Text = SecretStore.Help(backend);
                    Notifier.Banner("Passwords moved to " + SecretStore.Label(backend).ToLowerInvariant());
                }, 300)),
            Ui.Wide(null, help),
            Ui.Wide(null, Ui.Caption(
                "Either way these end up in clear text on a drive you build — Windows Setup reads "
                + "them that way — so treat a finished USB stick as a credential."))));

        panel.Children.Add(Ui.Banner(BannerKind.Info, "What is kept",
            "The IT admin password, the end-user password, domain join credentials, a specific "
            + "product key, and the Wi-Fi passphrase. Nothing else, and never inside a template "
            + "file — which is what makes a template safe to export and commit."));

        return panel;
    }

    // MARK: - Notifications

    private UIElement NotificationsPage()
    {
        var rows = new List<UIElement?>();
        foreach (NotificationEvent which in Labels.All<NotificationEvent>())
        {
            NotificationEvent captured = which;
            rows.Add(Ui.Setting(Notifier.Label(captured), Ui.Switch(
                () => Notifier.IsEnabled(captured),
                on =>
                {
                    switch (captured)
                    {
                        case NotificationEvent.BuildFinished:
                            Settings.Current.NotifyBuildFinished = on;
                            break;
                        case NotificationEvent.BuildFailed:
                            Settings.Current.NotifyBuildFailed = on;
                            break;
                        case NotificationEvent.DownloadFinished:
                            Settings.Current.NotifyDownloadFinished = on;
                            break;
                        case NotificationEvent.UpdateAvailable:
                            Settings.Current.NotifyUpdateAvailable = on;
                            break;
                    }
                    Save();
                })));
        }

        var panel = new StackPanel();
        panel.Children.Add(Ui.Group("System notifications", rows.ToArray()));
        panel.Children.Add(Ui.Wide(null, Ui.Caption(
            "Delivered through the notification area, which Windows 10 and 11 show as a toast. "
            + "Builds take a while, so this is how you find out one finished without watching it.")));
        return panel;
    }

    // MARK: - Updates

    private UIElement UpdatesPage()
    {
        var panel = new StackPanel();
        UpdateChecker updates = _state.Updates;

        var status = Ui.Caption(string.Empty);
        void UpdateStatus()
        {
            status.Text = updates.Status switch
            {
                UpdateChecker.State.Checking => "Checking…",
                UpdateChecker.State.UpToDate => $"ImageHub {AppVersion.Current} is the latest version.",
                UpdateChecker.State.NoReleasesVisible =>
                    "No releases visible — a private repository can't be checked anonymously.",
                UpdateChecker.State.UpdateAvailable =>
                    $"Version {updates.AvailableVersion} is available.",
                UpdateChecker.State.Failed => updates.FailureMessage,
                _ => updates.LastChecked is null
                    ? "Not checked yet."
                    : "Last checked " + Formatting.Clock(updates.LastChecked.Value) + ".",
            };
        }
        UpdateStatus();
        updates.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(new Action(UpdateStatus));

        panel.Children.Add(Ui.Group("Updates",
            Ui.Setting("Current version", Ui.Caption(AppVersion.Current)),
            Ui.Setting("Check for updates at launch", Ui.Switch(
                () => Settings.Current.AutoCheckUpdates,
                on => { Settings.Current.AutoCheckUpdates = on; Save(); })),
            Ui.Setting("Check now", Ui.Button("Check Now",
                () => _ = updates.CheckAsync(userInitiated: true))),
            Ui.Wide(null, status)));

        panel.Children.Add(Ui.Wide(null, Ui.Column(7,
            Ui.Caption(
                "Both ImageHub apps check the same GitHub release and each downloads the build for "
                + "the system it is running on — a .dmg on macOS, this .exe on Windows. Installing "
                + "replaces ImageHub.exe in place and restarts it."),
            Ui.Button("View releases on GitHub",
                () => AppPaths.OpenUrl(UpdateChecker.ReleasesPage), "LinkButton"))));

        return panel;
    }

    // MARK: - Advanced

    private UIElement AdvancedPage()
    {
        var panel = new StackPanel();

        panel.Children.Add(Ui.Group("Provisioning scripts",
            Ui.Setting("Source", Ui.Caption(PayloadSource.Describe())),
            Ui.PathRow("Override folder",
                () => Settings.Current.PayloadSourcePath,
                path => { Settings.Current.PayloadSourcePath = path; Save(); },
                "Use the copy inside ImageHub.exe",
                folder: true,
                help: "Point this at a checkout's Shared\\payload folder to test changes to "
                    + "Provision.ps1 without rebuilding ImageHub.",
                changed: () => ShowPage(5))));

        var files = new StackPanel();
        foreach (string name in PayloadSource.Names())
        {
            files.Children.Add(Ui.Mono(name));
        }
        if (files.Children.Count > 0)
        {
            panel.Children.Add(Ui.Wide("Shipped with this build", files,
                "Written onto every drive, byte for byte, exactly as the macOS app writes them."));
        }

        panel.Children.Add(Ui.Group("Diagnostics",
            Ui.Setting("Settings and templates", Ui.Button("Open Folder",
                () => AppPaths.Reveal(AppPaths.Roaming))),
            Ui.Setting("Logs, cache and images", Ui.Button("Open Folder",
                () => AppPaths.Reveal(AppPaths.Local))),
            Ui.Setting("Administrator rights",
                Elevation.IsElevated
                    ? (UIElement)Ui.Caption("Running elevated")
                    : Ui.ShieldButton("Restart as Administrator", () =>
                    {
                        if (Elevation.RelaunchElevated()) { Application.Current.Shutdown(); }
                    }),
                Elevation.IsElevated ? null : Elevation.Explanation)));

        panel.Children.Add(Ui.Group("Splitting oversized images",
            Ui.Wide(null, Ui.Caption(
                "Nothing to configure. Every current Windows 11 ISO has an install.wim larger than "
                + "4 GB, which FAT32 cannot hold, so it is split into install.swm parts — and on "
                + "Windows that is DISM's job, which ships with the OS. The macOS app carries a copy "
                + $"of wimlib for the same step. Parts are {WimSplitter.SplitPartSizeMb} MB either "
                + "way, so both produce the same media."))));

        return panel;
    }
}
