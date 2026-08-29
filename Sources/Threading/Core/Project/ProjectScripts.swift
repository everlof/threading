import Foundation

/// The checked-in, repository-root contract for commands a project deliberately exposes.
///
/// Reading this file discovers labels and commands; it never executes them. The repository is
/// untrusted input, so every dimension that could turn discovery into unbounded work is capped
/// before JSON is decoded, and each execution resolves its directory against the checkout again.
enum ProjectScriptDefaults {
    static let configurationFileName = ".threading.json"
    static let supportedVersion = 1
    static let maximumConfigurationBytes = 128 * 1_024
    static let maximumScripts = 32
    static let maximumDiagnostics = 16
    static let maximumIDBytes = 64
    static let maximumNameBytes = 96
    static let maximumCommandBytes = 4_096
    static let maximumIconBytes = 64
    static let maximumWorkingDirectoryBytes = 512
    static let maximumPreviewURLBytes = 2_048
    static let maximumSchemaReferenceBytes = 2_048
}

struct ProjectScript: Equatable, Sendable {
    let id: String
    let name: String
    let command: String
    let icon: String?
    /// Repository-relative. `.` means the execution checkout's root.
    let workingDirectory: String
    let previewURL: URL?
}

struct ProjectScriptDiagnostic: Equatable, Sendable {
    enum Code: String, Sendable {
        case unreadable
        case tooLarge
        case malformedJSON
        case invalidSchema
        case unknownField
        case unsupportedVersion
        case invalidScripts
        case tooManyScripts
        case invalidScript
        case duplicateID
    }

    let code: Code
    let message: String
}

struct ProjectScriptCatalog: Equatable, Sendable {
    let repositoryRoot: URL
    let configurationExists: Bool
    let scripts: [ProjectScript]
    let diagnostics: [ProjectScriptDiagnostic]

    var isValid: Bool { configurationExists && diagnostics.isEmpty }
}

struct ProjectScriptInvocation: Equatable, Sendable {
    let script: ProjectScript
    let repositoryRoot: URL
    let workingDirectory: URL
}

struct ProjectScriptExecutionReceipt: Equatable, Sendable {
    let terminalID: TerminalID
    let scriptID: String
    let workingDirectory: URL
    let previewURL: URL?
}

/// One command launched in a visible interactive terminal. Repository-authored shell syntax is
/// passed as a quoted argument to a child `/bin/sh -lc`; it cannot splice into the host-owned
/// receipt suffix. The child isolates `exit` and other shell state from the terminal that remains
/// open. The command itself travels in process argv rather than through the bounded PTY input
/// queue, which matters because a valid repository command may be 4 KiB.
enum ProjectScriptShellCommand {
    static func command(for invocation: ProjectScriptInvocation) -> ShellCommand {
        var command = ShellCommand(word: "/bin/sh")
        command.append(word: "-c")
        command.append(word: source(for: invocation))
        return command
    }

    static func source(for invocation: ProjectScriptInvocation) -> String {
        var launch = ShellCommand(word: "/bin/sh")
        launch.append(word: "-l")
        launch.append(word: "-c")
        launch.append(word: invocation.script.command)

        var receipt = ShellCommand(word: "printf")
        receipt.append(word: "\n[Threading] Project script %s finished with exit code %d.\n")
        receipt.append(word: invocation.script.name)

        var source = launch.source
            + "; __threading_project_script_status=$?; "
            + receipt.source
            + " \"$__threading_project_script_status\""

        if let previewURL = invocation.script.previewURL {
            var preview = ShellCommand(word: "printf")
            preview.append(word: "[Threading] Preview: %s\n")
            preview.append(word: previewURL.absoluteString)
            source += "; " + preview.source
        }
        return source
    }
}

enum ProjectScriptAvailability: Equatable, Sendable {
    case available(ProjectScriptInvocation)
    case unavailable(String)

    var invocation: ProjectScriptInvocation? {
        guard case .available(let invocation) = self else { return nil }
        return invocation
    }

    var reason: String? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}

enum ProjectScriptConfigurationLoader {
    private enum ScriptDecodeResult {
        case success(ProjectScript)
        case failure(String)
    }

