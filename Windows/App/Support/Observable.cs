using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Threading;

namespace ImageHub.Support;

/// <summary>
/// Change notification for the model and view-model types.
///
/// The views are built in C# rather than XAML and wire controls to properties
/// explicitly, so this is not here to drive data bindings — it is here so that one part
/// of the UI can react to a change made in another (a picker that reveals extra rows,
/// the Review tab recounting problems, the status bar following a build) without every
/// view having to know who else cares.
///
/// Notifications are raised on the UI thread whatever thread the change came from. A
/// download reports its progress from a thread-pool continuation and a build reports
/// from a copy loop; without this, the first handler to touch a control would throw
/// "the calling thread cannot access this object" somewhere far from the cause.
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
        PropertyChangedEventHandler? handler = PropertyChanged;
        if (handler is null) { return; }

        var args = new PropertyChangedEventArgs(name ?? string.Empty);
        Dispatcher? dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess())
        {
            handler(this, args);
            return;
        }
        dispatcher.BeginInvoke(new Action(() => handler(this, args)));
    }
}
