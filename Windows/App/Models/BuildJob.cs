using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using System.Windows.Threading;
using ImageHub.Support;

namespace ImageHub.Models;

/// <summary>
/// Live state for one "make me a golden-image USB" run.
///
/// The stage list is the same eight steps the macOS app shows, in the same order,
/// because they describe the work rather than the platform. Everything mutating
/// hops to the dispatcher the job was created on, so the writer can log from a
/// background copy loop without the UI ever touching state off-thread.
/// </summary>
public sealed class BuildJob : Observable
{
    public enum Stage
    {
        Validate,
        AcquireImage,
        Erase,
        CopyBootFiles,
        InstallImage,
        AnswerFile,
        Payload,
        Verify,
    }

    public enum StageState
    {
        Pending,
        Running,
        Done,
        Skipped,
        Failed,
    }

    public enum Phase
    {
        Idle,
        Running,
        Succeeded,
        Failed,
        Cancelled,
    }

    public sealed class LogLine
    {
        public DateTime Timestamp { get; init; }

        public string Text { get; init; } = string.Empty;

        public bool IsError { get; init; }
    }

    public static readonly Stage[] AllStages = (Stage[])Enum.GetValues(typeof(Stage));

    public static string Title(Stage stage) => stage switch
    {
        Stage.Validate => "Check template and drive",
        Stage.AcquireImage => "Get the Windows image",
        Stage.Erase => "Wipe and format the drive",
        Stage.CopyBootFiles => "Copy boot files",
        Stage.InstallImage => "Write the install image",
        Stage.AnswerFile => "Generate the answer file",
        Stage.Payload => "Write the provisioning payload",
        Stage.Verify => "Verify the media",
        _ => stage.ToString(),
    };

    private readonly Dispatcher? _dispatcher;
    private readonly CancellationTokenSource _cancellation = new();
    private readonly object _gate = new();
    private readonly List<LogLine> _log = new();
    private readonly Dictionary<Stage, StageState> _states = new();
    private readonly Dictionary<Stage, string> _stageNotes = new();
    private readonly Dictionary<Stage, DateTime> _stageStarted = new();
    private readonly Dictionary<Stage, TimeSpan> _stageDuration = new();

    private Phase _phase = Phase.Idle;
    private Stage? _currentStage;
    private double? _stageProgress;
    private string _detail = string.Empty;
    private DateTime? _startedAt;
    private DateTime? _finishedAt;
    private string _failureMessage = string.Empty;

    public BuildJob(string templateName, string driveName)
    {
        TemplateName = templateName;
        DriveName = driveName;
        _dispatcher = Dispatcher.FromThread(Thread.CurrentThread);
        foreach (Stage stage in AllStages) { _states[stage] = StageState.Pending; }
    }

    public Guid Id { get; } = Guid.NewGuid();

    public string TemplateName { get; }

    public string DriveName { get; }

    /// <summary>Safe to read from background work.</summary>
    public CancellationToken CancellationToken => _cancellation.Token;

    public bool CancelRequested => _cancellation.IsCancellationRequested;

    public Phase CurrentPhase { get => _phase; private set => Set(ref _phase, value); }

    public Stage? CurrentStage { get => _currentStage; private set => Set(ref _currentStage, value); }

    /// <summary>0…1 within the current stage, or null when the stage can't report progress.</summary>
    public double? StageProgress { get => _stageProgress; private set => Set(ref _stageProgress, value); }

    public string Detail { get => _detail; private set => Set(ref _detail, value); }

    public DateTime? StartedAt { get => _startedAt; private set => Set(ref _startedAt, value); }

    public DateTime? FinishedAt { get => _finishedAt; private set => Set(ref _finishedAt, value); }

    public string FailureMessage { get => _failureMessage; private set => Set(ref _failureMessage, value); }

    public bool IsRunning => CurrentPhase == Phase.Running;

    public TimeSpan? Elapsed =>
        StartedAt is null ? null : (FinishedAt ?? DateTime.Now) - StartedAt.Value;

    public IReadOnlyList<LogLine> Log
    {
        get { lock (_gate) { return _log.ToList(); } }
    }

    public StageState StateOf(Stage stage)
    {
        lock (_gate) { return _states.TryGetValue(stage, out StageState state) ? state : StageState.Pending; }
    }

    public string NoteOf(Stage stage)
    {
        lock (_gate) { return _stageNotes.TryGetValue(stage, out string? note) ? note : string.Empty; }
    }

    /// <summary>
    /// How long a stage has been running, or took. A whole-build timer cannot say
    /// which step is slow, and on this workload one step routinely takes longer than
    /// all the others together.
    /// </summary>
    public TimeSpan? DurationOf(Stage stage, DateTime now)
    {
        lock (_gate)
        {
            if (_stageDuration.TryGetValue(stage, out TimeSpan done)) { return done; }
            if (_states.TryGetValue(stage, out StageState state) && state == StageState.Running
                && _stageStarted.TryGetValue(stage, out DateTime started))
            {
                return now - started;
            }
            return null;
        }
    }

    /// <summary>Overall progress across stages, blending in the current stage's own progress.</summary>
    public double OverallProgress
    {
        get
        {
            double total = AllStages.Length;
            double completed = 0;
            lock (_gate)
            {
                foreach (Stage stage in AllStages)
                {
                    switch (_states.TryGetValue(stage, out StageState state) ? state : StageState.Pending)
                    {
                        case StageState.Done:
                        case StageState.Skipped:
                            completed += 1;
                            break;
                        case StageState.Running:
                            completed += StageProgress ?? 0.25;
                            break;
                    }
                }
            }
            return Math.Min(1, completed / total);
        }
    }

