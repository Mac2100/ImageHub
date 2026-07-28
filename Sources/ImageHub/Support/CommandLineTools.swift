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
          ImageHub --version                          Print the version
          ImageHub --help                             Show this

        With no template path, the built-in "Standard Workstation" starter is used.
        Passwords are never included — these modes read no secrets from the Keychain.
        """

    private static func loadTemplate(_ path: String?) -> DeploymentTemplate {
        guard let path else { return .standardWorkstation() }
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
