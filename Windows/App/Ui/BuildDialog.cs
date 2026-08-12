using System;
using System.Collections.Generic;
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
/// The build wizard: pick a template, an image and a drive, confirm what is about to be
/// destroyed, then watch the eight stages go by.
///
/// The confirmation is deliberately a separate, explicit step. Everything before it is
/// reversible; the moment after it is not.
/// </summary>
public sealed class BuildDialog : ThemedWindow
{
    private readonly AppState _state = AppState.Shared;
    private readonly ContentControl _body = new();
    private readonly ContentControl _footer = new();
    private readonly TextBlock _headerTitle = new();
    private readonly TextBlock _headerSubtitle = new();
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Dictionary<BuildJob.Stage, (System.Windows.Shapes.Path Icon, TextBlock Title,
        TextBlock Detail)> _stageRows = new();

    private DeploymentTemplate? _template;
    private WindowsImage? _image;
    private UsbDisk? _drive;
    private BuildJob? _job;
    private ProgressBar? _overall;
    private TextBlock? _headline;
    private TextBox? _log;
    private Grid? _progressRoot;
    private bool _celebrated;

    public BuildDialog(Window owner, DeploymentTemplate? template)
    {
        Title = "Build a golden-image USB";
        ConfigureAsDialog(owner, 760, 660);
        MinWidth = 640;
        MinHeight = 520;

        _template = template
            ?? _state.SelectedTemplate
            ?? _state.Templates.Templates.FirstOrDefault();
        _drive = _state.SelectedDrive ?? _state.Drives.FirstOrDefault();
        _image = _template is not null ? _state.Library.BestMatch(_template) : null;
        _image ??= _state.Library.Images.FirstOrDefault(image => image.FileExists);

        Content = BuildLayout();
        ShowConfiguration();

        _tick.Tick += (_, _) => UpdateProgress();
        Closing += (_, _) => _tick.Stop();
    }

    private UIElement BuildLayout()
    {
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        _headerTitle.FontSize = 17;
        _headerTitle.FontWeight = FontWeights.SemiBold;
        _headerSubtitle.FontSize = 12;
        _headerSubtitle.TextWrapping = TextWrapping.Wrap;
        _headerSubtitle.Themed(TextBlock.ForegroundProperty, "TextSecondary");

        var header = new Border
        {
            Child = Ui.Column(2, _headerTitle, _headerSubtitle),
            Padding = new Thickness(18, 14, 18, 13),
            BorderThickness = new Thickness(0, 0, 0, 1),
        };
        header.Themed(Border.BackgroundProperty, "BarBg");
        header.Themed(Border.BorderBrushProperty, "DividerBrush");
        Grid.SetRow(header, 0);
        grid.Children.Add(header);

        Grid.SetRow(_body, 1);
        grid.Children.Add(_body);

        var footer = new Border
        {
            Child = _footer,
            Padding = new Thickness(16, 12, 16, 13),
            BorderThickness = new Thickness(0, 1, 0, 0),
        };
        footer.Themed(Border.BackgroundProperty, "BarBg");
        footer.Themed(Border.BorderBrushProperty, "DividerBrush");
        Grid.SetRow(footer, 2);
        grid.Children.Add(footer);

        return grid;
    }

    // MARK: - Configuration

    private void ShowConfiguration()
    {
        _headerTitle.Text = "Build a golden-image USB";
        _headerSubtitle.Text =
            "Wipe the drive, write Windows Setup, and stage the provisioning payload.";

        var panel = new StackPanel();
        panel.Children.Add(Step(1, "Template", TemplateStep()));
        panel.Children.Add(Step(2, "Windows image", ImageStep()));
        panel.Children.Add(Step(3, "Target drive", DriveStep()));
        _body.Content = Ui.Scroll(panel, 16);

        UpdateFooter();
    }

