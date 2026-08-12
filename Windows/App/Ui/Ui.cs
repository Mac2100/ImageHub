using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Shapes;
using ImageHub.Services;

namespace ImageHub.Views;

/// <summary>
/// The small vocabulary the views are written in.
///
/// The views are built in C# rather than XAML on purpose. A XAML binding path that
/// does not resolve fails silently at runtime — the control just shows nothing — and
/// this app is a tool that erases disks, so "compiles but quietly does the wrong
/// thing" is the failure mode worth designing out. Building in code means every
/// getter and setter is checked by the compiler.
///
/// Appearance still comes from Themes/*.xaml: the implicit control styles apply to
/// code-created controls exactly as they would in markup, and anything custom here
/// takes its colours through SetResourceReference so a theme swap reaches it too.
/// </summary>
public static class Ui
{
    public const double RowLabelWidth = 260;

    // MARK: - Resources

    public static Brush Brush(string key)
    {
        object? found = Application.Current?.TryFindResource(key);
        return found as Brush ?? Brushes.Gray;
    }

    /// <summary>Points a property at a theme resource, so it follows a light/dark swap.</summary>
    public static T Themed<T>(this T element, DependencyProperty property, string key)
        where T : FrameworkElement
    {
        element.SetResourceReference(property, key);
        return element;
    }

    public static T Styled<T>(this T element, string styleKey) where T : FrameworkElement
    {
        element.SetResourceReference(FrameworkElement.StyleProperty, styleKey);
        return element;
    }

    /// <summary>
    /// Sets margins. Not called Margin: member lookup finds the property of that name
    /// first, and an extension method cannot shadow it.
    /// </summary>
    public static T Spaced<T>(this T element, double left, double top, double right, double bottom)
        where T : FrameworkElement
    {
        element.Margin = new Thickness(left, top, right, bottom);
        return element;
    }

    public static T Tip<T>(this T element, string? tooltip) where T : FrameworkElement
    {
        if (!string.IsNullOrEmpty(tooltip)) { element.ToolTip = tooltip; }
        return element;
    }

    public static T Grow<T>(this T element) where T : FrameworkElement
    {
        element.HorizontalAlignment = HorizontalAlignment.Stretch;
        return element;
    }

    // MARK: - Text

