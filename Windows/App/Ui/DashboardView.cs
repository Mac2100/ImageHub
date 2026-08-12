using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using ImageHub.Models;
using ImageHub.Services;
using ImageHub.Support;
using ImageHub.ViewModels;

namespace ImageHub.Views;

/// <summary>
/// The Overview page: what still has to be set up before a drive can be built, and
/// what has been built recently.
///
/// The checklist has one more item than the macOS app's — administrator rights — and
/// one fewer: nothing to install for splitting an oversized install.wim, because DISM
/// is already here.
/// </summary>
public sealed class DashboardView : UserControl, IRefreshable
{
    private readonly MainWindow _window;
    private readonly AppState _state = AppState.Shared;
    private readonly StackPanel _body = new();

    public DashboardView(MainWindow window)
    {
        _window = window;
        Content = Ui.Page(
            Ui.PageHeader("Overview", "Wipe a machine, build the drive, reimage from a template.",
                Ui.Button("Build USB Drive", () => _window.StartBuild(null), "AccentButton")),
            Ui.Scroll(_body));
        Refresh();
    }

    public void Refresh()
    {
        AppState.ReadinessReport readiness = _state.Readiness;
        _body.Children.Clear();

        _body.Children.Add(Hero(readiness));
        _body.Children.Add(Checklist(readiness));
        if (_state.History.Count > 0) { _body.Children.Add(RecentBuilds()); }
        _body.Children.Add(Stats());
    }

    private UIElement Hero(AppState.ReadinessReport readiness)
    {
        var mark = new System.Windows.Shapes.Path
        {
            Data = Glyphs.Drive,
            Stretch = System.Windows.Media.Stretch.Uniform,
            Width = 44,
            Height = 44,
            StrokeThickness = 1.2,
            VerticalAlignment = VerticalAlignment.Top,
        };
        mark.Themed(System.Windows.Shapes.Path.StrokeProperty, "AccentBrush");

        TextBlock heading = Ui.Heading(readiness.IsReady
            ? "Ready to build"
            : "A couple of things to set up");
        TextBlock body = Ui.Caption(readiness.IsReady
            ? "Pick a template, choose the drive, and ImageHub does the rest — wipe, write, and "
              + "stage the provisioning payload."
            : "Work through the checklist below and the build button lights up.");
        body.MaxWidth = 640;

        StackPanel row = Ui.Row(16, mark, Ui.Column(5, heading, body));
        row.VerticalAlignment = VerticalAlignment.Top;
        Border card = Ui.Card(row, 18);
        card.Margin = new Thickness(0, 0, 0, 6);
        return card;
    }

    private UIElement Checklist(AppState.ReadinessReport readiness)
    {
        int buildable = _state.Templates.Templates.Count(template => template.IsBuildable);
        int usable = _state.Library.Images.Count(image => image.FileExists);

        return Ui.Group("Getting ready",
            ChecklistRow(
                readiness.HasTemplate,
                "A buildable deployment template",
                readiness.HasTemplate
                    ? $"{buildable} of {_state.Templates.Templates.Count} templates are complete."
                    : "Templates need at least a name and an admin password.",
                "Templates",
                () => _state.CurrentSection = Section.Templates),
            ChecklistRow(
                readiness.HasImage,
                "A Windows image in the library",
                readiness.HasImage
                    ? $"{Formatting.Plural(usable, "image")}, "
                      + $"{Formatting.ByteSize(_state.Library.TotalBytesOnDisk)} on disk."
                    : "Get the ISO from Microsoft in your browser, then import it.",
                "Images",
                () => _state.CurrentSection = Section.Images),
            ChecklistRow(
                readiness.HasDrive,
                "A USB drive plugged in",
                readiness.HasDrive
                    ? string.Join(", ", _state.Drives.Select(drive => drive.DisplayName))
                    : "Plug in a 16 GB or larger stick. Internal disks are never offered.",
                "Drives",
                () => _state.CurrentSection = Section.Drives),
            ChecklistRow(
                readiness.IsElevated,
                "Administrator rights",
                readiness.IsElevated
                    ? "ImageHub is running elevated, so it can erase a drive and mount an ISO."
                    : "Erasing a drive and mounting an ISO both need them. Everything else doesn't, "
                      + "which is why ImageHub doesn't ask at launch.",
                readiness.IsElevated ? null : "Restart as Administrator",
                () =>
                {
                    if (Elevation.RelaunchElevated()) { Application.Current.Shutdown(); }
                },
                shield: true));
    }

    private UIElement ChecklistRow(
        bool done,
        string title,
        string detail,
        string? actionTitle,
        Action action,
        bool shield = false)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        System.Windows.Shapes.Path tick = Ui.Icon(
            done ? Glyphs.Success : Glyphs.Circle, 18,
            done ? "SuccessBrush" : "TextTertiary", thickness: 1.5);
        tick.VerticalAlignment = VerticalAlignment.Center;
        tick.Margin = new Thickness(0, 0, 12, 0);
        Grid.SetColumn(tick, 0);
        grid.Children.Add(tick);

