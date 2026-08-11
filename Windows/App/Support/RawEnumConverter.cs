using System;
using System.Collections.Generic;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ImageHub.Support;

/// <summary>
/// The exact string a template stores for an enum case.
///
/// The template JSON is a contract shared with the macOS app and with
/// Provision.ps1, so these strings are Swift's raw values — <c>win11</c>,
/// <c>proWorkstations</c>, <c>leaveOOBE</c> — not whatever C# naming would
/// produce. Spelling them out means a rename on this side can never silently
/// change what lands on a drive.
/// </summary>
[AttributeUsage(AttributeTargets.Field)]
public sealed class RawAttribute : Attribute
{
    public RawAttribute(string value) { Value = value; }

    public string Value { get; }
}

/// <summary>
/// Reads and writes an enum using its <see cref="RawAttribute"/> values.
///
/// Unknown and malformed values decode to the enum's default rather than
/// throwing, which mirrors the macOS side: templates are hand-edited files, and
/// one stale key should fall back to a default rather than reject the file.
/// </summary>
public sealed class RawEnumConverter<T> : JsonConverter<T> where T : struct, Enum
{
    private static readonly Dictionary<string, T> ByRaw = BuildRawMap();
    private static readonly Dictionary<T, string> ByValue = BuildValueMap();

    private static Dictionary<string, T> BuildRawMap()
    {
        var map = new Dictionary<string, T>(StringComparer.OrdinalIgnoreCase);
        foreach (FieldInfo field in typeof(T).GetFields(BindingFlags.Public | BindingFlags.Static))
        {
            var value = (T)field.GetValue(null)!;
            map[Raw(field)] = value;
        }
        return map;
    }

    private static Dictionary<T, string> BuildValueMap()
    {
        var map = new Dictionary<T, string>();
        foreach (FieldInfo field in typeof(T).GetFields(BindingFlags.Public | BindingFlags.Static))
        {
            map[(T)field.GetValue(null)!] = Raw(field);
        }
        return map;
    }

    private static string Raw(FieldInfo field) =>
        field.GetCustomAttribute<RawAttribute>()?.Value ?? field.Name;

    public static string RawValue(T value) => ByValue.TryGetValue(value, out string? raw) ? raw : value.ToString();

    public override T Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.String)
        {
            string? text = reader.GetString();
            if (text is not null && ByRaw.TryGetValue(text, out T value)) { return value; }
            return default;
        }
        // Anything else (a number, an object, null) is a malformed template; skip
        // over it and take the default rather than failing the whole file.
        reader.Skip();
        return default;
    }

    public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options)
    {
        writer.WriteStringValue(RawValue(value));
    }
}

/// <summary>Convenience for the UI: the raw value of any enum carrying RawAttribute.</summary>
public static class RawEnum
{
    public static string Of<T>(T value) where T : struct, Enum
    {
        FieldInfo? field = typeof(T).GetField(value.ToString()!, BindingFlags.Public | BindingFlags.Static);
        return field?.GetCustomAttribute<RawAttribute>()?.Value ?? value.ToString()!;
    }
}
