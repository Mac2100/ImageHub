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
/// The Templates page: the list on the left, the editor on the right.
///
/// The same two-pane shape as the macOS app, which is also how Windows tools from
/// Task Scheduler to Group Policy Editor lay this out.
/// </summary>
public sealed class TemplatesView : UserControl, IRefreshable
{
    private readonly MainWindow _window;
    private readonly AppState _state = AppState.Shared;
    private readonly ListBox _list = new();
    private readonly ContentControl _detail = new();
    private readonly Grid _search;
    private string _filter = string.Empty;
    private bool _selecting;
    private Guid? _editorFor;

    public TemplatesView(MainWindow window)
    {
        _window = window;

        _search = Ui.Field(() => _filter, text =>
        {
            _filter = text;
            RefreshList();
        }, "Filter templates");
        _search.Margin = new Thickness(10, 10, 10, 8);

        _list.SelectionChanged += (_, _) =>
        {
            if (_selecting) { return; }
            if (_list.SelectedItem is ListBoxItem { Tag: Guid id })
            {
                _state.SelectedTemplateId = id;
                ShowEditor();
            }
        };

        var left = new Grid();
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(_search, 0);
        left.Children.Add(_search);
        Grid.SetRow(_list, 1);
        left.Children.Add(_list);
        UIElement toolbar = Toolbar();
        Grid.SetRow(toolbar, 2);
        left.Children.Add(toolbar);

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(276) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        Grid.SetColumn(left, 0);
        grid.Children.Add(left);

        var line = new Border { Width = 1 };
        line.Themed(Border.BackgroundProperty, "DividerBrush");
        Grid.SetColumn(line, 1);
        grid.Children.Add(line);

        Grid.SetColumn(_detail, 2);
        grid.Children.Add(_detail);

        Content = grid;
        Refresh();
    }

    public void Refresh()
    {
        RefreshList();
        ShowEditor();
    }

    private IEnumerable<DeploymentTemplate> Filtered()
    {
        IReadOnlyList<DeploymentTemplate> all = _state.Templates.Templates;
        if (_filter.Trim().Length == 0) { return all; }
        string needle = _filter.Trim();
        return all.Where(template =>
            template.Name.Contains(needle, StringComparison.CurrentCultureIgnoreCase)
            || template.Summary.Contains(needle, StringComparison.CurrentCultureIgnoreCase)
            || template.Apps.Any(app =>
                app.DisplayName.Contains(needle, StringComparison.CurrentCultureIgnoreCase)));
    }

    private void RefreshList()
    {
        _selecting = true;
        _list.Items.Clear();
        foreach (DeploymentTemplate template in Filtered())
        {
            _list.Items.Add(TemplateRow(template));
        }
        foreach (object candidate in _list.Items)
        {
            if (candidate is ListBoxItem { Tag: Guid id } item && id == _state.SelectedTemplateId)
            {
                _list.SelectedItem = item;
                break;
            }
        }
        _selecting = false;
    }

    private ListBoxItem TemplateRow(DeploymentTemplate template)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        System.Windows.Shapes.Path icon = Ui.Icon(
            Glyphs.ForTemplateSymbol(template.Symbol), 18, "AccentBrush", thickness: 1.4);
        icon.VerticalAlignment = VerticalAlignment.Center;
        icon.Margin = new Thickness(0, 0, 10, 0);
        Grid.SetColumn(icon, 0);
        grid.Children.Add(icon);

