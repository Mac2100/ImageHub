import SwiftUI
import UniformTypeIdentifiers

struct TemplatesView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    @State private var search = ""
    @State private var pendingDeletion: DeploymentTemplate?

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 268)
            Divider()
            editor
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Template", role: .destructive) {
                if let template = pendingDeletion {
                    appState.templates.delete(template)
                    if appState.selectedTemplateID == template.id {
                        appState.selectedTemplateID = appState.templates.templates.first?.id
                    }
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Its stored passwords are removed too. This can't be undone.")
        }
    }

    // MARK: - List

    private var filtered: [DeploymentTemplate] {
        let all = appState.templates.templates
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.summary.localizedCaseInsensitiveContains(search)
                || $0.apps.contains { app in
                    app.displayName.localizedCaseInsensitiveContains(search)
                }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                SearchField(text: $search, prompt: "Filter templates", width: 178)
                Spacer()
            }
            .padding(10)

            if filtered.isEmpty {
                EmptyStateView(
                    symbol: "square.stack.3d.up.slash",
                    title: search.isEmpty ? "No templates" : "No matches",
                    message: search.isEmpty
                        ? "Create a template to describe how a machine should come out of the box."
                        : "Nothing matches “\(search)”."
                )
            } else {
                List(selection: $appState.selectedTemplateID) {
                    ForEach(filtered) { template in
                        TemplateRow(template: template)
                            .tag(template.id)
                            .contextMenu {
                                Button("Build USB Drive…") {
                                    appState.startBuild(template: template)
                                }
                                Button("Duplicate") {
                                    let copy = appState.templates.duplicate(template)
                                    appState.selectedTemplateID = copy.id
                                }
                                Button("Export…") { export(template) }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    pendingDeletion = template
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            toolbar
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            Button {
                let template = appState.templates.newTemplate()
                appState.selectedTemplateID = template.id
            } label: {
                Image(systemName: "plus")
            }
            .help("New template")

            Button {
                if let template = appState.selectedTemplate {
                    pendingDeletion = template
                }
            } label: {
                Image(systemName: "minus")
            }
            .disabled(appState.selectedTemplate == nil)
            .help("Delete template")

            Button {
                if let template = appState.selectedTemplate {
                    let copy = appState.templates.duplicate(template)
                    appState.selectedTemplateID = copy.id
                }
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .disabled(appState.selectedTemplate == nil)
            .help("Duplicate template")

            Spacer()

            Menu {
                Button("Import Template…") { importTemplate() }
                Button("Export Selected…") {
                    if let template = appState.selectedTemplate { export(template) }
                }
                .disabled(appState.selectedTemplate == nil)
                Divider()
                Button("Reveal Templates Folder") {
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: appState.templates.directoryURL.path
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(7)
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        if let template = appState.selectedTemplate {
            TemplateEditorView(template: template)
                .id(template.id)
        } else {
            EmptyStateView(
                symbol: "square.stack.3d.up",
                title: "No template selected",
                message: "Pick a template on the left, or create one with +."
            ) {
                Button("New Template") {
                    let template = appState.templates.newTemplate()
                    appState.selectedTemplateID = template.id
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Import / export

    private func importTemplate() {
        guard let url = Panels.chooseFile(title: "Import Template", types: [.json]) else { return }
        do {
            let template = try appState.templates.importTemplate(from: url)
            appState.selectedTemplateID = template.id
            ToastCenter.shared.show("Template imported", detail: template.name)
        } catch {
            ToastCenter.shared.show(
                "Couldn't import that file",
                detail: error.localizedDescription,
                style: .error
            )
        }
    }

    private func export(_ template: DeploymentTemplate) {
        let name = template.name
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespaces)
        guard let url = Panels.save(
            title: "Export Template",
            suggestedName: "\(name.isEmpty ? "Template" : name).json",
            types: [.json]
        ) else { return }
        do {
            try appState.templates.export(template, to: url)
            ToastCenter.shared.show("Template exported", detail: url.lastPathComponent)
        } catch {
            ToastCenter.shared.show(
                "Export failed",
                detail: error.localizedDescription,
                style: .error
            )
        }
    }
}

struct TemplateRow: View {
    let template: DeploymentTemplate
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.gradient.opacity(0.9))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: template.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(template.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(template.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if !template.isBuildable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(template.validationErrors.joined(separator: "\n"))
            }
        }
        .padding(.vertical, 3)
    }
}
