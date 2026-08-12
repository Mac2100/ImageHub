using System;
using System.IO;
using System.Runtime.InteropServices;
using ImageHub.Models;
using ImageHub.Services;

namespace ImageHub.Support;

/// <summary>
/// A couple of non-interactive entry points, checked before the window comes up.
///
/// These exist mainly so CI can verify the generated artifacts on every push — the
/// answer file has the least margin for error of anything ImageHub produces (a
/// malformed one fails on a technician's bench, not in a build) and the app is the
/// only thing that knows how to produce it. They are also what lets CI compare the
/// Windows app's output against the macOS app's, which is the check that keeps the
/// two able to build interchangeable media.
///
/// Deliberately the same flags as the macOS binary's, so one CI script drives both.
/// </summary>
public static class CommandLineTools
{
    /// <summary>
    /// Handles a command-line mode. Returns the process exit code, or null when the
    /// app should carry on and show its window.
    ///
    /// A WinExe has no console of its own, so output only lands somewhere when it is
    /// redirected — which is how CI uses it. AttachConsole hands the rest to whoever
    /// launched it, so `ImageHub.exe --version` in a terminal prints rather than
    /// silently doing nothing.
    /// </summary>
    public static int? Run(string[] arguments)
    {
        if (arguments.Length == 0) { return null; }

        string command = arguments[0];
        string? templatePath = arguments.Length > 1 ? arguments[1] : null;

        switch (command)
        {
            case "--emit-answer-file":
                AttachConsole();
                Print(new AnswerFileBuilder(LoadTemplate(templatePath)).Build());
                return 0;

            case "--emit-payload-config":
                AttachConsole();
                return EmitPayloadConfig(templatePath);

            case "--emit-office-config":
                AttachConsole();
                DeploymentTemplate office = LoadTemplate(templatePath);
                // The starter template has Office off; emit what it *would* write so the
                // check has something to parse.
                office.Microsoft365.Enabled = true;
                Print(OfficeConfigBuilder.Xml(office));
                return 0;

            case "--emit-template":
                AttachConsole();
                Print(Json.Serialize(LoadTemplate(templatePath)));
                return 0;

            case "--list-payload":
                AttachConsole();
                foreach (string name in PayloadSource.Names()) { Print(name); }
                return 0;

            case "--version":
                AttachConsole();
                Print(AppVersion.Current);
                return 0;

            case "--help":
            case "-h":
            case "/?":
                AttachConsole();
                Print(Help);
                return 0;

            default:
                // Anything else is left alone; Windows and shell integrations pass their
                // own arguments and must not be mistaken for a command.
                return null;
        }
    }

    private static string Help => $"""
        ImageHub {AppVersion.Current}

        Usage:
          ImageHub.exe                                     Launch the app
          ImageHub.exe --emit-answer-file [template.json]   Print the generated autounattend.xml
          ImageHub.exe --emit-payload-config [template.json]
                                                           Print the generated payload config.json
          ImageHub.exe --emit-office-config [template.json]
                                                           Print the generated Office configuration.xml
          ImageHub.exe --emit-template [template.json]      Print the template as ImageHub stores it
          ImageHub.exe --list-payload                       List the embedded provisioning scripts
          ImageHub.exe --version                            Print the version
          ImageHub.exe --help                               Show this

        With no template path, the built-in "Standard Workstation" starter is used.
        Passwords are never included — these modes read no secrets from the store.
        """;

    /// <summary>
    /// The built-in starter's Id is a fresh Guid every time it is constructed, which is
    /// right for the app and wrong for a fixture: CI generates from this template on
    /// both platforms and compares the results, and a random templateID in config.json
    /// is a difference on every run. Pinning it keeps that field genuinely compared —
    /// including that both apps write a GUID the same way — rather than excluded from
    /// the comparison. Must match CommandLineTools.fixtureTemplateID on the macOS side.
    /// A template loaded from a file needs no such help: its id travels with the JSON.
    /// </summary>
    public const string FixtureTemplateId = "0F1E2D3C-4B5A-4697-8899-AABBCCDDEEFF";

    private static DeploymentTemplate LoadTemplate(string? path)
    {
        if (path is null)
        {
            DeploymentTemplate starter = DeploymentTemplate.StandardWorkstation();
            starter.Id = Guid.Parse(FixtureTemplateId);
            return starter;
        }
        try
        {
            DeploymentTemplate? template = Json.Deserialize<DeploymentTemplate>(File.ReadAllText(path));
            if (template is null) { throw new InvalidDataException("not an ImageHub template"); }
            return template;
        }
        catch (Exception error)
        {
            PrintError($"error: couldn't read {path}: {error.Message}");
            Environment.Exit(2);
            throw;
        }
    }

    private static int EmitPayloadConfig(string? templatePath)
    {
        DeploymentTemplate template = LoadTemplate(templatePath);
        string directory = Path.Combine(Path.GetTempPath(), "imagehub-emit-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            // Empty secrets on purpose: this mode must never touch the secret store.
            string payload = PayloadBuilder.Write(template, new ResolvedSecrets(), directory, _ => { });
            Print(File.ReadAllText(Path.Combine(payload, PayloadBuilder.ConfigFileName)));
            return 0;
        }
        catch (Exception error)
        {
            PrintError("error: " + error.Message);
            return 2;
        }
        finally
        {
            try { Directory.Delete(directory, recursive: true); } catch (Exception) { }
        }
    }

    // Newlines are written as \n rather than \r\n so a file redirected on Windows is
    // byte-comparable with the same file produced on macOS.
    private static void Print(string text)
    {
        Console.Out.Write(text.Replace("\r\n", "\n"));
        if (!text.EndsWith("\n", StringComparison.Ordinal)) { Console.Out.Write('\n'); }
        Console.Out.Flush();
    }

    private static void PrintError(string text)
    {
        Console.Error.Write(text.Replace("\r\n", "\n") + "\n");
        Console.Error.Flush();
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(uint processId);

    private const uint AttachParentProcess = 0xFFFFFFFF;

    private static void AttachConsole()
    {
        try { AttachConsole(AttachParentProcess); } catch (Exception) { }
    }
}
