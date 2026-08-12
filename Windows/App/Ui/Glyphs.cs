using System.Collections.Generic;
using System.Windows.Media;

namespace ImageHub.Views;

/// <summary>
/// The handful of icons the UI draws, as vector geometry on a 24×24 grid.
///
/// Not Segoe Fluent Icons: that font is only present from Windows 11, its Windows 10
/// predecessor has different code points for several of these, and a wrong code point
/// renders as an empty box with no way to notice in a build. Geometry always draws.
/// Everything else in the UI is labelled with words, which is what Windows menus and
/// dialogs do anyway.
/// </summary>
public static class Glyphs
{
    public static Geometry Check { get; } = Parse("M 4,12.5 L 9.5,18 L 20,6");

    public static Geometry Cross { get; } = Parse("M 6,6 L 18,18 M 18,6 L 6,18");

    public static Geometry Plus { get; } = Parse("M 12,5 L 12,19 M 5,12 L 19,12");

    public static Geometry Minus { get; } = Parse("M 5,12 L 19,12");

    public static Geometry ChevronDown { get; } = Parse("M 6,9.5 L 12,15.5 L 18,9.5");

    public static Geometry ChevronUp { get; } = Parse("M 6,14.5 L 12,8.5 L 18,14.5");

    public static Geometry ChevronRight { get; } = Parse("M 9,5.5 L 15.5,12 L 9,18.5");

    public static Geometry Warning { get; } = Parse(
        "M 12,3 L 22.5,20.5 L 1.5,20.5 Z M 12,9 L 12,15 M 12,17.4 L 12,18.4");

    public static Geometry Info { get; } = Parse(
        "M 12,2.5 A 9.5,9.5 0 1 1 11.99,2.5 Z M 12,7 L 12,7.8 M 12,10.5 L 12,17");

    public static Geometry Error { get; } = Parse(
        "M 12,2.5 A 9.5,9.5 0 1 1 11.99,2.5 Z M 8.5,8.5 L 15.5,15.5 M 15.5,8.5 L 8.5,15.5");

    public static Geometry Success { get; } = Parse(
        "M 12,2.5 A 9.5,9.5 0 1 1 11.99,2.5 Z M 7.5,12.5 L 10.5,15.5 L 16.5,9");

    public static Geometry Circle { get; } = Parse("M 12,3.5 A 8.5,8.5 0 1 1 11.99,3.5 Z");

    /// <summary>The UAC shield, for the actions that need administrator rights.</summary>
    public static Geometry Shield { get; } = Parse(
        "M 12,2.2 L 20,5 L 20,11.2 C 20,16 16.4,19.9 12,21.8 C 7.6,19.9 4,16 4,11.2 L 4,5 Z");

    /// <summary>An external drive, the mark ImageHub uses for itself.</summary>
    public static Geometry Drive { get; } = Parse(
        "M 3.2,7.4 L 20.8,7.4 A 1.8,1.8 0 0 1 22.6,9.2 L 22.6,14.8 A 1.8,1.8 0 0 1 20.8,16.6 "
        + "L 3.2,16.6 A 1.8,1.8 0 0 1 1.4,14.8 L 1.4,9.2 A 1.8,1.8 0 0 1 3.2,7.4 Z");

    public static Geometry Search { get; } = Parse(
        "M 10.5,3.5 A 7,7 0 1 1 10.49,3.5 Z M 15.6,15.6 L 21,21");

    /// <summary>
    /// The macOS app stores an SF Symbol name on each template. Windows has no such
    /// catalogue, so the shape is mapped onto one of the glyphs above — the stored name
    /// is round-tripped untouched so a Mac user's choice survives an edit here.
    /// </summary>
    public static Geometry ForTemplateSymbol(string symbol) => symbol switch
    {
        "display" => Monitor,
        "laptopcomputer" => Laptop,
        "building.2" => Building,
        "briefcase" => Briefcase,
        "graduationcap" => Graduation,
        "shield.lefthalf.filled" => Shield,
        "wrench.and.screwdriver" => Wrench,
        "cube.box" => Box,
        "cross.case" => Briefcase,
        "person.2.badge.gearshape" => People,
        "pc" => Tower,
        _ => Monitor,
    };

    /// <summary>The icon choices offered for a template, paired with the name the file stores.</summary>
    public static readonly (string Symbol, string Label)[] TemplateSymbols =
    {
        ("desktopcomputer", "Desktop"),
        ("laptopcomputer", "Laptop"),
        ("display", "Display"),
        ("pc", "Tower"),
        ("building.2", "Office"),
        ("briefcase", "Field"),
        ("graduationcap", "Education"),
        ("shield.lefthalf.filled", "Secure"),
        ("wrench.and.screwdriver", "Workshop"),
        ("person.2.badge.gearshape", "Shared"),
        ("cube.box", "Kiosk"),
    };

    public static Geometry Monitor { get; } = Parse(
        "M 3,4.5 L 21,4.5 L 21,16 L 3,16 Z M 9,19.5 L 15,19.5 M 12,16 L 12,19.5");

    public static Geometry Laptop { get; } = Parse(
        "M 5,5.5 L 19,5.5 L 19,15 L 5,15 Z M 2.5,18 L 21.5,18");

    public static Geometry Tower { get; } = Parse(
        "M 7,3.5 L 17,3.5 L 17,20.5 L 7,20.5 Z M 10,7 L 14,7 M 10,10 L 14,10");

    public static Geometry Building { get; } = Parse(
        "M 4,20.5 L 4,7 L 12,3.5 L 12,20.5 M 12,10 L 20,10 L 20,20.5 M 7,11 L 9,11 M 7,15 L 9,15 "
        + "M 15,14 L 17,14");

    public static Geometry Briefcase { get; } = Parse(
        "M 3,8 L 21,8 L 21,19 L 3,19 Z M 9,8 L 9,5.5 L 15,5.5 L 15,8 M 3,13 L 21,13");

    public static Geometry Graduation { get; } = Parse(
        "M 2,9 L 12,4.5 L 22,9 L 12,13.5 Z M 6,11 L 6,17 C 6,17 8.5,19.5 12,19.5 "
        + "C 15.5,19.5 18,17 18,17 L 18,11");

    public static Geometry Wrench { get; } = Parse(
        "M 4,20 L 11,13 M 13.5,10.5 L 20,4 M 9.5,6.5 A 4,4 0 1 0 14,11");

    public static Geometry Box { get; } = Parse(
        "M 3,7.5 L 12,3.5 L 21,7.5 L 21,16.5 L 12,20.5 L 3,16.5 Z M 3,7.5 L 12,11.5 L 21,7.5 "
        + "M 12,11.5 L 12,20.5");

    public static Geometry People { get; } = Parse(
        "M 9,10.5 A 3.2,3.2 0 1 1 8.99,10.5 Z M 3,20 C 3,16.6 5.7,14.5 9,14.5 C 12.3,14.5 15,16.6 15,20 "
        + "M 16,7.5 A 2.6,2.6 0 1 1 15.99,7.5 Z M 16.5,14.8 C 19.3,15.2 21,17.2 21,20");

    private static Geometry Parse(string data)
    {
        Geometry geometry = Geometry.Parse(data);
        geometry.Freeze();
        return geometry;
    }
}
