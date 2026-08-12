using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using ImageHub.Models;
using ImageHub.Services;
using ImageHub.Support;
using ImageHub.ViewModels;

namespace ImageHub.Views;

/// <summary>
/// The Windows Images page: the local ISO library.
///
/// The default path is the browser round trip, as on macOS — Microsoft's download
/// service refuses automated requests often enough that offering it first would be
/// misleading. "Try direct download" is still there, and an internal URL with a pinned
/// SHA-256 is the answer for a team that wants everyone building from identical bytes.
/// </summary>
public sealed class ImagesView : UserControl, IRefreshable
{
    private readonly MainWindow _window;
    private readonly AppState _state = AppState.Shared;
    private readonly StackPanel _body = new();
    private readonly List<string> _downloadLog = new();
    private Guid? _expanded;
    private bool _lastDownloadFailed;

    private ImageLibrary Library => _state.Library;

    public ImagesView(MainWindow window)
    {
        _window = window;

        var download = new Button { Content = "Download" };
        var menu = new ContextMenu();
        menu.Items.Add(Menu("Open Microsoft's Download Page…",
            () => AppPaths.OpenUrl(MicrosoftIsoService.PageUrl(WindowsRelease.Win11))));
        menu.Items.Add(new Separator());
        menu.Items.Add(Menu("Try Direct Download (Windows 11)", () => Download(WindowsRelease.Win11)));
        menu.Items.Add(Menu("Try Direct Download (Windows 10)", () => Download(WindowsRelease.Win10)));
        download.Click += (_, _) =>
        {
            menu.PlacementTarget = download;
            menu.IsOpen = true;
        };

        Content = Ui.Page(
            Ui.PageHeader("Windows Images", null,
                download,
                Ui.Button("Import ISO…", ImportIso),
                Ui.Button("From URL…", () =>
                {
                    var dialog = new ImageFromUrlDialog(_window);
                    dialog.ShowDialog();
                    Refresh();
                })),
            Ui.Scroll(_body));
        Library.PropertyChanged += (_, _) => Refresh();
        Refresh();
    }