    private static UIElement Step(int number, string title, UIElement content)
    {
        var badge = new Border
        {
            Width = 20,
            Height = 20,
            CornerRadius = new CornerRadius(10),
            Background = Ui.Brush("AccentBrush"),
            Child = new TextBlock
            {
                Text = number.ToString(),
                FontSize = 11.5,
                FontWeight = FontWeights.Bold,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = Ui.Brush("OnAccentBrush"),
            },
        };

        StackPanel header = Ui.Row(9, badge, Ui.Subheading(title));
        Border card = Ui.Card(Ui.Column(10, header, content), 14);
        card.Margin = new Thickness(0, 0, 0, 8);
        return card;
    }

    private UIElement TemplateStep()
    {
        List<DeploymentTemplate> templates = _state.Templates.Templates.ToList();
        if (templates.Count == 0)
        {
            return Ui.Caption("No templates yet — create one first.");
        }

        var rows = new StackPanel();
        ComboBox picker = Ui.Combo(templates, template => template.Name,
            () => _template ?? templates[0],
            chosen =>
            {
                _template = chosen;
                _image = _state.Library.BestMatch(chosen)
                    ?? _state.Library.Images.FirstOrDefault(image => image.FileExists);
                ShowConfiguration();
            }, 380);
        picker.HorizontalAlignment = HorizontalAlignment.Left;
        rows.Children.Add(picker);

        if (_template is not null)
        {
            rows.Children.Add(Ui.Caption(_template.Subtitle).Spaced(0, 8, 0, 0));
            if (_template.ValidationErrors.Count > 0)
            {
                rows.Children.Add(Ui.Banner(BannerKind.Error, "This template isn't ready",
                    _template.ValidationErrors.ToArray()).Spaced(0, 9, 0, 0));
            }
            if (_template.ValidationWarnings.Count > 0)
            {
                rows.Children.Add(Ui.Banner(BannerKind.Warning, "Before you build",
                    _template.ValidationWarnings.ToArray()).Spaced(0, 9, 0, 0));
            }
        }
        return rows;
    }

    private UIElement ImageStep()
    {
        List<WindowsImage> usable = _state.Library.Images.Where(image => image.FileExists).ToList();
        if (usable.Count == 0)
        {
            return Ui.Caption("No usable images in the library. Download or import an ISO first.");
        }

        var rows = new StackPanel();
        ComboBox picker = Ui.Combo(usable, image => image.DisplayName,
            () => _image ?? usable[0],
            chosen =>
            {
                _image = chosen;
                ShowConfiguration();
            }, 380);
        picker.HorizontalAlignment = HorizontalAlignment.Left;
        rows.Children.Add(picker);

        if (_image is not null)
        {
            string detail = $"{Formatting.ByteSize(_image.SizeBytes)} · {Labels.Of(_image.Origin)}";
            if (_image.InstallImageName.Length > 0) { detail += " · " + _image.InstallImageName; }
            rows.Children.Add(Ui.Caption(detail).Spaced(0, 8, 0, 0));

            if (_image.InstallImageNeedsSplit)
            {
                rows.Children.Add(Ui.Banner(BannerKind.Info, "install.wim will be split",
                    $"It's {Formatting.ByteSize(_image.InstallImageSizeBytes)}, over FAT32's 4 GB "
                    + "file limit, so DISM splits it into install.swm parts. Windows Setup reads "
                    + "those natively, and DISM ships with Windows — nothing to install.")
                    .Spaced(0, 9, 0, 0));
            }
            if (_template is not null && _template.Windows.UsesCapturedImage)
            {
                rows.Children.Add(Ui.Banner(BannerKind.Info, "Template overrides the install image",
                    "Boot files come from this ISO, but the OS is installed from "
                    + System.IO.Path.GetFileName(_template.Windows.CustomWimPath) + ".")
                    .Spaced(0, 9, 0, 0));
            }
        }
        return rows;
    }

