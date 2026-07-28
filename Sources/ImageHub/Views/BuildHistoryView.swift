import SwiftUI

struct BuildHistoryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var expandedID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if appState.history.isEmpty {
                    EmptyStateView(
                        symbol: "clock.arrow.circlepath",
                        title: "No builds yet",
                        message: "Every drive you write shows up here with its full log, so you can see exactly what happened on a machine you handed over last week."
                    ) {
                        Button("Build USB Drive") {
                            appState.startBuild(template: nil)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.templates.templates.isEmpty)
                    }
                    .frame(minHeight: 320)
                } else {
                    ForEach(appState.history) { job in
                        HistoryCard(
                            job: job,
                            isExpanded: expandedID == job.id,
                            onToggle: { expandedID = expandedID == job.id ? nil : job.id }
                        )
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 26)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PageHeader(
                title: "Build History",
                subtitle: appState.history.isEmpty
                    ? "Nothing built in this session"
                    : "\(appState.history.count) build\(appState.history.count == 1 ? "" : "s") this session"
            ) {
                if !appState.history.isEmpty {
                    Button("Clear") {
                        appState.history.removeAll { !$0.isRunning }
                    }
                    .disabled(appState.history.allSatisfy { $0.isRunning })
                }
            }
            .background(.bar)
        }
    }
}

struct HistoryCard: View {
    @ObservedObject var job: BuildJob
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack {
                    BuildSummaryRow(job: job)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 14)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    if let started = job.startedAt {
                        Text("Started \(started.briefFormatted)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(job.log) { line in
                                Text(line.text)
                                    .font(.system(size: 10.5).monospaced())
                                    .foregroundStyle(line.isError ? Color.red : Color.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 220)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))

                    HStack {
                        Button("Copy Log") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(job.logText, forType: .string)
                            ToastCenter.shared.show("Build log copied")
                        }
                        .controlSize(.small)

                        Button("Save Log…") { saveLog() }
                            .controlSize(.small)

                        Spacer()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 13)
            }
        }
        .glassCard(padding: 0)
    }

    private func saveLog() {
        let stamp = (job.startedAt ?? Date()).formatted(
            .iso8601.year().month().day().dateSeparator(.dash)
        )
        guard let url = Panels.save(
            title: "Save Build Log",
            suggestedName: "ImageHub-\(job.templateName)-\(stamp).log".replacingOccurrences(of: "/", with: "-"),
            types: [.plainText]
        ) else { return }
        do {
            try Data(job.logText.utf8).write(to: url)
            ToastCenter.shared.show("Log saved", detail: url.lastPathComponent)
        } catch {
            ToastCenter.shared.show(
                "Couldn't save the log",
                detail: error.localizedDescription,
                style: .error
            )
        }
    }
}
