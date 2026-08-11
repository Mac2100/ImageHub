using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace ImageHub.Support;

/// <summary>
/// Change notification for the model and view-model types.
///
/// The views are built in C# rather than XAML and wire controls to properties
/// explicitly, so this is not here to drive data bindings — it is here so that
/// one part of the UI can react to a change made in another (a picker that
/// reveals extra rows, the Review tab recounting problems, the status bar
/// following a build) without every view having to know who else cares.
/// </summary>
public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) { return false; }
        field = value;
        Raise(name);
        return true;
    }

    public void Raise([CallerMemberName] string? name = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name ?? string.Empty));
    }
}
