using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using ImageHub.Models;
using ImageHub.Services;
using ImageHub.Support;
using ImageHub.ViewModels;

namespace ImageHub.Views;

/// <summary>
/// The main window: menu bar, navigation pane, content, status bar.
///
/// Laid out the way a Windows desktop tool is: the menu bar carries every command
/// with its accelerator spelled out, the navigation pane on the left mirrors what the
/// macOS app puts in its sidebar, and the status bar carries the two things that are
/// true all the time — whether ImageHub has the administrator rights a build needs,
/// and what a running build is doing.
/// </summary>
public sealed class MainWindow : ThemedWindow
{
    private readonly AppState _state = AppState.Shared;
    private readonly ContentControl _host = new();
    private readonly ListBox _navigation = new();
    private readonly StackPanel _bannerHost = new();
    private readonly TextBlock _statusText = new();
    private readonly TextBlock _buildText = new();
    private readonly ProgressBar _buildProgress = new();
    private readonly Dictionary<Section, UIElement> _views = new();
    private readonly DispatcherTimer _bannerTimer = new() { Interval = TimeSpan.FromSeconds(7) };
    private readonly DispatcherTimer _statusTimer = new() { Interval = TimeSpan.FromSeconds(1) };

    private readonly (Section Section, string Label)[] _sections =
    {
        (Section.Dashboard, "Overview"),
        (Section.Templates, "Templates"),
        (Section.Images, "Windows Images"),
        (Section.Drives, "USB Drives"),
        (Section.Builds, "Build History"),
    };

    private bool _navigating;

    public MainWindow()
    {
        Title = "ImageHub";
        Width = Math.Max(1100, Settings.Current.WindowWidth);
        Height = Math.Max(720, Settings.Current.WindowHeight);
        MinWidth = 1040;
        MinHeight = 680;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        if (Settings.Current.WindowMaximized) { WindowState = WindowState.Maximized; }

        Content = BuildLayout();
        RegisterShortcuts();

        Notifier.BannerRaised += OnBanner;
        _bannerTimer.Tick += (_, _) => { _bannerTimer.Stop(); _bannerHost.Children.Clear(); };
        _statusTimer.Tick += (_, _) => UpdateStatus();
        _statusTimer.Start();

        _state.Updates.UpdateOffered += (_, offer) => OfferUpdate(offer.Version, offer.Url);
        _state.PropertyChanged += (_, _) => UpdateStatus();
        _state.HistoryChanged += (_, _) => { UpdateBadges(); UpdateStatus(); };
        _state.DrivesChanged += (_, _) => UpdateBadges();
        _state.Templates.Changed += (_, _) => UpdateBadges();
        _state.Library.Changed += (_, _) => UpdateBadges();
        _state.SectionChanged += (_, section) => ShowSection(section);

        SourceInitialized += OnSourceInitialized;
        Loaded += OnLoaded;
        Closing += OnClosing;
        Closed += (_, _) => Notifier.BannerRaised -= OnBanner;

        ShowSection(Section.Dashboard);
        UpdateBadges();
        UpdateStatus();
    }

    // MARK: - Layout

    private UIElement BuildLayout()
    {
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var menuBar = new Border { Padding = new Thickness(6, 3, 6, 3), Child = BuildMenu() };
        menuBar.Themed(Border.BackgroundProperty, "BarBg");
        Grid.SetRow(menuBar, 0);
        grid.Children.Add(menuBar);

        _bannerHost.Margin = new Thickness(16, 10, 16, 0);
        Grid.SetRow(_bannerHost, 1);
        grid.Children.Add(_bannerHost);

        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(228) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        UIElement pane = BuildNavigation();
        Grid.SetColumn(pane, 0);
        body.Children.Add(pane);

        var line = new Border { Width = 1 };
        line.Themed(Border.BackgroundProperty, "DividerBrush");
        Grid.SetColumn(line, 1);
        body.Children.Add(line);

        _host.Themed(ContentControl.BackgroundProperty, "ContentBg");
        Grid.SetColumn(_host, 2);
        body.Children.Add(_host);

        Grid.SetRow(body, 2);
        grid.Children.Add(body);

        UIElement status = BuildStatusBar();
        Grid.SetRow(status, 3);
        grid.Children.Add(status);

        return grid;
    }