    private UIElement DriveStep()
    {
        if (_state.Drives.Count == 0)
        {
            return Ui.Column(9,
                Ui.Caption("No removable drives detected. Plug one in — it'll appear here."),
                Ui.Button("Rescan", () => _ = RescanAsync()));
        }

        var rows = new StackPanel();
        foreach (UsbDisk drive in _state.Drives)
        {
            UsbDisk captured = drive;
            bool selected = _drive?.Id == drive.Id;

            StackPanel content = Ui.Row(11,
                Ui.Icon(selected ? Glyphs.Success : Glyphs.Circle, 17,
                    selected ? "AccentBrush" : "TextTertiary", thickness: 1.5),
                Ui.Column(2,
                    Ui.Text(drive.DisplayName).Also(text => text.FontWeight = FontWeights.Medium),
                    Ui.Caption(drive.Subtitle)));

            var card = new Border
            {
                Child = content,
                Padding = new Thickness(10),
                CornerRadius = new CornerRadius(6),
                Margin = new Thickness(0, 0, 0, 6),
                Cursor = System.Windows.Input.Cursors.Hand,
                BorderThickness = new Thickness(selected ? 1.4 : 1),
                Background = selected ? Ui.Tint("AccentBrush", 0.09) : Ui.Brush("SubtleBg"),
                BorderBrush = selected ? Ui.Brush("AccentBrush") : Ui.Brush("DividerBrush"),
            };
            card.MouseLeftButtonUp += (_, _) =>
            {
                _drive = captured;
                _state.SelectedDriveId = captured.Id;
                ShowConfiguration();
            };
            rows.Children.Add(card);
        }
        rows.Children.Add(Ui.Button("Rescan", () => _ = RescanAsync(), "SubtleButton"));
        return rows;
    }

    private async System.Threading.Tasks.Task RescanAsync()
    {
        await _state.RefreshDrivesAsync().ConfigureAwait(true);
        if (_drive is not null && _state.Drives.All(drive => drive.Id != _drive.Id))
        {
            _drive = _state.Drives.FirstOrDefault();
        }
        _drive ??= _state.Drives.FirstOrDefault();
        ShowConfiguration();
    }

    // MARK: - Footer

    private string? BlockingProblem()
    {
        if (!Elevation.IsElevated)
        {
            return "Administrator rights are needed to erase a drive.";
        }
        if (_template is null) { return "Choose a template."; }
        if (_template.ValidationErrors.Count > 0) { return "Fix the template first."; }
        if (_image is null) { return "Choose a Windows image."; }
        if (_drive is null) { return "Choose a target drive."; }
        if (!_drive.HasRoom(_image.SizeBytes))
        {
            return $"{_drive.DisplayName} is too small for this image.";
        }
        return null;
    }

    private void UpdateFooter()
    {
        string? problem = BlockingProblem();

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        Button cancel = Ui.Button("Cancel", Close);
        Grid.SetColumn(cancel, 0);
        grid.Children.Add(cancel);

        if (problem is not null)
        {
            StackPanel notice = Ui.Row(8,
                Ui.Icon(Glyphs.Warning, 14, "WarningBrush"),
                Ui.Caption(problem).Also(text =>
                {
                    text.Themed(TextBlock.ForegroundProperty, "WarningBrush");
                    text.MaxWidth = 400;
                }));
            notice.HorizontalAlignment = HorizontalAlignment.Right;
            notice.Margin = new Thickness(14, 0, 14, 0);
            Grid.SetColumn(notice, 1);
            grid.Children.Add(notice);
        }

        StackPanel actions = Ui.Row(8);
        if (!Elevation.IsElevated)
        {
            actions.Children.Add(Ui.ShieldButton("Restart as Administrator", () =>
            {
                if (Elevation.RelaunchElevated()) { Application.Current.Shutdown(); }
            }));
        }
        Button start = Ui.Button("Erase & Build", Confirm, "AccentButton");
        start.IsEnabled = problem is null;
        actions.Children.Add(start);
        Grid.SetColumn(actions, 2);
        grid.Children.Add(actions);

        _footer.Content = grid;
    }

