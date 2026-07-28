import SwiftUI

struct BuildSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var templateID: UUID?
    @State private var driveID: String?
    @State private var imageID: UUID?
    @State private var confirmed = false
    @State private var showingConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if let job = appState.activeJob {
                BuildProgressView(job: job)
            } else if let job = appState.history.first, job.phase != .idle, confirmed {
                BuildProgressView(job: job)
            } else {
                configuration
            }

            Divider()
            footerBar
        }
        .frame(width: 700, height: 620)
        .onAppear(perform: prime)
    }

    // MARK: - Chrome

    private var headerBar: some View {
        HStack(spacing: 12) {
            theme.glyph(size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(runningJob == nil ? "Build a golden-image USB" : "Building")
                    .font(.headline)
                Text(
                    runningJob == nil
                        ? "Wipe the drive, write Windows Setup, and stage the provisioning payload."
                        : "\(runningJob?.templateName ?? "") → \(runningJob?.driveName ?? "")"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            if let job = displayedJob, job.isRunning {
                Button("Cancel Build", role: .destructive) { job.cancel() }
                Spacer()
                Text(job.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let job = displayedJob, !job.isRunning, job.phase != .idle {
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.logText, forType: .string)
                    ToastCenter.shared.show("Build log copied")
                }
                Spacer()
                Button("Done") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                Spacer()
                if let problem = blockingProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .frame(maxWidth: 340, alignment: .trailing)
                }
                Button("Erase & Build") { showingConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(blockingProblem != nil)
            }
        }
        .padding(14)
        .confirmationDialog(
            "Erase \(selectedDrive?.displayName ?? "this drive")?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Erase and Build", role: .destructive) { start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                """
                Everything on \(selectedDrive?.displayName ?? "the drive") \
                (\(selectedDrive?.sizeBytes.byteSize ?? "")) will be destroyed, and the finished \
                drive will hold the template's passwords in clear text — that's how Windows Setup \
                reads them, so treat it like a key.
                """
            )
        }
    }

    // MARK: - Configuration

    private var configuration: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                step(1, "Template") {
                    if appState.templates.templates.isEmpty {
                        Text("No templates yet — create one first.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: $templateID) {
                            ForEach(appState.templates.templates) { template in
                                Text(template.name).tag(Optional(template.id))
                            }
                        }
                        .labelsHidden()

                        if let template = selectedTemplate {
                            Text(template.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !template.validationErrors.isEmpty {
                                NoticeBanner(
                                    kind: .error,
                                    title: "This template isn't ready",
                                    messages: template.validationErrors
                                )
                            }
                            if !template.validationWarnings.isEmpty {
                                NoticeBanner(
                                    kind: .warning,
                                    title: "Before you build",
                                    messages: template.validationWarnings
                                )
                            }
                        }
                    }
                }

                step(2, "Windows image") {
                    if appState.library.images.filter({ $0.fileExists }).isEmpty {
                        Text("No usable images in the library. Download or import an ISO first.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: $imageID) {
                            ForEach(appState.library.images.filter { $0.fileExists }) { image in
                                Text(image.displayName).tag(Optional(image.id))
                            }
                        }
                        .labelsHidden()

                        if let image = selectedImage {
                            Text("\(image.sizeBytes.byteSize) · \(image.origin.label)\(image.installImageName.isEmpty ? "" : " · \(image.installImageName)")")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if image.installImageNeedsSplit {
                                if WimTools.isAvailable {
                                    NoticeBanner(
                                        kind: .info,
                                        title: "install.wim will be split",
                                        messages: [
                                            "It's \(image.installImageSizeBytes.byteSize), over FAT32's 4 GB file limit, so wimlib splits it into install.swm parts. Windows Setup reads those natively."
                                        ]
                                    )
                                } else {
                                    NoticeBanner(
                                        kind: .error,
                                        title: "wimlib is required for this image",
                                        messages: [WimTools.missingToolMessage]
                                    )
                                }
                            }

                            if let template = selectedTemplate,
                               template.windows.usesCapturedImage {
                                NoticeBanner(
                                    kind: .info,
                                    title: "Template overrides the install image",
                                    messages: [
                                        "Boot files come from this ISO, but the OS is installed from \((template.windows.customWimPath as NSString).lastPathComponent)."
                                    ]
                                )
                            }
                        }
                    }
                }

                step(3, "Target drive") {
                    if appState.drives.isEmpty {
                        Text("No removable drives detected. Plug one in — it'll appear here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(appState.drives) { drive in
                                Button {
                                    driveID = drive.id
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: driveID == drive.id
                                            ? "largecircle.fill.circle" : "circle")
                                            .foregroundStyle(
                                                driveID == drive.id
                                                    ? AnyShapeStyle(theme.primary)
                                                    : AnyShapeStyle(.tertiary)
                                            )
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(drive.displayName)
                                                .font(.callout.weight(.medium))
                                            Text(drive.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(9)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(driveID == drive.id
                                                ? theme.primary.opacity(0.1)
                                                : Color.primary.opacity(0.03))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(
                                                driveID == drive.id
                                                    ? theme.primary.opacity(0.6)
                                                    : Color.primary.opacity(0.07),
                                                lineWidth: 1
                                            )
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func step<Content: View>(
        _ number: Int,
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(theme.primary))
                Text(title)
                    .font(.headline)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Derived state

    private var selectedTemplate: DeploymentTemplate? {
        guard let templateID else { return nil }
        return appState.templates.template(id: templateID)
    }

    private var selectedImage: WindowsImage? {
        guard let imageID else { return nil }
        return appState.library.image(id: imageID)
    }

    private var selectedDrive: USBDrive? {
        appState.drives.first { $0.id == driveID }
    }

    private var runningJob: BuildJob? {
        appState.activeJob
    }

    private var displayedJob: BuildJob? {
        appState.activeJob ?? (confirmed ? appState.history.first : nil)
    }

    private var blockingProblem: String? {
        guard let template = selectedTemplate else { return "Choose a template." }
        if !template.validationErrors.isEmpty { return "Fix the template first." }
        guard let image = selectedImage else { return "Choose a Windows image." }
        guard selectedDrive != nil else { return "Choose a target drive." }
        if image.installImageNeedsSplit && !WimTools.isAvailable {
            return "wimlib is needed to split this image."
        }
        if let drive = selectedDrive, !drive.hasRoom(forISOSize: image.sizeBytes) {
            return "\(drive.displayName) is too small for this image."
        }
        return nil
    }

    // MARK: - Actions

    private func prime() {
        templateID = appState.buildSheetTemplateID
            ?? appState.selectedTemplateID
            ?? appState.templates.templates.first?.id
        driveID = appState.selectedDriveID ?? appState.drives.first?.id

        if let template = selectedTemplate,
           let match = appState.library.bestMatch(for: template) {
            imageID = match.id
        } else {
            imageID = appState.library.images.first { $0.fileExists }?.id
        }
    }

    private func start() {
        guard let template = selectedTemplate,
              let image = selectedImage,
              let drive = selectedDrive else { return }
        confirmed = true
        appState.runBuild(template: template, image: image, drive: drive)
    }

    private func finish() {
        confirmed = false
        appState.buildSheetTemplateID = nil
        dismiss()
    }
}

// MARK: - Progress

struct BuildProgressView: View {
    @ObservedObject var job: BuildJob
    @Environment(\.appTheme) private var theme
    @State private var showLog = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            stageList
            if showLog {
                logView
            }
        }
        .padding(16)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if job.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: resultSymbol)
                        .font(.system(size: 17))
                        .foregroundStyle(resultTint)
                }
                Text(headline)
                    .font(.callout.weight(.medium))
                Spacer()
                if let elapsed = job.elapsed {
                    Text(BuildSummaryRow.duration(elapsed))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button {
                    showLog.toggle()
                } label: {
                    Label(showLog ? "Hide log" : "Show log", systemImage: "text.alignleft")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }

            ProgressView(value: job.overallProgress)
                .progressViewStyle(.linear)

            if case .failed(let message) = job.phase {
                NoticeBanner(kind: .error, title: "Build failed", messages: [message])
            } else if job.phase == .succeeded {
                NoticeBanner(
                    kind: .success,
                    title: "Drive is ready to boot",
                    messages: [
                        "Plug it into the target machine, boot from it, and Setup runs unattended from there. Eject the drive from Finder before pulling it out."
                    ]
                )
            }
        }
        .glassCard()
    }

    private var headline: String {
        switch job.phase {
        case .idle: return "Waiting"
        case .running: return job.detail
        case .succeeded: return "\(job.templateName) written to \(job.driveName)"
        case .failed: return "Stopped"
        case .cancelled: return "Cancelled"
        }
    }

    private var resultSymbol: String {
        switch job.phase {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        default: return "clock"
        }
    }

    private var resultTint: Color {
        switch job.phase {
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        default: return .secondary
        }
    }

    private var stageList: some View {
        VStack(spacing: 0) {
            ForEach(BuildJob.Stage.allCases) { stage in
                let state = job.stages[stage] ?? .pending
                HStack(spacing: 10) {
                    stageIcon(state)
                        .frame(width: 18)
                    Text(stage.title)
                        .font(.callout)
                        .foregroundStyle(textStyle(state))
                    Spacer()
                    if case .running = state, let progress = job.stageProgress {
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if case .skipped(let reason) = state {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if case .failed = state {
                        Text("Failed")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                if stage != BuildJob.Stage.allCases.last {
                    Divider()
                }
            }
        }
        .glassCard(padding: 0)
    }

    @ViewBuilder
    private func stageIcon(_ state: BuildJob.StageState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.tertiary)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func textStyle(_ state: BuildJob.StageState) -> HierarchicalShapeStyle {
        switch state {
        case .pending: return .tertiary
        case .running, .done, .failed: return .primary
        case .skipped: return .secondary
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(job.log) { line in
                        Text(line.text)
                            .font(.system(size: 10.5).monospaced())
                            .foregroundStyle(line.isError ? Color.red : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: .infinity)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
            .onChange(of: job.log.count) { _, _ in
                if let last = job.log.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}