    private Menu BuildMenu()
    {
        var menu = new Menu();

        // File
        var file = new MenuItem { Header = "_File" };
        file.Items.Add(Item("_New Template", "Ctrl+N", NewTemplate));
        file.Items.Add(Item("_Build USB Drive…", "Ctrl+B", () => StartBuild(_state.SelectedTemplate)));
        file.Items.Add(new Separator());
        file.Items.Add(Item("_Import Template…", null, ImportTemplate));
        file.Items.Add(Item("_Export Template…", null, ExportSelectedTemplate));
        file.Items.Add(new Separator());
        file.Items.Add(Item("E_xit", "Alt+F4", Close));
        menu.Items.Add(file);

        // Edit
        var edit = new MenuItem { Header = "_Edit" };
        edit.Items.Add(Item("_Duplicate Template", "Ctrl+D", DuplicateSelectedTemplate));
        edit.Items.Add(Item("De_lete Template…", "Del", DeleteSelectedTemplate));
        edit.Items.Add(new Separator());
        edit.Items.Add(Item("Copy _Answer File", null, CopyAnswerFile));
        menu.Items.Add(edit);

        // View
        var view = new MenuItem { Header = "_View" };
        for (int i = 0; i < _sections.Length; i++)
        {
            Section section = _sections[i].Section;
            view.Items.Add(Item(_sections[i].Label, $"Ctrl+{i + 1}", () => _state.CurrentSection = section));
        }
        view.Items.Add(new Separator());
        view.Items.Add(Item("_Refresh Drives", "F5", () => _ = _state.RefreshDrivesAsync()));
        view.Items.Add(new Separator());

        var appearance = new MenuItem { Header = "_Appearance" };
        foreach (AppearanceMode mode in new[] { AppearanceMode.System, AppearanceMode.Light, AppearanceMode.Dark })
        {
            AppearanceMode captured = mode;
            var option = new MenuItem
            {
                Header = mode switch
                {
                    AppearanceMode.Light => "_Light",
                    AppearanceMode.Dark => "_Dark",
                    _ => "Use _system setting",
                },
                IsCheckable = true,
                IsChecked = Settings.Current.Appearance == mode,
            };
            option.Click += (_, _) =>
            {
                Settings.Current.Appearance = captured;
                Settings.Current.Save();
                ThemeManager.Apply();
                RebuildViews();
                foreach (object child in appearance.Items)
                {
                    if (child is MenuItem item) { item.IsChecked = ReferenceEquals(item, option); }
                }
            };
            appearance.Items.Add(option);
        }
        view.Items.Add(appearance);

        var accent = new MenuItem { Header = "Accent _Colour" };
        foreach (AccentTheme theme in ThemeManager.Themes)
        {
            AccentTheme captured = theme;
            var option = new MenuItem
            {
                Header = theme.Name,
                IsCheckable = true,
                IsChecked = Settings.Current.ThemeId == theme.Id,
            };
            option.Click += (_, _) =>
            {
                Settings.Current.ThemeId = captured.Id;
                Settings.Current.Save();
                ThemeManager.Apply();
                RebuildViews();
                foreach (object child in accent.Items)
                {
                    if (child is MenuItem item) { item.IsChecked = ReferenceEquals(item, option); }
                }
            };
            accent.Items.Add(option);
        }
        view.Items.Add(accent);
        menu.Items.Add(view);

        // Tools
        var tools = new MenuItem { Header = "_Tools" };
        tools.Items.Add(Item("_Options…", "Ctrl+,", ShowOptions));
        tools.Items.Add(new Separator());
        tools.Items.Add(Item("Open _Templates Folder", null, () => AppPaths.Reveal(AppPaths.Templates)));
        tools.Items.Add(Item("Open _Image Library", null, () => AppPaths.Reveal(AppPaths.Images)));
        tools.Items.Add(Item("Open _Logs Folder", null, () => AppPaths.Reveal(AppPaths.Logs)));
        if (!Elevation.IsElevated)
        {
            tools.Items.Add(new Separator());
            tools.Items.Add(Item("_Restart as Administrator", null, RestartElevated));
        }
        menu.Items.Add(tools);

        // Help
        var help = new MenuItem { Header = "_Help" };
        // F1 is the documentation, as it is in every other Windows application. There
        // is no compiled help file to ship, so it opens the documentation where it is
        // actually maintained.
        help.Items.Add(Item("ImageHub _Help", "F1", OpenDocumentation));
        help.Items.Add(new Separator());
        help.Items.Add(Item("ImageHub on _GitHub", null,
            () => AppPaths.OpenUrl($"https://github.com/{UpdateChecker.Repo}")));
        help.Items.Add(Item("_Release Notes", null, () => AppPaths.OpenUrl(UpdateChecker.ReleasesPage)));
        help.Items.Add(new Separator());
        help.Items.Add(Item("_Check for Updates…", null,
            () => _ = _state.Updates.CheckAsync(userInitiated: true)));
        help.Items.Add(new Separator());
        help.Items.Add(Item("_About ImageHub", null, () => new AboutDialog(this).ShowDialog()));
        menu.Items.Add(help);

        return menu;
    }

