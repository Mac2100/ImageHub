using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using ImageHub.Models;
using ImageHub.Services;
using ImageHub.Support;
using ImageHub.ViewModels;

namespace ImageHub.Views;

/// <summary>
/// The template editor: eight tabs over one template, saved as you go.
///
/// The tabs are the macOS app's, in the same order and with the same contents, because
/// they follow the shape of the thing being described rather than the platform. What is
/// Windows here is the presentation — each setting is its own card with the control on
/// the right, the way Settings does it — and the fact that every control is wired to a
/// property in code, so a rename cannot silently disconnect one.
/// </summary>
public sealed class TemplateEditorView : UserControl
{
    private readonly MainWindow _window;
    private readonly AppState _state = AppState.Shared;
    private readonly DeploymentTemplate _template;
    private readonly Action _listChanged;
    private readonly List<Action> _sync = new();

    // Rows for apps, scripts and registry values are rebuilt whenever one is added or
    // removed, so their refresh callbacks live in their own bags and are cleared with
    // them. Without that, _sync would grow a stale closure per rebuild for the life of
    // the editor.
    private readonly List<Action> _appSync = new();
    private readonly List<Action> _scriptSync = new();
    private readonly List<Action> _registrySync = new();
    private readonly DispatcherTimer _saveTimer = new() { Interval = TimeSpan.FromMilliseconds(600) };
    private readonly TextBlock _savedLabel = new();
    private readonly Button _buildButton;
    private readonly TabControl _tabs = new();
    private readonly Border _issueChip;
    private readonly StackPanel _reviewBody = new();
    private readonly StackPanel _appList = new();
    private readonly StackPanel _scriptList = new();
    private readonly StackPanel _registryList = new();
    private readonly StackPanel _bloatwareList = new();
    private readonly HashSet<Guid> _expandedApps = new();
    private DateTime? _lastSaved;

    public TemplateEditorView(MainWindow window, DeploymentTemplate template, Action listChanged)
    {
        _window = window;
        _template = template;
        _listChanged = listChanged;

        _buildButton = Ui.Button("Build USB…", () => _window.StartBuild(_template), "AccentButton");
        _issueChip = Ui.Chip("0 to fix", "WarningBrush", Glyphs.Warning);
        _issueChip.Cursor = System.Windows.Input.Cursors.Hand;
        _issueChip.MouseLeftButtonUp += (_, _) => SelectTab("Review");

        _saveTimer.Tick += (_, _) =>
        {
            _saveTimer.Stop();
            Persist();
        };

        BuildTabs();

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        UIElement header = Header();
        Grid.SetRow(header, 0);
        grid.Children.Add(header);
        Grid.SetRow(_tabs, 1);
        grid.Children.Add(_tabs);
        Content = grid;

        Sync();
        Unloaded += (_, _) =>
        {
            _saveTimer.Stop();
            Persist();
        };
    }

    // MARK: - Change tracking

    private void Changed()
    {
        _saveTimer.Stop();
        _saveTimer.Start();
        Sync();
    }

    private void Sync()
    {
        foreach (Action action in _sync) { action(); }
        foreach (Action action in _appSync) { action(); }
        foreach (Action action in _scriptSync) { action(); }
        foreach (Action action in _registrySync) { action(); }

        int problems = _template.Issues.Count;
        _issueChip.Visibility = problems == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (problems > 0 && _issueChip.Child is StackPanel row
            && row.Children.Count > 1 && row.Children[1] is TextBlock text)
        {
            text.Text = $"{problems} to fix";
        }
        _buildButton.IsEnabled = _template.IsBuildable && !_state.IsBuilding;
        _buildButton.ToolTip = _template.IsBuildable
            ? "Write this template to a USB drive"
            : string.Join("\n", _template.ValidationErrors);
        _savedLabel.Text = _lastSaved is null
            ? "Saved automatically"
            : "Saved " + Formatting.Clock(_lastSaved.Value);
    }

    private void Persist()
    {
        if (_state.Templates.Save(_template))
        {
            _lastSaved = DateTime.Now;
            _savedLabel.Text = "Saved " + Formatting.Clock(_lastSaved.Value);
            _listChanged();
        }
    }

    /// <summary>Registers a control's refresh callback, so a change elsewhere reaches it.</summary>
    private T Track<T>(T element) where T : FrameworkElement
    {
        _sync.Add(() => Ui.Refresh(element));
        return element;
    }

    /// <summary>Like <see cref="Track{T}"/>, but into a bag that gets cleared on rebuild.</summary>
    private static T TrackIn<T>(List<Action> bag, T element) where T : FrameworkElement
    {
        bag.Add(() => Ui.Refresh(element));
        return element;
    }

    /// <summary>Shows or hides a row depending on another setting.</summary>
    private T When<T>(T element, Func<bool> visible) where T : FrameworkElement
    {
        _sync.Add(() => element.Visibility = visible() ? Visibility.Visible : Visibility.Collapsed);
        return element;
    }

    private void SelectTab(string header)
    {
        foreach (object candidate in _tabs.Items)
        {
            if (candidate is TabItem item && (string)item.Header == header)
            {
                _tabs.SelectedItem = item;
                return;
            }
        }
    }

    // MARK: - Header

    private UIElement Header()
    {
        var iconButton = new Button { Width = 38, Height = 38, Padding = new Thickness(0) };
        iconButton.Styled("SubtleButton");
        void RefreshIcon() =>
            iconButton.Content = Ui.Icon(Glyphs.ForTemplateSymbol(_template.Symbol), 22, "AccentBrush",
                thickness: 1.4);
        RefreshIcon();
        iconButton.ToolTip = "Change icon";

        var iconMenu = new ContextMenu();
        foreach ((string symbol, string label) in Glyphs.TemplateSymbols)
        {
            string captured = symbol;
            var option = new MenuItem { Header = label };
            option.Click += (_, _) =>
            {
                _template.Symbol = captured;
                RefreshIcon();
                Changed();
            };
            iconMenu.Items.Add(option);
        }
        iconButton.Click += (_, _) =>
        {
            iconMenu.PlacementTarget = iconButton;
            iconMenu.IsOpen = true;
        };

        var name = new TextBox
        {
            Text = _template.Name,
            FontSize = 18,
            FontWeight = FontWeights.SemiBold,
            BorderThickness = new Thickness(0),
            Background = System.Windows.Media.Brushes.Transparent,
            Padding = new Thickness(2, 0, 2, 0),
        };
        name.TextChanged += (_, _) =>
        {
            _template.Name = name.Text;
            Changed();
        };

        var summary = new TextBox
        {
            Text = _template.Summary,
            FontSize = 12.5,
            BorderThickness = new Thickness(0),
            Background = System.Windows.Media.Brushes.Transparent,
            Padding = new Thickness(2, 0, 2, 0),
            MinHeight = 0,
        };
        summary.Themed(Control.ForegroundProperty, "TextSecondary");
        summary.TextChanged += (_, _) =>
        {
            _template.Summary = summary.Text;
            Changed();
        };

        _savedLabel.FontSize = 11.5;
        _savedLabel.HorizontalAlignment = HorizontalAlignment.Right;
        _savedLabel.Themed(TextBlock.ForegroundProperty, "TextTertiary");

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        iconButton.VerticalAlignment = VerticalAlignment.Center;
        iconButton.Margin = new Thickness(0, 0, 10, 0);
        Grid.SetColumn(iconButton, 0);
        grid.Children.Add(iconButton);

        StackPanel text = Ui.Column(1, name, summary);
        text.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        _issueChip.Margin = new Thickness(10, 0, 10, 0);
        Grid.SetColumn(_issueChip, 2);
        grid.Children.Add(_issueChip);

        StackPanel right = Ui.Column(3, _buildButton, _savedLabel);
        right.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(right, 3);
        grid.Children.Add(right);

        var band = new Border
        {
            Child = grid,
            Padding = new Thickness(18, 13, 18, 12),
            BorderThickness = new Thickness(0, 0, 0, 1),
        };
        band.Themed(Border.BackgroundProperty, "BarBg");
        band.Themed(Border.BorderBrushProperty, "DividerBrush");
        return band;
    }

    // MARK: - Tabs

    private void BuildTabs()
    {
        Add("Windows", WindowsTab());
        Add("Disk", DiskTab());
        Add("Accounts", AccountsTab());
        Add("Apps", AppsTab());
        Add("Configuration", ConfigurationTab());
        Add("First Boot", FirstBootTab());
        Add("Scripts", ScriptsTab());
        Add("Review", _reviewBody);

        _tabs.SelectionChanged += (_, e) =>
        {
            if (!ReferenceEquals(e.OriginalSource, _tabs)) { return; }
            if (_tabs.SelectedItem is TabItem item && (string)item.Header == "Review")
            {
                RefreshReview();
            }
        };
    }

    private void Add(string header, UIElement content)
    {
        _tabs.Items.Add(new TabItem { Header = header, Content = Ui.Scroll(content, 18) });
    }

    // MARK: - Windows

