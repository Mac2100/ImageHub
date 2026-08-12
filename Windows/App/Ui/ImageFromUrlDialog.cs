using System;
using System.Windows;
using System.Windows.Controls;
using ImageHub.Models;
using ImageHub.Services;
using ImageHub.ViewModels;

namespace ImageHub.Views;

/// <summary>
/// Adds an ISO from an internal URL, with an optional pinned SHA-256.
///
/// This is the recommended way to share one approved image across a team: with the
/// checksum set, a download that doesn't match is discarded rather than quietly
/// producing bad media.
/// </summary>
public sealed class ImageFromUrlDialog : ThemedWindow
{
    private readonly AppState _state = AppState.Shared;
    private string _url = string.Empty;
    private string _checksum = string.Empty;
    private WindowsRelease _release = WindowsRelease.Win11;

    public ImageFromUrlDialog(Window owner)
    {
        Title = "Add an image from a URL";
        ConfigureAsDialog(owner, 580, 400);
        ResizeMode = ResizeMode.NoResize;

        Button download = Ui.Button("Download", Start, "AccentButton");
        download.IsDefault = true;

        var footerGrid = new Grid();
        footerGrid.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = new GridLength(1, GridUnitType.Star),
        });
        footerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        StackPanel buttons = Ui.Row(8, Ui.Button("Cancel", Close), download);
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

        var body = new StackPanel();
        body.Children.Add(Ui.Group(null,
            Ui.Setting("HTTPS URL", Ui.Field(() => _url, value => _url = value,
                "https://files.corp.example.com/win11-24h2.iso", 300)),
            Ui.Setting("Release", Ui.Combo(
                Labels.All<WindowsRelease>(), r => Labels.Of(r),
                () => _release, value => _release = value, 200)),
            Ui.Setting("Expected SHA-256 (optional)", Ui.Field(
                () => _checksum, value => _checksum = value, "64 hex characters", 300)),
            Ui.Wide(null, Ui.Caption(
                "With a checksum set, a download that doesn't match is discarded instead of quietly "
                + "producing bad media. This is the recommended way to share one approved ISO across "
                + "a team."))));

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        ScrollViewer scroll = Ui.Scroll(body, 16);
        Grid.SetRow(scroll, 0);
        grid.Children.Add(scroll);
        Grid.SetRow(footer, 1);
        grid.Children.Add(footer);

        Content = grid;
    }

    private void Start()
    {
        string url = _url.Trim();
        if (!Uri.TryCreate(url, UriKind.Absolute, out Uri? parsed)
            || (parsed.Scheme != Uri.UriSchemeHttps && parsed.Scheme != Uri.UriSchemeHttp))
        {
            Notifier.Banner("That doesn't look like a URL",
                "Use an http:// or https:// address.", BannerKind.Error);
            return;
        }

        string expected = _checksum.Trim();
        WindowsRelease release = _release;
        Close();
        _ = _state.Library.DownloadFromUrlAsync(url, expected, release);
    }
}
