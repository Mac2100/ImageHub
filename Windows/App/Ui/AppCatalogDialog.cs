using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using ImageHub.Services;

namespace ImageHub.Views;

/// <summary>
/// The application catalog: a shortlist of winget packages IT departments actually
/// deploy, so the common case is a click instead of typing a package ID from memory.
///
/// A convenience, not a limit — any winget ID can still be typed into the Apps tab.
/// </summary>
public sealed class AppCatalogDialog : ThemedWindow
{
    private readonly HashSet<string> _alreadyAdded;
    private readonly HashSet<string> _selected = new(StringComparer.Ordinal);
    private readonly StackPanel _list = new();
    private readonly TextBlock _count = new();
    private string _search = string.Empty;

    public AppCatalogDialog(Window owner, IEnumerable<string> alreadyAdded)
    {
        Title = "Application catalog";
        ConfigureAsDialog(owner, 640, 620);
        _alreadyAdded = new HashSet<string>(alreadyAdded, StringComparer.Ordinal);

        Grid search = Ui.Field(() => _search, text =>
        {
            _search = text;
            RefreshList();
        }, "Search packages", 240);

        var header = new Border
        {
            Padding = new Thickness(14, 11, 14, 11),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Child = Ui.Row(12, Ui.Subheading("Application catalog"), search),
        };
        header.Themed(Border.BackgroundProperty, "BarBg");
        header.Themed(Border.BorderBrushProperty, "DividerBrush");

        _count.FontSize = 12;
        _count.VerticalAlignment = VerticalAlignment.Center;
        _count.Themed(TextBlock.ForegroundProperty, "TextSecondary");

        Button add = Ui.Button("Add", () =>
        {
            DialogResult = true;
            Close();
        }, "AccentButton");
        add.IsDefault = true;

        var footerGrid = new Grid();
        footerGrid.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = new GridLength(1, GridUnitType.Star),
        });
        footerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_count, 0);
        footerGrid.Children.Add(_count);
        StackPanel buttons = Ui.Row(8, Ui.Button("Cancel", Close), add);
        Grid.SetColumn(buttons, 1);
        footerGrid.Children.Add(buttons);

        var footer = new Border
        {
            Padding = new Thickness(14, 11, 14, 12),
            BorderThickness = new Thickness(0, 1, 0, 0),
            Child = footerGrid,
        };
        footer.Themed(Border.BackgroundProperty, "BarBg");
        footer.Themed(Border.BorderBrushProperty, "DividerBrush");

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(header, 0);
        grid.Children.Add(header);
        ScrollViewer scroll = Ui.Scroll(_list, 12);
        Grid.SetRow(scroll, 1);
        grid.Children.Add(scroll);
        Grid.SetRow(footer, 2);
        grid.Children.Add(footer);

        Content = grid;
        RefreshList();
    }

    /// <summary>What the operator ticked, once the dialog closes with Add.</summary>
    public IReadOnlyList<AppCatalog.Entry> Chosen =>
        AppCatalog.Entries.Where(entry => _selected.Contains(entry.Id)).ToList();

    private void RefreshList()
    {
        _list.Children.Clear();
        IReadOnlyList<AppCatalog.Entry> matches = AppCatalog.Search(_search);

        bool any = false;
        foreach (string category in AppCatalog.Categories)
        {
            List<AppCatalog.Entry> entries = matches.Where(entry => entry.Category == category).ToList();
            if (entries.Count == 0) { continue; }
            any = true;

            TextBlock header = Ui.Caption(category);
            header.FontWeight = FontWeights.SemiBold;
            header.Margin = new Thickness(2, 12, 0, 5);
            _list.Children.Add(header);

            foreach (AppCatalog.Entry entry in entries)
            {
                _list.Children.Add(Row(entry));
            }
        }

        if (!any)
        {
            _list.Children.Add(Ui.EmptyState(Glyphs.Search, "No matches",
                $"Nothing in the catalog matches “{_search}”. Any winget package ID can still be "
                + "typed in by hand — the catalog is only a shortcut."));
        }

        UpdateCount();
    }

    private UIElement Row(AppCatalog.Entry entry)
    {
        bool added = _alreadyAdded.Contains(entry.Id);
        bool selected = _selected.Contains(entry.Id);

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        System.Windows.Shapes.Path tick = Ui.Icon(
            added || selected ? Glyphs.Success : Glyphs.Circle, 17,
            added ? "SuccessBrush" : selected ? "AccentBrush" : "TextTertiary", thickness: 1.5);
        tick.VerticalAlignment = VerticalAlignment.Center;
        tick.Margin = new Thickness(0, 0, 11, 0);
        Grid.SetColumn(tick, 0);
        grid.Children.Add(tick);

        StackPanel text = Ui.Column(1, Ui.Text(entry.Name), Ui.Mono(entry.Id));
        text.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        if (added)
        {
            Border chip = Ui.Chip("In template", "SuccessBrush");
            Grid.SetColumn(chip, 2);
            grid.Children.Add(chip);
        }
        else if (entry.Note.Length > 0)
        {
            TextBlock note = Ui.Hint(entry.Note);
            note.MaxWidth = 200;
            note.TextAlignment = TextAlignment.Right;
            note.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(note, 2);
            grid.Children.Add(note);
        }

        var card = new Border
        {
            Child = grid,
            Padding = new Thickness(11, 8, 11, 9),
            CornerRadius = new CornerRadius(6),
            Margin = new Thickness(0, 0, 0, 3),
            Opacity = added ? 0.6 : 1,
        };
        if (selected) { card.Background = Ui.Tint("AccentBrush", 0.09); }

        if (!added)
        {
            card.Cursor = System.Windows.Input.Cursors.Hand;
            card.MouseLeftButtonUp += (_, _) =>
            {
                if (!_selected.Add(entry.Id)) { _selected.Remove(entry.Id); }
                RefreshList();
            };
        }
        else
        {
            card.ToolTip = "Already in this template";
        }
        return card;
    }

    private void UpdateCount() =>
        _count.Text = _selected.Count == 0 ? "Nothing selected" : $"{_selected.Count} selected";
}
