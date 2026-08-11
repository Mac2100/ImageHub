using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ImageHub.Support;

/// <summary>The outcome of one external command.</summary>
public sealed class ProcessResult
{
    public int ExitCode { get; init; }

    public string StandardOutput { get; init; } = string.Empty;

    public string StandardError { get; init; } = string.Empty;

    public bool Succeeded => ExitCode == 0;

    /// <summary>Whichever stream said something useful, trimmed for a message.</summary>
    public string FailureMessage
    {
        get
        {
            string text = StandardError.Trim();
            if (text.Length == 0) { text = StandardOutput.Trim(); }
            if (text.Length == 0) { return $"exit code {ExitCode}"; }
            return text.Length > 600 ? text.Substring(0, 600) + "…" : text;
        }
    }
}

/// <summary>
/// Runs the external tools the build needs: Windows PowerShell for disks and ISO
/// mounting, DISM for splitting an oversized install.wim.
///
/// Windows PowerShell 5.1 is used rather than PowerShell 7 because it is present
/// on every Windows installation and the storage cmdlets ship with it — the same
/// reason Windows/ImageHub.ps1 targets it. Scripts go through a temporary .ps1
/// file rather than -Command, so nothing has to be escaped twice and a quote in a
/// template value cannot change the meaning of a command line.
/// </summary>
public static class ProcessRunner
{
    public const string PowerShell = "powershell.exe";

    public const string Dism = "dism.exe";

    public static async Task<ProcessResult> RunAsync(
        string fileName,
        IEnumerable<string> arguments,
        Action<string>? onLine = null,
        CancellationToken cancellation = default)
    {
        var start = new ProcessStartInfo
        {
            FileName = fileName,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (string argument in arguments) { start.ArgumentList.Add(argument); }

        using var process = new Process { StartInfo = start };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();

        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is null) { return; }
            stdout.Append(e.Data).Append('\n');
            onLine?.Invoke(e.Data);
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is null) { return; }
            stderr.Append(e.Data).Append('\n');
            onLine?.Invoke(e.Data);
        };

        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        try
        {
            await process.WaitForExitAsync(cancellation).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            throw;
        }

        return new ProcessResult
        {
            ExitCode = process.ExitCode,
            StandardOutput = stdout.ToString(),
            StandardError = stderr.ToString(),
        };
    }

    /// <summary>
    /// Like <see cref="RunAsync"/> but splits output on carriage returns as well as
    /// newlines. DISM draws its progress bar by rewriting one line with \r, so a
    /// line-based reader sees nothing at all until the whole operation finishes —
    /// and splitting an install.wim is the longest step of a build.
    /// </summary>
    public static async Task<ProcessResult> RunWithProgressAsync(
        string fileName,
        IEnumerable<string> arguments,
        Action<string> onChunk,
        CancellationToken cancellation = default)
    {
        var start = new ProcessStartInfo
        {
            FileName = fileName,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (string argument in arguments) { start.ArgumentList.Add(argument); }

        using var process = new Process { StartInfo = start };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();

        process.Start();

        Task readError = Task.Run(async () =>
        {
            string text = await process.StandardError.ReadToEndAsync().ConfigureAwait(false);
            stderr.Append(text);
        }, CancellationToken.None);

        Task readOutput = Task.Run(async () =>
        {
            var buffer = new char[512];
            var line = new StringBuilder();
            StreamReader reader = process.StandardOutput;
            while (true)
            {
                int read = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                if (read <= 0) { break; }
                for (int i = 0; i < read; i++)
                {
                    char c = buffer[i];
                    if (c == '\r' || c == '\n')
                    {
                        if (line.Length > 0)
                        {
                            string text = line.ToString();
                            stdout.Append(text).Append('\n');
                            onChunk(text);
                            line.Clear();
                        }
                    }
                    else
                    {
                        line.Append(c);
                    }
                }
            }
            if (line.Length > 0)
            {
                string tail = line.ToString();
                stdout.Append(tail).Append('\n');
                onChunk(tail);
            }
        }, CancellationToken.None);

        try
        {
            await process.WaitForExitAsync(cancellation).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            throw;
        }

        await Task.WhenAll(readOutput, readError).ConfigureAwait(false);

        return new ProcessResult
        {
            ExitCode = process.ExitCode,
            StandardOutput = stdout.ToString(),
            StandardError = stderr.ToString(),
        };
    }

    /// <summary>
    /// Runs a PowerShell script from a temporary file. Returns stdout, which for
    /// the callers here is JSON produced by ConvertTo-Json.
    /// </summary>
    public static async Task<ProcessResult> PowerShellAsync(
        string script,
        Action<string>? onLine = null,
        CancellationToken cancellation = default)
    {
        string path = Path.Combine(Path.GetTempPath(),
            "imagehub-" + Guid.NewGuid().ToString("N") + ".ps1");
        try
        {
            // $ErrorActionPreference so a failing cmdlet is an error rather than a
            // warning followed by the script carrying on with half a result.
            await File.WriteAllTextAsync(
                path,
                "$ErrorActionPreference = 'Stop'\r\n$ProgressPreference = 'SilentlyContinue'\r\n" + script,
                new UTF8Encoding(true),
                cancellation).ConfigureAwait(false);

            return await RunAsync(
                PowerShell,
                new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", path },
                onLine,
                cancellation).ConfigureAwait(false);
        }
        finally
        {
            try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited) { process.Kill(entireProcessTree: true); }
        }
        catch (Exception)
        {
        }
    }
}