    private static MenuItem Menu(string header, Action action)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => action();
        return item;
    }

    public void Refresh()
    {
        _body.Children.Clear();

        if (Library.IsBusy) { _body.Children.Add(BusyCard()); }

        if (Library.Images.Count == 0 && !Library.IsBusy)
        {
            _body.Children.Add(Ui.EmptyState(
                Glyphs.Box,
                "No Windows images yet",
                "Get the current retail ISO from Microsoft in your browser, then import it — their "
                + "download service refuses automated requests, so that round trip is the reliable "
                + "path. Enterprise and LTSC media has to be imported too, since Microsoft doesn't "
                + "publish it.",
                Ui.Row(8,
                    Ui.Button("Get Windows 11 ISO…",
                        () => AppPaths.OpenUrl(MicrosoftIsoService.PageUrl(WindowsRelease.Win11)),
                        "AccentButton"),
                    Ui.Button("Import ISO…", ImportIso))));
        }
        else
        {
            foreach (WindowsImage image in Library.Images)
            {
                _body.Children.Add(ImageCard(image));
            }
        }

        if (_lastDownloadFailed)
        {
            _body.Children.Add(Ui.Banner(BannerKind.Info,
                "Microsoft wouldn't hand over a download link",
                "Their anti-abuse check refuses clients that aren't a real browser session. ImageHub "
                + "can't reliably satisfy it, and this isn't a sign anything else is wrong.",
                "Downloading the ISO in a browser takes about the same time and always works. Grab "
                + "it, then use Import ISO to add it to the library."));
            _body.Children.Add(Ui.Row(8,
                Ui.Button("Open Microsoft's Download Page",
                    () => AppPaths.OpenUrl(MicrosoftIsoService.PageUrl(WindowsRelease.Win11)),
                    "AccentButton"),
                Ui.Button("Import ISO…", ImportIso)));
        }

        if (_downloadLog.Count > 0)
        {
            (Border host, TextBox box) = Ui.LogPane(130);
            box.Text = string.Join("\r\n", _downloadLog);
            _body.Children.Add(Ui.Wide("Download log", Ui.Column(7, host,
                Ui.Button("Clear", () =>
                {
                    _downloadLog.Clear();
                    Refresh();
                }, "SubtleButton"))));
        }

        if (!Elevation.IsElevated)
        {
            _body.Children.Add(Ui.Banner(BannerKind.Info,
                "Edition lists need administrator rights",
                "Reading which editions are inside an ISO means mounting it, and Windows only lets "
                + "an elevated process do that. Importing works either way — the list fills in when "
                + "you use “Read editions” after restarting as administrator."));
        }

        _body.Children.Add(Ui.Banner(BannerKind.Info, "Where these come from",
            "ImageHub never mirrors or modifies Microsoft's images — whichever route you use, the "
            + "bytes come from Microsoft.",
            "“Try direct download” asks the same public service microsoft.com uses. It often refuses "
            + "non-browser clients, which is why the browser round trip is the default. For a team, "
            + "host one approved ISO on an internal URL with a pinned SHA-256 so everyone builds "
            + "from identical bytes."));
    }

    private UIElement BusyCard()
    {
        var rows = new List<UIElement?>
        {
            Ui.Row(10,
                Ui.Text(Library.BusyMessage.Length == 0 ? "Working…" : Library.BusyMessage)
                    .Also(text => text.FontWeight = FontWeights.Medium),
                Library.Downloader.IsDownloading && Library.Downloader.CanCancel
                    ? Ui.Button("Cancel", () => Library.Downloader.Cancel(), "SubtleButton")
                    : null),
        };

        if (Library.Downloader.IsDownloading)
        {
            rows.Add(Ui.Progress(Library.Downloader.Progress));
            rows.Add(Ui.Caption(Library.Downloader.StatusText));
        }
        else if (Library.CopyProgress is double copy)
        {
            rows.Add(Ui.Progress(copy));
            rows.Add(Ui.Caption($"Copying — {(int)(copy * 100)}%"));
        }
        else if (Library.HashProgress is double hash)
        {
            rows.Add(Ui.Progress(hash));
            rows.Add(Ui.Caption($"Hashing — {(int)(hash * 100)}%"));
        }

        Border card = Ui.Card(Ui.Column(8, rows.ToArray()), 14);
        card.Margin = new Thickness(0, 0, 0, 6);
        return card;
    }

    private UIElement ImageCard(WindowsImage image)
    {
        bool expanded = _expanded == image.Id;

        StackPanel titleRow = Ui.Row(7, Ui.Text(image.DisplayName)
            .Also(text => text.FontWeight = FontWeights.Medium));
        if (!image.FileExists)
        {
            titleRow.Children.Add(Ui.Chip("Missing", "DangerBrush", Glyphs.Warning)
                .Tip(image.Path));
        }
        if (image.InstallImageNeedsSplit)
        {
            titleRow.Children.Add(Ui.Chip("Splits on build", "TextSecondary")
                .Tip("This image's install.wim is over FAT32's 4 GB file limit, so DISM splits it "
                    + "into install.swm parts while building. Nothing for you to do."));
        }
        if (image.LastVerifiedAt is not null)
        {
            titleRow.Children.Add(Ui.Chip("Verified", "SuccessBrush", Glyphs.Check));
        }
        if (image.Editions.Count == 0 && image.FileExists)
        {
            titleRow.Children.Add(Ui.Chip("Editions unread", "WarningBrush")
                .Tip("Reading the edition list needs administrator rights."));
        }

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        StackPanel text = Ui.Column(3, titleRow, Ui.Caption(image.Subtitle));
        text.VerticalAlignment = VerticalAlignment.Center;
        text.Margin = new Thickness(0, 0, 12, 0);
        Grid.SetColumn(text, 0);
        grid.Children.Add(text);

        StackPanel actions = Ui.Row(6,
            Ui.Button("Use", () => Use(image)).Also(button => button.IsEnabled = image.FileExists),
            Ui.IconButton(expanded ? Glyphs.ChevronUp : Glyphs.ChevronDown, () =>
            {
                _expanded = expanded ? null : image.Id;
                Refresh();
            }, expanded ? "Collapse" : "Details"));
        actions.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(actions, 1);
        grid.Children.Add(actions);

        if (!expanded)
        {
            Border row = Ui.Card(grid, 0);
            row.Padding = new Thickness(14, 11, 10, 11);
            row.Margin = new Thickness(0, 0, 0, 6);
            return row;
        }

        var detail = new List<UIElement?>
        {
            grid,
            Ui.Divider(),
            Line("Path", image.Path, mono: true),
            Line("Added", Formatting.Brief(image.AddedAt)),
            Line("Origin", Labels.Of(image.Origin)),
            image.SourceUrl.Length == 0 ? null : Line("Source", image.SourceUrl, mono: true),
            image.InstallImageName.Length == 0
                ? null
                : Line("Install image",
                    $"{image.InstallImageName} · {Formatting.ByteSize(image.InstallImageSizeBytes)}"),
            image.Sha256.Length == 0 ? null : Line("SHA-256", image.Sha256, mono: true),
            image.LastVerifiedAt is null
                ? null
                : Line("Last verified", Formatting.Brief(image.LastVerifiedAt.Value)),
        };

        if (image.Editions.Count > 0)
        {
            var editions = new StackPanel();
            foreach (ImageEdition edition in image.Editions)
            {
                editions.Children.Add(Ui.Row(9,
                    Ui.Mono(edition.Index.ToString()),
                    Ui.Caption(edition.Name),
                    edition.SizeBytes > 0 ? Ui.Hint(Formatting.ByteSize(edition.SizeBytes)) : null));
            }
            detail.Add(Ui.Inset(Ui.Column(4, Ui.Caption("Editions inside this image"), editions), 9));
        }

        detail.Add(Ui.Row(6,
            Ui.Button(image.Sha256.Length == 0 ? "Record Checksum" : "Verify",
                    () => _ = Library.VerifyAsync(image))
                .Also(button => button.IsEnabled = image.FileExists),
            Ui.Button("Read Editions", () => _ = Library.ReinspectAsync(image))
                .Also(button => button.IsEnabled = image.FileExists),
            Ui.Button("Show in Explorer", () => AppPaths.Reveal(image.Path))
                .Also(button => button.IsEnabled = image.FileExists),
            Ui.Button("Remove…", () => Remove(image), "DangerButton")));

        Border card = Ui.Card(Ui.Column(8, detail.ToArray()), 0);
        card.Padding = new Thickness(14, 11, 10, 12);
        card.Margin = new Thickness(0, 0, 0, 6);
        return card;
    }

    private static UIElement Line(string label, string value, bool mono = false)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(110) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        TextBlock name = Ui.Caption(label);
        Grid.SetColumn(name, 0);
        grid.Children.Add(name);
        TextBlock text = mono ? Ui.Mono(value) : Ui.Caption(value);
        text.TextTrimming = TextTrimming.CharacterEllipsis;
        text.TextWrapping = TextWrapping.NoWrap;
        text.ToolTip = value;
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        return grid;
    }

    // MARK: - Actions

    private void Download(WindowsRelease release)
    {
        _downloadLog.Clear();
        _lastDownloadFailed = false;
        Refresh();
        string language = Settings.Current.DefaultLanguage;
        _ = DownloadAsync(release, language);
    }

    private async System.Threading.Tasks.Task DownloadAsync(WindowsRelease release, string language)
    {
        WindowsImage? image = await Library.DownloadLatestAsync(release, language, line =>
        {
            _downloadLog.Add(line);
            Refresh();
        }).ConfigureAwait(true);
        _lastDownloadFailed = image is null;
        Refresh();
    }

    private void ImportIso()
    {
        string? path = Ui.PickFile("Import a Windows ISO",
            "Disc image (*.iso)|*.iso|All files (*.*)|*.*");
        if (path is null) { return; }

        long size = 0;
        try { size = new FileInfo(path).Length; } catch (IOException) { }
        string sizeText = size > 0 ? Formatting.ByteSize(size) : "several GB";

        MessageBoxResult answer = MessageBox.Show(
            _window,
            "Linking uses the ISO where it is — nothing is duplicated, and it's the better choice "
            + "unless the file lives somewhere temporary.\n\n"
            + $"Copying spends another {sizeText} of disk so the image survives the original being "
            + "moved or deleted.\n\n"
            + "Yes to copy, No to link in place.",
            "How should ImageHub keep this ISO?",
            MessageBoxButton.YesNoCancel,
            MessageBoxImage.Question,
            MessageBoxResult.No);
        if (answer == MessageBoxResult.Cancel) { return; }

        _ = Library.ImportAsync(path, copyIntoLibrary: answer == MessageBoxResult.Yes);
    }

    private void Use(WindowsImage image)
    {
        DeploymentTemplate? template = _state.SelectedTemplate
            ?? _state.Templates.Templates.FirstOrDefault();
        if (template is null)
        {
            Notifier.Banner("No template to attach it to", "Create a template first.", BannerKind.Info);
            return;
        }
        template.Windows.LibraryImageId = image.Id;
        _state.Templates.Save(template);
        _state.Select(template);
        Notifier.Banner($"Pinned to “{template.Name}”", image.DisplayName);
    }

    private void Remove(WindowsImage image)
    {
        string question = image.Managed
            ? "This ISO lives inside ImageHub's library folder.\n\nDelete the file from disk as well?"
            : "This ISO is linked from elsewhere on disk, so only the library record is removed.\n\n"
              + "Remove it?";
        MessageBoxResult answer = MessageBox.Show(
            _window,
            $"Remove “{image.DisplayName}”?\n\n{question}",
            "Remove image",
            image.Managed ? MessageBoxButton.YesNoCancel : MessageBoxButton.OKCancel,
            MessageBoxImage.Warning,
            MessageBoxResult.Cancel);

        if (answer == MessageBoxResult.Cancel) { return; }
        bool deleteFile = image.Managed && answer == MessageBoxResult.Yes;
        if (!image.Managed && answer != MessageBoxResult.OK) { return; }
        Library.Remove(image, deleteFile);
        Refresh();
    }
}
