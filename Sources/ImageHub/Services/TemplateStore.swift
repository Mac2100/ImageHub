import Foundation

/// Templates live as one JSON file each under
/// `~/Library/Application Support/ImageHub/Templates/`, so a team can keep the
/// folder in git or drop a colleague's template in by hand.
@MainActor
final class TemplateStore: ObservableObject {
    @Published private(set) var templates: [DeploymentTemplate] = []
    @Published var loadWarnings: [String] = []

    private let directory: URL

    /// IDs of templates deleted in this session.
    ///
    /// The editor autosaves, and closing it flushes one last write. Deleting the
    /// template that is currently open therefore raced its own editor: the file
    /// was removed, the editor disappeared, its flush wrote the JSON straight
    /// back, and the deletion looked like it had done nothing. A save for a
    /// tombstoned ID is refused instead.
    private var tombstones: Set<UUID> = []

    init(directory: URL? = nil) {
        self.directory = directory ?? AppPaths.templates
        load()
    }

    // MARK: - Loading

    func load() {
        tombstones.removeAll()
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var loaded: [DeploymentTemplate] = []
        var warnings: [String] = []

        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in files where file.pathExtension.lowercased() == "json" {
            do {
                let data = try Data(contentsOf: file)
                loaded.append(try decoder.decode(DeploymentTemplate.self, from: data))
            } catch {
                warnings.append("Couldn't read \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Seed the starter templates on genuine first run only. Keying off "the
        // folder is empty" would silently recreate them after someone deleted
        // the last template, which reads as deletion not working.
        let seededKey = "didSeedStarterTemplates"
        if loaded.isEmpty && files.isEmpty
            && !UserDefaults.standard.bool(forKey: seededKey) {
            loaded = DeploymentTemplate.starterPack()
            for template in loaded {
                try? persist(template)
            }
            UserDefaults.standard.set(true, forKey: seededKey)
        }

        templates = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        loadWarnings = warnings
    }

    // MARK: - Mutation

    func template(id: UUID) -> DeploymentTemplate? {
        templates.first { $0.id == id }
    }

    @discardableResult
    func save(_ template: DeploymentTemplate) -> Bool {
        guard !tombstones.contains(template.id) else { return false }
        var updated = template
        updated.updatedAt = Date()
        do {
            try persist(updated)
        } catch {
            ToastCenter.shared.show(
                "Couldn't save template",
                detail: error.localizedDescription,
                style: .error
            )
            return false
        }
        if let index = templates.firstIndex(where: { $0.id == updated.id }) {
            templates[index] = updated
        } else {
            templates.append(updated)
        }
        templates.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return true
    }

    func delete(_ template: DeploymentTemplate) {
        tombstones.insert(template.id)
        try? FileManager.default.removeItem(at: url(for: template.id))
        Keychain.deleteAll(for: template.id)
        templates.removeAll { $0.id == template.id }
    }

    @discardableResult
    func duplicate(_ template: DeploymentTemplate) -> DeploymentTemplate {
        var copy = template
        copy.id = UUID()
        copy.name = uniqueName(basedOn: template.name)
        copy.createdAt = Date()
        copy.updatedAt = Date()

        // Secrets are per-template Keychain items; carry them across so the copy
        // is immediately buildable.
        for slot in Keychain.Slot.allCases {
            if let secret = Keychain.get(for: template.id, slot: slot) {
                Keychain.set(secret, for: copy.id, slot: slot)
            }
        }
        save(copy)
        return copy
    }

    func newTemplate() -> DeploymentTemplate {
        var template = DeploymentTemplate()
        template.name = uniqueName(basedOn: "New Template")
        save(template)
        return template
    }

    private func uniqueName(basedOn base: String) -> String {
        let existing = Set(templates.map { $0.name })
        if !existing.contains(base) { return base }
        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    // MARK: - Import / export

    /// Reads a template from an arbitrary file, giving it a fresh identity so it
    /// never collides with one already in the library.
    @discardableResult
    func importTemplate(from url: URL) throws -> DeploymentTemplate {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var template = try decoder.decode(DeploymentTemplate.self, from: try Data(contentsOf: url))
        if templates.contains(where: { $0.id == template.id }) || tombstones.contains(template.id) {
            template.id = UUID()
            template.name = uniqueName(basedOn: template.name)
        }
        save(template)
        return template
    }

    func export(_ template: DeploymentTemplate, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(template).write(to: url)
    }

    // MARK: - Disk

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func persist(_ template: DeploymentTemplate) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(template).write(to: url(for: template.id), options: .atomic)
    }

    var directoryURL: URL { directory }
}

/// Locations ImageHub owns on disk.
enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = base.appendingPathComponent("ImageHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var templates: URL {
        support.appendingPathComponent("Templates", isDirectory: true)
    }

    static var images: URL {
        support.appendingPathComponent("Images", isDirectory: true)
    }

    static var imageIndex: URL {
        support.appendingPathComponent("images.json")
    }

    static var logs: URL {
        support.appendingPathComponent("Logs", isDirectory: true)
    }
}