    private UIElement WindowsTab()
    {
        var panel = new StackPanel();

        panel.Children.Add(Ui.Group("Product",
            Ui.Setting("Release", Track(Ui.Combo(
                Labels.All<WindowsRelease>(), r => Labels.Of(r),
                () => _template.Windows.Release,
                v => { _template.Windows.Release = v; Changed(); }, 200))),
            Ui.Setting("Edition", Track(Ui.Combo(
                Labels.All<WindowsEdition>(), e => Labels.Of(e),
                () => _template.Windows.Edition,
                v => { _template.Windows.Edition = v; Changed(); }, 240)),
                "Setup matches the edition by its image name inside install.wim. If your captured "
                + "image uses custom names, set an explicit index below."),
            Ui.Setting("Architecture", Track(Ui.Combo(
                new[] { "x64", "arm64" },
                a => a == "x64" ? "x64 (Intel/AMD)" : "ARM64",
                () => _template.Windows.Architecture,
                v => { _template.Windows.Architecture = v; Changed(); }, 200)))));

        var imageSummary = new TextBlock
        {
            TextAlignment = TextAlignment.Right,
            MaxWidth = 320,
            TextWrapping = TextWrapping.Wrap,
        };
        imageSummary.Themed(TextBlock.ForegroundProperty, "TextSecondary");
        _sync.Add(() => imageSummary.Text = ImageSummary());

        Border pin = Ui.Setting("Always build from one specific image",
            Track(Ui.Switch(
                () => _template.Windows.PinsLibraryImage,
                on =>
                {
                    _template.Windows.LibraryImageId = on
                        ? _state.Library.Images.FirstOrDefault(image => image.FileExists)?.Id
                        : null;
                    Changed();
                })),
            "Every build of this template then uses that exact ISO, so the result is repeatable "
            + "byte for byte.");

        List<WindowsImage> images = _state.Library.Images.ToList();
        Border pinned = When(Ui.Setting("Image", Track(Ui.Combo(
                images, image => image.DisplayName,
                () => images.FirstOrDefault(image => image.Id == _template.Windows.LibraryImageId)
                    ?? images.FirstOrDefault()!,
                v => { if (v is not null) { _template.Windows.LibraryImageId = v.Id; Changed(); } },
                300))),
            () => _template.Windows.PinsLibraryImage && images.Count > 0);

        Border captured = Ui.PathRow("Install a captured image",
            () => _template.Windows.CustomWimPath,
            path => _template.Windows.CustomWimPath = path,
            "Use the one in the ISO",
            "Windows image (*.wim)|*.wim|All files (*.*)|*.*",
            help: "The true golden-image route. Setup and the boot files still come from the ISO; "
                + "only the installed OS comes from your image. Sysprep the reference machine with "
                + "/generalize /oobe before capturing.",
            changed: Changed);
        _sync.Add(() => Ui.Refresh(captured));

        Border index = When(Ui.Setting("Image index",
                Ui.Field(
                    () => _template.Windows.ImageIndex?.ToString() ?? string.Empty,
                    text =>
                    {
                        _template.Windows.ImageIndex =
                            int.TryParse(text.Trim(), out int value) ? value : null;
                        Changed();
                    },
                    "Auto", 90),
                "Only needed if your image uses custom edition names."),
            () => _template.Windows.UsesCapturedImage);

        var advanced = new Expander
        {
            Header = "Advanced",
            Content = Ui.Column(0, pin, pinned, captured, index),
            Margin = new Thickness(0, 0, 0, 6),
        };

        panel.Children.Add(Ui.Group("Image",
            Ui.Setting("Windows image", imageSummary),
            advanced));

        var genericKey = new TextBlock { FontSize = 12.5 };
        genericKey.SetResourceReference(Control.FontFamilyProperty, "MonoFont");
        genericKey.Themed(TextBlock.ForegroundProperty, "TextSecondary");
        _sync.Add(() => genericKey.Text = WindowsEditions.GenericKey(
            _template.Windows.Edition, _template.Windows.Release) ?? string.Empty);

        var keyDetail = Ui.Caption(string.Empty);
        _sync.Add(() => keyDetail.Text = Labels.Detail(_template.Windows.ProductKeyMode));

        panel.Children.Add(Ui.Group("Licensing",
            Ui.Setting("Product key", Track(Ui.Combo(
                Labels.All<ProductKeyMode>(), m => Labels.Of(m),
                () => _template.Windows.ProductKeyMode,
                v => { _template.Windows.ProductKeyMode = v; Changed(); }, 250))),
            When(Ui.Setting("Key", genericKey),
                () => _template.Windows.ProductKeyMode == ProductKeyMode.Generic),
            When(Ui.SecretRow("Product key", _template.Id, SecretSlot.ProductKey,
                    "Written into autounattend.xml at build time.", Changed),
                () => _template.Windows.ProductKeyMode == ProductKeyMode.Custom),
            Ui.Wide(null, keyDetail),
            Ui.Setting("Accept the Windows licence terms automatically",
                Track(Ui.Switch(() => _template.Windows.AcceptEula,
                    on => { _template.Windows.AcceptEula = on; Changed(); })))));

        var activationDetail = Ui.Caption(string.Empty);
        _sync.Add(() => activationDetail.Text = Labels.Detail(_template.Windows.Activation.Mode));

        panel.Children.Add(Ui.Group("Activation",
            Ui.Setting("Activate Windows", Track(Ui.Combo(
                Labels.All<ActivationMode>(), m => Labels.Of(m),
                () => _template.Windows.Activation.Mode,
                v => { _template.Windows.Activation.Mode = v; Changed(); }, 220))),
            When(Ui.Setting("KMS host", Ui.Field(
                    () => _template.Windows.Activation.KmsHost,
                    v => { _template.Windows.Activation.KmsHost = v; Changed(); },
                    "kms.example.com:1688", 240)),
                () => _template.Windows.Activation.Mode == ActivationMode.Kms),
            Ui.Wide(null, activationDetail)));

        panel.Children.Add(Ui.Group("Language & input",
            Ui.Setting("Display language", Track(Ui.Combo(
                WindowsLocales.All.Select(entry => entry.Locale), WindowsLocales.Label,
                () => _template.System.Locale,
                v =>
                {
                    _template.System.Locale = v;
                    _template.System.InputLocale = WindowsLocales.Input(v);
                    _template.Windows.Language = v;
                    Changed();
                }, 260))),
            Ui.Setting("Keyboard layout", Track(Ui.Field(
                () => _template.System.InputLocale,
                v => { _template.System.InputLocale = v; Changed(); },
                "0409:00000409", 170)))));

        return panel;
    }

    private string ImageSummary()
    {
        var parts = new List<string>();
        WindowsImage? pinned = _state.Library.Image(_template.Windows.LibraryImageId);
        if (pinned is not null) { parts.Add(pinned.DisplayName); }
        else if (_template.Windows.PinsLibraryImage)
        {
            parts.Add("A pinned image that is no longer in the library");
        }
        else { parts.Add("Chosen when you build"); }

        if (_template.Windows.UsesCapturedImage)
        {
            parts.Add("installing " + Path.GetFileName(_template.Windows.CustomWimPath));
        }
        return string.Join(", ", parts);
    }

    // MARK: - Disk

    private UIElement DiskTab()
    {
        var panel = new StackPanel();

        panel.Children.Add(Ui.Group("Wipe",
            Ui.Setting("Wipe the target disk during Setup",
                Track(Ui.Switch(() => _template.Disk.WipeTargetDisk,
                    on => { _template.Disk.WipeTargetDisk = on; Changed(); })),
                "This is what makes reimaging a used machine a single unattended step: Setup "
                + "destroys the existing partition table before installing. Turn it off to install "
                + "alongside what's already there — Setup will then ask where to install.")));

        Border style = Ui.Setting("Partition style", Track(Ui.Combo(
            Labels.All<PartitionStyle>(), s => Labels.Of(s),
            () => _template.Disk.PartitionStyle,
            v => { _template.Disk.PartitionStyle = v; Changed(); }, 220)));

        Border number = Ui.Setting("Target disk number",
            Track(Ui.NumberField(() => _template.Disk.DiskNumber,
                v => { _template.Disk.DiskNumber = v; Changed(); }, 0, 15)),
            "Disk 0 is the machine's primary drive on almost every laptop and desktop. Change it "
            + "only if the target has a layout you know differs.");

        Border efi = When(Ui.Setting("EFI system partition (MB)",
                Track(Ui.NumberField(() => _template.Disk.EfiSizeMb,
                    v => { _template.Disk.EfiSizeMb = v; Changed(); }, 100, 1024))),
            () => _template.Disk.PartitionStyle == PartitionStyle.Gpt);

        Border msr = When(Ui.Setting("Microsoft reserved (MB)",
                Track(Ui.NumberField(() => _template.Disk.MsrSizeMb,
                    v => { _template.Disk.MsrSizeMb = v; Changed(); }, 16, 128))),
            () => _template.Disk.PartitionStyle == PartitionStyle.Gpt);

        Border recovery = Ui.Setting("Keep the Windows recovery environment",
            Track(Ui.Switch(() => _template.Disk.RecoveryPartition,
                on => { _template.Disk.RecoveryPartition = on; Changed(); })),
            "Setup creates the WinRE partition itself. Turning this off runs “reagentc /disable” "
            + "during provisioning to reclaim the space instead.");

        StackPanel layout = Ui.Group("Layout", style, number, efi, msr, recovery);
        When(layout, () => _template.Disk.WipeTargetDisk);
        panel.Children.Add(layout);

        Border wipeAll = Ui.Setting("Wipe every disk in the machine",
            Track(Ui.Switch(() => _template.Disk.WipeAllDisks,
                on => { _template.Disk.WipeAllDisks = on; Changed(); })));
        Border danger = When(
            Ui.Banner(BannerKind.Error, "This destroys secondary drives too",
                "Every attached disk (0–3) is wiped, including data drives and external disks that "
                + "happen to be plugged into the target machine."),
            () => _template.Disk.WipeAllDisks);

        StackPanel dangerZone = Ui.Group("Danger zone", wipeAll, danger);
        When(dangerZone, () => _template.Disk.WipeTargetDisk);
        panel.Children.Add(dangerZone);

        return panel;
    }

