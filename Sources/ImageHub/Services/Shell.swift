import Foundation

struct CommandResult {
    var status: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { status == 0 }

    /// Best-effort single-line failure reason for surfacing in the UI.
    var failureMessage: String {
        let text = stderr.isEmpty ? stdout : stderr
        let line = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "exit code \(status)"
        return String(line.prefix(300))
    }
}

struct CommandError: LocalizedError {
    let tool: String
    let result: CommandResult

    var errorDescription: String? {
        "\((tool as NSString).lastPathComponent) failed: \(result.failureMessage)"
    }
}

/// Thin wrapper around `Process`. Everything ImageHub does to a disk goes
/// through here (`diskutil`, `hdiutil`, `rsync`, `wimlib-imagex`), which keeps
/// the destructive surface small and auditable.
enum Shell {
    /// Runs a tool to completion off the main thread, optionally streaming
    /// combined output line by line as it arrives.
    static func run(
        _ tool: String,
        _ arguments: [String],
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            try runBlocking(tool, arguments, onLine: onLine)
        }.value
    }

    /// Runs a tool and throws unless it exits 0.
    @discardableResult
    static func check(
        _ tool: String,
        _ arguments: [String],
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        let result = try await run(tool, arguments, onLine: onLine)
        guard result.succeeded else { throw CommandError(tool: tool, result: result) }
        return result
    }

    /// Runs a tool and returns its stdout, or nil if it isn't available / fails.
    static func output(_ tool: String, _ arguments: [String]) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let result = try? await run(tool, arguments)
        guard let result, result.succeeded else { return nil }
        return result.stdout
    }

    // MARK: - Blocking core

    nonisolated static func runBlocking(
        _ tool: String,
        _ arguments: [String],
        onLine: (@Sendable (String) -> Void)? = nil
    ) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw CommandError(
                tool: tool,
                result: CommandResult(status: -1, stdout: "", stderr: "\(tool) is not available on this Mac.")
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector(onLine: onLine)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData, stream: .out)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData, stream: .err)
        }

        try process.run()
        process.waitUntilExit()

        // Drain anything the handlers haven't seen yet, then detach them.
        collector.append(outPipe.fileHandleForReading.readDataToEndOfFile(), stream: .out)
        collector.append(errPipe.fileHandleForReading.readDataToEndOfFile(), stream: .err)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        collector.flush()

        return CommandResult(
            status: process.terminationStatus,
            stdout: collector.stdout,
            stderr: collector.stderr
        )
    }
}

/// Accumulates process output and splits it into lines for live log streaming.
/// `readabilityHandler` fires on an arbitrary queue, so all state is lock-guarded.
private final class OutputCollector: @unchecked Sendable {
    enum Stream { case out, err }

    private let lock = NSLock()
    private var outBuffer = ""
    private var errBuffer = ""
    private var pendingLine = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    var stdout: String { lock.sync { outBuffer } }
    var stderr: String { lock.sync { errBuffer } }

    func append(_ data: Data, stream: Stream) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        var completed: [String] = []
        lock.sync {
            switch stream {
            case .out: outBuffer += text
            case .err: errBuffer += text
            }
            guard onLine != nil else { return }
            // `diskutil` and `rsync` both emit \r for in-place progress updates.
            pendingLine += text.replacingOccurrences(of: "\r", with: "\n")
            while let index = pendingLine.firstIndex(of: "\n") {
                let line = String(pendingLine[pendingLine.startIndex..<index])
                pendingLine = String(pendingLine[pendingLine.index(after: index)...])
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { completed.append(trimmed) }
            }
        }
        completed.forEach { onLine?($0) }
    }

    func flush() {
        var remainder: String?
        lock.sync {
            let trimmed = pendingLine.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { remainder = trimmed }
            pendingLine = ""
        }
        if let remainder { onLine?(remainder) }
    }
}

extension NSLock {
    /// Named `sync` rather than `withLock` so it never overlaps with
    /// Foundation's own `NSLocking.withLock`.
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
