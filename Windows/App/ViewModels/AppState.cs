using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Threading;
using ImageHub.Models;
using ImageHub.Services;
using ImageHub.Support;

namespace ImageHub.ViewModels;

/// <summary>Sections in the navigation pane.</summary>
public enum Section
{
    Dashboard,
    Templates,
    Images,
    Drives,
    Builds,
}

/// <summary>
/// App-wide state: the stores, the drive list, and the build queue.
///
/// The mac app's equivalent republishes its nested stores through Combine; here each
/// store raises its own Changed event and views subscribe to what they display, which
/// is the same idea with less machinery.
/// </summary>
public sealed class AppState : Observable
{
    public static AppState Shared { get; } = new();

    private Section _section = Section.Dashboard;
    private Guid? _selectedTemplateId;
    private string? _selectedDriveId;
    private bool _isScanningDrives;
    private BuildJob? _activeJob;
    private List<UsbDisk> _drives = new();

    /// <summary>
    /// Windows sends a burst of WM_DEVICECHANGE when a stick is plugged in, so the
    /// rescan waits for the burst to finish rather than running a PowerShell query per
    /// message. A DispatcherTimer rather than a Task delay, so the scan and every
    /// notification it causes stay on the UI thread.
    /// </summary>
    private readonly DispatcherTimer _rescanDebounce =
        new() { Interval = TimeSpan.FromMilliseconds(1500) };

    private AppState()
    {
        Templates = new TemplateStore();
        Library = new ImageLibrary();
        Updates = new UpdateChecker();

        _rescanDebounce.Tick += (_, _) =>
        {
            _rescanDebounce.Stop();
            _ = RefreshDrivesAsync();
        };

        Templates.Changed += (_, _) => Raise(nameof(Templates));
        Library.Changed += (_, _) => Raise(nameof(Library));

        SelectedTemplateId = Templates.Templates.FirstOrDefault()?.Id;
    }

    public TemplateStore Templates { get; }

    public ImageLibrary Library { get; }

    public UpdateChecker Updates { get; }

    public Section CurrentSection
    {
        get => _section;
        set
        {
            if (Set(ref _section, value)) { SectionChanged?.Invoke(this, value); }
        }
    }

    public event EventHandler<Section>? SectionChanged;

    // MARK: - Templates

    public Guid? SelectedTemplateId
    {
        get => _selectedTemplateId;
        set
        {
            if (Set(ref _selectedTemplateId, value)) { SelectionChanged?.Invoke(this, EventArgs.Empty); }
        }
    }

    public event EventHandler? SelectionChanged;

    public DeploymentTemplate? SelectedTemplate =>
        SelectedTemplateId is null ? null : Templates.Template(SelectedTemplateId.Value);

    public void Select(DeploymentTemplate template)
    {
        SelectedTemplateId = template.Id;
        CurrentSection = Section.Templates;
    }

    // MARK: - Drives

    public IReadOnlyList<UsbDisk> Drives => _drives;

    public bool IsScanningDrives { get => _isScanningDrives; private set => Set(ref _isScanningDrives, value); }

    public string? SelectedDriveId { get => _selectedDriveId; set => Set(ref _selectedDriveId, value); }

    public UsbDisk? SelectedDrive => _drives.FirstOrDefault(drive => drive.Id == SelectedDriveId);

    public event EventHandler? DrivesChanged;

    public async Task RefreshDrivesAsync()
    {
        if (IsScanningDrives) { return; }
        // Never re-enumerate disks while a build is mid-write.
        if (ActiveJob?.IsRunning == true) { return; }

        IsScanningDrives = true;
        try
        {
            _drives = await DiskService.ScanAsync().ConfigureAwait(true);
            if (SelectedDriveId is null || _drives.All(drive => drive.Id != SelectedDriveId))
            {
                SelectedDriveId = _drives.FirstOrDefault()?.Id;
            }
        }
        finally
        {
            IsScanningDrives = false;
        }
        Raise(nameof(Drives));
        DrivesChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Called from the window's WM_DEVICECHANGE hook.</summary>
    public void DevicesChanged()
    {
        _rescanDebounce.Stop();
        _rescanDebounce.Start();
    }

    // MARK: - Builds

    public BuildJob? ActiveJob
    {
        get => _activeJob;
        private set
        {
            if (Set(ref _activeJob, value)) { Raise(nameof(IsBuilding)); }
        }
    }

    public List<BuildJob> History { get; } = new();

    public bool IsBuilding => ActiveJob?.IsRunning == true;

    public event EventHandler? HistoryChanged;

    /// <summary>Kicks off the actual write. Returns the job so the dialog can follow it.</summary>
    public BuildJob RunBuild(DeploymentTemplate template, WindowsImage image, UsbDisk drive)
    {
        var job = new BuildJob(template.Name, drive.DisplayName);
        ActiveJob = job;
        History.Insert(0, job);
        if (History.Count > 25) { History.RemoveRange(25, History.Count - 25); }
        HistoryChanged?.Invoke(this, EventArgs.Empty);

        _ = RunBuildAsync(template, image, drive, job);
        return job;
    }

    private async Task RunBuildAsync(
        DeploymentTemplate template,
        WindowsImage image,
        UsbDisk drive,
        BuildJob job)
    {
        // A snapshot, so editing the template while a drive is being written cannot
        // change what lands on it halfway through.
        DeploymentTemplate snapshot = template.DeepCopy();
        await UsbWriter.BuildAsync(snapshot, image, drive, job).ConfigureAwait(true);
        if (ReferenceEquals(ActiveJob, job)) { ActiveJob = null; }
        Raise(nameof(IsBuilding));
        HistoryChanged?.Invoke(this, EventArgs.Empty);
        await RefreshDrivesAsync().ConfigureAwait(true);
    }

    public void ClearFinishedHistory()
    {
        History.RemoveAll(job => !job.IsRunning);
        HistoryChanged?.Invoke(this, EventArgs.Empty);
    }

    // MARK: - Readiness summary for the dashboard

    public sealed class ReadinessReport
    {
        public bool HasTemplate { get; init; }

        public bool HasImage { get; init; }

        public bool HasDrive { get; init; }

        public bool IsElevated { get; init; }

        public bool IsReady => HasTemplate && HasImage && HasDrive && IsElevated;
    }

    public ReadinessReport Readiness => new()
    {
        HasTemplate = Templates.Templates.Any(template => template.IsBuildable),
        HasImage = Library.Images.Any(image => image.FileExists),
        HasDrive = Drives.Count > 0,
        IsElevated = Elevation.IsElevated,
    };
}