    // MARK: - Accounts

    private UIElement AccountsTab()
    {
        var panel = new StackPanel();

        var adminRows = new List<UIElement?>
        {
            Ui.Setting("Create a local IT admin account",
                Track(Ui.Switch(() => _template.Admin.Enabled,
                    on => { _template.Admin.Enabled = on; Changed(); }))),
            When(Ui.Setting("Username", Track(Ui.Field(() => _template.Admin.Username,
                v => { _template.Admin.Username = v; Changed(); }, "ITAdmin", 200))),
                () => _template.Admin.Enabled),
            When(Ui.Setting("Display name", Track(Ui.Field(() => _template.Admin.DisplayName,
                v => { _template.Admin.DisplayName = v; Changed(); }, "", 240))),
                () => _template.Admin.Enabled),
            When(Ui.Setting("Description", Track(Ui.Field(() => _template.Admin.AccountDescription,
                v => { _template.Admin.AccountDescription = v; Changed(); }, "", 280))),
                () => _template.Admin.Enabled),
            When(Ui.SecretRow("Password", _template.Id, SecretSlot.AdminPassword,
                    "Required to build.", Changed),
                () => _template.Admin.Enabled),
            When(Ui.Setting("Automatic sign-ins",
                    Track(Ui.NumberField(() => _template.Admin.AutoLogonCount,
                        v => { _template.Admin.AutoLogonCount = v; Changed(); }, 0, 9)),
                    "Provisioning needs at least one automatic sign-in to run. Windows clears the "
                    + "auto-logon once the count is used up."),
                () => _template.Admin.Enabled),
            When(Ui.Setting("Password never expires",
                Track(Ui.Switch(() => _template.Admin.PasswordNeverExpires,
                    on => { _template.Admin.PasswordNeverExpires = on; Changed(); }))),
                () => _template.Admin.Enabled),
            When(Ui.Setting("Hide from the sign-in screen after provisioning",
                Track(Ui.Switch(() => _template.Admin.HideFromLoginScreen,
                    on => { _template.Admin.HideFromLoginScreen = on; Changed(); }))),
                () => _template.Admin.Enabled),
            When(Ui.Setting("Also enable the built-in Administrator account",
                Track(Ui.Switch(() => _template.Admin.EnableBuiltInAdministrator,
                    on => { _template.Admin.EnableBuiltInAdministrator = on; Changed(); }))),
                () => _template.Admin.Enabled),
            Ui.Wide(null, Ui.Caption(
                "Passwords live in " + SecretStore.Label(SecretStore.Backend).ToLowerInvariant()
                + ", never in the template JSON. They are written in clear text into the answer file "
                + "on the USB stick at build time — that is how Windows Setup consumes them, so treat "
                + "a built drive as a credential.")),
        };
        panel.Children.Add(Ui.Group("IT admin profile", adminRows.ToArray()));

        var endUserRows = new List<UIElement?>
        {
            Ui.Setting("End-user setup", Track(Ui.Combo(
                Labels.All<EndUserMode>(), m => Labels.Of(m),
                () => _template.EndUser.Mode,
                v => { _template.EndUser.Mode = v; Changed(); }, 300))),
            When(Ui.Wide(null, Ui.Caption(
                    "The machine finishes at the Windows welcome screen and whoever receives it "
                    + "creates their own account.")),
                () => _template.EndUser.Mode == EndUserMode.LeaveOobe),
            When(Ui.Setting("Username", Track(Ui.Field(() => _template.EndUser.Username,
                v => { _template.EndUser.Username = v; Changed(); }, "", 200))),
                () => _template.EndUser.Mode == EndUserMode.CreateLocalAccount),
            When(Ui.Setting("Display name", Track(Ui.Field(() => _template.EndUser.DisplayName,
                v => { _template.EndUser.DisplayName = v; Changed(); }, "", 240))),
                () => _template.EndUser.Mode == EndUserMode.CreateLocalAccount),
            When(Ui.SecretRow("Password", _template.Id, SecretSlot.UserPassword, null, Changed),
                () => _template.EndUser.Mode == EndUserMode.CreateLocalAccount),
            When(Ui.Setting("Administrator",
                Track(Ui.Switch(() => _template.EndUser.Administrator,
                    on => { _template.EndUser.Administrator = on; Changed(); }))),
                () => _template.EndUser.Mode == EndUserMode.CreateLocalAccount),
            When(Ui.Setting("Must change password at first sign-in",
                Track(Ui.Switch(() => _template.EndUser.MustChangePassword,
                    on => { _template.EndUser.MustChangePassword = on; Changed(); }))),
                () => _template.EndUser.Mode == EndUserMode.CreateLocalAccount),
            // Username, display name, Administrator and must-change belong on the
            // first-boot dialog, not here — the whole point of this mode is that the
            // technician decides them at the machine.
            When(Ui.Setting("Give up after (minutes)",
                    Track(Ui.NumberField(() => _template.EndUser.PromptTimeoutMinutes,
                        v => { _template.EndUser.PromptTimeoutMinutes = v; Changed(); }, 1, 240)),
                    "Provisioning shows a dialog on the machine asking for the username, display "
                    + "name, password, whether the account is an administrator, and whether the "
                    + "password must be changed at first sign-in. If nobody answers within the time "
                    + "limit it carries on without creating the account and says so on the finish "
                    + "screen — it never waits indefinitely."),
                () => _template.EndUser.Mode == EndUserMode.PromptAtFirstBoot),
            Ui.Wide("Note shown on the finish screen",
                Ui.Field(() => _template.EndUser.WelcomeNote,
                    v => { _template.EndUser.WelcomeNote = v; Changed(); },
                    "", 0, multiline: true).Also(field => field.Height = 60)),
        };
        panel.Children.Add(Ui.Group("End user", endUserRows.ToArray()));

        panel.Children.Add(Ui.Group("Identity",
            Ui.Setting("Join", Track(Ui.Combo(
                Labels.All<JoinMode>(), m => Labels.Of(m),
                () => _template.Identity.JoinMode,
                v => { _template.Identity.JoinMode = v; Changed(); }, 260))),
            When(Ui.Setting("Workgroup", Track(Ui.Field(() => _template.Identity.Workgroup,
                v => { _template.Identity.Workgroup = v; Changed(); }, "WORKGROUP", 200))),
                () => _template.Identity.JoinMode == JoinMode.Workgroup),
            When(Ui.Setting("Domain", Track(Ui.Field(() => _template.Identity.Domain,
                v => { _template.Identity.Domain = v; Changed(); }, "corp.example.com", 240))),
                () => _template.Identity.JoinMode == JoinMode.ActiveDirectory),
            When(Ui.Setting("Computer OU (optional)",
                Track(Ui.Field(() => _template.Identity.OrganizationalUnit,
                    v => { _template.Identity.OrganizationalUnit = v; Changed(); },
                    "OU=Workstations,DC=corp,DC=example,DC=com", 300))),
                () => _template.Identity.JoinMode == JoinMode.ActiveDirectory),
            When(Ui.Setting("Join account", Track(Ui.Field(() => _template.Identity.DomainJoinUser,
                v => { _template.Identity.DomainJoinUser = v; Changed(); }, "", 220))),
                () => _template.Identity.JoinMode == JoinMode.ActiveDirectory),
            When(Ui.SecretRow("Join password", _template.Id, SecretSlot.DomainPassword, null, Changed),
                () => _template.Identity.JoinMode == JoinMode.ActiveDirectory),
            When(Ui.Wide(null, Ui.Caption(
                    "The machine joins during Setup's specialize pass, before first sign-in. It "
                    + "needs a working network connection at that point.")),
                () => _template.Identity.JoinMode == JoinMode.ActiveDirectory),
            When(Ui.Wide(null, Ui.Caption(
                    "The device is left unjoined so it can enrol into Entra ID / Intune (or "
                    + "Autopilot) at the welcome screen.")),
                () => _template.Identity.JoinMode == JoinMode.EntraAtOobe),
            Ui.Setting("Computer name", Track(Ui.Field(
                    () => _template.System.ComputerNameTemplate,
                    v => { _template.System.ComputerNameTemplate = v; Changed(); },
                    "IT-%SERIAL4%", 220)),
                "Tokens: %SERIAL% and %SERIAL4% (BIOS serial, full or last four), %MODEL%, "
                + "%RANDOM4%, %TEMPLATE%.")));

        return panel;
    }

