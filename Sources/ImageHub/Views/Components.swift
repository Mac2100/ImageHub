import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Wrappers around `NSOpenPanel` / `NSSavePanel`, kept in one place so the views
/// stay declarative.
enum Panels {
    static func chooseFile(
        title: String,
        types: [UTType]? = nil,
        directories: Bool = false
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if let types { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func save(title: String, suggestedName: String, types: [UTType]? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = suggestedName
        if let types { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// A read-only path display with Choose / Clear buttons.
struct PathField: View {
    let label: String
    @Binding var path: String
    var prompt: String = "Not set"
    var types: [UTType]?
    var directories = false

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(display)
                    .font(.callout)
                    .foregroundStyle(path.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(path.isEmpty ? prompt : path)

                Button("Choose…") {
                    if let url = Panels.chooseFile(
                        title: label, types: types, directories: directories
                    ) {
                        path = url.path
                    }
                }
                .controlSize(.small)

                if !path.isEmpty {
                    Button {
                        path = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }
        }
    }

    private var display: String {
        path.isEmpty ? prompt : (path as NSString).lastPathComponent
    }
}

/// A password field backed by `SecretStore` rather than the template JSON.
struct SecretPasswordField: View {
    let label: String
    let templateID: UUID
    let slot: SecretStore.Slot
    var footer: String?

    @State private var value = ""
    @State private var stored = false
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(label) {
                HStack(spacing: 6) {
                    if revealed {
                        TextField("", text: $value)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField(stored ? "••••••••" : "", text: $value)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revealed ? "Hide" : "Show")

                    Button("Save") {
                        SecretStore.set(value, for: templateID, slot: slot)
                        stored = SecretStore.has(templateID, slot: slot)
                        ToastCenter.shared.show(
                            stored ? "\(slot.label) saved" : "\(slot.label) cleared",
                            detail: "Stored in the \(SecretStore.backend.label.lowercased())"
                        )
                    }
                    .controlSize(.small)
                    .disabled(value.isEmpty && !stored)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: stored ? "checkmark.shield.fill" : "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(stored ? Color.green : Color.orange)
                Text(
                    stored
                        ? "Stored in the \(SecretStore.backend.label.lowercased())."
                        : "Not set yet."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let footer {
                    Text("· \(footer)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            stored = SecretStore.has(templateID, slot: slot)
            value = ""
        }
        .onChange(of: templateID) { _, _ in
            stored = SecretStore.has(templateID, slot: slot)
            value = ""
            revealed = false
        }
    }
}

/// Inline warning / info banner used across the editor and build sheet.
struct NoticeBanner: View {
    enum Kind {
        case info, warning, error, success

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            case .success: return "checkmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .info: return .blue
            case .warning: return .orange
            case .error: return .red
            case .success: return .green
            }
        }
    }

    let kind: Kind
    let title: String
    var messages: [String] = []

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.color)
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.medium))
                ForEach(messages, id: \.self) { message in
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(kind.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(kind.color.opacity(0.25), lineWidth: 1)
        )
    }
}

/// Same look as `NoticeBanner`, but every line is a button that jumps to the part
/// of the template the problem came from. Used by the editor's Review tab, where
/// "Admin account has no password set." is only useful if it can take you there.
struct IssueBanner: View {
    let kind: NoticeBanner.Kind
    let title: String
    let issues: [ValidationIssue]
    let destination: (ValidationIssue) -> String
    let action: (ValidationIssue) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.color)
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.callout.weight(.medium))
                ForEach(issues) { issue in
                    IssueRow(
                        issue: issue,
                        tint: kind.color,
                        destination: destination(issue),
                        action: { action(issue) }
                    )
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(kind.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(kind.color.opacity(0.25), lineWidth: 1)
        )
    }
}

private struct IssueRow: View {
    let issue: ValidationIssue
    let tint: Color
    let destination: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 2) {
                    Text(destination)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
                .opacity(hovering ? 1 : 0.65)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(hovering ? 0.12 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Go to \(destination)")
    }
}

/// Empty-state placeholder with an optional call to action.
struct EmptyStateView<Action: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.weight(.medium))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            action
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

extension EmptyStateView where Action == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

extension UTType {
    static let diskImage = UTType("public.disk-image") ?? .data
    static let iso = UTType(filenameExtension: "iso") ?? .diskImage
    static let wim = UTType(filenameExtension: "wim") ?? .data
}
