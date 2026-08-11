using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Xml.Linq;
using ImageHub.Models;

namespace ImageHub.Services;

/// <summary>
/// Reads the edition list out of a .wim / .esd without any external tools.
///
/// A WIM stores an uncompressed UTF-16LE XML blob describing every image it
/// contains, and the header says exactly where it is. That is all ImageHub needs to
/// show "which editions are in this ISO", so inspection needs neither DISM nor an
/// elevated process — only the mounted ISO the file sits on.
///
/// A port of Sources/ImageHub/Services/WimReader.swift.
/// </summary>
public static class WimReader
{
    private static readonly byte[] Magic = Encoding.ASCII.GetBytes("MSWIM\0\0\0");

    public sealed class Header
    {
        public int ImageCount { get; init; }

        public int PartNumber { get; init; }

        public int TotalParts { get; init; }

        public ulong XmlOffset { get; init; }

        public ulong XmlSize { get; init; }
    }

    /// <summary>Parses the 208-byte WIM header.</summary>
    public static Header ReadHeader(string path)
    {
        using FileStream stream = File.OpenRead(path);
        var head = new byte[208];
        int read = stream.Read(head, 0, head.Length);
        if (read != head.Length)
        {
            throw new BuildException($"{Path.GetFileName(path)} is too small to be a WIM.");
        }
        for (int i = 0; i < Magic.Length; i++)
        {
            if (head[i] != Magic[i])
            {
                throw new BuildException($"{Path.GetFileName(path)} is not a WIM/ESD image.");
            }
        }

        // Header layout: part/total at 40/42, image count at 44, then 24-byte resource
        // headers — xml_data starts at offset 72.
        int partNumber = BitConverter.ToUInt16(head, 40);
        int totalParts = BitConverter.ToUInt16(head, 42);
        int imageCount = (int)BitConverter.ToUInt32(head, 44);

        // Resource header: [size:7|flags:1][offset:8][original size:8]
        ulong xmlSize = BitConverter.ToUInt64(head, 72) & 0x00FF_FFFF_FFFF_FFFFUL;
        ulong xmlOffset = BitConverter.ToUInt64(head, 80);

        if (xmlSize == 0 || xmlSize > 64UL * 1024 * 1024)
        {
            throw new BuildException($"{Path.GetFileName(path)} has no readable image metadata.");
        }

        return new Header
        {
            ImageCount = imageCount,
            PartNumber = partNumber,
            TotalParts = totalParts,
            XmlOffset = xmlOffset,
            XmlSize = xmlSize,
        };
    }

    /// <summary>Returns the raw XML metadata blob as a string.</summary>
    public static string ReadXml(string path)
    {
        Header header = ReadHeader(path);
        using FileStream stream = File.OpenRead(path);
        stream.Seek((long)header.XmlOffset, SeekOrigin.Begin);

        var raw = new byte[(int)header.XmlSize];
        int total = 0;
        while (total < raw.Length)
        {
            int read = stream.Read(raw, total, raw.Length - total);
            if (read <= 0) { break; }
            total += read;
        }
        if (total == 0)
        {
            throw new BuildException($"Couldn't read the image metadata from {Path.GetFileName(path)}.");
        }

        // The blob is UTF-16LE and starts with a BOM.
        string text = Encoding.Unicode.GetString(raw, 0, total);
        return text.Replace("\uFEFF", string.Empty);
    }

    /// <summary>Editions inside the image, in index order.</summary>
    public static List<ImageEdition> Editions(string path)
    {
        string xml = ReadXml(path);
        XDocument document;
        try
        {
            document = XDocument.Parse(xml);
        }
        catch (Exception)
        {
            throw new BuildException("Couldn't parse the image metadata XML.");
        }

        var editions = new List<ImageEdition>();
        foreach (XElement element in document.Descendants("IMAGE"))
        {
            string? indexText = element.Attribute("INDEX")?.Value;
            int index = int.TryParse(indexText, out int parsed) ? parsed : editions.Count + 1;
            string name = FirstText(element, "NAME")
                ?? FirstText(element, "DISPLAYNAME")
                ?? $"Image {index}";
            string description = FirstText(element, "DESCRIPTION")
                ?? FirstText(element, "DISPLAYDESCRIPTION")
                ?? string.Empty;
            long bytes = long.TryParse(FirstText(element, "TOTALBYTES"), out long size) ? size : 0;
            editions.Add(new ImageEdition
            {
                Index = index,
                Name = name,
                EditionDescription = description,
                SizeBytes = bytes,
            });
        }
        editions.Sort((a, b) => a.Index.CompareTo(b.Index));
        return editions;
    }

    private static string? FirstText(XElement parent, string name)
    {
        XElement? child = parent.Element(name);
        string? value = child?.Value.Trim();
        return string.IsNullOrEmpty(value) ? null : value;
    }
}
