using System;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ImageHub.Support;

/// <summary>
/// JSON settings for everything ImageHub reads and writes.
///
/// Template files are the contract with the macOS app, with Provision.ps1 and
/// with whoever hand-edits one in a pull request, so two properties matter more
/// than convenience:
///
/// * Names match Swift's exactly. camelCase covers most of it, and every name
///   with an acronym in it carries an explicit [JsonPropertyName] in the model.
/// * Reading is lenient. A missing key takes the property's default, and a key
///   holding the wrong kind of value takes the default too rather than rejecting
///   the file — the same behaviour as the macOS side's decoding helpers.
/// </summary>
public static class Json
{
    public static readonly JsonSerializerOptions Options = Build(indented: false);

    public static readonly JsonSerializerOptions Pretty = Build(indented: true);

    private static JsonSerializerOptions Build(bool indented)
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            PropertyNameCaseInsensitive = true,
            WriteIndented = indented,
            DefaultIgnoreCondition = JsonIgnoreCondition.Never,
            NumberHandling = JsonNumberHandling.AllowReadingFromString,
            ReadCommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        };
        options.Converters.Add(new LenientInt32Converter());
        options.Converters.Add(new LenientInt64Converter());
        options.Converters.Add(new LenientBooleanConverter());
        options.Converters.Add(new LenientStringConverter());
        options.Converters.Add(new SwiftDateTimeConverter());
        options.Converters.Add(new UppercaseGuidConverter());
        return options;
    }

    public static T? Deserialize<T>(string text) => JsonSerializer.Deserialize<T>(text, Options);

    public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Pretty);
}

internal sealed class LenientInt32Converter : JsonConverter<int>
{
    public override int Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        switch (reader.TokenType)
        {
            case JsonTokenType.Number:
                if (reader.TryGetInt32(out int value)) { return value; }
                if (reader.TryGetDouble(out double approximate)) { return (int)approximate; }
                return 0;
            case JsonTokenType.String:
                _ = int.TryParse(reader.GetString(), NumberStyles.Integer,
                    CultureInfo.InvariantCulture, out int parsed);
                return parsed;
            case JsonTokenType.True: return 1;
            case JsonTokenType.False:
            case JsonTokenType.Null: return 0;
            default:
                reader.Skip();
                return 0;
        }
    }

    public override void Write(Utf8JsonWriter writer, int value, JsonSerializerOptions options) =>
        writer.WriteNumberValue(value);
}

internal sealed class LenientInt64Converter : JsonConverter<long>
{
    public override long Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        switch (reader.TokenType)
        {
            case JsonTokenType.Number:
                if (reader.TryGetInt64(out long value)) { return value; }
                if (reader.TryGetDouble(out double approximate)) { return (long)approximate; }
                return 0;
            case JsonTokenType.String:
                _ = long.TryParse(reader.GetString(), NumberStyles.Integer,
                    CultureInfo.InvariantCulture, out long parsed);
                return parsed;
            default:
                reader.Skip();
                return 0;
        }
    }

    public override void Write(Utf8JsonWriter writer, long value, JsonSerializerOptions options) =>
        writer.WriteNumberValue(value);
}

internal sealed class LenientBooleanConverter : JsonConverter<bool>
{
    public override bool Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        switch (reader.TokenType)
        {
            case JsonTokenType.True: return true;
            case JsonTokenType.False:
            case JsonTokenType.Null: return false;
            case JsonTokenType.Number:
                return reader.TryGetDouble(out double number) && number != 0;
            case JsonTokenType.String:
                string? text = reader.GetString();
                return string.Equals(text, "true", StringComparison.OrdinalIgnoreCase)
                    || text == "1" || string.Equals(text, "yes", StringComparison.OrdinalIgnoreCase);
            default:
                reader.Skip();
                return false;
        }
    }

    public override void Write(Utf8JsonWriter writer, bool value, JsonSerializerOptions options) =>
        writer.WriteBooleanValue(value);
}

internal sealed class LenientStringConverter : JsonConverter<string>
{
    public override string Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        switch (reader.TokenType)
        {
            case JsonTokenType.String: return reader.GetString() ?? string.Empty;
            case JsonTokenType.Number:
                return reader.TryGetInt64(out long number)
                    ? number.ToString(CultureInfo.InvariantCulture)
                    : reader.GetDouble().ToString(CultureInfo.InvariantCulture);
            case JsonTokenType.True: return "true";
            case JsonTokenType.False: return "false";
            case JsonTokenType.Null: return string.Empty;
            default:
                reader.Skip();
                return string.Empty;
        }
    }

    public override void Write(Utf8JsonWriter writer, string value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value);
}

/// <summary>
/// ISO 8601 without fractional seconds, in UTC — exactly what Swift's
/// <c>ISO8601DateFormatter</c> writes and, more to the point, all its default
/// configuration will read. A stamp with fractional seconds decodes to nil there,
/// which would quietly reset the created/updated dates of any template that had
/// been through Windows.
/// </summary>
internal sealed class SwiftDateTimeConverter : JsonConverter<DateTime>
{
    public override DateTime Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.String)
        {
            string? text = reader.GetString();
            if (DateTime.TryParse(text, CultureInfo.InvariantCulture,
                    DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out DateTime parsed))
            {
                return parsed;
            }
            return DateTime.UtcNow;
        }
        if (reader.TokenType == JsonTokenType.Number && reader.TryGetDouble(out double seconds))
        {
            // Swift's default Date encoding is seconds since 2001-01-01.
            return new DateTime(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(seconds);
        }
        reader.Skip();
        return DateTime.UtcNow;
    }

    public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options)
    {
        DateTime utc = value.Kind == DateTimeKind.Utc ? value : value.ToUniversalTime();
        writer.WriteStringValue(utc.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture));
    }
}

/// <summary>
/// Upper-case GUIDs, because Swift's <c>UUID.uuidString</c> is upper case and a
/// template that has been round-tripped through Windows should not read as
/// gratuitously different in a diff.
/// </summary>
internal sealed class UppercaseGuidConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.String
            && Guid.TryParse(reader.GetString(), out Guid value))
        {
            return value;
        }
        if (reader.TokenType != JsonTokenType.String) { reader.Skip(); }
        return Guid.NewGuid();
    }

    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}