    // MARK: - Apps

    private UIElement AppsTab()
    {
        var panel = new StackPanel();

        StackPanel header = Ui.Row(8,
            Ui.Button("Add from catalog", () =>
            {
                var dialog = new AppCatalogDialog(_window,
                    _template.Apps.Select(app => app.PackageId).Where(id => id.Length > 0));
                if (dialog.ShowDialog() == true)
                {
                    foreach (AppCatalog.Entry entry in dialog.Chosen)
                    {
                        if (_template.Apps.Any(app => app.PackageId == entry.Id)) { continue; }
                        _template.Apps.Add(entry.ToSelection());
                    }
                    RefreshAppList();
                    Changed();
                }
            }, "AccentButton"),
            Ui.Button("winget package", () => AddApp(AppSource.Winget)),
            Ui.Button("Bundled installer…", AddInstaller),
            Ui.Button("PowerShell", () => AddApp(AppSource.Script)));

        panel.Children.Add(Ui.Wide("Applications", header,
            "winget covers anything in Microsoft's repository. A bundled installer is copied onto "
            + "the stick for offline or version-pinned software."));
        panel.Children.Add(_appList);
        RefreshAppList();

        Border wingetNotice = When(
            Ui.Banner(BannerKind.Info, "winget needs internet on first boot",
                "Wire the machine up before reimaging, or add a Wi-Fi profile under Configuration "
                + "so provisioning can get online by itself."),
            () => _template.EnabledApps.Any(app => app.Source == AppSource.Winget));
        panel.Children.Add(wingetNotice);

        panel.Children.Add(Microsoft365Section());
        return panel;
    }

    private void AddApp(AppSource source)
    {
        var app = new AppSelection { Source = source };
        if (source == AppSource.Script) { app.Name = "New script step"; }
        _template.Apps.Add(app);
        _expandedApps.Add(app.Id);
        RefreshAppList();
        Changed();
    }

    private void AddInstaller()
    {
        string? path = Ui.PickFile("Choose an installer",
            "Installers (*.exe;*.msi)|*.exe;*.msi|All files (*.*)|*.*");
        if (path is null) { return; }
        var app = new AppSelection
        {
            Source = AppSource.Installer,
            InstallerPath = path,
            Name = Path.GetFileNameWithoutExtension(path),
            SilentArgs = SilentSwitches.Arguments(
                SilentSwitches.Suggested(Path.GetExtension(path))) ?? string.Empty,
        };
        _template.Apps.Add(app);
        _expandedApps.Add(app.Id);
        RefreshAppList();
        Changed();
    }

    private void RefreshAppList()
    {
        _appSync.Clear();
        _appList.Children.Clear();
        if (_template.Apps.Count == 0)
        {
            _appList.Children.Add(Ui.Wide(null, Ui.Caption(
                "No applications yet. Everything provisioning installs is listed here, in order.")));
            return;
        }
        foreach (AppSelection app in _template.Apps.ToList())
        {
            _appList.Children.Add(AppCard(app));
        }
    }

    private UIElement AppCard(AppSelection app)
    {
        bool expanded = _expandedApps.Contains(app.Id);

        var title = new TextBlock { FontWeight = FontWeights.Medium };
        var subtitle = new TextBlock { FontSize = 12 };
        subtitle.Themed(TextBlock.ForegroundProperty, "TextSecondary");

        void UpdateText()
        {
            title.Text = app.DisplayName;
            subtitle.Text = app.Source switch
            {
                AppSource.Winget => app.PackageId.Length == 0
                    ? "No package ID yet"
                    : app.PackageId + (app.Version.Length == 0 ? string.Empty : " · " + app.Version),
                AppSource.Installer => app.InstallerPath.Length == 0
                    ? "No installer chosen"
                    : Path.GetFileName(app.InstallerPath) + " " + app.SilentArgs,
                _ => app.Script.Trim().Length == 0 ? "Empty script" : "PowerShell",
            };
        }

        UpdateText();
        _appSync.Add(UpdateText);

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        System.Windows.Controls.Primitives.ToggleButton enabled = TrackIn(_appSync, Ui.Switch(
            () => app.Enabled, on => { app.Enabled = on; Changed(); }, "Include in this template"));
        enabled.VerticalAlignment = VerticalAlignment.Center;
        enabled.Margin = new Thickness(0, 0, 12, 0);
        Grid.SetColumn(enabled, 0);
        grid.Children.Add(enabled);

        StackPanel text = Ui.Column(1, title, subtitle);
        text.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        StackPanel actions = Ui.Row(4);
        if (app.Required) { actions.Children.Add(Ui.Chip("Required", "WarningBrush")); }
        if (!app.IsActionable)
        {
            actions.Children.Add(Ui.Icon(Glyphs.Warning, 15, "WarningBrush")
                .Tip("This entry is incomplete and will be skipped."));
        }
        actions.Children.Add(Ui.IconButton(expanded ? Glyphs.ChevronUp : Glyphs.ChevronDown, () =>
        {
            if (expanded) { _expandedApps.Remove(app.Id); } else { _expandedApps.Add(app.Id); }
            RefreshAppList();
        }, expanded ? "Collapse" : "Expand"));
        actions.Children.Add(Ui.IconButton(Glyphs.Cross, () =>
        {
            _template.Apps.RemoveAll(candidate => candidate.Id == app.Id);
            RefreshAppList();
            Changed();
        }, "Remove", "DangerBrush"));
        actions.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(actions, 2);
        grid.Children.Add(actions);

        if (!expanded)
        {
            Border row = Ui.Card(grid, 0);
            row.Padding = new Thickness(14, 10, 10, 10);
            row.Margin = new Thickness(0, 0, 0, 6);
            return row;
        }

        var detail = new List<UIElement?>
        {
            Ui.Setting("Source", TrackIn(_appSync, Ui.Combo(
                Labels.All<AppSource>(), s => Labels.Of(s),
                () => app.Source,
                v => { app.Source = v; RefreshAppList(); Changed(); }, 200))),
            Ui.Setting("Display name", Ui.Field(() => app.Name,
                v => { app.Name = v; UpdateText(); Changed(); }, "", 260)),
        };

        switch (app.Source)
        {
            case AppSource.Winget:
                detail.Add(Ui.Setting("winget package ID", Ui.Field(() => app.PackageId,
                    v => { app.PackageId = v; UpdateText(); Changed(); }, "Google.Chrome", 260)));
                detail.Add(Ui.Setting("Pin a version (optional)", Ui.Field(() => app.Version,
                    v => { app.Version = v; UpdateText(); Changed(); }, "latest", 160)));
                break;

            case AppSource.Installer:
                detail.Add(Ui.PathRow("Installer", () => app.InstallerPath,
                    path => { app.InstallerPath = path; UpdateText(); },
                    "None chosen",
                    "Installers (*.exe;*.msi)|*.exe;*.msi|All files (*.*)|*.*",
                    changed: Changed));
                detail.Add(SilentSwitchRow(app));
                break;

            case AppSource.Script:
                detail.Add(Ui.Wide("PowerShell", Ui.Field(() => app.Script,
                        v => { app.Script = v; UpdateText(); Changed(); },
                        "", 0, multiline: true, monospaced: true)
                    .Also(field => field.Height = 130)));
                break;
        }

        detail.Add(Ui.Setting("Fail provisioning if this doesn't install",
            TrackIn(_appSync, Ui.Switch(
                () => app.Required, on => { app.Required = on; RefreshAppList(); Changed(); }))));
        detail.Add(Ui.Setting("Notes", Ui.Field(() => app.Notes,
            v => { app.Notes = v; Changed(); }, "", 280)));

        Border card = Ui.Card(Ui.Column(6, grid, Ui.Divider(), Ui.Column(0, detail.ToArray())), 0);
        card.Padding = new Thickness(14, 10, 10, 10);
        card.Margin = new Thickness(0, 0, 0, 6);
        return card;
    }

