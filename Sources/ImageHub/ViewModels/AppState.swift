import AppKit
import Combine
import SwiftUI

/// Sections in the sidebar. Deliberately not called `Section` — that name
/// belongs to SwiftUI and shadowing it breaks every `Form`.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case templates
    case images
    case drives
    case builds

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: return "Overview"
        case .templates: return "Templates"
        case .images: return "Windows Images"
        case .drives: return "USB Drives"
        case .builds: return "Build History"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .templates: return "square.stack.3d.up"
        case .images: return "opticaldiscdrive"
        case .drives: return "externaldrive"
        case .builds: return "clock.arrow.circlepath"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var section: SidebarSection = .dashboard
    @Published var selectedTemplateID: UUID?

    let templates = TemplateStore()
    let library = ImageLibrary()
    let updates = UpdateChecker()

    // Drives
    @Published var drives: [USBDrive] = []
    @Published var rejectedDrives: [RejectedDrive] = []
    @Published var isScanningDrives = false
    @Published var selectedDriveID: String?

    // Builds
    @Published var activeJob: BuildJob?
    @Published var history: [BuildJob] = []
    @Published var showingBuildSheet = false
    /// Pre-selected template when the build sheet is opened from a template row.
    @Published var buildSheetTemplateID: UUID?

    private var driveTimer: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // The stores are nested ObservableObjects. SwiftUI only observes the
        // object a view actually holds, so their change notifications are
        // republished through AppState — otherwise `appState.templates.templates`
        // updates without ever redrawing.
        for publisher in [
            templates.objectWillChange.eraseToAnyPublisher(),
            library.objectWillChange.eraseToAnyPublisher(),
            updates.objectWillChange.eraseToAnyPublisher()
        ] {
            publisher
                .sink { [weak self] _ in
                    // These publishers are owned by @MainActor stores, so this
                    // always runs on the main thread.
                    MainActor.assumeIsolated { self?.objectWillChange.send() }
                }
                .store(in: &cancellables)
        }

        Task { await refreshDrives() }
        startDriveWatch()
    }

    // MARK: - Drives

    /// Drives are polled rather than watched: `DADiskAppeared` callbacks need a
    /// run-loop session and a poll every few seconds is plenty for a picker.
    private func startDriveWatch() {
        driveTimer = Timer.publish(every: 4, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isScanningDrives else { return }
                    // Don't re-enumerate disks while a build is mid-write.
                    guard self.activeJob?.isRunning != true else { return }
                    Task { await self.refreshDrives() }
                }
            }
    }

    func refreshDrives() async {
        isScanningDrives = true
        let result = await DiskService.scan()
        drives = result.eligible
        rejectedDrives = result.rejected
        if let selected = selectedDriveID, !drives.contains(where: { $0.id == selected }) {
            selectedDriveID = drives.first?.id
        } else if selectedDriveID == nil {
            selectedDriveID = drives.first?.id
        }
        isScanningDrives = false
    }

    var selectedDrive: USBDrive? {
        drives.first { $0.id == selectedDriveID }
    }

    // MARK: - Templates

    var selectedTemplate: DeploymentTemplate? {
        guard let selectedTemplateID else { return nil }
        return templates.template(id: selectedTemplateID)
    }

    func select(_ template: DeploymentTemplate) {
        selectedTemplateID = template.id
        section = .templates
    }

    // MARK: - Builds

    /// Opens the build wizard, optionally pinned to a template.
    func startBuild(template: DeploymentTemplate?) {
        buildSheetTemplateID = template?.id ?? selectedTemplateID ?? templates.templates.first?.id
        showingBuildSheet = true
    }

    /// Kicks off the actual write. Returns the job so the sheet can follow it.
    @discardableResult
    func runBuild(template: DeploymentTemplate, image: WindowsImage, drive: USBDrive) -> BuildJob {
        let job = BuildJob(templateName: template.name, driveName: drive.displayName)
        activeJob = job
        history.insert(job, at: 0)
        if history.count > 25 { history.removeLast(history.count - 25) }

        Task {
            await USBWriter.build(template: template, image: image, drive: drive, job: job)
            if activeJob === job { activeJob = nil }
            await refreshDrives()
        }
        return job
    }

    var isBuilding: Bool { activeJob?.isRunning == true }

    // MARK: - Window

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Readiness summary for the dashboard

    struct Readiness {
        var hasTemplate: Bool
        var hasImage: Bool
        var hasDrive: Bool
        var hasSplitTool: Bool
        var needsSplitTool: Bool

        var isReady: Bool {
            hasTemplate && hasImage && hasDrive && (!needsSplitTool || hasSplitTool)
        }
    }

    var readiness: Readiness {
        let usableImages = library.images.filter { $0.fileExists }
        return Readiness(
            hasTemplate: templates.templates.contains { $0.isBuildable },
            hasImage: !usableImages.isEmpty,
            hasDrive: !drives.isEmpty,
            hasSplitTool: WimTools.isAvailable,
            needsSplitTool: usableImages.contains { $0.installImageNeedsSplit }
        )
    }
}