    private void Confirm()
    {
        if (_drive is null || _image is null || _template is null) { return; }

        MessageBoxResult answer = MessageBox.Show(
            this,
            $"Everything on {_drive.DisplayName} ({Formatting.ByteSize(_drive.SizeBytes)}) will be "
            + "destroyed.\n\n"
            + "The finished drive will hold this template's passwords in clear text — that is how "
            + "Windows Setup reads them, so treat it like a key.\n\n"
            + "Erase the drive and build?",
            $"Erase {_drive.DisplayName}?",
            MessageBoxButton.OKCancel,
            MessageBoxImage.Warning,
            MessageBoxResult.Cancel);
        if (answer != MessageBoxResult.OK) { return; }

        _job = _state.RunBuild(_template, _image, _drive);
        _job.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(new Action(UpdateProgress));
        ShowProgress();
        _tick.Start();
    }

    // MARK: - Progress

    private void ShowProgress()
    {
        if (_job is null) { return; }
        _headerTitle.Text = "Building";
        _headerSubtitle.Text = $"{_job.TemplateName} → {_job.DriveName}";

        _headline = Ui.Text(_job.Detail);
        _headline.FontWeight = FontWeights.Medium;
        _overall = Ui.Progress();

        var summary = new StackPanel();
        summary.Children.Add(_headline);
        summary.Children.Add(_overall.Spaced(0, 9, 0, 0));

        var stages = new StackPanel();
        _stageRows.Clear();
        foreach (BuildJob.Stage stage in BuildJob.AllStages)
        {
            System.Windows.Shapes.Path icon = Ui.Icon(Glyphs.Circle, 15, "TextTertiary", thickness: 1.4);
            icon.VerticalAlignment = VerticalAlignment.Center;
            icon.Margin = new Thickness(0, 0, 10, 0);
            var title = new TextBlock
            {
                Text = BuildJob.Title(stage),
                VerticalAlignment = VerticalAlignment.Center,
            };
            title.Themed(TextBlock.ForegroundProperty, "TextTertiary");
            var detail = new TextBlock
            {
                FontSize = 12,
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Right,
            };
            detail.Themed(TextBlock.ForegroundProperty, "TextTertiary");

            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(icon, 0);
            grid.Children.Add(icon);
            Grid.SetColumn(title, 1);
            grid.Children.Add(title);
            Grid.SetColumn(detail, 2);
            grid.Children.Add(detail);
            grid.Margin = new Thickness(0, 4, 0, 4);

            stages.Children.Add(grid);
            _stageRows[stage] = (icon, title, detail);
        }

        (Border host, TextBox box) = Ui.LogPane(210);
        _log = box;

        var column = Ui.Column(8,
            Ui.Card(summary, 14),
            Ui.Card(stages, 12),
            host);

        _progressRoot = new Grid();
        _progressRoot.Children.Add(Ui.Scroll(column, 16));
        _body.Content = _progressRoot;

        UpdateProgress();
    }