    /// <summary>
    /// Silent switches from named presets rather than free text.
    ///
    /// The free-text field this replaces let a template ship /S to an installer that
    /// wanted --quiet. The installer then showed a modal dialog and the whole
    /// provisioning run stopped on it, which is a lot of consequence for a
    /// two-character mistake with no feedback.
    /// </summary>
    private UIElement SilentSwitchRow(AppSelection app)
    {
        SilentSwitchPreset preset = SilentSwitches.Matching(app.SilentArgs);
        var custom = Ui.Field(() => app.SilentArgs, v => { app.SilentArgs = v; Changed(); },
            "/qn /norestart", 200);
        custom.Visibility = preset == SilentSwitchPreset.Custom ? Visibility.Visible : Visibility.Collapsed;

        var detail = Ui.Caption(SilentSwitches.Detail(preset));

        ComboBox combo = Ui.Combo(
            Labels.All<SilentSwitchPreset>(), SilentSwitches.Label,
            () => SilentSwitches.Matching(app.SilentArgs),
            chosen =>
            {
                string? arguments = SilentSwitches.Arguments(chosen);
                if (arguments is not null) { app.SilentArgs = arguments; }
                custom.Visibility = chosen == SilentSwitchPreset.Custom
                    ? Visibility.Visible : Visibility.Collapsed;
                detail.Text = SilentSwitches.Detail(chosen);
                Ui.Refresh(custom);
                RefreshAppList();
                Changed();
            }, 220);

        return Ui.Wide("Silent install", Ui.Column(7, combo, custom, detail));
    }

    private UIElement Microsoft365Section()
    {
        var apps = new List<UIElement?>();
        foreach ((string id, string label) in Microsoft365Spec.AvailableApps)
        {
            string captured = id;
            CheckBox box = Track(Ui.Check(label,
                () => _template.Microsoft365.IncludedApps.Contains(captured),
                on =>
                {
                    if (on)
                    {
                        if (!_template.Microsoft365.IncludedApps.Contains(captured))
                        {
                            _template.Microsoft365.IncludedApps.Add(captured);
                        }
                    }
                    else
                    {
                        _template.Microsoft365.IncludedApps.Remove(captured);
                    }
                    Changed();
                }));
            box.Margin = new Thickness(0, 0, 22, 5);
            apps.Add(box);
        }

        var wrap = new WrapPanel();
        foreach (UIElement? box in apps)
        {
            if (box is not null) { wrap.Children.Add(box); }
        }

        Border chooser = When(Ui.Wide("Install these apps", Ui.Column(7, wrap, Ui.Caption(
                "Microsoft 365 Apps for enterprise, 64-bit, Current channel, in this template's "
                + "display language. Teams and OneDrive are left to the app catalog and to Windows "
                + "itself, so Office does not install a second copy of either."))),
            () => _template.Microsoft365.Enabled);

        Border notice = When(
            Ui.Banner(BannerKind.Info, "Office downloads itself during provisioning",
                "The Deployment Tool fetches several GB from Microsoft, so the machine needs a "
                + "network at first boot and this is the longest step in a run."),
            () => _template.Microsoft365.Enabled);

        Border off = When(Ui.Wide(null, Ui.Caption(
                "Off. Turning it on needs nothing from you — ImageHub fetches Microsoft's Office "
                + "Deployment Tool itself and installs the apps you tick.")),
            () => !_template.Microsoft365.Enabled);

        return Ui.Group("Microsoft 365",
            Ui.Setting("Install Microsoft 365",
                Track(Ui.Switch(() => _template.Microsoft365.Enabled,
                    on => { _template.Microsoft365.Enabled = on; Changed(); })),
                "winget's Microsoft.Office pins an installer hash Microsoft keeps replacing, so it "
                + "fails on nearly every run. This uses Microsoft's own Office Deployment Tool."),
            off, chooser, notice);
    }

    // MARK: - Configuration

