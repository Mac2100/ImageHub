import SwiftUI
import UniformTypeIdentifiers

struct ImagesView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    @State private var showingURLSheet = false
    @State private var pendingDeletion: WindowsImage?
    @State private var expandedID: UUID?
    @State private var downloadLog: [String] = []
    @State private var lastDownloadFailed = false

    private var library: ImageLibrary { appState.library }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if library.isBusy {
                    busyCard
                }

                if library.images.isEmpty && !library.isBusy {
                    EmptyStateView(
                        symbol: "opticaldiscdrive",
                        title: "No Windows images yet",
                        message: "Get the current retail ISO from Microsoft in your browser, then import it — their download service refuses automated requests, so that round trip is the reliable path. Enterprise and LTSC media has to be imported too, since Microsoft doesn't publish it."
                    ) {
                        HStack {
                            Button("Get Windows 11 ISO…") {
                                openMicrosoftPage(.win11)
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Import ISO…") { importISO() }
                            Button("Try Direct Download") { download(.win11) }
                        }
                    }
                    .frame(minHeight: 320)
                } else {
                    VStack(spacing: 0) {
                        ForEach(library.images) { image in
                            ImageRow(
                                image: image,
                                isExpanded: expandedID == image.id,
                                onToggle: {
                                    expandedID = expandedID == image.id ? nil : image.id
                                },
                                onVerify: { Task { await library.verify(image) } },
                                onReinspect: { Task { await library.reinspect(image) } },
                                onDelete: { pendingDeletion = image },
                                onUse: { use(image) }
                            )
                            if image.id != library.images.last?.id {
                                Divider()
                            }
                        }
                    }
                    .glassCard(padding: 0)
                }

                if lastDownloadFailed {
                    VStack(alignment: .leading, spacing: 10) {
                        NoticeBanner(
                            kind: .info,
                            title: "Microsoft wouldn't hand over a download link",
                            messages: [
                                "Their anti-abuse check refuses clients that aren't a real browser session. ImageHub can't reliably satisfy it, and this isn't a sign anything else is wrong.",
                                "Downloading the ISO in a browser takes about the same time and always works. Grab it, then use Import ISO to add it to the library."
                            ]
                        )
                        HStack(spacing: 8) {
                            Button {
                                openMicrosoftPage(.win11)
                            } label: {
                                Label("Open Microsoft's Download Page", systemImage: "safari")
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Import ISO…") { importISO() }
                            Spacer()
                        }
                    }
                }

                if !downloadLog.isEmpty {
                    logCard
                }

                NoticeBanner(
                    kind: .info,
                    title: "Where these come from",
                    messages: [
                        "ImageHub never mirrors or modifies Microsoft's images — whichever route you use, the bytes come from Microsoft.",
                        "“Try direct download” asks the same public service microsoft.com uses. It often refuses non-browser clients, which is why the browser round trip is the default. For a team, host one approved ISO on an internal URL with a pinned SHA-256 so everyone builds from identical bytes."
                    ]
                )
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 26)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PageHeader(
                title: "Windows Images",
                subtitle: library.images.isEmpty
                    ? "Nothing in the library yet"
                    : "\(library.images.count) image\(library.images.count == 1 ? "" : "s") · \(library.totalBytesOnDisk.byteSize) on disk"
            ) {
                HStack(spacing: 8) {
                    Menu {
                        Button("Open Microsoft's Download Page…") { openMicrosoftPage(.win11) }
                        Divider()
                        Button("Try Direct Download (Windows 11)") { download(.win11) }
                        Button("Try Direct Download (Windows 10)") { download(.win10) }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .fixedSize()
                    .disabled(library.isBusy)

                    Button {
                        importISO()
                    } label: {
                        Label("Import ISO…", systemImage: "folder")
                    }
                    .disabled(library.isBusy)

                    Button {
                        showingURLSheet = true
                    } label: {
                        Label("From URL…", systemImage: "link")
                    }
                    .disabled(library.isBusy)
                }
            }
            .background(.bar)
        }
        .sheet(isPresented: $showingURLSheet) {
            ImageFromURLSheet()
                .environmentObject(appState)
        }
        .confirmationDialog(
            "Remove “\(pendingDeletion?.displayName ?? "")”?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let image = pendingDeletion, image.managed {
                Button("Delete ISO from Disk", role: .destructive) {
                    library.remove(image, deleteFile: true)
                    pendingDeletion = nil
                }
            }
            Button("Remove from Library") {
                if let image = pendingDeletion {
                    library.remove(image, deleteFile: false)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(
                (pendingDeletion?.managed ?? false)
                    ? "This ISO lives inside ImageHub's library folder. You can delete the file or just forget about it."
                    : "This ISO is linked from elsewhere on disk, so only the library record is removed."
            )
        }
    }

    // MARK: - Cards

    private var busyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(library.busyMessage.isEmpty ? "Working…" : library.busyMessage)
                    .font(.callout.weight(.medium))
                Spacer()
                if library.downloader.isDownloading, library.downloader.canCancel {
                    Button("Cancel") { library.downloader.cancel() }
                        .controlSize(.small)
                }
            }

            if library.downloader.isDownloading {
                ProgressView(value: library.downloader.progress)
                Text(library.downloader.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let hash = library.hashProgress {
                ProgressView(value: hash)
                Text("Hashing — \(Int(hash * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .glassCard()
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Download log")
                    .font(.headline)
                Spacer()
                Button("Clear") { downloadLog = [] }
                    .controlSize(.small)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(downloadLog.enumerated()), id: \.offset) { entry in
                        Text(entry.element)
                            .font(.system(size: 11).monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(height: 120)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
        .glassCard()
    }

    // MARK: - Actions

    private func download(_ release: WindowsRelease) {
        downloadLog = []
        lastDownloadFailed = false
        let language = UserDefaults.standard.string(forKey: "defaultLanguage") ?? "en-US"
        Task { @MainActor in
            let image = await library.downloadLatest(
                release: release,
                language: language,
                log: { line in
                    Task { @MainActor in downloadLog.append(line) }
                }
            )
            lastDownloadFailed = (image == nil)
        }
    }

    private func openMicrosoftPage(_ release: WindowsRelease) {
        NSWorkspace.shared.open(MicrosoftISOService.pageURL(for: release))
    }

    private func importISO() {
        guard let url = Panels.chooseFile(
            title: "Import a Windows ISO", types: [.iso, .diskImage]
        ) else { return }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let sizeText = size > 0 ? size.byteSize : "several GB"

        let alert = NSAlert()
        alert.messageText = "Copy this ISO into ImageHub's library?"
        alert.informativeText = """
            Copying uses another \(sizeText) of disk but keeps the image available if the \
            original moves or gets unmounted. Linking leaves the file where it is.
            """
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Link in Place")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }

        Task {
            await library.importISO(at: url, copyIntoLibrary: response == .alertFirstButtonReturn)
        }
    }

    private func use(_ image: WindowsImage) {
        guard var template = appState.selectedTemplate ?? appState.templates.templates.first else {
            ToastCenter.shared.show(
                "No template to attach it to",
                detail: "Create a template first.",
                style: .info
            )
            return
        }
        template.windows.imageSource = .libraryImage
        template.windows.libraryImageID = image.id
        appState.templates.save(template)
        appState.selectedTemplateID = template.id
        appState.section = .templates
        ToastCenter.shared.show("Pinned to “\(template.name)”", detail: image.displayName)
    }
}

struct ImageRow: View {
    let image: WindowsImage
    let isExpanded: Bool
    let onToggle: () -> Void
    let onVerify: () -> Void
    let onReinspect: () -> Void
    let onDelete: () -> Void
    let onUse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: image.origin.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(image.displayName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if !image.fileExists {
                            Chip(text: "Missing", symbol: "exclamationmark.triangle.fill", tint: .red)
                        }
                        if image.installImageNeedsSplit {
                            Chip(text: "Needs split", symbol: "scissors", tint: .orange)
                        }
                        if image.lastVerifiedAt != nil {
                            Chip(text: "Verified", symbol: "checkmark.seal.fill", tint: .green)
                        }
                    }
                    Text(image.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                Button("Use") { onUse() }
                    .controlSize(.small)
                    .disabled(!image.fileExists)

                Button {
                    onToggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onToggle)

            if isExpanded {
                detail
                    .padding(.horizontal, 16)
                    .padding(.bottom, 13)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                detailRow("Path", image.path, monospaced: true)
                detailRow("Added", image.addedAt.briefFormatted)
                detailRow("Origin", image.origin.label)
                if !image.sourceURL.isEmpty {
                    detailRow("Source", image.sourceURL, monospaced: true)
                }
                if !image.installImageName.isEmpty {
                    detailRow(
                        "Install image",
                        "\(image.installImageName) · \(image.installImageSizeBytes.byteSize)"
                    )
                }
                if !image.sha256.isEmpty {
                    detailRow("SHA-256", image.sha256, monospaced: true)
                }
                if let verified = image.lastVerifiedAt {
                    detailRow("Last verified", verified.briefFormatted)
                }
            }

            if !image.editions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Editions inside this image")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(image.editions) { edition in
                        HStack(spacing: 8) {
                            Text("\(edition.index)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .frame(width: 16, alignment: .trailing)
                            Text(edition.name)
                                .font(.caption)
                            Spacer()
                            if edition.sizeBytes > 0 {
                                Text(edition.sizeBytes.byteSize)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(9)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
            }

            if image.installImageNeedsSplit && !WimTools.isAvailable {
                NoticeBanner(
                    kind: .warning,
                    title: "wimlib needed for this image",
                    messages: [WimTools.missingToolMessage]
                )
            }

            HStack(spacing: 8) {
                Button(image.sha256.isEmpty ? "Record Checksum" : "Verify") { onVerify() }
                    .controlSize(.small)
                    .disabled(!image.fileExists)
                Button("Re-read Editions") { onReinspect() }
                    .controlSize(.small)
                    .disabled(!image.fileExists)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: image.path)
                }
                .controlSize(.small)
                .disabled(!image.fileExists)
                Spacer()
                Button("Remove", role: .destructive) { onDelete() }
                    .controlSize(.small)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

struct ImageFromURLSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var checksum = ""
    @State private var release: WindowsRelease = .win11

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add an image from a URL")
                .font(.headline)
                .padding(14)

            Divider()

            Form {
                TextField("HTTPS URL", text: $urlString, prompt: Text("https://files.corp.example.com/win11-24h2.iso"))
                    .autocorrectionDisabled()
                Picker("Release", selection: $release) {
                    ForEach(WindowsRelease.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                TextField("Expected SHA-256 (optional)", text: $checksum)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                SectionCaption(
                    text: "With a checksum set, a download that doesn't match is discarded instead of quietly producing bad media. This is the recommended way to share one approved ISO across a team."
                )
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Download") {
                    guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)) else {
                        ToastCenter.shared.show("That doesn't look like a URL", style: .error)
                        return
                    }
                    let expected = checksum.trimmingCharacters(in: .whitespaces)
                    let target = release
                    dismiss()
                    Task {
                        await appState.library.downloadFromURL(
                            url, expectedSHA256: expected, release: target
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 520)
    }
}