    private static void OpenDocumentation() =>
        AppPaths.OpenUrl($"https://github.com/{UpdateChecker.Repo}#readme");

    private static MenuItem Item(string header, string? gesture, Action action)
    {
        var item = new MenuItem { Header = header };
        if (gesture is not null) { item.InputGestureText = gesture; }
        item.Click += (_, _) => action();
        return item;
    }

    private UIElement BuildNavigation()
    {
        var panel = new Grid();
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.Themed(Grid.BackgroundProperty, "SidebarBg");

        // Header: the app mark and what it does, the same two lines as the Mac sidebar.
        var mark = new System.Windows.Shapes.Path
        {
            Data = Glyphs.Drive,
            Stretch = System.Windows.Media.Stretch.Uniform,
            Width = 24,
            Height = 24,
            StrokeThickness = 1.5,
        };
        mark.Themed(System.Windows.Shapes.Path.StrokeProperty, "AccentBrush");

        StackPanel header = Ui.Row(10, mark, Ui.Column(1,
            new TextBlock { Text = "ImageHub", FontWeight = FontWeights.SemiBold, FontSize = 15 },
            Ui.Hint("Windows deployment media")));
        header.Margin = new Thickness(16, 15, 12, 12);
        Grid.SetRow(header, 0);
        panel.Children.Add(header);

        foreach ((Section section, string label) in _sections)
        {
            var item = new ListBoxItem { Tag = section, Content = NavigationContent(label, null) };
            _navigation.Items.Add(item);
        }
        _navigation.SelectedIndex = 0;
        _navigation.Margin = new Thickness(6, 0, 6, 0);
        _navigation.SelectionChanged += (_, _) =>
        {
            if (_navigating) { return; }
            if (_navigation.SelectedItem is ListBoxItem { Tag: Section section })
            {
                _state.CurrentSection = section;
            }
        };
        Grid.SetRow(_navigation, 1);
        panel.Children.Add(_navigation);

        Button build = Ui.Button("Build USB Drive", () => StartBuild(_state.SelectedTemplate),
            "AccentButton");
        build.Margin = new Thickness(12, 10, 12, 14);
        build.MinHeight = 36;
        build.HorizontalAlignment = HorizontalAlignment.Stretch;
        Grid.SetRow(build, 2);
        panel.Children.Add(build);

        return panel;
    }

    private static UIElement NavigationContent(string label, string? badge)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var text = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(text, 0);
        grid.Children.Add(text);

