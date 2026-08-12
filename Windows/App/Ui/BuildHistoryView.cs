using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using ImageHub.Models;
using ImageHub.Services;
using ImageHub.Support;
using ImageHub.ViewModels;

namespace ImageHub.Views;

/// <summary>
/// Build History: every drive written in this session, each with its full log.
///
/// The log is the point. A machine handed over last week that turns out wrong is
/// diagnosed from what the build actually did, not from what the template says now.
/// </summary>
public sealed class BuildHistoryView : UserControl, IRefreshable
{
    private readonly AppState _state = AppState.Shared;
    private readonly StackPanel _body = new();
    private readonly MainWindow _window;
    private Guid? _expanded;

    public BuildHistoryView(MainWindow window)
    {
        _window = window;
        Content = Ui.Page(
            Ui.PageHeader("Build History", null,
                Ui.Button("Clear", () =>
                {
                    _state.ClearFinishedHistory();
                    Refresh();
                })),
            Ui.Scroll(_body));
        Refresh();
    }

    public void Refresh()
    {
        _body.Children.Clear();

        if (_state.History.Count == 0)
        {
            _body.Children.Add(Ui.EmptyState(
                Glyphs.Circle,
                "No builds yet",
                "Every drive you write shows up here with its full log, so you can see exactly what "
                + "happened on a machine you handed over last week.",
                Ui.Button("Build USB Drive", () => _window.StartBuild(null), "AccentButton")));
            return;
        }

        foreach (BuildJob job in _state.History)
        {
            _body.Children.Add(HistoryCard(job));
        }
    }

    private UIElement HistoryCard(BuildJob job)
    {
        bool expanded = _expanded == job.Id;

        Border summary = BuildRow.Card(job, () =>
        {
            _expanded = expanded ? null : job.Id;
            Refresh();
        });
        summary.Margin = new Thickness(0, 0, 0, expanded ? 0 : 6);
        if (expanded) { summary.CornerRadius = new CornerRadius(8, 8, 0, 0); }

        if (!expanded) { return summary; }

        (Border host, TextBox box) = Ui.LogPane(240);
        box.Text = job.LogText;
        box.TextChanged += (_, _) => box.ScrollToEnd();
        box.ScrollToEnd();

        var detail = new List<UIElement?>
        {
            job.StartedAt is null ? null : Ui.Caption("Started " + Formatting.Brief(job.StartedAt.Value)),
            job.FailureMessage.Length == 0
                ? null
                : Ui.Banner(BannerKind.Error, "Build failed", job.FailureMessage),
            host,
            Ui.Row(8,
                Ui.Button("Copy Log", () =>
                {
                    try
                    {
                        Clipboard.SetText(job.LogText);
                        Notifier.Banner("Build log copied");
                    }
                    catch (Exception error)
                    {
                        Notifier.Banner("Couldn't copy", error.Message, BannerKind.Error);
                    }
                }),
                Ui.Button("Save Log…", () => SaveLog(job))),
        };

        Border body = Ui.Card(Ui.Column(9, detail.ToArray()), 14);
        body.CornerRadius = new CornerRadius(0, 0, 8, 8);
        body.BorderThickness = new Thickness(1, 0, 1, 1);
        body.Margin = new Thickness(0, 0, 0, 6);

        return Ui.Column(0, summary, body);
    }

    private void SaveLog(BuildJob job)
    {
        string stamp = (job.StartedAt ?? DateTime.Now).ToString("yyyy-MM-dd-HHmm");
        string name = $"ImageHub-{job.TemplateName}-{stamp}.log"
            .Replace('/', '-')
            .Replace('\\', '-');
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = "Save Build Log",
            FileName = name,
            Filter = "Log file (*.log)|*.log|Text file (*.txt)|*.txt",
            InitialDirectory = AppPaths.Logs,
        };
        if (dialog.ShowDialog(_window) != true) { return; }
        try
        {
            File.WriteAllText(dialog.FileName, job.LogText);
            Notifier.Banner("Log saved", Path.GetFileName(dialog.FileName));
        }
        catch (Exception error)
        {
            Notifier.Banner("Couldn't save the log", error.Message, BannerKind.Error);
        }
    }
}
