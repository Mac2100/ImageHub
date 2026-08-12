using System;
using System.Windows;
using System.Windows.Controls;
using ImageHub.Models;
using ImageHub.Services;
using ImageHub.Support;
using ImageHub.ViewModels;

namespace ImageHub.Views;

/// <summary>
/// The USB Drives page.
///
/// Only removable external media ever appears here: DiskService filters the list
/// before the UI sees it, so an internal disk is not something to pick by mistake.
/// The list refreshes from Windows' own device-change message rather than a timer.
/// </summary>
public sealed class DrivesView : UserControl, IRefreshable
{
    private readonly MainWindow _window;
    private readonly AppState _state = AppState.Shared;
    private readonly StackPanel _body = new();
    private readonly Border _header;

    public DrivesView(MainWindow window)
    {
        _window = window;
        _header = Ui.PageHeader("USB Drives", null,
            Ui.Button("Rescan", () => _ = _state.RefreshDrivesAsync()),
            Ui.Button("Build USB Drive", () => _window.StartBuild(null), "AccentButton"));
        Content = Ui.Page(_header, Ui.Scroll(_body));
        Refresh();
    }

    public void Refresh()
    {
        _body.Children.Clear();

        if (_state.Drives.Count == 0)
        {
            _body.Children.Add(Ui.EmptyState(
                Glyphs.Drive,
                "No USB drives detected",
                "Plug in a USB stick — 16 GB or larger for Windows 11. ImageHub only ever lists "
                + "removable external media; internal disks are filtered out and can't be selected.",
                Ui.Button("Scan again", () => _ = _state.RefreshDrivesAsync(), "AccentButton")));
        }
        else
        {
            foreach (UsbDisk drive in _state.Drives)
            {
                _body.Children.Add(DriveCard(drive));
            }
        }

        _body.Children.Add(Ui.Banner(BannerKind.Warning, "Building erases the whole drive",
            "The selected drive is repartitioned and formatted FAT32 from scratch. Anything on it "
            + "is gone.",
            "FAT32 isn't a preference — UEFI firmware is only guaranteed to read FAT, so it's the one "
            + "filesystem Windows Setup media can reliably boot from. That's also why install.wim "
            + "gets split when it's over 4 GB.",
            $"Windows won't format a FAT32 volume larger than 32 GB, so on a bigger stick ImageHub "
            + $"uses the first {Formatting.ByteSize(DiskService.MaxFat32PartitionBytes)} and leaves "
            + "the rest unallocated."));

        if (!Elevation.IsElevated)
        {
            _body.Children.Add(Ui.Banner(BannerKind.Info, "Administrator rights are needed to write",
                Elevation.Explanation));
        }
    }

    private UIElement DriveCard(UsbDisk drive)
    {
        bool selected = _state.SelectedDriveId == drive.Id;

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        System.Windows.Shapes.Path radio = Ui.Icon(
            selected ? Glyphs.Success : Glyphs.Circle, 18,
            selected ? "AccentBrush" : "TextTertiary", thickness: 1.5);
        radio.VerticalAlignment = VerticalAlignment.Center;
        radio.Margin = new Thickness(0, 0, 12, 0);
        Grid.SetColumn(radio, 0);
        grid.Children.Add(radio);

        StackPanel titleRow = Ui.Row(7, Ui.Text(drive.DisplayName));
        if (drive.SizeBytes < 16_000_000_000)
        {
            titleRow.Children.Add(Ui.Chip("Small", "WarningBrush", Glyphs.Warning)
                .Tip("Windows 11 media needs roughly 8–16 GB depending on the image."));
        }
        if (drive.SizeBytes > DiskService.MaxFat32PartitionBytes)
        {
            titleRow.Children.Add(Ui.Chip("Uses first 31 GB", "TextSecondary")
                .Tip("Windows won't create a FAT32 volume larger than 32 GB, and Setup media has to "
                    + "be FAT32. The rest of the drive is left unallocated."));
        }

        StackPanel text = Ui.Column(3, titleRow, Ui.Caption(drive.Subtitle));
        text.VerticalAlignment = VerticalAlignment.Center;
        text.Margin = new Thickness(0, 0, 14, 0);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        StackPanel actions = Ui.Row(6);
        if (drive.DriveLetters.Count > 0)
        {
            actions.Children.Add(Ui.Button("Eject", () =>
            {
                _ = EjectAsync(drive);
            }));
        }
        actions.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(actions, 2);
        grid.Children.Add(actions);

        Border card = Ui.Card(grid, 0);
        card.Padding = new Thickness(14, 12, 14, 12);
        card.Margin = new Thickness(0, 0, 0, 6);
        card.Cursor = System.Windows.Input.Cursors.Hand;
        if (selected)
        {
            card.BorderBrush = Ui.Brush("AccentBrush");
            card.BorderThickness = new Thickness(1.4);
        }
        card.MouseLeftButtonUp += (_, _) =>
        {
            _state.SelectedDriveId = drive.Id;
            Refresh();
        };
        return card;
    }

    private async System.Threading.Tasks.Task EjectAsync(UsbDisk drive)
    {
        foreach (string letter in drive.DriveLetters)
        {
            await DiskService.EjectAsync(letter).ConfigureAwait(true);
        }
        Notifier.Banner("Ejected", drive.DisplayName);
        await _state.RefreshDrivesAsync().ConfigureAwait(true);
        Refresh();
    }
}
