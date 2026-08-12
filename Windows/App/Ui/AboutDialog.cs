using System.Windows;
using System.Windows.Controls;
using ImageHub.Services;
using ImageHub.Support;

namespace ImageHub.Views;

/// <summary>Help → About, in the shape Windows apps have always used it.</summary>
public sealed class AboutDialog : ThemedWindow
{
    public AboutDialog(Window owner)
    {
        Title = "About ImageHub";
        ConfigureAsDialog(owner, 520, 460);
        ResizeMode = ResizeMode.NoResize;

        var mark = new System.Windows.Shapes.Path
        {
            Data = Glyphs.Drive,
            Stretch = System.Windows.Media.Stretch.Uniform,
            Width = 56,
            Height = 56,
            StrokeThickness = 1.1,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        mark.Themed(System.Windows.Shapes.Path.StrokeProperty, "AccentBrush");

        TextBlock name = Ui.Title("ImageHub");
        name.HorizontalAlignment = HorizontalAlignment.Center;

        TextBlock version = Ui.Caption("Version " + AppVersion.Current);
        version.HorizontalAlignment = HorizontalAlignment.Center;

        TextBlock blurb = Ui.Caption(
            "Bootable Windows golden-image USB drives, built from reusable deployment templates.");
        blurb.TextAlignment = TextAlignment.Center;
        blurb.MaxWidth = 380;
        blurb.HorizontalAlignment = HorizontalAlignment.Center;

        StackPanel links = Ui.Row(14,
            Ui.Button("GitHub", () => AppPaths.OpenUrl($"https://github.com/{UpdateChecker.Repo}"),
                "LinkButton"),
            Ui.Button("Releases", () => AppPaths.OpenUrl(UpdateChecker.ReleasesPage), "LinkButton"),
            Ui.Button("MIT License",
                () => AppPaths.OpenUrl($"https://github.com/{UpdateChecker.Repo}/blob/main/LICENSE"),
                "LinkButton"));
        links.HorizontalAlignment = HorizontalAlignment.Center;

        TextBlock credit = Ui.Hint(
            "The macOS and Windows apps share one release and one template format, so a drive built "
            + "on either is interchangeable. Splitting an oversized install.wim uses DISM here and "
            + "wimlib on the Mac.");
        credit.TextAlignment = TextAlignment.Center;
        credit.MaxWidth = 400;
        credit.HorizontalAlignment = HorizontalAlignment.Center;

        Button close = Ui.Button("Close", Close, "AccentButton");
        close.IsDefault = true;
        close.HorizontalAlignment = HorizontalAlignment.Center;
        close.MinWidth = 110;

        StackPanel column = Ui.Column(12, mark, name, version, blurb, links, credit, close);
        column.VerticalAlignment = VerticalAlignment.Center;
        column.Margin = new Thickness(28);

        Content = column;
    }
}
