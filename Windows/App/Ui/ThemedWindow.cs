using System;
using System.Windows;
using System.Windows.Input;

namespace ImageHub.Views;

/// <summary>
/// The base every ImageHub window derives from.
///
/// It exists because WPF matches implicit styles on the exact type, so a
/// `Style TargetType="Window"` never reaches a Window subclass. This applies the
/// keyed AppWindow style instead, and repaints the title bar when the appearance
/// changes — without that, a dark window keeps a light frame and looks like a
/// half-finished port.
/// </summary>
public class ThemedWindow : Window
{
    public ThemedWindow()
    {
        this.SetResourceReference(StyleProperty, "AppWindow");
        SnapsToDevicePixels = true;
        UseLayoutRounding = true;
        SourceInitialized += (_, _) => ThemeManager.ApplyTitleBar(this);
        ThemeManager.Changed += OnThemeChanged;
        Closed += (_, _) => ThemeManager.Changed -= OnThemeChanged;
    }

    private void OnThemeChanged(object? sender, EventArgs e) => ThemeManager.ApplyTitleBar(this);

    /// <summary>Sets up a modal dialog the way Windows dialogs behave.</summary>
    protected void ConfigureAsDialog(Window? owner, double width, double height)
    {
        // Application.MainWindow is whatever window WPF constructed first, and during
        // startup that can be *this* one: the install offer is built before the main
        // window exists, so the fallback resolved to itself and setting a window as its
        // own owner throws "Cannot set Owner property to itself".
        Window? candidate = owner ?? Application.Current?.MainWindow;
        Owner = ReferenceEquals(candidate, this) ? null : candidate;

        Width = width;
        Height = height;
        WindowStartupLocation = Owner is null
            ? WindowStartupLocation.CenterScreen
            : WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.CanResize;
        // A dialog normally rides on its owner's taskbar button. With no owner there is
        // no button to ride on, and an ownerless modal that is not in the taskbar can be
        // lost behind another window with no way back to it.
        ShowInTaskbar = Owner is null;
        MinWidth = Math.Min(width, 460);
        MinHeight = Math.Min(height, 320);
        // Escape closes a dialog, as it does everywhere else in Windows.
        InputBindings.Add(new KeyBinding(new RelayCommand(() => Close()), Key.Escape, ModifierKeys.None));
    }
}

/// <summary>
/// The smallest ICommand that works, for the window's keyboard shortcuts. Menu items
/// use plain Click handlers; only the accelerators need a command.
/// </summary>
public sealed class RelayCommand : ICommand
{
    private readonly Action _action;
    private readonly Func<bool>? _canExecute;

    public RelayCommand(Action action, Func<bool>? canExecute = null)
    {
        _action = action;
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged
    {
        add => CommandManager.RequerySuggested += value;
        remove => CommandManager.RequerySuggested -= value;
    }

    public bool CanExecute(object? parameter) => _canExecute?.Invoke() ?? true;

    public void Execute(object? parameter) => _action();
}
