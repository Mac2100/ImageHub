using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

namespace ImageHub.Services;

/// <summary>
/// Copying with progress and a cancel that actually works.
///
/// robocopy would do the copy, but it reports progress in a form meant for a
/// console and cannot be interrupted cleanly mid-file, and a build that cannot be
/// cancelled while writing 5 GB to a slow stick is a build that has to be waited
/// out. So the copy is native: a plan first, so the total is known before anything
/// is written, then a chunked copy that checks for cancellation between chunks.
/// </summary>
public static class FileCopier
{
    /// <summary>4 MB: large enough that a slow USB stick is not syscall-bound.</summary>
    private const int ChunkSize = 4 * 1024 * 1024;

    public sealed class Plan
    {
        public string Root { get; init; } = string.Empty;

        public List<string> RelativeFiles { get; init; } = new();

        public List<string> RelativeDirectories { get; init; } = new();

        public long TotalBytes { get; init; }

        public int FileCount => RelativeFiles.Count;
    }

    /// <summary>
    /// Walks <paramref name="directory"/> and totals what has to be copied.
    /// <paramref name="excluded"/> holds relative paths (with forward slashes) to skip.
    /// </summary>
    public static Plan BuildPlan(string directory, IReadOnlySet<string> excluded)
    {
        var files = new List<string>();
        var directories = new List<string>();
        long total = 0;

        var pending = new Stack<string>();
        pending.Push(directory);
        while (pending.Count > 0)
        {
            string current = pending.Pop();
            foreach (string sub in Directory.GetDirectories(current))
            {
                string relative = Relative(directory, sub);
                directories.Add(relative);
                pending.Push(sub);
            }
            foreach (string file in Directory.GetFiles(current))
            {
                string relative = Relative(directory, file);
                if (excluded.Contains(relative.Replace('\\', '/').ToLowerInvariant())) { continue; }
                // macOS sidecars: a drive built on a Mac and re-copied here should not
                // carry them, and Windows Setup's OS-analysis service cannot parse them.
                string name = Path.GetFileName(file);
                if (name.StartsWith("._", StringComparison.Ordinal)) { continue; }
                if (name.Equals(".DS_Store", StringComparison.OrdinalIgnoreCase)) { continue; }
                files.Add(relative);
                try { total += new FileInfo(file).Length; } catch (IOException) { }
            }
        }

        files.Sort(StringComparer.OrdinalIgnoreCase);
        directories.Sort(StringComparer.OrdinalIgnoreCase);
        return new Plan
        {
            Root = directory,
            RelativeFiles = files,
            RelativeDirectories = directories,
            TotalBytes = total,
        };
    }

    /// <summary>
    /// Copies a plan to <paramref name="destination"/>, reporting 0…1 of the total
    /// bytes as it goes.
    /// </summary>
    public static void Copy(
        Plan plan,
        string destination,
        Action<double, long> progress,
        CancellationToken cancellation)
    {
        Directory.CreateDirectory(destination);
        foreach (string relative in plan.RelativeDirectories)
        {
            Directory.CreateDirectory(Path.Combine(destination, relative));
        }

        long copied = 0;
        var buffer = new byte[ChunkSize];
        foreach (string relative in plan.RelativeFiles)
        {
            cancellation.ThrowIfCancellationRequested();
            string source = Path.Combine(plan.Root, relative);
            string target = Path.Combine(destination, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            CopyOne(source, target, buffer, cancellation, written =>
            {
                copied += written;
                if (plan.TotalBytes > 0)
                {
                    progress(Math.Min(1, (double)copied / plan.TotalBytes), copied);
                }
            });
        }
        progress(1, copied);
    }

    /// <summary>Copies one file, reporting 0…1 of that file.</summary>
    public static void CopyFile(
        string source,
        string destination,
        Action<double> progress,
        CancellationToken cancellation)
    {
        long total = new FileInfo(source).Length;
        long copied = 0;
        var buffer = new byte[ChunkSize];
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        CopyOne(source, destination, buffer, cancellation, written =>
        {
            copied += written;
            if (total > 0) { progress(Math.Min(1, (double)copied / total)); }
        });
        progress(1);
    }

    /// <summary>
    /// Copies a file and returns the number of bytes actually written, so the caller
    /// can compare it with the source. An ISO that silently truncated fails hours
    /// later, halfway through a reimage, rather than here.
    /// </summary>
    public static long CopyVerified(
        string source,
        string destination,
        Action<double> progress,
        CancellationToken cancellation)
    {
        CopyFile(source, destination, progress, cancellation);
        try { return new FileInfo(destination).Length; }
        catch (IOException) { return -1; }
    }

    private static void CopyOne(
        string source,
        string destination,
        byte[] buffer,
        CancellationToken cancellation,
        Action<long> onChunk)
    {
        using FileStream input = new(source, FileMode.Open, FileAccess.Read, FileShare.Read,
            buffer.Length, FileOptions.SequentialScan);
        using FileStream output = new(destination, FileMode.Create, FileAccess.Write, FileShare.None,
            buffer.Length, FileOptions.SequentialScan);
        while (true)
        {
            cancellation.ThrowIfCancellationRequested();
            int read = input.Read(buffer, 0, buffer.Length);
            if (read <= 0) { break; }
            output.Write(buffer, 0, read);
            onChunk(read);
        }
        output.Flush(flushToDisk: false);
    }

    private static string Relative(string root, string path)
    {
        string relative = Path.GetRelativePath(root, path);
        return relative;
    }
}