    public static TextBlock Text(string text, string style = "BodyText") =>
        new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap }.Styled(style);

    public static TextBlock Caption(string text) => Text(text, "CaptionText");

    public static TextBlock Hint(string text) => Text(text, "HintText");

    public static TextBlock Heading(string text) => Text(text, "HeadingText");

    public static TextBlock Subheading(string text) => Text(text, "SubheadingText");

    public static TextBlock Title(string text) => Text(text, "TitleText");

    public static TextBlock Mono(string text) =>
        new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap }.Styled("MonoText");

    // MARK: - Layout

    public static StackPanel Stack(Orientation orientation, double spacing, params UIElement?[] children)
    {
        var panel = new StackPanel { Orientation = orientation };
        Add(panel, spacing, children);
        return panel;
    }

    public static StackPanel Column(double spacing, params UIElement?[] children) =>
        Stack(Orientation.Vertical, spacing, children);

    public static StackPanel Row(double spacing, params UIElement?[] children)
    {
        StackPanel panel = Stack(Orientation.Horizontal, spacing, children);
        panel.VerticalAlignment = VerticalAlignment.Center;
        return panel;
    }

    private static void Add(StackPanel panel, double spacing, UIElement?[] children)
    {
        bool horizontal = panel.Orientation == Orientation.Horizontal;
        bool first = true;
        foreach (UIElement? child in children)
        {
            if (child is null) { continue; }
            if (!first && child is FrameworkElement element)
            {
                Thickness margin = element.Margin;
                element.Margin = horizontal
                    ? new Thickness(margin.Left + spacing, margin.Top, margin.Right, margin.Bottom)
                    : new Thickness(margin.Left, margin.Top + spacing, margin.Right, margin.Bottom);
            }
            panel.Children.Add(child);
            first = false;
        }
    }

    public static Border Card(UIElement content, double padding = 16)
    {
        var border = new Border { Child = content, Padding = new Thickness(padding) };
        return border.Styled("Card");
    }

    public static Border Inset(UIElement content, double padding = 10)
    {
        var border = new Border { Child = content, Padding = new Thickness(padding) };
        return border.Styled("Inset");
    }

    public static Border Divider() =>
        new Border { Height = 1, SnapsToDevicePixels = true }
            .Themed(Border.BackgroundProperty, "DividerBrush");

    public static ScrollViewer Scroll(UIElement content, double padding = 20) => new()
    {
        Content = new Border { Child = content, Padding = new Thickness(padding) },
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Padding = new Thickness(0),
        Focusable = false,
    };

    /// <summary>
    /// One settings row: name and optional explanation on the left, the control on the
    /// right, in its own card. Windows 11's Settings does it this way, and giving each
    /// row its own card means a row that hides itself leaves no gap or stray divider.
    /// </summary>
    public static Border Setting(string label, UIElement? control, string? help = null)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        StackPanel text = Column(2, Text(label), help is null ? null : Caption(help));
        text.VerticalAlignment = VerticalAlignment.Center;
        text.Margin = new Thickness(0, 0, 16, 0);
        Grid.SetColumn(text, 0);
        grid.Children.Add(text);

        if (control is not null)
        {
            if (control is FrameworkElement element)
            {
                element.VerticalAlignment = VerticalAlignment.Center;
                element.HorizontalAlignment = HorizontalAlignment.Right;
            }
            Grid.SetColumn(control, 1);
            grid.Children.Add(control);
        }

        Border card = Card(grid, 0);
        card.Padding = new Thickness(14, 11, 14, 11);
        card.Margin = new Thickness(0, 0, 0, 6);
        return card;
    }

    /// <summary>A row whose control spans the full width, for editors and lists.</summary>
    public static Border Wide(string? label, UIElement content, string? help = null)
    {
        StackPanel column = Column(8,
            label is null ? null : Subheading(label),
            help is null ? null : Caption(help),
            content);
        Border card = Card(column, 0);
        card.Padding = new Thickness(14, 12, 14, 13);
        card.Margin = new Thickness(0, 0, 0, 6);
        return card;
    }

    public static StackPanel Group(string? header, params UIElement?[] rows)
    {
        var panel = new StackPanel();
        if (header is not null)
        {
            TextBlock title = Subheading(header);
            title.Margin = new Thickness(2, 10, 0, 7);
            panel.Children.Add(title);
        }
        foreach (UIElement? row in rows)
        {
            if (row is not null) { panel.Children.Add(row); }
        }
        return panel;
    }

    // MARK: - Icons and chips

    public static Path Icon(Geometry geometry, double size = 16, string brushKey = "TextSecondary",
        bool filled = false, double thickness = 1.6)
    {
        var path = new Path
        {
            Data = geometry,
            Stretch = Stretch.Uniform,
            Width = size,
            Height = size,
            StrokeThickness = thickness,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round,
            SnapsToDevicePixels = false,
        };
        path.Themed(filled ? Path.FillProperty : Path.StrokeProperty, brushKey);
        return path;
    }

    public static Border Chip(string text, string brushKey = "TextSecondary", Geometry? glyph = null)
    {
        StackPanel content = Row(4,
            glyph is null ? null : Icon(glyph, 11, brushKey, thickness: 1.8),
            new TextBlock { Text = text, FontSize = 11.5, FontWeight = FontWeights.Medium }
                .Themed(TextBlock.ForegroundProperty, brushKey));

        var border = new Border
        {
            Child = content,
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(8, 2, 8, 3),
            VerticalAlignment = VerticalAlignment.Center,
            Background = Tint(brushKey, 0.13),
        };
        return border;
    }

    /// <summary>
    /// A translucent wash of a theme brush, for chip and banner backgrounds. Resolved
    /// once at build time: a theme swap rebuilds these views anyway, and an alpha
    /// blend cannot be expressed as a resource reference.
    /// </summary>
    public static Brush Tint(string brushKey, double alpha)
    {
        if (Brush(brushKey) is SolidColorBrush solid)
        {
            Color color = solid.Color;
            return new SolidColorBrush(Color.FromArgb((byte)(alpha * 255), color.R, color.G, color.B));
        }
        return Brushes.Transparent;
    }

    public static string BrushKeyFor(BannerKind kind) => kind switch
    {
        BannerKind.Success => "SuccessBrush",
        BannerKind.Warning => "WarningBrush",
        BannerKind.Error => "DangerBrush",
        _ => "InfoBrush",
    };

    public static Geometry GlyphFor(BannerKind kind) => kind switch
    {
        BannerKind.Success => Glyphs.Success,
        BannerKind.Warning => Glyphs.Warning,
        BannerKind.Error => Glyphs.Error,
        _ => Glyphs.Info,
    };

    /// <summary>
    /// Windows' InfoBar: an icon, a title, and as many explanatory lines as the case
    /// needs. Used inline in the editor and the build dialog for the things a technician
    /// has to know before the drive is written.
    /// </summary>
    public static Border Banner(BannerKind kind, string title, params string[] messages)
    {
        string key = BrushKeyFor(kind);
        var lines = new List<UIElement?>
        {
            new TextBlock { Text = title, FontWeight = FontWeights.Medium, TextWrapping = TextWrapping.Wrap }
                .Themed(TextBlock.ForegroundProperty, "TextPrimary"),
        };
        foreach (string message in messages)
        {
            if (!string.IsNullOrEmpty(message)) { lines.Add(Caption(message)); }
        }

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        Path icon = Icon(GlyphFor(kind), 17, key, thickness: 1.7);
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 1, 11, 0);
        Grid.SetColumn(icon, 0);
        grid.Children.Add(icon);

        StackPanel column = Column(4, lines.ToArray());
        Grid.SetColumn(column, 1);
        grid.Children.Add(column);

        return new Border
        {
            Child = grid,
            CornerRadius = new CornerRadius(7),
            Padding = new Thickness(13, 11, 13, 12),
            Margin = new Thickness(0, 0, 0, 6),
            Background = Tint(key, 0.11),
            BorderBrush = Tint(key, 0.32),
            BorderThickness = new Thickness(1),
        };
    }

    // MARK: - Controls

    public static Button Button(string label, Action click, string? style = null, string? tooltip = null)
    {
        var button = new Button { Content = label };
        if (style is not null) { button.Styled(style); }
        button.Click += (_, _) => click();
        return button.Tip(tooltip);
    }

    public static Button IconButton(Geometry glyph, Action click, string tooltip,
        string brushKey = "TextSecondary")
    {
        var button = new Button
        {
            Content = Icon(glyph, 15, brushKey),
            Width = 30,
            Height = 28,
            Padding = new Thickness(0),
        };
        button.Styled("SubtleButton");
        button.Click += (_, _) => click();
        return button.Tip(tooltip);
    }

    /// <summary>A button carrying the UAC shield, for anything that needs elevation.</summary>
    public static Button ShieldButton(string label, Action click, string? tooltip = null)
    {
        var button = new Button
        {
            Content = Row(7, Icon(Glyphs.Shield, 15, "WarningBrush", thickness: 1.5),
                new TextBlock { Text = label }),
        };
        button.Click += (_, _) => click();
        return button.Tip(tooltip);
    }

    public static CheckBox Check(string label, Func<bool> get, Action<bool> set)
    {
        var box = new CheckBox { Content = label, IsChecked = get() };
        bool updating = false;
        box.Checked += (_, _) => { if (!updating) { set(true); } };
        box.Unchecked += (_, _) => { if (!updating) { set(false); } };
        box.Tag = new Action(() =>
        {
            updating = true;
            box.IsChecked = get();
            updating = false;
        });
        return box;
    }

    public static ToggleButton Switch(Func<bool> get, Action<bool> set, string? tooltip = null)
    {
        var toggle = new ToggleButton { IsChecked = get() };
        toggle.Styled("ToggleSwitch");
        bool updating = false;
        toggle.Checked += (_, _) => { if (!updating) { set(true); } };
        toggle.Unchecked += (_, _) => { if (!updating) { set(false); } };
        toggle.Tag = new Action(() =>
        {
            updating = true;
            toggle.IsChecked = get();
            updating = false;
        });
        return toggle.Tip(tooltip);
    }

    /// <summary>Calls the refresh action a Check/Switch/Combo registered on its Tag.</summary>
    public static void Refresh(object? control)
    {
        if (control is FrameworkElement element && element.Tag is Action refresh) { refresh(); }
    }

    public static ComboBox Combo<T>(
        IEnumerable<T> items,
        Func<T, string> label,
        Func<T> get,
        Action<T> set,
        double width = 0)
    {
        var combo = new ComboBox();
        var values = new List<T>();
        foreach (T item in items)
        {
            values.Add(item);
            combo.Items.Add(new ComboBoxItem { Content = label(item) });
        }
        if (width > 0) { combo.Width = width; }

        bool updating = true;
        combo.SelectedIndex = IndexOf(values, get());
        updating = false;

        combo.SelectionChanged += (_, _) =>
        {
            if (updating) { return; }
            int index = combo.SelectedIndex;
            if (index >= 0 && index < values.Count) { set(values[index]); }
        };
        combo.Tag = new Action(() =>
        {
            updating = true;
            int index = IndexOf(values, get());
            if (combo.SelectedIndex != index) { combo.SelectedIndex = index; }
            updating = false;
        });
        return combo;
    }

    private static int IndexOf<T>(List<T> values, T wanted)
    {
        for (int i = 0; i < values.Count; i++)
        {
            if (EqualityComparer<T>.Default.Equals(values[i], wanted)) { return i; }
        }
        return -1;
    }

    /// <summary>
    /// A text field with a placeholder. WPF has no watermark, so the hint is a TextBlock
    /// behind the box, hidden as soon as there is anything to read.
    /// </summary>
    public static Grid Field(
        Func<string> get,
        Action<string> set,
        string placeholder = "",
        double width = 0,
        bool multiline = false,
        bool monospaced = false)
    {
        var box = new TextBox { Text = get(), AcceptsReturn = multiline };
        if (monospaced) { box.Styled("CodeBox"); }
        if (multiline)
        {
            box.TextWrapping = monospaced ? TextWrapping.NoWrap : TextWrapping.Wrap;
            box.VerticalContentAlignment = VerticalAlignment.Top;
            box.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        }
        if (width > 0) { box.Width = width; }

        TextBlock hint = Hint(placeholder);
        hint.IsHitTestVisible = false;
        hint.Margin = new Thickness(11, multiline ? 7 : 0, 11, 0);
        hint.VerticalAlignment = multiline ? VerticalAlignment.Top : VerticalAlignment.Center;
        hint.Visibility = box.Text.Length == 0 && placeholder.Length > 0
            ? Visibility.Visible : Visibility.Collapsed;

        box.TextChanged += (_, _) =>
        {
            hint.Visibility = box.Text.Length == 0 && placeholder.Length > 0
                ? Visibility.Visible : Visibility.Collapsed;
            set(box.Text);
        };

        var grid = new Grid();
        grid.Children.Add(box);
        grid.Children.Add(hint);
        if (width > 0) { grid.Width = width; }
        // Refreshing a field while it has focus would move the caret, so the value is
        // only pulled back in when something else changed it.
        grid.Tag = new Action(() =>
        {
            if (box.IsKeyboardFocusWithin) { return; }
            string value = get();
            if (box.Text != value) { box.Text = value; }
        });
        return grid;
    }

    /// <summary>A whole-number field with a range, for sizes and counts.</summary>
    public static Grid NumberField(Func<int> get, Action<int> set, int minimum, int maximum,
        double width = 90)
    {
        return Field(
            () => get().ToString(),
            text =>
            {
                if (int.TryParse(text.Trim(), out int value))
                {
                    set(Math.Clamp(value, minimum, maximum));
                }
                else if (text.Trim().Length == 0)
                {
                    set(minimum);
                }
            },
            width: width);
    }

    public static ProgressBar Progress(double value = 0, double width = 0)
    {
        var bar = new ProgressBar { Minimum = 0, Maximum = 1, Value = value };
        if (width > 0) { bar.Width = width; }
        return bar;
    }

    /// <summary>
    /// The band at the top of a page: what this is, one line about it, and the actions
    /// that belong to the whole page.
    /// </summary>
    public static Border PageHeader(string title, string? subtitle, params UIElement?[] actions)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        StackPanel text = Column(2, Title(title), subtitle is null ? null : Caption(subtitle));
        text.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(text, 0);
        grid.Children.Add(text);

        StackPanel trailing = Row(8, actions);
        trailing.VerticalAlignment = VerticalAlignment.Center;
        trailing.Margin = new Thickness(16, 0, 0, 0);
        Grid.SetColumn(trailing, 1);
        grid.Children.Add(trailing);

        var band = new Border
        {
            Child = grid,
            Padding = new Thickness(20, 16, 20, 15),
            BorderThickness = new Thickness(0, 0, 0, 1),
        };
        band.Themed(Border.BackgroundProperty, "BarBg");
        band.Themed(Border.BorderBrushProperty, "DividerBrush");
        return band;
    }

    /// <summary>A page: fixed header, scrolling body.</summary>
    public static Grid Page(Border header, UIElement body)
    {
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(header, 0);
        grid.Children.Add(header);
        Grid.SetRow(body, 1);
        grid.Children.Add(body);
        return grid;
    }

    /// <summary>A scrolling log pane, monospaced on a recessed background.</summary>
    public static (Border Host, TextBox Box) LogPane(double height)
    {
        var box = new TextBox
        {
            IsReadOnly = true,
            BorderThickness = new Thickness(0),
            Background = System.Windows.Media.Brushes.Transparent,
            TextWrapping = TextWrapping.NoWrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            FontSize = 12,
            Padding = new Thickness(8),
        };
        box.SetResourceReference(Control.FontFamilyProperty, "MonoFont");
        box.Themed(Control.ForegroundProperty, "TextSecondary");

        var host = new Border { Child = box, Height = height };
        host.Styled("Inset");
        host.Padding = new Thickness(0);
        return (host, box);
    }

    // MARK: - Paths and secrets

    /// <summary>
    /// A file or folder chooser: the chosen name, a Browse button, and a way to clear it.
    /// The full path is the tool tip, because it is usually too long to show and almost
    /// never what you need to read.
    /// </summary>
    public static Border PathRow(
        string label,
        Func<string> get,
        Action<string> set,
        string placeholder = "Not set",
        string? filter = null,
        bool folder = false,
        string? help = null,
        Action? changed = null)
    {
        var display = new TextBlock
        {
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 260,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var clear = new Button { Content = "Clear", MinWidth = 0 };
        clear.Styled("SubtleButton");

        void Update()
        {
            string path = get();
            display.Text = path.Length == 0 ? placeholder : System.IO.Path.GetFileName(path);
            if (display.Text.Length == 0) { display.Text = path; }
            display.SetResourceReference(TextBlock.ForegroundProperty,
                path.Length == 0 ? "TextTertiary" : "TextSecondary");
            display.ToolTip = path.Length == 0 ? placeholder : path;
            clear.Visibility = path.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        }

        Update();

        var browse = new Button { Content = "Browse…" };
        browse.Click += (_, _) =>
        {
            string? chosen = folder ? PickFolder() : PickFile(label, filter);
            if (chosen is null) { return; }
            set(chosen);
            Update();
            changed?.Invoke();
        };
        clear.Click += (_, _) =>
        {
            set(string.Empty);
            Update();
            changed?.Invoke();
        };

        StackPanel control = Row(6, display, browse, clear);
        Border row = Setting(label, control, help);
        row.Tag = new Action(Update);
        return row;
    }

    public static string? PickFile(string title, string? filter)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = title,
            Filter = filter ?? "All files (*.*)|*.*",
            CheckFileExists = true,
        };
        return dialog.ShowDialog() == true ? dialog.FileName : null;
    }

    public static string? PickFolder()
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = "Choose a folder" };
        return dialog.ShowDialog() == true ? dialog.FolderName : null;
    }

    /// <summary>
    /// A password field backed by the secret store rather than the template JSON.
    ///
    /// It never shows what is stored — only whether something is. The value goes in, the
    /// Save button puts it in the store, and the only place it comes out again is
    /// writing a drive.
    /// </summary>
    public static Border SecretRow(
        string label,
        Guid templateId,
        SecretSlot slot,
        string? footer = null,
        Action? changed = null)
    {
        var box = new PasswordBox { Width = 190 };
        var status = new TextBlock { FontSize = 12 };
        var statusIcon = new System.Windows.Shapes.Path
        {
            Stretch = System.Windows.Media.Stretch.Uniform,
            Width = 13,
            Height = 13,
            StrokeThickness = 1.7,
            VerticalAlignment = VerticalAlignment.Center,
        };

        void Update()
        {
            bool stored = SecretStore.Has(templateId, slot);
            statusIcon.Data = stored ? Glyphs.Check : Glyphs.Warning;
            statusIcon.SetResourceReference(System.Windows.Shapes.Path.StrokeProperty,
                stored ? "SuccessBrush" : "WarningBrush");
            status.Text = stored
                ? "Stored in " + SecretStore.Label(SecretStore.Backend)
                : "Not set yet." + (footer is null ? string.Empty : " " + footer);
            status.SetResourceReference(TextBlock.ForegroundProperty,
                stored ? "TextSecondary" : "WarningBrush");
        }

        var save = new Button { Content = "Save" };
        save.Click += (_, _) =>
        {
            SecretStore.Set(box.Password, templateId, slot);
            box.Clear();
            Update();
            Notifier.Banner(
                SecretStore.Has(templateId, slot)
                    ? SecretStore.Label(slot) + " saved"
                    : SecretStore.Label(slot) + " cleared",
                "Kept in " + SecretStore.Label(SecretStore.Backend));
            changed?.Invoke();
        };
        box.KeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Enter) { save.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent)); }
        };

        var clear = new Button { Content = "Clear", MinWidth = 0 };
        clear.Styled("SubtleButton");
        clear.Click += (_, _) =>
        {
            SecretStore.Delete(templateId, slot);
            box.Clear();
            Update();
            changed?.Invoke();
        };

        Update();

        StackPanel control = Row(6, box, save, clear);
        StackPanel left = Column(3,
            Text(label),
            Row(5, statusIcon, status));

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        left.VerticalAlignment = VerticalAlignment.Center;
        left.Margin = new Thickness(0, 0, 16, 0);
        Grid.SetColumn(left, 0);
        grid.Children.Add(left);
        control.VerticalAlignment = VerticalAlignment.Center;
        control.HorizontalAlignment = HorizontalAlignment.Right;
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);

        Border card = Card(grid, 0);
        card.Padding = new Thickness(14, 11, 14, 11);
        card.Margin = new Thickness(0, 0, 0, 6);
        card.Tag = new Action(Update);
        return card;
    }

    // MARK: - Empty state

    public static UIElement EmptyState(Geometry glyph, string title, string message,
        UIElement? action = null)
    {
        Path icon = Icon(glyph, 40, "TextTertiary", thickness: 1.3);
        icon.HorizontalAlignment = HorizontalAlignment.Center;

        TextBlock heading = Heading(title);
        heading.HorizontalAlignment = HorizontalAlignment.Center;
        heading.TextAlignment = TextAlignment.Center;

        TextBlock body = Caption(message);
        body.MaxWidth = 420;
        body.TextAlignment = TextAlignment.Center;
        body.HorizontalAlignment = HorizontalAlignment.Center;

        if (action is FrameworkElement element)
        {
            element.HorizontalAlignment = HorizontalAlignment.Center;
        }

        StackPanel column = Column(11, icon, heading, body, action);
        column.HorizontalAlignment = HorizontalAlignment.Center;
        column.VerticalAlignment = VerticalAlignment.Center;
        column.Margin = new Thickness(30);
        return column;
    }
}
