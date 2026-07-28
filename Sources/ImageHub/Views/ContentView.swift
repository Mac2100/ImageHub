import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 216, ideal: 232, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottomTrailing) {
            ToastHostView()
        }
        .sheet(isPresented: $appState.showingBuildSheet) {
            BuildSheet()
                .environmentObject(appState)
                .environment(\.appTheme, theme)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.section {
        case .dashboard:
            DashboardView()
        case .templates:
            TemplatesView()
        case .images:
            ImagesView()
        case .drives:
            DrivesView()
        case .builds:
            BuildHistoryView()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header

            List(selection: $appState.section) {
                ForEach(SidebarSection.allCases) { item in
                    Label {
                        HStack {
                            Text(item.label)
                            Spacer()
                            if let badge = badge(for: item) {
                                Text(badge)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: item.symbol)
                    }
                    .tag(item)
                }
            }
            .listStyle(.sidebar)

            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            theme.glyph(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("ImageHub")
                    .font(.headline)
                Text("Windows deployment media")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let job = appState.activeJob, job.isRunning {
                Button {
                    appState.showingBuildSheet = true
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(job.templateName)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(job.overallProgress * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: job.overallProgress)
                            .progressViewStyle(.linear)
                        Text(job.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    appState.startBuild(template: appState.selectedTemplate)
                } label: {
                    Label("Build USB Drive", systemImage: "externaldrive.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(appState.templates.templates.isEmpty)
            }
        }
        .padding(12)
    }

    private func badge(for item: SidebarSection) -> String? {
        switch item {
        case .templates:
            return appState.templates.templates.isEmpty
                ? nil : "\(appState.templates.templates.count)"
        case .images:
            return appState.library.images.isEmpty ? nil : "\(appState.library.images.count)"
        case .drives:
            return appState.drives.isEmpty ? nil : "\(appState.drives.count)"
        case .builds:
            return appState.history.isEmpty ? nil : "\(appState.history.count)"
        case .dashboard:
            return nil
        }
    }
}

/// Standard page chrome: title, subtitle, trailing controls.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
