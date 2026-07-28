import Foundation

/// Thread-safe cancellation flag shared with background copy work.
///
/// Reading `@MainActor` state from a detached task is what crashed 1.0.3:
/// `MainActor.assumeIsolated` traps when the caller genuinely isn't on the main
/// actor, and the file copier's `isCancelled` callback runs on a cooperative
/// background thread. A plain locked box has no isolation to assume.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool { lock.sync { flag } }

    func cancel() { lock.sync { flag = true } }
}

/// Live state for one "make me a golden-image USB" run.
@MainActor
final class BuildJob: ObservableObject, Identifiable {
    enum Stage: String, CaseIterable, Identifiable {
        case validate
        case acquireImage
        case erase
        case copyBootFiles
        case installImage
        case answerFile
        case payload
        case verify

        var id: String { rawValue }

        var title: String {
            switch self {
            case .validate: return "Check template and drive"
            case .acquireImage: return "Get the Windows image"
            case .erase: return "Wipe and format the drive"
            case .copyBootFiles: return "Copy boot files"
            case .installImage: return "Write the install image"
            case .answerFile: return "Generate the answer file"
            case .payload: return "Write the provisioning payload"
            case .verify: return "Verify the media"
            }
        }

        var symbol: String {
            switch self {
            case .validate: return "checklist"
            case .acquireImage: return "arrow.down.circle"
            case .erase: return "eraser"
            case .copyBootFiles: return "doc.on.doc"
            case .installImage: return "shippingbox"
            case .answerFile: return "doc.text"
            case .payload: return "shippingbox.and.arrow.backward"
            case .verify: return "checkmark.seal"
            }
        }
    }

    enum StageState: Equatable {
        case pending
        case running
        case done
        case skipped(String)
        case failed(String)
    }

    enum Phase: Equatable {
        case idle
        case running
        case succeeded
        case failed(String)
        case cancelled
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let timestamp: Date
        let text: String
        let isError: Bool
    }

    let id = UUID()
    let templateName: String
    let driveName: String

    /// Safe to read from background work; mirrors `cancelRequested`.
    nonisolated let cancelToken = CancelToken()

    @Published var phase: Phase = .idle
    @Published var stages: [Stage: StageState] = [:]
    @Published var currentStage: Stage?
    /// 0…1 within the current stage, or nil when the stage can't report progress.
    @Published var stageProgress: Double?
    @Published var detail: String = ""
    @Published var log: [LogLine] = []
    @Published var startedAt: Date?
    @Published var finishedAt: Date?

    /// When each stage started, and how long the finished ones took.
    ///
    /// Without this, "the build has been running 45 minutes" says nothing about
    /// which step is slow — and on this workload one step legitimately takes
    /// longer than all the others together.
    @Published var stageStartedAt: [Stage: Date] = [:]
    @Published var stageDuration: [Stage: TimeInterval] = [:]

    /// Set by the UI; long-running steps check it between chunks.
    @Published var cancelRequested = false

    init(templateName: String, driveName: String) {
        self.templateName = templateName
        self.driveName = driveName
        for stage in Stage.allCases {
            stages[stage] = .pending
        }
    }

    var isRunning: Bool { phase == .running }

    var elapsed: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// Overall progress across stages, blending in the current stage's own progress.
    var overallProgress: Double {
        let total = Double(Stage.allCases.count)
        var completed = 0.0
        for stage in Stage.allCases {
            switch stages[stage] ?? .pending {
            case .done, .skipped: completed += 1
            case .running: completed += stageProgress ?? 0.25
            default: break
            }
        }
        return min(1, completed / total)
    }

    func begin(_ stage: Stage, _ message: String? = nil) {
        currentStage = stage
        stages[stage] = .running
        stageProgress = nil
        stageStartedAt[stage] = Date()
        detail = message ?? stage.title
        append(message ?? "\(stage.title)…")
    }

    func finish(_ stage: Stage) {
        stages[stage] = .done
        stageProgress = nil
        if let started = stageStartedAt[stage] {
            let took = Date().timeIntervalSince(started)
            stageDuration[stage] = took
            if took >= 10 {
                append("\(stage.title) took \(BuildJob.shortDuration(took)).")
            }
        }
    }

    /// How long `stage` has been running, or took. `now` is a parameter so a view
    /// can pass its own tick and genuinely depend on it.
    func duration(of stage: Stage, at now: Date = Date()) -> TimeInterval? {
        if let done = stageDuration[stage] { return done }
        guard stages[stage] == .running, let started = stageStartedAt[stage] else { return nil }
        return now.timeIntervalSince(started)
    }

    static func shortDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    func skip(_ stage: Stage, _ reason: String) {
        stages[stage] = .skipped(reason)
        append("Skipped \(stage.title.lowercased()): \(reason)")
    }

    func fail(_ stage: Stage?, _ message: String) {
        if let stage { stages[stage] = .failed(message) }
        phase = .failed(message)
        finishedAt = Date()
        currentStage = nil
        append(message, isError: true)
    }

    func succeed() {
        phase = .succeeded
        finishedAt = Date()
        currentStage = nil
        stageProgress = nil
        detail = "Drive ready"
        append("Drive ready.")
    }

    func cancel() {
        cancelRequested = true
        cancelToken.cancel()
        append("Cancelling…", isError: true)
    }

    func markCancelled() {
        phase = .cancelled
        finishedAt = Date()
        currentStage = nil
        detail = "Cancelled"
    }

    /// `at` is when the line was *produced*. Background work hops to the main
    /// actor to log, so a line produced during the payload step can land after a
    /// line produced by the verify step — which is how a real build log ended up
    /// claiming it verified the media before writing the payload. Timestamping at
    /// the source and inserting in order keeps the log a truthful record.
    func append(_ text: String, at moment: Date = Date(), isError: Bool = false) {
        let line = LogLine(timestamp: moment, text: text, isError: isError)
        if let last = log.last, last.timestamp > moment {
            let index = log.lastIndex { $0.timestamp <= moment }.map { $0 + 1 } ?? 0
            log.insert(line, at: index)
        } else {
            log.append(line)
        }
        // A long split emits thousands of progress lines; keep the tail.
        if log.count > 2000 {
            log.removeFirst(log.count - 2000)
        }
    }

    /// Full log as plain text, for "Copy log" / saving alongside a failure.
    var logText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return log
            .map { "[\(formatter.string(from: $0.timestamp))] \($0.text)" }
            .joined(separator: "\n")
    }
}

struct CancellationRequested: LocalizedError {
    var errorDescription: String? { "Build cancelled." }
}