        var count = new TextBlock
        {
            Text = badge ?? string.Empty,
            FontSize = 11.5,
            VerticalAlignment = VerticalAlignment.Center,
        };
        count.Themed(TextBlock.ForegroundProperty, "TextTertiary");
        Grid.SetColumn(count, 1);
        grid.Children.Add(count);
        return grid;
    }

    private UIElement BuildStatusBar()
    {
        var bar = new Border
        {
            Padding = new Thickness(14, 6, 12, 7),
            BorderThickness = new Thickness(0, 1, 0, 0),
        };
        bar.Themed(Border.BackgroundProperty, "BarBg");
        bar.Themed(Border.BorderBrushProperty, "DividerBrush");

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        _statusText.FontSize = 12;
        _statusText.VerticalAlignment = VerticalAlignment.Center;
        _statusText.Themed(TextBlock.ForegroundProperty, "TextSecondary");
        StackPanel left = Ui.Row(8, _statusText);
        if (!Elevation.IsElevated)
        {
            Button elevate = Ui.Button("Restart as Administrator", RestartElevated, "LinkButton");
            elevate.FontSize = 12;
            left.Children.Add(elevate);
        }
        Grid.SetColumn(left, 0);
        grid.Children.Add(left);

        _buildText.FontSize = 12;
        _buildText.VerticalAlignment = VerticalAlignment.Center;
        _buildText.TextTrimming = TextTrimming.CharacterEllipsis;
        _buildText.Themed(TextBlock.ForegroundProperty, "TextSecondary");
        _buildProgress.Width = 120;
        _buildProgress.Visibility = Visibility.Collapsed;
        StackPanel middle = Ui.Row(10, _buildText, _buildProgress);
        middle.HorizontalAlignment = HorizontalAlignment.Right;
        middle.Margin = new Thickness(16, 0, 16, 0);
        Grid.SetColumn(middle, 1);
        grid.Children.Add(middle);

        var version = new TextBlock
        {
            Text = "ImageHub " + AppVersion.Current,
            FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center,
        };
        version.Themed(TextBlock.ForegroundProperty, "TextTertiary");
        Grid.SetColumn(version, 2);
        grid.Children.Add(version);

        bar.Child = grid;
        return bar;
    }

    private void RegisterShortcuts()
    {
        void Bind(Key key, ModifierKeys modifiers, Action action) =>
            InputBindings.Add(new KeyBinding(new RelayCommand(action), key, modifiers));

        Bind(Key.N, ModifierKeys.Control, NewTemplate);
        Bind(Key.B, ModifierKeys.Control, () => StartBuild(_state.SelectedTemplate));
        Bind(Key.D, ModifierKeys.Control, DuplicateSelectedTemplate);
        Bind(Key.OemComma, ModifierKeys.Control, ShowOptions);
        Bind(Key.F5, ModifierKeys.None, () => _ = _state.RefreshDrivesAsync());
        Bind(Key.F1, ModifierKeys.None, OpenDocumentation);
        for (int i = 0; i < _sections.Length; i++)
        {
            Section section = _sections[i].Section;
            Key key = Key.D1 + i;
            Bind(key, ModifierKeys.Control, () => _state.CurrentSection = section);
        }
    }

    // MARK: - Lifecycle

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        // Rather than polling for drives every few seconds — which on Windows means
        // spawning PowerShell every few seconds — listen for the message Windows already
        // sends when something is plugged in or removed.
        var source = (HwndSource?)PresentationSource.FromVisual(this);
        source?.AddHook(WindowProcedure);
    }

    private const int WmDeviceChange = 0x0219;
    private const int DbtDevNodesChanged = 0x0007;

    private IntPtr WindowProcedure(IntPtr hwnd, int message, IntPtr wparam, IntPtr lparam, ref bool handled)
    {
        if (message == WmDeviceChange && wparam.ToInt64() == DbtDevNodesChanged)
        {
            _state.DevicesChanged();
        }
        return IntPtr.Zero;
    }

    private void OnLoaded(object? sender, RoutedEventArgs e)
    {
        _ = _state.RefreshDrivesAsync();
        _state.Updates.CheckOnLaunchIfEnabled();

        foreach (string warning in _state.Templates.LoadWarnings)
        {
            Notifier.Banner("Couldn't read a template", warning, BannerKind.Warning);
        }
    }

    private void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        // A half-written USB stick is worse than no USB stick, so quitting mid-build asks
        // first — the same question the macOS app asks.
        if (_state.IsBuilding)
        {
            MessageBoxResult answer = MessageBox.Show(
                this,
                "Quitting now leaves the USB drive unbootable. You can cancel the build first, "
                + "or quit anyway and run it again later.\n\nQuit anyway?",
                "A drive is still being written",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);
            if (answer != MessageBoxResult.Yes)
            {
                e.Cancel = true;
                return;
            }
            _state.ActiveJob?.Cancel();
        }

        Settings.Current.WindowMaximized = WindowState == WindowState.Maximized;
        if (WindowState == WindowState.Normal)
        {
            Settings.Current.WindowWidth = ActualWidth;
            Settings.Current.WindowHeight = ActualHeight;
        }
        Settings.Current.Save();
        _statusTimer.Stop();
    }

    // MARK: - Sections

    private void ShowSection(Section section)
    {
        if (!_views.TryGetValue(section, out UIElement? view))
        {
            view = section switch
            {
                Section.Templates => new TemplatesView(this),
                Section.Images => new ImagesView(this),
                Section.Drives => new DrivesView(this),
                Section.Builds => new BuildHistoryView(this),
                _ => new DashboardView(this),
            };
            _views[section] = view;
        }
        _host.Content = view;
        if (view is IRefreshable refreshable) { refreshable.Refresh(); }

        _navigating = true;
        foreach (object candidate in _navigation.Items)
        {
            if (candidate is ListBoxItem { Tag: Section tag } item && tag == section)
            {
                _navigation.SelectedItem = item;
                break;
            }
        }
        _navigating = false;
    }

    /// <summary>Throws the cached views away, so a theme change is picked up everywhere.</summary>
    private void RebuildViews()
    {
        _views.Clear();
        ShowSection(_state.CurrentSection);
    }

    private void UpdateBadges()
    {
        foreach (object candidate in _navigation.Items)
        {
            if (candidate is not ListBoxItem { Tag: Section section } item) { continue; }
            int count = section switch
            {
                Section.Templates => _state.Templates.Templates.Count,
                Section.Images => _state.Library.Images.Count,
                Section.Drives => _state.Drives.Count,
                Section.Builds => _state.History.Count,
                _ => 0,
            };
            string label = _sections.First(entry => entry.Section == section).Label;
            item.Content = NavigationContent(label, count > 0 ? count.ToString() : null);
        }
        if (_host.Content is IRefreshable refreshable) { refreshable.Refresh(); }
    }

    private void UpdateStatus()
    {
        _statusText.Text = Elevation.IsElevated
            ? "Running as administrator"
            : "Not running as administrator — a build needs it";

        BuildJob? job = _state.ActiveJob ?? _state.History.FirstOrDefault();
        if (job is null)
        {
            _buildText.Text = string.Empty;
            _buildProgress.Visibility = Visibility.Collapsed;
            return;
        }
        if (job.IsRunning)
        {
            _buildText.Text = $"{job.TemplateName}: {job.Detail}";
            _buildProgress.Value = job.OverallProgress;
            _buildProgress.Visibility = Visibility.Visible;
        }
        else
        {
            _buildText.Text = job.CurrentPhase switch
            {
                BuildJob.Phase.Succeeded => $"{job.TemplateName} → {job.DriveName}: ready",
                BuildJob.Phase.Failed => $"{job.TemplateName}: build failed",
                BuildJob.Phase.Cancelled => $"{job.TemplateName}: cancelled",
                _ => string.Empty,
            };
            _buildProgress.Visibility = Visibility.Collapsed;
        }
    }

    // MARK: - Banners

    private void OnBanner(object? sender, BannerMessage message)
    {
        _bannerHost.Children.Clear();
        Border banner = Ui.Banner(message.Kind, message.Title, message.Detail);
        banner.Margin = new Thickness(0);

        Button dismiss = Ui.IconButton(Glyphs.Cross, () =>
        {
            _bannerTimer.Stop();
            _bannerHost.Children.Clear();
        }, "Dismiss");

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(banner, 0);
        grid.Children.Add(banner);
        dismiss.VerticalAlignment = VerticalAlignment.Top;
        dismiss.Margin = new Thickness(6, 4, 0, 0);
        Grid.SetColumn(dismiss, 1);
        grid.Children.Add(dismiss);

        _bannerHost.Children.Add(grid);
        _bannerTimer.Stop();
        // Errors stay until dismissed; everything else is a passing confirmation.
        if (message.Kind != BannerKind.Error) { _bannerTimer.Start(); }
    }

    // MARK: - Commands

    private void NewTemplate()
    {
        DeploymentTemplate template = _state.Templates.NewTemplate();
        _state.Select(template);
    }

    public void StartBuild(DeploymentTemplate? template)
    {
        if (_state.IsBuilding)
        {
            Notifier.Banner("A build is already running",
                "Wait for it to finish, or cancel it first.", BannerKind.Info);
            _state.CurrentSection = Section.Builds;
            return;
        }
        if (_state.Templates.Templates.Count == 0)
        {
            Notifier.Banner("No templates yet", "Create one first.", BannerKind.Info);
            _state.CurrentSection = Section.Templates;
            return;
        }
        var dialog = new BuildDialog(this, template ?? _state.SelectedTemplate);
        dialog.ShowDialog();
        UpdateBadges();
        UpdateStatus();
    }

    private void ImportTemplate()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = "Import Template",
            Filter = "ImageHub template (*.json)|*.json|All files (*.*)|*.*",
        };
        if (dialog.ShowDialog(this) != true) { return; }
        try
        {
            DeploymentTemplate template = _state.Templates.Import(dialog.FileName);
            _state.Select(template);
            Notifier.Banner("Template imported", template.Name);
        }
        catch (Exception error)
        {
            Notifier.Banner("Couldn't import that file", error.Message, BannerKind.Error);
        }
    }

    private void ExportSelectedTemplate()
    {
        DeploymentTemplate? template = _state.SelectedTemplate;
        if (template is null)
        {
            Notifier.Banner("Nothing selected", "Pick a template first.", BannerKind.Info);
            return;
        }
        string name = template.Name.Replace('/', '-').Replace('\\', '-').Trim();
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = "Export Template",
            FileName = (name.Length == 0 ? "Template" : name) + ".json",
            Filter = "ImageHub template (*.json)|*.json",
        };
        if (dialog.ShowDialog(this) != true) { return; }
        try
        {
            _state.Templates.Export(template, dialog.FileName);
            Notifier.Banner("Template exported", System.IO.Path.GetFileName(dialog.FileName));
        }
        catch (Exception error)
        {
            Notifier.Banner("Export failed", error.Message, BannerKind.Error);
        }
    }

    private void DuplicateSelectedTemplate()
    {
        DeploymentTemplate? template = _state.SelectedTemplate;
        if (template is null) { return; }
        DeploymentTemplate copy = _state.Templates.Duplicate(template);
        _state.Select(copy);
    }

    private void DeleteSelectedTemplate()
    {
        DeploymentTemplate? template = _state.SelectedTemplate;
        if (template is null) { return; }
        MessageBoxResult answer = MessageBox.Show(
            this,
            $"Delete “{template.Name}”?\n\nIts stored passwords are removed too. This can't be undone.",
            "Delete template",
            MessageBoxButton.OKCancel,
            MessageBoxImage.Warning,
            MessageBoxResult.Cancel);
        if (answer != MessageBoxResult.OK) { return; }
        _state.Templates.Delete(template);
        _state.SelectedTemplateId = _state.Templates.Templates.FirstOrDefault()?.Id;
        RebuildViews();
    }

    private void CopyAnswerFile()
    {
        DeploymentTemplate? template = _state.SelectedTemplate;
        if (template is null)
        {
            Notifier.Banner("Nothing selected", "Pick a template first.", BannerKind.Info);
            return;
        }
        try
        {
            // Empty secrets: the preview never shows a password.
            Clipboard.SetText(new AnswerFileBuilder(template).Build());
            Notifier.Banner("Copied autounattend.xml", "Passwords are not included.");
        }
        catch (Exception error)
        {
            Notifier.Banner("Couldn't copy", error.Message, BannerKind.Error);
        }
    }

    private void ShowOptions()
    {
        new OptionsDialog(this).ShowDialog();
        ThemeManager.Apply();
        RebuildViews();
    }

    private void RestartElevated()
    {
        if (_state.IsBuilding)
        {
            Notifier.Banner("A build is running",
                "Let it finish before restarting ImageHub.", BannerKind.Warning);
            return;
        }
        if (Elevation.RelaunchElevated())
        {
            Application.Current.Shutdown();
        }
    }

    private void OfferUpdate(string version, string url)
    {
        var dialog = new UpdateDialog(this, version, url);
        dialog.ShowDialog();
    }
}

/// <summary>
/// A view that can be asked to re-read the model. The window calls this when the
/// stores change, so a view does not have to subscribe to everything itself.
/// </summary>
public interface IRefreshable
{
    void Refresh();
}