    private UIElement ConfigurationTab()
    {
        var panel = new StackPanel();

        panel.Children.Add(Ui.Group("Machine",
            Ui.Setting("Time zone", Track(Ui.Combo(
                WindowsTimeZones.All, zone => zone,
                () => _template.System.TimeZone,
                v => { _template.System.TimeZone = v; Changed(); }, 260))),
            Ui.Setting("Power plan", Track(Ui.Combo(
                Labels.All<PowerPlan>(), p => Labels.Of(p),
                () => _template.System.PowerPlan,
                v => { _template.System.PowerPlan = v; Changed(); }, 200))),
            Ui.Setting("Never sleep on mains power",
                Track(Ui.Switch(() => _template.System.DisableSleepOnAc,
                    on => { _template.System.DisableSleepOnAc = on; Changed(); }))),
            Ui.Setting("Disable fast startup",
                Track(Ui.Switch(() => _template.System.DisableFastStartup,
                    on => { _template.System.DisableFastStartup = on; Changed(); }))),
            Ui.Setting("Disable hibernation (reclaims hiberfil.sys)",
                Track(Ui.Switch(() => _template.System.DisableHibernation,
                    on => { _template.System.DisableHibernation = on; Changed(); })))));

        panel.Children.Add(Ui.Group("Screen lock and power timeouts",
            Ui.Setting("Lock the screen after", MinutesCombo(
                () => _template.System.ScreenLockMinutes,
                v => { _template.System.ScreenLockMinutes = v; Changed(); })),
            Ui.Setting("Manage display, sleep and lid behaviour",
                Track(Ui.Switch(() => _template.System.ManagePowerTimeouts,
                    on => { _template.System.ManagePowerTimeouts = on; Changed(); }))),
            When(Ui.Setting("Display off (plugged in)", MinutesCombo(
                    () => _template.System.DisplayOffMinutesAc,
                    v => { _template.System.DisplayOffMinutesAc = v; Changed(); })),
                () => _template.System.ManagePowerTimeouts),
            When(Ui.Setting("Display off (on battery)", MinutesCombo(
                    () => _template.System.DisplayOffMinutesDc,
                    v => { _template.System.DisplayOffMinutesDc = v; Changed(); })),
                () => _template.System.ManagePowerTimeouts),
            When(Ui.Setting("Sleep (plugged in)", MinutesCombo(
                    () => _template.System.SleepMinutesAc,
                    v => { _template.System.SleepMinutesAc = v; Changed(); })),
                () => _template.System.ManagePowerTimeouts),
            When(Ui.Setting("Sleep (on battery)", MinutesCombo(
                    () => _template.System.SleepMinutesDc,
                    v => { _template.System.SleepMinutesDc = v; Changed(); })),
                () => _template.System.ManagePowerTimeouts),
            When(Ui.Setting("Lid closed (plugged in)", Track(Ui.Combo(
                    Labels.All<LidAction>(), a => Labels.Of(a),
                    () => _template.System.LidCloseActionAc,
                    v => { _template.System.LidCloseActionAc = v; Changed(); }, 180))),
                () => _template.System.ManagePowerTimeouts),
            When(Ui.Setting("Lid closed (on battery)", Track(Ui.Combo(
                    Labels.All<LidAction>(), a => Labels.Of(a),
                    () => _template.System.LidCloseActionDc,
                    v => { _template.System.LidCloseActionDc = v; Changed(); }, 180))),
                () => _template.System.ManagePowerTimeouts),
            Ui.Wide(null, Ui.Caption(
                "Written as machine policy, so every account gets them — including the end-user "
                + "account provisioning creates. Power schemes are per-user, so the policy route is "
                + "the only one that reaches the person who receives the machine. Windows shows "
                + "these as managed by your organisation, and they override “Never sleep on mains "
                + "power” above."))));

        panel.Children.Add(Ui.Group("Remote access",
            Ui.Setting("Enable Remote Desktop",
                Track(Ui.Switch(() => _template.System.EnableRemoteDesktop,
                    on => { _template.System.EnableRemoteDesktop = on; Changed(); })),
                "Enabled in the answer file; the firewall rule is opened during provisioning."),
            Ui.Setting("Allow ping (ICMP echo) through the firewall",
                Track(Ui.Switch(() => _template.System.AllowPing,
                    on => { _template.System.AllowPing = on; Changed(); })))));

        panel.Children.Add(Ui.Group("Desktop defaults",
            Ui.Setting("Show file extensions",
                Track(Ui.Switch(() => _template.System.ShowFileExtensions,
                    on => { _template.System.ShowFileExtensions = on; Changed(); }))),
            Ui.Setting("Show hidden files",
                Track(Ui.Switch(() => _template.System.ShowHiddenFiles,
                    on => { _template.System.ShowHiddenFiles = on; Changed(); }))),
            Ui.Setting("Restore the classic right-click menu",
                Track(Ui.Switch(() => _template.System.ClassicContextMenu,
                    on => { _template.System.ClassicContextMenu = on; Changed(); }))),
            Ui.Setting("Align the taskbar left",
                Track(Ui.Switch(() => _template.System.TaskbarAlignLeft,
                    on => { _template.System.TaskbarAlignLeft = on; Changed(); }))),
            Ui.Setting("Remove Widgets",
                Track(Ui.Switch(() => _template.System.DisableWidgets,
                    on => { _template.System.DisableWidgets = on; Changed(); }))),
            Ui.Setting("Turn off web results in Search",
                Track(Ui.Switch(() => _template.System.DisableWebSearch,
                    on => { _template.System.DisableWebSearch = on; Changed(); }))),
            Ui.Wide(null, Ui.Caption(
                "Applied to the default user profile, so every account created afterwards inherits "
                + "them."))));

        panel.Children.Add(Ui.Group("Debloat",
            Ui.Setting("Turn off telemetry and diagnostic data",
                Track(Ui.Switch(() => _template.System.DisableTelemetry,
                    on => { _template.System.DisableTelemetry = on; Changed(); }))),
            Ui.Setting("Turn off consumer features and suggested apps",
                Track(Ui.Switch(() => _template.System.DisableConsumerFeatures,
                    on => { _template.System.DisableConsumerFeatures = on; Changed(); }))),
            Ui.Setting("Remove preinstalled consumer apps",
                Track(Ui.Switch(() => _template.System.RemoveBloatware,
                    on => { _template.System.RemoveBloatware = on; Changed(); }))),
            When(BloatwareEditor(), () => _template.System.RemoveBloatware)));

        panel.Children.Add(Ui.Group("Updates",
            Ui.Setting("Windows Update", Track(Ui.Combo(
                Labels.All<UpdatePolicy>(), p => Labels.Of(p),
                () => _template.System.WindowsUpdate,
                v => { _template.System.WindowsUpdate = v; Changed(); }, 280))),
            Ui.Setting("Install available updates during provisioning",
                Track(Ui.Switch(() => _template.System.InstallUpdatesDuringProvisioning,
                    on => { _template.System.InstallUpdatesDuringProvisioning = on; Changed(); })),
                "Can add half an hour or more, but the machine is fully patched when it's handed "
                + "over.")));

        var features = new List<UIElement?>();
        foreach ((string id, string label) in SystemSpec.AvailableFeatures)
        {
            string captured = id;
            features.Add(Ui.Setting(label, Track(Ui.Switch(
                () => _template.System.OptionalFeatures.Contains(captured),
                on =>
                {
                    if (on)
                    {
                        if (!_template.System.OptionalFeatures.Contains(captured))
                        {
                            _template.System.OptionalFeatures.Add(captured);
                        }
                    }
                    else
                    {
                        _template.System.OptionalFeatures.Remove(captured);
                    }
                    Changed();
                }))));
        }
        panel.Children.Add(Ui.Group("Optional Windows features", features.ToArray()));

        panel.Children.Add(Ui.Group("Encryption",
            Ui.Setting("BitLocker", Track(Ui.Combo(
                Labels.All<BitLockerMode>(), m => Labels.Of(m),
                () => _template.System.BitLocker,
                v => { _template.System.BitLocker = v; Changed(); }, 220))),
            When(Ui.Setting("Back the recovery key up to Active Directory",
                Track(Ui.Switch(() => _template.System.EnableBitLockerRecoveryToAd,
                    on => { _template.System.EnableBitLockerRecoveryToAd = on; Changed(); }))),
                () => _template.System.BitLocker != BitLockerMode.Off),
            When(Ui.Banner(BannerKind.Warning, "Keep the recovery key somewhere you can reach it",
                    "Provisioning writes the recovery key to C:\\ImageHub\\logs so you can collect "
                    + "it before handover. Move it into your key escrow and delete the log."),
                () => _template.System.BitLocker != BitLockerMode.Off)));

        panel.Children.Add(Ui.Group("Wi-Fi",
            Ui.Setting("Provision a Wi-Fi profile",
                Track(Ui.Switch(() => _template.System.Wifi.Enabled,
                    on => { _template.System.Wifi.Enabled = on; Changed(); }))),
            When(Ui.Setting("SSID", Track(Ui.Field(() => _template.System.Wifi.Ssid,
                v => { _template.System.Wifi.Ssid = v; Changed(); }, "", 220))),
                () => _template.System.Wifi.Enabled),
            When(Ui.Setting("Security", Track(Ui.Combo(
                    new[] { "WPA2PSK", "WPA3SAE", "open" },
                    security => security switch
                    {
                        "WPA3SAE" => "WPA3 Personal",
                        "open" => "Open",
                        _ => "WPA2 Personal",
                    },
                    () => _template.System.Wifi.Security,
                    v => { _template.System.Wifi.Security = v; Changed(); }, 200))),
                () => _template.System.Wifi.Enabled),
            When(Ui.SecretRow("Password", _template.Id, SecretSlot.WifiPassword, null, Changed),
                () => _template.System.Wifi.Enabled && _template.System.Wifi.Security != "open"),
            When(Ui.Setting("Hidden network",
                Track(Ui.Switch(() => _template.System.Wifi.Hidden,
                    on => { _template.System.Wifi.Hidden = on; Changed(); }))),
                () => _template.System.Wifi.Enabled),
            When(Ui.Setting("Connect automatically",
                Track(Ui.Switch(() => _template.System.Wifi.ConnectAutomatically,
                    on => { _template.System.Wifi.ConnectAutomatically = on; Changed(); }))),
                () => _template.System.Wifi.Enabled),
            When(Ui.Wide(null, Ui.Caption(
                    "The profile is imported before apps install, so winget can reach the internet "
                    + "on a machine with no Ethernet.")),
                () => _template.System.Wifi.Enabled)));

        panel.Children.Add(Ui.Group("Organisation",
            Ui.Setting("Organisation name", Track(Ui.Field(
                () => _template.System.OrganizationName,
                v => { _template.System.OrganizationName = v; Changed(); }, "", 260))),
            Ui.PathRow("Logo", () => _template.System.LogoPath,
                path => _template.System.LogoPath = path, "None",
                "Images (*.png;*.jpg;*.jpeg;*.bmp)|*.png;*.jpg;*.jpeg;*.bmp", changed: Changed),
            Ui.Setting("Support phone", Track(Ui.Field(
                () => _template.System.SupportPhone,
                v => { _template.System.SupportPhone = v; Changed(); }, "", 200))),
            Ui.Setting("Support URL", Track(Ui.Field(
                () => _template.System.SupportUrl,
                v => { _template.System.SupportUrl = v; Changed(); }, "", 260))),
            Ui.Wide(null, Ui.Caption(
                "Written into Windows' OEM information, so it shows in Settings → About, and used "
                + "on the setup screen below."))));

        panel.Children.Add(Ui.Group("Setup screen",
            Ui.Setting("Show a branded setup screen while provisioning",
                Track(Ui.Switch(() => _template.System.ShowProvisioningScreen,
                    on => { _template.System.ShowProvisioningScreen = on; Changed(); })),
                "Provisioning takes 10–40 minutes and otherwise runs in a bare PowerShell window. "
                + "This replaces it with a full-screen screen showing your logo, the current step, "
                + "and a progress bar. It runs as its own process, so it can't slow provisioning "
                + "down or hang it."),
            When(Ui.Banner(BannerKind.Info, "What it can and can't cover",
                    "This appears once Windows is installed and provisioning starts — the part "
                    + "someone actually sits and watches.",
                    "The earlier screens can't be branded: the logo before Windows loads comes from "
                    + "the target machine's own firmware, and Windows Setup's UI isn't themable."),
                () => _template.System.ShowProvisioningScreen)));

        panel.Children.Add(Ui.Group("Branding",
            Ui.PathRow("Desktop wallpaper", () => _template.System.WallpaperPath,
                path => _template.System.WallpaperPath = path, "Windows default",
                "Images (*.png;*.jpg;*.jpeg;*.bmp)|*.png;*.jpg;*.jpeg;*.bmp", changed: Changed),
            Ui.PathRow("Lock screen", () => _template.System.LockScreenPath,
                path => _template.System.LockScreenPath = path, "Windows default",
                "Images (*.png;*.jpg;*.jpeg;*.bmp)|*.png;*.jpg;*.jpeg;*.bmp", changed: Changed),
            Ui.PathRow("Start menu layout", () => _template.System.StartLayoutPath,
                path => _template.System.StartLayoutPath = path, "Windows default",
                "Start layout (*.json;*.xml)|*.json;*.xml|All files (*.*)|*.*", changed: Changed),
            Ui.Wide(null, Ui.Caption(
                "Export a Start layout on a reference machine with “Export-StartLayout -Path "
                + "layout.json”."))));

        panel.Children.Add(Ui.Group("Registry",
            Ui.Wide(null, Ui.Column(8, _registryList,
                Ui.Button("Add registry value", () =>
                {
                    _template.System.RegistryTweaks.Add(new RegistryTweak());
                    RefreshRegistryList();
                    Changed();
                })),
                "Applied with Set-ItemProperty during provisioning, after everything else. Use "
                + "PowerShell paths (HKLM:\\…).")));
        RefreshRegistryList();

        return panel;
    }

    private ComboBox MinutesCombo(Func<int> get, Action<int> set)
    {
        int[] presets = { 0, 1, 2, 3, 5, 10, 15, 20, 30, 45, 60, 90, 120 };
        // A hand-edited template can hold a value no preset offers; carry it rather than
        // silently rewriting it on the next edit.
        List<int> choices = presets.ToList();
        if (!choices.Contains(get())) { choices.Add(get()); choices.Sort(); }
        return Track(Ui.Combo(choices, MinutesLabel, get, value => set(value), 160));
    }

    private static string MinutesLabel(int minutes) => minutes switch
    {
        <= 0 => "Never",
        1 => "1 minute",
        _ => $"{minutes} minutes",
    };