    private void UpdateProgress()
    {
        if (_job is null) { return; }

        if (_overall is not null) { _overall.Value = _job.OverallProgress; }
        if (_headline is not null)
        {
            _headline.Text = _job.CurrentPhase switch
            {
                BuildJob.Phase.Succeeded => $"{_job.TemplateName} written to {_job.DriveName}",
                BuildJob.Phase.Failed => "Stopped",
                BuildJob.Phase.Cancelled => "Cancelled",
                BuildJob.Phase.Idle => "Waiting",
                _ => _job.Detail,
            };
        }

        DateTime now = DateTime.Now;
        foreach (BuildJob.Stage stage in BuildJob.AllStages)
        {
            if (!_stageRows.TryGetValue(stage, out var row)) { continue; }
            BuildJob.StageState state = _job.StateOf(stage);

            (System.Windows.Media.Geometry glyph, string brush, string titleBrush) = state switch
            {
                BuildJob.StageState.Done => (Glyphs.Success, "SuccessBrush", "TextPrimary"),
                BuildJob.StageState.Running => (Glyphs.ChevronRight, "AccentBrush", "TextPrimary"),
                BuildJob.StageState.Failed => (Glyphs.Error, "DangerBrush", "TextPrimary"),
                BuildJob.StageState.Skipped => (Glyphs.Minus, "TextTertiary", "TextSecondary"),
                _ => (Glyphs.Circle, "TextTertiary", "TextTertiary"),
            };
            row.Icon.Data = glyph;
            row.Icon.SetResourceReference(System.Windows.Shapes.Path.StrokeProperty, brush);
            row.Title.SetResourceReference(TextBlock.ForegroundProperty, titleBrush);

            var parts = new List<string>();
            TimeSpan? took = _job.DurationOf(stage, now);
            if (took is not null && took.Value.TotalSeconds >= 1)
            {
                parts.Add(Formatting.ShortDuration(took.Value));
            }
            if (state == BuildJob.StageState.Running && _job.StageProgress is double fraction)
            {
                parts.Add($"{(int)(fraction * 100)}%");
            }
            if (state == BuildJob.StageState.Skipped) { parts.Add(_job.NoteOf(stage)); }
            if (state == BuildJob.StageState.Failed) { parts.Add("Failed"); }
            row.Detail.Text = string.Join(" · ", parts);
        }

        if (_log is not null)
        {
            string text = _job.LogText;
            if (_log.Text != text)
            {
                _log.Text = text;
                _log.ScrollToEnd();
            }
        }

        if (!_job.IsRunning && _job.CurrentPhase != BuildJob.Phase.Idle)
        {
            _tick.Stop();
            Celebrate();
        }
        UpdateProgressFooter();
    }

    private void Celebrate()
    {
        if (_celebrated || _job?.CurrentPhase != BuildJob.Phase.Succeeded) { return; }
        _celebrated = true;
        if (_progressRoot is null) { return; }
        var confetti = new Confetti(Environment.TickCount, ActualWidth, 420)
        {
            VerticalAlignment = VerticalAlignment.Top,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Height = 420,
        };
        _progressRoot.Children.Add(confetti);
    }

    private void UpdateProgressFooter()
    {
        if (_job is null) { return; }

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        if (_job.IsRunning || _job.CurrentPhase == BuildJob.Phase.Idle)
        {
            Button cancel = Ui.Button("Cancel Build", () =>
            {
                _job.Cancel();
                UpdateProgressFooter();
            }, "DangerButton");
            cancel.IsEnabled = !_job.CancelRequested;
            Grid.SetColumn(cancel, 0);
            grid.Children.Add(cancel);

            var detail = new TextBlock
            {
                Text = _job.CancelRequested ? "Cancelling…" : _job.Detail,
                FontSize = 12,
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(14, 0, 0, 0),
            };
            detail.Themed(TextBlock.ForegroundProperty, "TextSecondary");
            Grid.SetColumn(detail, 1);
            grid.Children.Add(detail);
        }
        else
        {
            Button copy = Ui.Button("Copy Log", () =>
            {
                try
                {
                    Clipboard.SetText(_job.LogText);
                    Notifier.Banner("Build log copied");
                }
                catch (Exception error)
                {
                    Notifier.Banner("Couldn't copy", error.Message, BannerKind.Error);
                }
            });
            Grid.SetColumn(copy, 0);
            grid.Children.Add(copy);

            Button done = Ui.Button("Done", Close, "AccentButton");
            done.IsDefault = true;
            Grid.SetColumn(done, 2);
            grid.Children.Add(done);
        }

        _footer.Content = grid;
    }
}