    // MARK: - Transitions

    public void Start()
    {
        OnUi(() =>
        {
            CurrentPhase = Phase.Running;
            StartedAt = DateTime.Now;
            Raise(nameof(OverallProgress));
        });
    }

    public void Begin(Stage stage, string? message = null)
    {
        OnUi(() =>
        {
            lock (_gate)
            {
                _states[stage] = StageState.Running;
                _stageStarted[stage] = DateTime.Now;
            }
            CurrentStage = stage;
            StageProgress = null;
            Detail = message ?? Title(stage);
            Append(message ?? Title(stage) + "…");
            Raise(nameof(OverallProgress));
        });
    }

    public void Finish(Stage stage)
    {
        OnUi(() =>
        {
            TimeSpan? took = null;
            lock (_gate)
            {
                _states[stage] = StageState.Done;
                if (_stageStarted.TryGetValue(stage, out DateTime started))
                {
                    took = DateTime.Now - started;
                    _stageDuration[stage] = took.Value;
                }
            }
            StageProgress = null;
            if (took is not null && took.Value.TotalSeconds >= 10)
            {
                Append($"{Title(stage)} took {Formatting.ShortDuration(took.Value)}.");
            }
            Raise(nameof(OverallProgress));
        });
    }

    public void Skip(Stage stage, string reason)
    {
        OnUi(() =>
        {
            lock (_gate)
            {
                _states[stage] = StageState.Skipped;
                _stageNotes[stage] = reason;
            }
            Append($"Skipped {Title(stage).ToLowerInvariant()}: {reason}");
            Raise(nameof(OverallProgress));
        });
    }

    public void Progress(double fraction, string? detail = null)
    {
        OnUi(() =>
        {
            StageProgress = Math.Clamp(fraction, 0, 1);
            if (detail is not null) { Detail = detail; }
            Raise(nameof(OverallProgress));
        });
    }

    public void Fail(Stage? stage, string message)
    {
        OnUi(() =>
        {
            if (stage is not null)
            {
                lock (_gate)
                {
                    _states[stage.Value] = StageState.Failed;
                    _stageNotes[stage.Value] = message;
                }
            }
            FailureMessage = message;
            CurrentPhase = Phase.Failed;
            FinishedAt = DateTime.Now;
            CurrentStage = null;
            Append(message, isError: true);
            Raise(nameof(OverallProgress));
        });
    }

    public void Succeed()
    {
        OnUi(() =>
        {
            CurrentPhase = Phase.Succeeded;
            FinishedAt = DateTime.Now;
            CurrentStage = null;
            StageProgress = null;
            Detail = "Drive ready";
            Append("Drive ready.");
            Raise(nameof(OverallProgress));
        });
    }

    public void Cancel()
    {
        Append("Cancelling…", isError: true);
        try { _cancellation.Cancel(); } catch (ObjectDisposedException) { }
    }

    public void MarkCancelled()
    {
        OnUi(() =>
        {
            CurrentPhase = Phase.Cancelled;
            FinishedAt = DateTime.Now;
            CurrentStage = null;
            Detail = "Cancelled";
            Raise(nameof(OverallProgress));
        });
    }

    // MARK: - Log

    /// <summary>
    /// <paramref name="moment"/> is when the line was *produced*. Background work
    /// hops to the UI thread to log, so a line produced during the payload step can
    /// land after one produced by the verify step — which is how a real build log
    /// ended up claiming it verified the media before writing the payload.
    /// Timestamping at the source and inserting in order keeps the log truthful.
    /// </summary>
    public void Append(string text, DateTime? at = null, bool isError = false)
    {
        DateTime moment = at ?? DateTime.Now;
        OnUi(() =>
        {
            var line = new LogLine { Timestamp = moment, Text = text, IsError = isError };
            lock (_gate)
            {
                if (_log.Count > 0 && _log[^1].Timestamp > moment)
                {
                    int index = _log.FindLastIndex(existing => existing.Timestamp <= moment) + 1;
                    _log.Insert(index, line);
                }
                else
                {
                    _log.Add(line);
                }
                // A long split emits thousands of progress lines; keep the tail.
                if (_log.Count > 2000) { _log.RemoveRange(0, _log.Count - 2000); }
            }
            LineAppended?.Invoke(this, line);
            Raise(nameof(Log));
        });
    }

    public event EventHandler<LogLine>? LineAppended;

    /// <summary>Full log as plain text, for "Copy log" / saving alongside a failure.</summary>
    public string LogText
    {
        get
        {
            var text = new StringBuilder();
            foreach (LogLine line in Log)
            {
                text.Append('[').Append(Formatting.Clock(line.Timestamp)).Append("] ")
                    .Append(line.Text).Append("\r\n");
            }
            return text.ToString();
        }
    }

    private void OnUi(Action action)
    {
        if (_dispatcher is null || _dispatcher.CheckAccess())
        {
            action();
            return;
        }
        _dispatcher.BeginInvoke(action);
    }
}

/// <summary>Thrown when the operator cancels a build.</summary>
public sealed class BuildCancelledException : Exception
{
    public BuildCancelledException() : base("Build cancelled.")
    {
    }
}

/// <summary>A problem that stopped a build, with a message meant for an operator.</summary>
public sealed class BuildException : Exception
{
    public BuildException(string message) : base(message)
    {
    }
}
