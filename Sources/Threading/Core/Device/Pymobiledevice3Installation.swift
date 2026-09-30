import Darwin
import Foundation

/// The app-owned installation of the optional iPhone protocol tool.
///
/// `pymobiledevice3` remains a separate GPL program. Threading does not ship it inside the app;
/// an explicit Settings action asks PyPI for the current release and installs it into this
/// directory. A versioned environment is prepared and validated before `current` is switched,
/// so a failed download never damages the tool Device Logs is already using.
enum Pymobiledevice3ManagedTool {
    static let name = "pymobiledevice3"
    static let directoryName = "pymobiledevice3"
    static let toolsDirectoryName = "Managed Tools"
    static let versionsDirectoryName = "versions"
    static let currentLinkName = "current"
    static let candidatePrefix = "install-"
    static let executableRelativePath = "bin/pymobiledevice3"

    static var root: URL {
        let support = StateManager.isHostedTest
            ? StateManager.hostedTestDirectory()
            : AppDataLocations.supportDirectory
        return support
            .appendingPathComponent(toolsDirectoryName, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func versionsDirectory(in root: URL = root) -> URL {
        root.appendingPathComponent(versionsDirectoryName, isDirectory: true)
    }

    static func currentLink(in root: URL = root) -> URL {
        root.appendingPathComponent(currentLinkName, isDirectory: false)
    }

    static func executable(in root: URL = root) -> URL {
        currentLink(in: root).appendingPathComponent(executableRelativePath)
    }

    static func runtimeDirectory(in root: URL = root) -> URL {
        root.appendingPathComponent("runtime", isDirectory: true)
    }
}

/// Gives every pymobiledevice3 process a writable, Threading-owned data directory.
///
/// pymobiledevice3 otherwise prefers a legacy `~/.pymobiledevice3` folder whenever one exists.
/// A folder left behind by an old sudo invocation can therefore prevent its iOS 27 DDI downloader
/// from writing even though Threading's managed environment is healthy. Python imports
/// `sitecustomize` before the CLI module, which lets this narrow adapter select the private cache
/// without replacing `HOME`, changing the user's legacy folder, or modifying the installed tool.
enum Pymobiledevice3RuntimeEnvironment {
    private static let directoryPermissions = 0o700
    private static let filePermissions = 0o600
    private static let cacheEnvironmentKey = "THREADING_PYMOBILEDEVICE3_CACHE"
    private static let customizationSource = """
        import os
        from pathlib import Path

        cache_root = os.environ.get("THREADING_PYMOBILEDEVICE3_CACHE")
        if cache_root:
            import pymobiledevice3.common
            pymobiledevice3.common._HOMEFOLDER = Path(cache_root)
        """

    static func prepare(
        inherited: [String: String],
        root: URL = Pymobiledevice3ManagedTool.runtimeDirectory(),
        fileManager: FileManager = .default
    ) throws -> [String: String] {
        let customization = root.appendingPathComponent("python", isDirectory: true)
        let cache = root.appendingPathComponent("data", isDirectory: true)
        for directory in [root, customization, cache] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions]
            )
            try fileManager.setAttributes(
                [.posixPermissions: directoryPermissions],
                ofItemAtPath: directory.path
            )
        }

        let helper = customization.appendingPathComponent("sitecustomize.py")
        let source = Data(customizationSource.utf8)
        if (try? Data(contentsOf: helper)) != source {
            try source.write(to: helper, options: .atomic)
        }
        try fileManager.setAttributes(
            [.posixPermissions: filePermissions],
            ofItemAtPath: helper.path
        )

        var result = inherited
        result[cacheEnvironmentKey] = cache.path
        result["PYTHONPATH"] = customization.path
        result["PYTHONNOUSERSITE"] = "1"
        return result
    }
}

enum Pymobiledevice3ManagedStatus: Equatable, Sendable {
    case absent
    case installed(version: String, executable: URL)
    case damaged
}

struct Pymobiledevice3InstalledTool: Equatable, Sendable {
    let version: String
    let executable: URL
}

enum Pymobiledevice3InstallStep: String, Equatable, Sendable {
    case createEnvironment
    case installPackage
    case validateVersion
}

struct Pymobiledevice3InstallCommand: Equatable, Sendable {
    let step: Pymobiledevice3InstallStep
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    let maximumOutputBytes: Int
    let output: BoundedChildOutput
}

protocol Pymobiledevice3InstallCommandRunning: Sendable {
    func run(_ command: Pymobiledevice3InstallCommand) throws -> BoundedChildResult
}

struct BoundedPymobiledevice3InstallCommandRunner: Pymobiledevice3InstallCommandRunning {
    func run(_ command: Pymobiledevice3InstallCommand) throws -> BoundedChildResult {
        try BoundedChildProcess.run(
            executable: command.executable.path,
            arguments: command.arguments,
            environment: command.environment,
            timeout: command.timeout,
            maximumOutputBytes: command.maximumOutputBytes,
            output: command.output
        )
    }
}

