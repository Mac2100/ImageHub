import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                checklist
                if !appState.history.isEmpty {
                    recentBuilds
                }
                stats
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 26)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PageHeader(
                title: "Overview",
                subtitle: "Wipe a machine, build the drive, reimage from a template."
            ) {
                Button {
                    appState.startBuild(template: nil)
                } label: {
                    Label("Build USB Drive", systemImage: "externaldrive.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isBuilding || appState.templates.templates.isEmpty)
            }
            .background(.bar)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(spacing: 18) {
            theme.glyph(size: 62)
            VStack(alignment: .leading, spacing: 6) {
                Text(appState.readiness.isReady ? "Ready to build" : "A couple of things to set up")
                    .font(.title3.weight(.semibold))
                Text(
                    appState.readiness.isReady
                        ? "Pick a template, choose the drive, and ImageHub does the rest — wipe, write, and stage the provisioning payload."
                        : "Work through the checklist below and the build button lights up."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .glassCard(padding: 20)
    }

    // MARK: - Checklist

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Getting ready")
                .font(.headline)

            VStack(spacing: 0) {
                checklistRow(
                    done: appState.readiness.hasTemplate,
                    symbol: "square.stack.3d.up",
                    title: "A buildable deployment template",
                    detail: appState.readiness.hasTemplate
                        ? "\(appState.templates.templates.filter { $0.isBuildable }.count) of \(appState.templates.templates.count) templates are complete."
                        : "Templates need at least a name and an admin password.",
                    actionTitle: "Templates"
                ) {
                    appState.section = .templates
                }

                Divider()

                checklistRow(
                    done: appState.readiness.hasImage,
                    symbol: "opticaldiscdrive",
                    title: "A Windows image in the library",
                    detail: appState.readiness.hasImage
                        ? "\(appState.library.images.filter { $0.fileExists }.count) image(s), \(appState.library.totalBytesOnDisk.byteSize) on disk."
                        : "Download the latest ISO from Microsoft, or import one you already have.",
                    actionTitle: "Images"
                ) {
                    appState.section = .images
                }

                Divider()

                checklistRow(
                    done: appState.readiness.hasDrive,
                    symbol: "externaldrive",
                    title: "A USB drive plugged in",
                    detail: appState.readiness.hasDrive
                        ? appState.drives.map { $0.displayName }.joined(separator: ", ")
                        : "Plug in a 16 GB or larger stick. Internal disks are never offered.",
                    actionTitle: "Drives"
                ) {
                    appState.section = .drives
                }

                if appState.readiness.needsSplitTool {
                    Divider()
                    checklistRow(
                        done: appState.readiness.hasSplitTool,
                        symbol: "scissors",
                        title: "wimlib, for splitting install.wim",
                        detail: appState.readiness.hasSplitTool
                            ? "Found at \(WimTools.locate() ?? "—")."
                            : "Your image's install.wim is over 4 GB, so it must be split to fit the FAT32 boot volume.",
                        actionTitle: "Set up"
                    ) {
                        NSApp.sendAction(
                            Selector(("showSettingsWindow:")), to: nil, from: nil
                        )
                    }
                }
            }
            .glassCard(padding: 0)
        }
    }

    private func checklistRow(
        done: Bool,
        symbol: String,
        title: String,
        detail: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 17))
                .foregroundStyle(done ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                .frame(width: 22)

            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Recent builds

    private var recentBuilds: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent builds")
                    .font(.headline)
                Spacer()
                Button("See all") { appState.section = .builds }
                    .buttonStyle(.link)
                    .font(.callout)
            }

            VStack(spacing: 0) {
                ForEach(Array(appState.history.prefix(3))) { job in
                    BuildSummaryRow(job: job)
                    if job.id != appState.history.prefix(3).last?.id {
                        Divider()
                    }
                }
            }
            .glassCard(padding: 0)
        }
    }

    // MARK: - Stats

    private var stats: some View {
        HStack(spacing: 12) {
            statCard(
                value: "\(appState.templates.templates.count)",
                label: "Templates",
                symbol: "square.stack.3d.up"
            )
            statCard(
                value: "\(appState.library.images.count)",
                label: "Images",
                symbol: "opticaldiscdrive"
            )
            statCard(
                value: appState.library.totalBytesOnDisk.byteSize,
                label: "On disk",
                symbol: "internaldrive"
            )
            statCard(
                value: "\(appState.drives.count)",
                label: "USB drives",
                symbol: "externaldrive"
            )
        }
    }

    private func statCard(value: String, label: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(theme.primary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
    }
}

/// One row in a build list: state, names, elapsed time.
struct BuildSummaryRow: View {
    @ObservedObject var job: BuildJob

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.templateName)
                    .font(.callout.weight(.medium))
                Text("→ \(job.driveName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(stateLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tint)
                if let elapsed = job.elapsed {
                    Text(Self.duration(elapsed))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var symbol: String {
        switch job.phase {
        case .idle: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        }
    }

    private var tint: Color {
        switch job.phase {
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        default: return .secondary
        }
    }

    private var stateLabel: String {
        switch job.phase {
        case .idle: return "Queued"
        case .running: return "\(Int(job.overallProgress * 100))%"
        case .succeeded: return "Ready"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let remainder = total % 60
        if minutes < 60 { return "\(minutes)m \(remainder)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