    private static let rootFields: Set<String> = ["$schema", "version", "scripts"]
    private static let scriptFields: Set<String> = [
        "id", "name", "command", "icon", "workingDirectory", "previewURL"
    ]

    static func load(repositoryRoot rawRoot: URL) -> ProjectScriptCatalog {
        let root = rawRoot.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(ProjectScriptDefaults.configurationFileName)
        let manager = FileManager.default

        guard manager.fileExists(atPath: file.path) else {
            return ProjectScriptCatalog(
                repositoryRoot: root,
                configurationExists: false,
                scripts: [],
                diagnostics: []
            )
        }

        do {
            let values = try file.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return failure(root, .unreadable, ProjectScriptStrings.regularFile)
            }
            guard let size = values.fileSize,
                  size <= ProjectScriptDefaults.maximumConfigurationBytes else {
                return failure(
                    root,
                    .tooLarge,
                    ProjectScriptStrings.tooLarge
                )
            }

            let data = try Data(contentsOf: file, options: [.mappedIfSafe])
            guard data.count <= ProjectScriptDefaults.maximumConfigurationBytes else {
                return failure(
                    root,
                    .tooLarge,
                    ProjectScriptStrings.changedWhileReading
                )
            }
            return decode(data, repositoryRoot: root)
        } catch {
            return failure(
                root,
                .unreadable,
                ProjectScriptStrings.couldNotRead(bounded(error.localizedDescription))
            )
        }
    }

    static func resolve(
        _ script: ProjectScript,
        repositoryRoot rawRoot: URL
    ) -> ProjectScriptAvailability {
        let root = rawRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root
            .appendingPathComponent(script.workingDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            return .unavailable(ProjectScriptStrings.workingDirectoryEscapes(script.workingDirectory))
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .unavailable(ProjectScriptStrings.workingDirectoryMissing(script.workingDirectory))
        }

        return .available(ProjectScriptInvocation(
            script: script,
            repositoryRoot: root,
            workingDirectory: candidate
        ))
    }

    private static func decode(_ data: Data, repositoryRoot: URL) -> ProjectScriptCatalog {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return failure(
                repositoryRoot,
                .malformedJSON,
                ProjectScriptStrings.invalidJSON(bounded(error.localizedDescription))
            )
        }

        guard let root = object as? [String: Any] else {
            return failure(repositoryRoot, .malformedJSON, ProjectScriptStrings.objectRequired)
        }

        let unknownRoot = Set(root.keys).subtracting(rootFields).sorted()
        guard unknownRoot.isEmpty else {
            return failure(
                repositoryRoot,
                .unknownField,
                ProjectScriptStrings.unknownRootField(unknownRoot[0])
            )
        }

        if let rawSchema = root["$schema"] {
            guard let schema = rawSchema as? String,
                  isBoundedText(
                    schema,
                    maximumBytes: ProjectScriptDefaults.maximumSchemaReferenceBytes
                  ) else {
                return failure(
                    repositoryRoot,
                    .invalidSchema,
                    ProjectScriptStrings.invalidSchemaReference
                )
            }
        }

        guard let version = integer(root["version"]),
              version == ProjectScriptDefaults.supportedVersion else {
            return failure(
                repositoryRoot,
                .unsupportedVersion,
                ProjectScriptStrings.unsupportedVersion(ProjectScriptDefaults.supportedVersion)
            )
        }

        guard let rawScripts = root["scripts"] as? [Any] else {
            return failure(repositoryRoot, .invalidScripts, ProjectScriptStrings.scriptsArrayRequired)
        }
        guard rawScripts.count <= ProjectScriptDefaults.maximumScripts else {
            return failure(
                repositoryRoot,
                .tooManyScripts,
                ProjectScriptStrings.tooManyScripts(
                    rawScripts.count,
                    maximum: ProjectScriptDefaults.maximumScripts
                )
            )
        }

        var scripts: [ProjectScript] = []
        var diagnostics: [ProjectScriptDiagnostic] = []
        var identifiers: Set<String> = []

        for (index, rawScript) in rawScripts.enumerated() {
            guard diagnostics.count < ProjectScriptDefaults.maximumDiagnostics else { break }
            switch decodeScript(rawScript, index: index) {
            case .success(let script):
                guard identifiers.insert(script.id).inserted else {
                    diagnostics.append(ProjectScriptDiagnostic(
                        code: .duplicateID,
                        message: ProjectScriptStrings.duplicateID(index + 1, id: script.id)
                    ))
                    continue
                }
                scripts.append(script)
            case .failure(let message):
                diagnostics.append(ProjectScriptDiagnostic(code: .invalidScript, message: message))
            }
        }

        return ProjectScriptCatalog(
            repositoryRoot: repositoryRoot,
            configurationExists: true,
            scripts: scripts,
            diagnostics: Array(diagnostics.prefix(ProjectScriptDefaults.maximumDiagnostics))
        )
    }

    private static func decodeScript(
        _ value: Any,
        index: Int
    ) -> ScriptDecodeResult {
        let position = index + 1
        guard let object = value as? [String: Any] else {
            return .failure(ProjectScriptStrings.scriptObjectRequired(position))
        }

        let unknown = Set(object.keys).subtracting(scriptFields).sorted()
        guard unknown.isEmpty else {
            return .failure(ProjectScriptStrings.unknownScriptField(position, field: unknown[0]))
        }

        guard let id = object["id"] as? String,
              isValidID(id) else {
            return .failure(
                ProjectScriptStrings.invalidID(position)
            )
        }
        guard let name = object["name"] as? String,
              isBoundedText(name, maximumBytes: ProjectScriptDefaults.maximumNameBytes) else {
            return .failure(ProjectScriptStrings.invalidName(position))
        }
        guard let command = object["command"] as? String,
              isBoundedText(command, maximumBytes: ProjectScriptDefaults.maximumCommandBytes) else {
            return .failure(ProjectScriptStrings.invalidCommand(position))
        }

        let icon: String?
        if let rawIcon = object["icon"] {
            guard let value = rawIcon as? String, isValidIcon(value) else {
                return .failure(ProjectScriptStrings.invalidIcon(position))
            }
            icon = value
        } else {
            icon = nil
        }

        let workingDirectory: String
        if let rawDirectory = object["workingDirectory"] {
            guard let value = rawDirectory as? String, isValidRelativePath(value) else {
                return .failure(
                    ProjectScriptStrings.invalidWorkingDirectory(position)
                )
            }
            workingDirectory = value
        } else {
            workingDirectory = "."
        }

        let previewURL: URL?
        if let rawPreview = object["previewURL"] {
            guard let value = rawPreview as? String,
                  let parsed = validPreviewURL(value) else {
                return .failure(ProjectScriptStrings.invalidPreviewURL(position))
            }
            previewURL = parsed
        } else {
            previewURL = nil
        }

        return .success(ProjectScript(
            id: id,
            name: name,
            command: command,
            icon: icon,
            workingDirectory: workingDirectory,
            previewURL: previewURL
        ))
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double else { return nil }
        return number.intValue
    }

    private static func isValidID(_ value: String) -> Bool {
        guard isBoundedText(value, maximumBytes: ProjectScriptDefaults.maximumIDBytes),
              let first = value.unicodeScalars.first,
              lowercaseAlphanumeric.contains(first) else { return false }
        return value.unicodeScalars.allSatisfy { identifierCharacters.contains($0) }
    }

    private static func isValidIcon(_ value: String) -> Bool {
        isBoundedText(value, maximumBytes: ProjectScriptDefaults.maximumIconBytes)
            && value.unicodeScalars.allSatisfy { iconCharacters.contains($0) }
    }

    private static func isValidRelativePath(_ value: String) -> Bool {
        guard isBoundedText(
            value,
            maximumBytes: ProjectScriptDefaults.maximumWorkingDirectoryBytes
        ), !(value as NSString).isAbsolutePath, !value.hasPrefix("~") else { return false }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == ".." }) else { return false }
        return true
    }

    private static func validPreviewURL(_ value: String) -> URL? {
        guard isBoundedText(
            value,
            maximumBytes: ProjectScriptDefaults.maximumPreviewURLBytes
        ), let components = URLComponents(string: value),
        let scheme = components.scheme?.lowercased(),
        scheme == "http" || scheme == "https",
        components.host?.isEmpty == false,
        components.user == nil,
        components.password == nil else { return nil }
        return components.url
    }

    private static func isBoundedText(_ value: String, maximumBytes: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func failure(
        _ root: URL,
        _ code: ProjectScriptDiagnostic.Code,
        _ message: String
    ) -> ProjectScriptCatalog {
        ProjectScriptCatalog(
            repositoryRoot: root,
            configurationExists: true,
            scripts: [],
            diagnostics: [ProjectScriptDiagnostic(code: code, message: message)]
        )
    }

    private static func bounded(_ value: String) -> String {
        String(value.prefix(240))
    }

    private static let lowercaseAlphanumeric = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
    private static let identifierCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
    private static let iconCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
}