enum Pymobiledevice3InstallError: LocalizedError, Equatable {
    case pythonUnavailable
    case directoryUnavailable
    case commandTimedOut(Pymobiledevice3InstallStep)
    case commandFailed(Pymobiledevice3InstallStep)
    case unsupportedVersion
    case activationFailed

    var errorDescription: String? {
        switch self {
        case .pythonUnavailable:
            return L10n.string(
                "Threading could not find Xcode's Python 3, which is needed to install iPhone tooling."
            )
        case .directoryUnavailable:
            return L10n.string("Threading could not prepare its managed iPhone tooling folder.")
        case .commandTimedOut:
            return L10n.string("The iPhone tooling installation took too long and was stopped.")
        case .commandFailed:
            return L10n.string(
                "The iPhone tooling installation failed. Check the network connection and try again."
            )
        case .unsupportedVersion:
            return L10n.string(
                "PyPI returned an iPhone tooling version that Threading cannot use."
            )
        case .activationFailed:
            return L10n.string("Threading installed the iPhone tooling but could not activate it.")
        }
    }
}

/// Installs and inspects the app-owned `pymobiledevice3` environment.
///
/// All methods are blocking by design and are called only from bounded detached work. Keeping
/// filesystem and child-process work together makes the publish edge testable: only a validated
/// candidate may replace the `current` symlink.
struct Pymobiledevice3Installation: @unchecked Sendable {
    private let root: URL
    private let pythonExecutable: @Sendable () -> URL?
    private let runner: any Pymobiledevice3InstallCommandRunning
    private let fileManager: FileManager
    private let environment: [String: String]
    private let makeIdentifier: @Sendable () -> String

    init(
        root: URL = Pymobiledevice3ManagedTool.root,
        pythonExecutable: @escaping @Sendable () -> URL? = {
            Pymobiledevice3PythonLocator.python3()
        },
        runner: any Pymobiledevice3InstallCommandRunning =
            BoundedPymobiledevice3InstallCommandRunner(),
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        makeIdentifier: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.root = root
        self.pythonExecutable = pythonExecutable
        self.runner = runner
        self.fileManager = fileManager
        self.environment = environment
        self.makeIdentifier = makeIdentifier
    }

    var executable: URL { Pymobiledevice3ManagedTool.executable(in: root) }

    func status() -> Pymobiledevice3ManagedStatus {
        guard fileManager.isExecutableFile(atPath: executable.path) else { return .absent }
        guard let version = validatedVersion(at: executable) else { return .damaged }
        return .installed(version: version, executable: executable)
    }

    func installLatest() throws -> Pymobiledevice3InstalledTool {
        guard let pythonExecutable = pythonExecutable(),
              fileManager.isExecutableFile(atPath: pythonExecutable.path) else {
            throw Pymobiledevice3InstallError.pythonUnavailable
        }

        let versions = Pymobiledevice3ManagedTool.versionsDirectory(in: root)
        do {
            try fileManager.createDirectory(
                at: versions,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Pymobiledevice3InstallDefaults.directoryPermissions]
            )
        } catch {
            throw Pymobiledevice3InstallError.directoryUnavailable
        }

        let candidate = versions.appendingPathComponent(
            Pymobiledevice3ManagedTool.candidatePrefix + makeIdentifier(),
            isDirectory: true
        )
        defer {
            if !currentDestinationMatches(candidate) {
                try? fileManager.removeItem(at: candidate)
            }
        }

        try requireSuccess(
            run(createEnvironmentCommand(python: pythonExecutable, at: candidate)),
            step: .createEnvironment
        )

        let candidatePython = candidate.appendingPathComponent("bin/python", isDirectory: false)
        try requireSuccess(
            run(installPackageCommand(python: candidatePython)),
            step: .installPackage
        )

        let candidateExecutable = candidate.appendingPathComponent(
            Pymobiledevice3ManagedTool.executableRelativePath,
            isDirectory: false
        )
        guard fileManager.isExecutableFile(atPath: candidateExecutable.path),
              let version = validatedVersion(at: candidateExecutable) else {
            throw Pymobiledevice3InstallError.unsupportedVersion
        }

