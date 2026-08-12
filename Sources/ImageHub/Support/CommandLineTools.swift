import Foundation

/// A couple of non-interactive entry points, checked before the UI comes up.
///
/// These exist mainly so CI can verify the generated answer file is well-formed
/// XML on every push — `autounattend.xml` is the artifact with the least margin
/// for error (a malformed one fails on a technician's bench, not here) and the
/// app is the only thing that knows how to produce it.
enum CommandLineTools {
    /// Runs a command-line mode and exits, or returns and lets the app launch.
    static func runIfRequested() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { return }

        switch command {
        case "--emit-answer-file":
            emitAnswerFile(templatePath: arguments.dropFirst().first)
        case "--emit-payload-config":
            emitPayloadConfig(templatePath: arguments.dropFirst().first)
        case "--emit-office-config":
            emitOfficeConfig(templatePath: arguments.dropFirst().first)
        case "--version":
            print(AppVersion.current)
            exit(0)
        case "--help":
            print(help)
            exit(0)
        default:
            // Anything else is left for AppKit (it passes its own arguments).
            return
        }
    }

    private static let help = """
        ImageHub \(AppVersion.current)

        Usage:
          ImageHub                                    Launch the app
          ImageHub --emit-answer-file [template.json] Print the generated autounattend.xml
          ImageHub --emit-payload-config [template.json]
                                                      Print the generated payload config.json
          ImageHub --emit-office-config [template.json]
                                                      Print the generated Office configuration.xml
          ImageHub --version                          Print the version
          ImageHub --help                             Show this

        With no template path, the built-in "Standard Workstation" starter is used.
        Passwords are never included — these modes read no secrets from the Keychain.
        """

    /// The built-in starter's `id` is a fresh UUID every time it is constructed, which
    /// is right for the app and wrong for a fixture: CI generates from this template on
    /// both platforms and compares the results, and a random `templateID` in
    /// `config.json` is a difference on every run. Pinning it here keeps that field
    /// genuinely compared — including that both apps write a GUID the same way — rather
    /// than excluded from the comparison. A template loaded from a file needs no such
    /// help: its id travels with the JSON.
    static let fixtureTemplateID = "0F1E2D3C-4B5A-4697-8899-AABBCCDDEEFF"

    private static func loadTemplate(_ path: String?) -> DeploymentTemplate {
        guard let path else {
            var starter = DeploymentTemplate.standardWorkstation()
            starter.id = UUID(uuidString: fixtureTemplateID) ?? starter.id
            return starter
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(DeploymentTemplate.self, from: data)
        } catch {
            FileHandle.standardError.write(
                Data("error: couldn't read \(path): \(error.localizedDescription)\n".utf8)
            )
            exit(2)
        }
    }

    private static func emitAnswerFile(templatePath: String?) {
        let template = loadTemplate(templatePath)
        // Empty secrets on purpose: this mode must never touch the Keychain.
        print(AnswerFileBuilder(template: template, secrets: .init()).build())
        exit(0)
    }

    /// The Office Deployment Tool rejects a malformed configuration outright, and
    /// it would do so after Windows is installed. Same reasoning as the answer
    /// file: check it here.
    private static func emitOfficeConfig(templatePath: String?) {
        var template = loadTemplate(templatePath)
        // The starter template has Office off; emit what it *would* write so the
        // check has something to parse.
        template.microsoft365.enabled = true
        print(OfficeConfigBuilder.xml(for: template))
        exit(0)
    }

    private static func emitPayloadConfig(templatePath: String?) {
        let template = loadTemplate(templatePath)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imagehub-emit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let payload = try PayloadBuilder.write(
                template: template,
                secrets: .init(),
                to: directory,
                log: { _ in }
            )
            let config = payload.appendingPathComponent(PayloadBuilder.configFileName)
            print(String(data: try Data(contentsOf: config), encoding: .utf8) ?? "")
            exit(0)
        } catch {
            FileHandle.standardError.write(
                Data("error: \(error.localizedDescription)\n".utf8)
            )
            exit(2)
        }
    }
}