        StackPanel text = Ui.Column(2, Ui.Text(title), Ui.Caption(detail));
        text.VerticalAlignment = VerticalAlignment.Center;
        text.Margin = new Thickness(0, 0, 14, 0);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        if (actionTitle is not null)
        {
            Button button = shield
                ? Ui.ShieldButton(actionTitle, action)
                : Ui.Button(actionTitle, action);
            button.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(button, 2);
            grid.Children.Add(button);
        }

        Border card = Ui.Card(grid, 0);
        card.Padding = new Thickness(14, 12, 14, 12);
        card.Margin = new Thickness(0, 0, 0, 6);
        return card;
    }

    private UIElement RecentBuilds()
    {
        var rows = new System.Collections.Generic.List<UIElement?>();
        foreach (BuildJob job in _state.History.Take(3))
        {
            rows.Add(BuildRow.Card(job, () => _state.CurrentSection = Section.Builds));
        }
        rows.Add(Ui.Button("See all builds", () => _state.CurrentSection = Section.Builds, "LinkButton"));
        return Ui.Group("Recent builds", rows.ToArray());
    }

    private UIElement Stats()
    {
        var grid = new Grid { Margin = new Thickness(0, 4, 0, 0) };
        for (int i = 0; i < 4; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        }

        (string Value, string Label)[] stats =
        {
            (_state.Templates.Templates.Count.ToString(), "Templates"),
            (_state.Library.Images.Count.ToString(), "Images"),
            (Formatting.ByteSize(_state.Library.TotalBytesOnDisk), "On disk"),
            (_state.Drives.Count.ToString(), "USB drives"),
        };

        for (int i = 0; i < stats.Length; i++)
        {
            var value = new TextBlock
            {
                Text = stats[i].Value,
                FontSize = 19,
                FontWeight = FontWeights.SemiBold,
            };
            value.Themed(TextBlock.ForegroundProperty, "TextPrimary");
            Border card = Ui.Card(Ui.Column(3, value, Ui.Caption(stats[i].Label)), 14);
            card.Margin = new Thickness(i == 0 ? 0 : 3, 0, i == stats.Length - 1 ? 0 : 3, 0);
            Grid.SetColumn(card, i);
            grid.Children.Add(card);
        }
        return grid;
    }
}

/// <summary>One row describing a build: state, names, elapsed time. Shared by two pages.</summary>
public static class BuildRow
{
    public static Border Card(BuildJob job, Action? click = null)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        System.Windows.Shapes.Path icon = Ui.Icon(GlyphFor(job), 17, BrushFor(job), thickness: 1.5);
        icon.VerticalAlignment = VerticalAlignment.Center;
        icon.Margin = new Thickness(0, 0, 12, 0);
        Grid.SetColumn(icon, 0);
        grid.Children.Add(icon);

        StackPanel text = Ui.Column(2,
            Ui.Text(job.TemplateName),
            Ui.Caption("→ " + job.DriveName));
        text.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        var state = new TextBlock
        {
            Text = StateLabel(job),
            FontSize = 12,
            FontWeight = FontWeights.Medium,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        state.Themed(TextBlock.ForegroundProperty, BrushFor(job));
        StackPanel right = Ui.Column(2, state,
            job.Elapsed is null
                ? null
                : Ui.Hint(Formatting.ShortDuration(job.Elapsed.Value)));
        right.VerticalAlignment = VerticalAlignment.Center;
        right.HorizontalAlignment = HorizontalAlignment.Right;
        Grid.SetColumn(right, 2);
        grid.Children.Add(right);

        Border card = Ui.Card(grid, 0);
        card.Padding = new Thickness(14, 11, 14, 11);
        card.Margin = new Thickness(0, 0, 0, 6);
        if (click is not null)
        {
            card.Cursor = System.Windows.Input.Cursors.Hand;
            card.MouseLeftButtonUp += (_, _) => click();
        }
        return card;
    }

    public static System.Windows.Media.Geometry GlyphFor(BuildJob job) => job.CurrentPhase switch
    {
        BuildJob.Phase.Succeeded => Glyphs.Success,
        BuildJob.Phase.Failed => Glyphs.Error,
        BuildJob.Phase.Cancelled => Glyphs.Minus,
        _ => Glyphs.Circle,
    };

    public static string BrushFor(BuildJob job) => job.CurrentPhase switch
    {
        BuildJob.Phase.Succeeded => "SuccessBrush",
        BuildJob.Phase.Failed => "DangerBrush",
        BuildJob.Phase.Cancelled => "WarningBrush",
        _ => "TextSecondary",
    };

    public static string StateLabel(BuildJob job) => job.CurrentPhase switch
    {
        BuildJob.Phase.Idle => "Queued",
        BuildJob.Phase.Running => $"{(int)(job.OverallProgress * 100)}%",
        BuildJob.Phase.Succeeded => "Ready",
        BuildJob.Phase.Failed => "Failed",
        BuildJob.Phase.Cancelled => "Cancelled",
        _ => string.Empty,
    };
}