private enum ProjectScriptStrings {
    static let regularFile = L10n.string(
        "The project configuration must be a regular file, not a symbolic link."
    )
    static let tooLarge = L10n.string(
        "The project configuration exceeds the 128 KiB discovery limit."
    )
    static let changedWhileReading = L10n.string(
        "The project configuration changed while it was read and now exceeds 128 KiB."
    )
    static let objectRequired = L10n.string("The project configuration must be a JSON object.")
    static let invalidSchemaReference = L10n.string(
        "The $schema field must be a non-empty string of at most 2048 bytes without control characters."
    )
    static let scriptsArrayRequired = L10n.string("The scripts field must be an array.")

    static func couldNotRead(_ detail: String) -> String {
        L10n.format("The project configuration could not be read: %@.", detail)
    }

    static func workingDirectoryEscapes(_ path: String) -> String {
        L10n.format("Working directory “%@” resolves outside this checkout.", path)
    }

    static func workingDirectoryMissing(_ path: String) -> String {
        L10n.format("Working directory “%@” does not exist in this checkout.", path)
    }

    static func invalidJSON(_ detail: String) -> String {
        L10n.format("The project configuration is not valid JSON: %@.", detail)
    }

    static func unknownRootField(_ field: String) -> String {
        L10n.format("Unknown project configuration field: %@.", field)
    }