    private UIElement BloatwareEditor()
    {
        var entry = string.Empty;
        Grid field = Ui.Field(() => entry, text => entry = text, "Add an AppX package name", 260);

        void Refresh()
        {
            _bloatwareList.Children.Clear();
            foreach (string package in _template.System.BloatwareList.ToList())
            {
                string captured = package;
                var grid = new Grid();
                grid.ColumnDefinitions.Add(new ColumnDefinition
                {
                    Width = new GridLength(1, GridUnitType.Star),
                });
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                TextBlock text = Ui.Mono(captured);
                text.VerticalAlignment = VerticalAlignment.Center;
                Grid.SetColumn(text, 0);
                grid.Children.Add(text);
                Button remove = Ui.IconButton(Glyphs.Cross, () =>
                {
                    _template.System.BloatwareList.Remove(captured);
                    Refresh();
                    Changed();
                }, "Remove");
                Grid.SetColumn(remove, 1);
                grid.Children.Add(remove);
                _bloatwareList.Children.Add(grid);
            }
        }

        Refresh();

        var scroll = new ScrollViewer
        {
            Content = _bloatwareList,
            Height = 150,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };

        StackPanel controls = Ui.Row(8, field,
            Ui.Button("Add", () =>
            {
                string trimmed = entry.Trim();
                if (trimmed.Length == 0 || _template.System.BloatwareList.Contains(trimmed)) { return; }
                _template.System.BloatwareList.Add(trimmed);
                entry = string.Empty;
                Ui.Refresh(field);
                Refresh();
                Changed();
            }),
            Ui.Button("Reset to defaults", () =>
            {
                _template.System.BloatwareList = SystemSpec.DefaultBloatware.ToList();
                Refresh();
                Changed();
            }, "SubtleButton"));

        var count = Ui.Caption(string.Empty);
        _sync.Add(() => count.Text =
            Formatting.Plural(_template.System.BloatwareList.Count, "package") + " will be removed.");

        return Ui.Wide("Preinstalled apps to remove",
            Ui.Column(8, Ui.Inset(scroll, 6), controls, count));
    }

    private void RefreshRegistryList()
    {
        _registrySync.Clear();
        _registryList.Children.Clear();
        if (_template.System.RegistryTweaks.Count == 0)
        {
            _registryList.Children.Add(Ui.Caption("No registry changes."));
            return;
        }
        foreach (RegistryTweak tweak in _template.System.RegistryTweaks.ToList())
        {
            RegistryTweak captured = tweak;
            StackPanel top = Ui.Row(6,
                TrackIn(_registrySync, Ui.Switch(() => captured.Enabled,
                    on => { captured.Enabled = on; Changed(); })),
                Ui.Field(() => captured.Path, v => { captured.Path = v; Changed(); },
                    "HKLM:\\SOFTWARE\\…", 340),
                Ui.IconButton(Glyphs.Cross, () =>
                {
                    _template.System.RegistryTweaks.RemoveAll(candidate => candidate.Id == captured.Id);
                    RefreshRegistryList();
                    Changed();
                }, "Remove", "DangerBrush"));

            StackPanel bottom = Ui.Row(6,
                Ui.Field(() => captured.Name, v => { captured.Name = v; Changed(); }, "Value name", 170),
                TrackIn(_registrySync, Ui.Combo(Labels.All<RegistryValueType>(), type => type.ToString(),
                    () => captured.Type, v => { captured.Type = v; Changed(); }, 130)),
                Ui.Field(() => captured.Value, v => { captured.Value = v; Changed(); }, "Data", 170));

            Border row = Ui.Inset(Ui.Column(6, top, bottom), 9);
            row.Margin = new Thickness(0, 0, 0, 6);
            _registryList.Children.Add(row);
        }
    }

    // MARK: - First boot

    private UIElement FirstBootTab()
    {
        var panel = new StackPanel();

        panel.Children.Add(Ui.Group("Welcome screens",
            Ui.Setting("Hide the licence terms page",
                Track(Ui.Switch(() => _template.Oobe.HideEula,
                    on => { _template.Oobe.HideEula = on; Changed(); }))),
            Ui.Setting("Hide OEM registration",
                Track(Ui.Switch(() => _template.Oobe.HideOemRegistration,
                    on => { _template.Oobe.HideOemRegistration = on; Changed(); }))),
            Ui.Setting("Hide Microsoft account screens",
                Track(Ui.Switch(() => _template.Oobe.HideOnlineAccountScreens,
                    on => { _template.Oobe.HideOnlineAccountScreens = on; Changed(); }))),
            Ui.Setting("Hide wireless setup",
                Track(Ui.Switch(() => _template.Oobe.HideWirelessSetup,
                    on => { _template.Oobe.HideWirelessSetup = on; Changed(); }))),
            Ui.Setting("Express settings", Track(Ui.Combo(
                new[] { 1, 3 },
                value => value == 1 ? "Recommended settings" : "Critical updates only",
                () => _template.Oobe.ProtectYourPc,
                v => { _template.Oobe.ProtectYourPc = v; Changed(); }, 240)))));

        panel.Children.Add(Ui.Group("Unattended",
            Ui.Setting("Skip machine setup screens",
                Track(Ui.Switch(() => _template.Oobe.SkipMachineOobe,
                    on => { _template.Oobe.SkipMachineOobe = on; Changed(); }))),
            Ui.Setting("Skip user setup screens",
                Track(Ui.Switch(() => _template.Oobe.SkipUserOobe,
                    on => { _template.Oobe.SkipUserOobe = on; Changed(); })),
                "Skipping user screens only makes sense when the template also creates an account — "
                + "otherwise the machine boots to a sign-in screen with no usable user."),
            When(Ui.Banner(BannerKind.Warning, "No account will exist",
                    "User setup is skipped, no admin account is created, and no end-user account is "
                    + "pre-created."),
                () => _template.Oobe.SkipUserOobe
                    && _template.EndUser.Mode == EndUserMode.LeaveOobe
                    && !_template.Admin.Enabled)));

        panel.Children.Add(Ui.Group("Requirement bypasses",
            Ui.Setting("Allow finishing setup without a network or Microsoft account",
                Track(Ui.Switch(() => _template.System.BypassNetworkRequirement,
                    on => { _template.System.BypassNetworkRequirement = on; Changed(); }))),
            Ui.Setting("Bypass the Windows 11 hardware checks",
                Track(Ui.Switch(() => _template.System.BypassWin11Requirements,
                    on => { _template.System.BypassWin11Requirements = on; Changed(); }))),
            When(Ui.Banner(BannerKind.Warning, "Unsupported configuration",
                    "Setting the LabConfig bypasses lets Windows 11 install without TPM 2.0, Secure "
                    + "Boot, or the CPU/RAM floor. Microsoft does not support the result, and future "
                    + "updates may refuse to install."),
                () => _template.System.BypassWin11Requirements)));

        return panel;
    }

    // MARK: - Scripts

    private UIElement ScriptsTab()
    {
        var panel = new StackPanel();

        panel.Children.Add(Ui.Wide("Custom PowerShell",
            Ui.Button("Add script", () =>
            {
                var script = new CustomScript { Name = $"Script {_template.Scripts.Count + 1}" };
                _template.Scripts.Add(script);
                RefreshScriptList();
                Changed();
            }, "AccentButton"),
            "For anything the template can't express — mapped drives, printers, line-of-business "
            + "config, agent enrolment."));

        panel.Children.Add(_scriptList);
        RefreshScriptList();

        panel.Children.Add(Ui.Banner(BannerKind.Info, "How scripts run",
            "Setup (specialize) runs before any user signs in, as SYSTEM, with no network guarantee.",
            "Provisioning runs after apps and configuration, as the admin account.",
            "Finalize runs last, just before the completion screen.",
            "Everything is logged to C:\\ImageHub\\logs on the target machine."));

        return panel;
    }

    private void RefreshScriptList()
    {
        _scriptSync.Clear();
        _scriptList.Children.Clear();
        if (_template.Scripts.Count == 0)
        {
            _scriptList.Children.Add(Ui.Wide(null, Ui.Caption("No custom scripts.")));
            return;
        }
        foreach (CustomScript script in _template.Scripts.ToList())
        {
            CustomScript captured = script;
            StackPanel header = Ui.Row(8,
                TrackIn(_scriptSync, Ui.Switch(() => captured.Enabled,
                    on => { captured.Enabled = on; Changed(); })),
                Ui.Field(() => captured.Name, v => { captured.Name = v; Changed(); }, "Name", 240),
                TrackIn(_scriptSync, Ui.Combo(Labels.All<ScriptPhase>(), p => Labels.Of(p),
                    () => captured.Phase, v => { captured.Phase = v; Changed(); }, 180)),
                Ui.IconButton(Glyphs.Cross, () =>
                {
                    _template.Scripts.RemoveAll(candidate => candidate.Id == captured.Id);
                    RefreshScriptList();
                    Changed();
                }, "Remove", "DangerBrush"));

            Grid body = Ui.Field(() => captured.Body, v => { captured.Body = v; Changed(); },
                "# PowerShell, run on the target machine", 0, multiline: true, monospaced: true);
            body.Height = 150;

            CheckBox carryOn = TrackIn(_scriptSync, Ui.Check("Carry on if this script fails",
                () => captured.ContinueOnError,
                on => { captured.ContinueOnError = on; Changed(); }));

            var fileName = Ui.Hint("Written to ImageHub\\Scripts\\"
                + PayloadBuilder.ScriptFileName(captured));

            Border card = Ui.Card(Ui.Column(8, header, body, carryOn, fileName), 13);
            card.Margin = new Thickness(0, 0, 0, 6);
            _scriptList.Children.Add(card);
        }
    }