        try activate(candidate)
        return Pymobiledevice3InstalledTool(version: version, executable: executable)
    }

    /// Removes environments left behind by earlier successful updates.
    ///
    /// Called once on an ordinary launch, when no reader from the preceding app process can still
    /// exist. An update deliberately leaves its predecessor alone for the rest of the current
    /// process: a running Python child may import a module lazily, so deleting its environment
    /// underneath it would turn an update into a stream fault.
    func cleanupStaleVersions() {
        let versions = Pymobiledevice3ManagedTool.versionsDirectory(in: root)
        guard let current = currentDestination(),
              let entries = try? fileManager.contentsOfDirectory(
                at: versions,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return }

        for entry in entries.prefix(Pymobiledevice3InstallDefaults.maximumVersionsInspected)
            where entry.standardizedFileURL != current.standardizedFileURL {
            try? fileManager.removeItem(at: entry)
        }
    }

    private func createEnvironmentCommand(
        python: URL,
        at candidate: URL
    ) -> Pymobiledevice3InstallCommand {
        Pymobiledevice3InstallCommand(
            step: .createEnvironment,
            executable: python,
            arguments: ["-m", "venv", candidate.path],
            environment: sanitizedEnvironment,
            timeout: Pymobiledevice3InstallDefaults.environmentTimeout,
            maximumOutputBytes: Pymobiledevice3InstallDefaults.maximumOutputBytes,
            output: .merged
        )
    }

    private func installPackageCommand(python: URL) -> Pymobiledevice3InstallCommand {
        Pymobiledevice3InstallCommand(
            step: .installPackage,
            executable: python,
            arguments: [
                "-m", "pip", "--isolated", "install", "--disable-pip-version-check",
                "--no-input", "--upgrade", Pymobiledevice3ManagedTool.name,
            ],
            environment: sanitizedEnvironment,
            timeout: Pymobiledevice3InstallDefaults.installTimeout,
            maximumOutputBytes: Pymobiledevice3InstallDefaults.maximumOutputBytes,
            output: .merged
        )
    }

    private func versionCommand(executable: URL) -> Pymobiledevice3InstallCommand {
        Pymobiledevice3InstallCommand(
            step: .validateVersion,
            executable: executable,
            arguments: ["--no-color", "version"],
            environment: sanitizedEnvironment,
            timeout: Pymobiledevice3InstallDefaults.versionTimeout,
            maximumOutputBytes: Pymobiledevice3InstallDefaults.versionOutputBytes,
            output: .standardOutput
        )
    }

    private var sanitizedEnvironment: [String: String] {
        var result = environment
        result.removeValue(forKey: "PYTHONHOME")
        result.removeValue(forKey: "PYTHONPATH")
        return result
    }

    private func run(_ command: Pymobiledevice3InstallCommand) throws -> BoundedChildResult {
        do {
            return try runner.run(command)
        } catch {
            ThreadingLogger.app.error(
                "iPhone tooling command could not start step=\(command.step.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            throw Pymobiledevice3InstallError.commandFailed(command.step)
        }
    }

    private func requireSuccess(
        _ result: BoundedChildResult,
        step: Pymobiledevice3InstallStep
    ) throws {
        switch result.termination {
        case .timedOut:
            throw Pymobiledevice3InstallError.commandTimedOut(step)
        case .exited(0):
            return
        case .exited:
            ThreadingLogger.app.error(
                "iPhone tooling installation command failed output=\(String(decoding: result.output, as: UTF8.self), privacy: .private(mask: .hash))"
            )
            throw Pymobiledevice3InstallError.commandFailed(step)
        }
    }

    private func validatedVersion(at executable: URL) -> String? {
        guard let result = try? runner.run(versionCommand(executable: executable)),
              result.termination == .exited(0),
              result.outputWasTruncated == false,
              PhysicalDeviceCapabilityProbe.toolVersionIsSupported(result.output) == true else {
            return nil
        }
        return String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func activate(_ candidate: URL) throws {
        let temporaryLink = root.appendingPathComponent(
            ".\(Pymobiledevice3ManagedTool.currentLinkName)-\(makeIdentifier())",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryLink) }

        do {
            try fileManager.createSymbolicLink(
                atPath: temporaryLink.path,
                withDestinationPath: candidate.path
            )
        } catch {
            throw Pymobiledevice3InstallError.activationFailed
        }

        let current = Pymobiledevice3ManagedTool.currentLink(in: root)
        guard rename(temporaryLink.path, current.path) == 0,
              fileManager.isExecutableFile(atPath: executable.path) else {
            throw Pymobiledevice3InstallError.activationFailed
        }
    }

    private func currentDestinationMatches(_ candidate: URL) -> Bool {
        currentDestination()?.standardizedFileURL == candidate.standardizedFileURL
    }

    private func currentDestination() -> URL? {
        let current = Pymobiledevice3ManagedTool.currentLink(in: root)
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: current.path)
        else { return nil }
        let resolved = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : root.appendingPathComponent(destination)
        let versions = Pymobiledevice3ManagedTool.versionsDirectory(in: root)
            .standardizedFileURL.path + "/"
        let standardized = resolved.standardizedFileURL
        guard standardized.path.hasPrefix(versions) else { return nil }
        return standardized
    }
}

enum Pymobiledevice3PythonLocator {
    static func python3(fileManager: FileManager = .default) -> URL? {
        [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        .map(URL.init(fileURLWithPath:))
        .first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }
}

enum Pymobiledevice3InstallDefaults {
    static let directoryPermissions = 0o700
    static let maximumOutputBytes = 512 * 1024
    static let versionOutputBytes = 4 * 1024
    static let environmentTimeout: TimeInterval = 60
    static let installTimeout: TimeInterval = 10 * 60
    static let versionTimeout: TimeInterval = 10
    static let maximumVersionsInspected = 64
}
