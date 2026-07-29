import Foundation

/// Native file copying with byte-accurate progress and cancellation.
///
/// This deliberately does not shell out to `rsync`. macOS still ships rsync
/// 2.6.9 from 2006, which has no `--info=progress2` — the copy step failed
/// outright on a stock Mac. `ditto` has no progress reporting at all. Doing it
/// here means no dependency on which tools a particular macOS happens to have,
/// real progress on the multi-gigabyte files that dominate the build, and a
/// cancel button that responds mid-file.
enum FileCopier {
    struct CopyError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 8 MB — large enough that syscall overhead is irrelevant, small enough
    /// that progress and cancellation stay responsive.
    private static let chunkSize = 8 * 1024 * 1024

    struct Item {
        let source: URL
        let relativePath: String
        let size: Int64
        let isDirectory: Bool
    }

    struct Plan {
        var items: [Item]
        var totalBytes: Int64
        var fileCount: Int
    }

    /// Names skipped anywhere in the tree.
    private static let alwaysSkip: Set<String> = [
        ".DS_Store",
        ".Spotlight-V100",
        ".fseventsd",
        ".TemporaryItems",
        ".Trashes",
        "System Volume Information"
    ]

    /// macOS AppleDouble sidecars — `._foo.inf` beside `foo.inf` — holding
    /// resource forks and extended attributes for filesystems that can't store
    /// them. They are meaningless to Windows and actively harmful on install
    /// media: Setup enumerates `Sources\Migration\WTR\*.inf`, finds
    /// `._adminpack_en-us.inf`, tries to parse an AppleDouble blob as an INF, and
    /// its OS-analysis service fails. Seen on a real build's setuperr.log.
    private static func isAppleDouble(_ name: String) -> Bool {
        name.hasPrefix("._")
    }

    /// Walks `directory` and totals up what needs copying.
    /// `excluding` holds lower-cased relative paths (e.g. `sources/install.wim`).
    nonisolated static func plan(
        directory: URL,
        excluding: Set<String> = []
    ) throws -> Plan {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw CopyError(message: "Couldn't read \(directory.lastPathComponent).")
        }

        let base = directory.standardizedFileURL.path
        var items: [Item] = []
        var totalBytes: Int64 = 0
        var fileCount = 0

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if alwaysSkip.contains(name) || isAppleDouble(name) {
                enumerator.skipDescendants()
                continue
            }

            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base) else { continue }
            var relative = String(full.dropFirst(base.count))
            while relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty else { continue }

            if excluding.contains(relative.lowercased()) { continue }

            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                items.append(Item(source: url, relativePath: relative, size: 0, isDirectory: true))
                continue
            }
            guard values?.isRegularFile == true else { continue }

            let size = Int64(values?.fileSize ?? 0)
            items.append(Item(source: url, relativePath: relative, size: size, isDirectory: false))
            totalBytes += size
            fileCount += 1
        }

        return Plan(items: items, totalBytes: totalBytes, fileCount: fileCount)
    }

    /// Copies a planned tree, reporting 0…1 as bytes land.
    nonisolated static func copy(
        plan: Plan,
        to destination: URL,
        progress: @Sendable (Double, String) -> Void,
        isCancelled: @Sendable () -> Bool
    ) throws {
        let fm = FileManager.default
        var copied: Int64 = 0

        // Directories first, so files never race their parent.
        for item in plan.items where item.isDirectory {
            if isCancelled() { throw CancellationRequested() }
            try fm.createDirectory(
                at: destination.appendingPathComponent(item.relativePath),
                withIntermediateDirectories: true
            )
        }

        for item in plan.items where !item.isDirectory {
            if isCancelled() { throw CancellationRequested() }
            let target = destination.appendingPathComponent(item.relativePath)
            try fm.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let before = copied
            try copyFile(
                from: item.source,
                to: target,
                progress: { fileFraction in
                    guard plan.totalBytes > 0 else { return }
                    let done = before + Int64(Double(item.size) * fileFraction)
                    progress(min(1, Double(done) / Double(plan.totalBytes)), item.relativePath)
                },
                isCancelled: isCancelled
            )
            copied += item.size
            if plan.totalBytes > 0 {
                progress(min(1, Double(copied) / Double(plan.totalBytes)), item.relativePath)
            }
        }
    }

    /// Streams one file across in chunks, reporting 0…1 for that file.
    nonisolated static func copyFile(
        from source: URL,
        to destination: URL,
        progress: @Sendable (Double) -> Void,
        isCancelled: @Sendable () -> Bool
    ) throws {
        let fm = FileManager.default

        let attributes = try? fm.attributesOfItem(atPath: source.path)
        let total = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        // fsync costs whole seconds on a cheap flash controller: measured on a
        // real build, 975 small files took 20 minutes at 0.73 MB/s while wimlib
        // writing 7.5 GB to the same stick managed 2.67 MB/s. One flush per file
        // was the entire difference. Flush only files big enough for the cost to
        // disappear into the transfer; the rest are flushed by the OS, and the
        // build ejects the volume when it finishes.
        let flushWhenDone = total >= 64 * 1024 * 1024

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw CopyError(
                message: "Couldn't create \(destination.lastPathComponent) on the target volume."
            )
        }

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var written: Int64 = 0
        while true {
            if isCancelled() {
                try? fm.removeItem(at: destination)
                throw CancellationRequested()
            }
            guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            written += Int64(chunk.count)
            if total > 0 { progress(min(1, Double(written) / Double(total))) }
        }
        if flushWhenDone { try output.synchronize() }

        // A short write means the volume filled up or the source vanished; that
        // has to be an error here rather than unbootable media discovered later.
        if total > 0 && written != total {
            try? fm.removeItem(at: destination)
            throw CopyError(
                message: """
                    \(source.lastPathComponent) copied \(written.byteSize) of \(total.byteSize) — \
                    the destination may be out of space.
                    """
            )
        }
        progress(1)
    }

    /// Copies a single file with size verification, used for imports.
    /// Returns the number of bytes copied.
    @discardableResult
    nonisolated static func copyVerified(
        from source: URL,
        to destination: URL,
        progress: @Sendable (Double) -> Void = { _ in }
    ) throws -> Int64 {
        try copyFile(from: source, to: destination, progress: progress, isCancelled: { false })
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