    // MARK: - Review

    private void RefreshReview()
    {
        _reviewBody.Children.Clear();

        IReadOnlyList<ValidationIssue> issues = _template.Issues;
        if (issues.Count == 0)
        {
            _reviewBody.Children.Add(Ui.Banner(BannerKind.Success, "This template is ready to build"));
        }
        else
        {
            _reviewBody.Children.Add(IssueList(BannerKind.Error,
                "Fix before building — click one to go there", issues));
        }

        IReadOnlyList<ValidationIssue> warnings = _template.Warnings;
        if (warnings.Count > 0)
        {
            _reviewBody.Children.Add(IssueList(BannerKind.Warning, "Worth knowing", warnings));
        }

        _reviewBody.Children.Add(SummaryCard());

        (Border host, TextBox box) = Ui.LogPane(300);
        box.Text = new AnswerFileBuilder(_template).Build();
        _reviewBody.Children.Add(Ui.Wide("Generated answer file",
            Ui.Column(8,
                Ui.Row(8,
                    Ui.Button("Copy", () =>
                    {
                        try
                        {
                            Clipboard.SetText(box.Text);
                            Notifier.Banner("Copied autounattend.xml");
                        }
                        catch (Exception error)
                        {
                            Notifier.Banner("Couldn't copy", error.Message, BannerKind.Error);
                        }
                    }),
                    Ui.Button("Save…", () =>
                    {
                        var dialog = new Microsoft.Win32.SaveFileDialog
                        {
                            FileName = "autounattend.xml",
                            Filter = "Answer file (*.xml)|*.xml",
                        };
                        if (dialog.ShowDialog(_window) != true) { return; }
                        try
                        {
                            File.WriteAllText(dialog.FileName, box.Text,
                                new System.Text.UTF8Encoding(false));
                            Notifier.Banner("Answer file saved", Path.GetFileName(dialog.FileName));
                        }
                        catch (Exception error)
                        {
                            Notifier.Banner("Couldn't save", error.Message, BannerKind.Error);
                        }
                    })),
                host),
            "Passwords are shown as empty here — they're injected from "
            + SecretStore.Label(SecretStore.Backend).ToLowerInvariant()
            + " only when a drive is written."));
    }

    private UIElement IssueList(BannerKind kind, string title, IReadOnlyList<ValidationIssue> issues)
    {
        var rows = new List<UIElement?> { Ui.Text(title).Also(text => text.FontWeight = FontWeights.Medium) };
        foreach (ValidationIssue issue in issues)
        {
            ValidationIssue captured = issue;
            var button = new Button
            {
                Content = Ui.Row(8,
                    Ui.Caption(captured.Message).Also(text => text.MaxWidth = 620),
                    Ui.Row(3,
                        new TextBlock
                        {
                            Text = TabFor(captured.Field),
                            FontSize = 11.5,
                            FontWeight = FontWeights.Medium,
                        }.Themed(TextBlock.ForegroundProperty, Ui.BrushKeyFor(kind)),
                        Ui.Icon(Glyphs.ChevronRight, 9, Ui.BrushKeyFor(kind), thickness: 2))),
                HorizontalContentAlignment = HorizontalAlignment.Left,
            };
            button.Styled("SubtleButton");
            button.ToolTip = "Go to " + TabFor(captured.Field);
            button.Click += (_, _) => SelectTab(TabFor(captured.Field));
            rows.Add(button);
        }

        string key = Ui.BrushKeyFor(kind);
        return new Border
        {
            Child = Ui.Column(3, rows.ToArray()),
            CornerRadius = new CornerRadius(7),
            Padding = new Thickness(12, 10, 12, 11),
            Margin = new Thickness(0, 0, 0, 6),
            Background = Ui.Tint(key, 0.11),
            BorderBrush = Ui.Tint(key, 0.32),
            BorderThickness = new Thickness(1),
        };
    }

    /// <summary>
    /// Where a validation issue lives in this editor. The model names parts of the
    /// template rather than tabs, so the mapping is here — as it is on macOS.
    /// </summary>
    private static string TabFor(TemplateField field) => field switch
    {
        TemplateField.Windows => "Windows",
        TemplateField.Disk => "Disk",
        TemplateField.Accounts => "Accounts",
        TemplateField.Apps => "Apps",
        TemplateField.System => "Configuration",
        TemplateField.FirstBoot => "First Boot",
        TemplateField.Scripts => "Scripts",
        _ => "Windows",
    };

    private UIElement SummaryCard()
    {
        var rows = new List<UIElement?>();

        void Line(string label, string value)
        {
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
            grid.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });
            TextBlock name = Ui.Caption(label);
            name.TextAlignment = TextAlignment.Right;
            name.Margin = new Thickness(0, 0, 12, 0);
            Grid.SetColumn(name, 0);
            grid.Children.Add(name);
            TextBlock text = Ui.Text(value);
            Grid.SetColumn(text, 1);
            grid.Children.Add(text);
            grid.Margin = new Thickness(0, 0, 0, 5);
            rows.Add(grid);
        }

        Line("Installs", $"{Labels.Of(_template.Windows.Release)} "
            + $"{Labels.Of(_template.Windows.Edition)} ({_template.Windows.Architecture})");
        Line("Image from", ImageSummary());
        Line("Target disk", _template.Disk.WipeTargetDisk
            ? $"Wipes disk {_template.Disk.DiskNumber} · {Labels.Of(_template.Disk.PartitionStyle)}"
            : "Leaves the existing partitions alone");
        Line("Admin account", _template.Admin.Enabled
            ? $"{_template.Admin.Username} (Administrators)"
            : "None");
        Line("End user", Labels.Of(_template.EndUser.Mode));
        Line("Identity", IdentitySummary());
        Line("Applications", _template.EnabledApps.Count == 0
            ? "None"
            : string.Join(", ", _template.EnabledApps.Select(app => app.DisplayName)));
        if (_template.Microsoft365.Enabled)
        {
            Line("Microsoft 365", _template.Microsoft365.IncludedApps.Count == 0
                ? "On, but no apps selected"
                : string.Join(", ", Microsoft365Spec.AvailableApps
                    .Where(app => _template.Microsoft365.IncludedApps.Contains(app.Id))
                    .Select(app => app.Label)));
        }
        Line("Licence", ActivationSummary());
        Line("Time zone", _template.System.TimeZone);
        if (_template.System.RemoveBloatware)
        {
            Line("Removes", Formatting.Plural(_template.System.BloatwareList.Count, "preinstalled app"));
        }
        if (_template.System.OptionalFeatures.Count > 0)
        {
            Line("Enables", string.Join(", ", _template.System.OptionalFeatures));
        }
        List<CustomScript> scripts = _template.Scripts.Where(script => script.Enabled).ToList();
        if (scripts.Count > 0)
        {
            Line("Custom scripts", string.Join(", ", scripts.Select(script => script.Name)));
        }

        return Ui.Wide("What this template does", Ui.Column(0, rows.ToArray()));
    }

    /// <summary>
    /// Key source plus what provisioning does about activation, because those two
    /// together decide whether the machine ends up wearing an "Activate Windows"
    /// watermark on someone's desk.
    /// </summary>
    private string ActivationSummary()
    {
        string key = _template.Windows.ProductKeyMode switch
        {
            ProductKeyMode.Firmware => "The PC's built-in key",
            ProductKeyMode.Generic => "Generic KMS client key",
            ProductKeyMode.Custom => "A key of your own",
            _ => "Setup asks for a key",
        };
        return _template.Windows.Activation.Mode switch
        {
            ActivationMode.Automatic => key + " · activates during provisioning",
            ActivationMode.Kms => key + " · activates against "
                + (_template.Windows.Activation.KmsHost.Length == 0
                    ? "no host set"
                    : _template.Windows.Activation.KmsHost),
            _ => key + " · activation left alone",
        };
    }

    private string IdentitySummary() => _template.Identity.JoinMode switch
    {
        JoinMode.Workgroup => "Workgroup " + _template.Identity.Workgroup,
        JoinMode.ActiveDirectory => _template.Identity.Domain.Length == 0
            ? "Domain join (not configured)"
            : "Joins " + _template.Identity.Domain,
        _ => "Left for Entra ID / Intune enrolment",
    };
}

/// <summary>Lets a freshly built element be tweaked inline without a local variable.</summary>
public static class FluentExtensions
{
    public static T Also<T>(this T value, Action<T> configure)
    {
        configure(value);
        return value;
    }
}