        var name = new TextBlock
        {
            Text = template.Name,
            FontWeight = FontWeights.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var subtitle = new TextBlock
        {
            Text = template.Subtitle,
            FontSize = 12,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        subtitle.Themed(TextBlock.ForegroundProperty, "TextSecondary");
        StackPanel text = Ui.Column(1, name, subtitle);
        text.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        if (!template.IsBuildable)
        {
            System.Windows.Shapes.Path warning = Ui.Icon(Glyphs.Warning, 15, "WarningBrush");
            warning.VerticalAlignment = VerticalAlignment.Center;
            warning.ToolTip = string.Join("\n", template.ValidationErrors);
            Grid.SetColumn(warning, 2);
            grid.Children.Add(warning);
        }

        var item = new ListBoxItem { Content = grid, Tag = template.Id, Padding = new Thickness(8, 8, 8, 8) };

        var menu = new ContextMenu();
        menu.Items.Add(MenuItemFor("Build USB Drive…", () => _window.StartBuild(template)));
        menu.Items.Add(MenuItemFor("Duplicate", () =>
        {
            DeploymentTemplate copy = _state.Templates.Duplicate(template);
            _state.SelectedTemplateId = copy.Id;
            Refresh();
        }));
        menu.Items.Add(MenuItemFor("Export…", () => Export(template)));
        menu.Items.Add(new Separator());
        menu.Items.Add(MenuItemFor("Delete…", () => Delete(template)));
        item.ContextMenu = menu;

        return item;
    }

    private static MenuItem MenuItemFor(string header, Action action)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => action();
        return item;
    }

    private UIElement Toolbar()
    {
        var bar = new Border
        {
            Padding = new Thickness(7, 6, 7, 7),
            BorderThickness = new Thickness(0, 1, 0, 0),
        };
        bar.Themed(Border.BorderBrushProperty, "DividerBrush");

        StackPanel row = Ui.Row(2,
            Ui.IconButton(Glyphs.Plus, () =>
            {
                DeploymentTemplate template = _state.Templates.NewTemplate();
                _state.SelectedTemplateId = template.Id;
                Refresh();
            }, "New template"),
            Ui.IconButton(Glyphs.Minus, () =>
            {
                if (_state.SelectedTemplate is DeploymentTemplate template) { Delete(template); }
            }, "Delete template"),
            Ui.Button("Duplicate", () =>
            {
                if (_state.SelectedTemplate is not DeploymentTemplate template) { return; }
                DeploymentTemplate copy = _state.Templates.Duplicate(template);
                _state.SelectedTemplateId = copy.Id;
                Refresh();
            }, "SubtleButton"));

        bar.Child = row;
        return bar;
    }

    private void Delete(DeploymentTemplate template)
    {
        MessageBoxResult answer = MessageBox.Show(
            _window,
            $"Delete “{template.Name}”?\n\nIts stored passwords are removed too. This can't be undone.",
            "Delete template",
            MessageBoxButton.OKCancel,
            MessageBoxImage.Warning,
            MessageBoxResult.Cancel);
        if (answer != MessageBoxResult.OK) { return; }
        _state.Templates.Delete(template);
        _state.SelectedTemplateId = _state.Templates.Templates.FirstOrDefault()?.Id;
        _editorFor = null;
        Refresh();
    }

    private void Export(DeploymentTemplate template)
    {
        string name = template.Name.Replace('/', '-').Replace('\\', '-').Trim();
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = "Export Template",
            FileName = (name.Length == 0 ? "Template" : name) + ".json",
            Filter = "ImageHub template (*.json)|*.json",
        };
        if (dialog.ShowDialog(_window) != true) { return; }
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

    private void ShowEditor()
    {
        DeploymentTemplate? template = _state.SelectedTemplate;
        if (template is null)
        {
            _editorFor = null;
            _detail.Content = Ui.EmptyState(
                Glyphs.Box,
                "No template selected",
                "Pick a template on the left, or create one with the + button.",
                Ui.Button("New Template", () =>
                {
                    DeploymentTemplate created = _state.Templates.NewTemplate();
                    _state.SelectedTemplateId = created.Id;
                    Refresh();
                }, "AccentButton"));
            return;
        }

        // Keep the live editor when the selection has not moved, so a list refresh
        // triggered by an autosave does not throw away scroll position or focus.
        if (_editorFor == template.Id && _detail.Content is TemplateEditorView) { return; }
        _editorFor = template.Id;
        _detail.Content = new TemplateEditorView(_window, template, RefreshList);
    }
}