    static func unsupportedVersion(_ version: Int) -> String {
        L10n.format("Project configuration version must be %lld.", Int64(version))
    }

    static func tooManyScripts(_ count: Int, maximum: Int) -> String {
        L10n.format(
            "The project declares %lld scripts; at most %lld are allowed.",
            Int64(count),
            Int64(maximum)
        )
    }

    static func duplicateID(_ position: Int, id: String) -> String {
        L10n.format("Script %lld repeats the ID “%@”.", Int64(position), id)
    }

    static func scriptObjectRequired(_ position: Int) -> String {
        L10n.format("Script %lld must be a JSON object.", Int64(position))
    }

    static func unknownScriptField(_ position: Int, field: String) -> String {
        L10n.format("Script %lld has an unknown field: %@.", Int64(position), field)
    }

    static func invalidID(_ position: Int) -> String {
        L10n.format(
            "Script %lld needs a lowercase ID of 1–64 bytes using letters, numbers, dots, underscores, or hyphens.",
            Int64(position)
        )
    }

    static func invalidName(_ position: Int) -> String {
        L10n.format(
            "Script %lld needs a non-empty display name of at most 96 bytes without control characters.",
            Int64(position)
        )
    }

    static func invalidCommand(_ position: Int) -> String {
        L10n.format(
            "Script %lld needs a one-line command of at most 4096 bytes without control characters.",
            Int64(position)
        )
    }

    static func invalidIcon(_ position: Int) -> String {
        L10n.format("Script %lld has an invalid SF Symbol name.", Int64(position))
    }

    static func invalidWorkingDirectory(_ position: Int) -> String {
        L10n.format(
            "Script %lld has an invalid workingDirectory; use . or a checkout-relative path without .. components.",
            Int64(position)
        )
    }

    static func invalidPreviewURL(_ position: Int) -> String {
        L10n.format(
            "Script %lld previewURL must be an absolute http or https URL without credentials.",
            Int64(position)
        )
    }
}
