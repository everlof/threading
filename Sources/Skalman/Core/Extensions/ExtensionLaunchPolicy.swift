import Darwin
import Foundation

/// One of the child's three standard streams.
///
/// The launch abstraction names streams rather than handing a policy a configured `Process`,
/// because the supported runner will not own a `Process` at all: it receives descriptors over
/// XPC and installs them with `posix_spawn` file actions. Describing intent here is what lets
/// that policy be written without changing either call site.
enum ExtensionChildStream {
    case pipe(Pipe)
    case nullDevice

    var processValue: Any {
        switch self {
        case .pipe(let pipe):
            return pipe
        case .nullDevice:
            return FileHandle.nullDevice
        }
    }
}

/// Everything a launch policy needs to start one extension child, and nothing about how it is
/// contained.
struct ExtensionLaunchRequest {
    /// The inspected package. Its root is the child's working directory and the only path a
    /// policy may authorise the child to read.
    let bundle: SkalmanExtensionBundle
    /// The entry mode, e.g. `["--skalman-register"]`. A policy may reject an unknown mode.
    let arguments: [String]
    /// Host-supplied environment: storage directories, settings values, and host authorisation.
    /// A policy composes this over its own base environment; it never replaces it.
    let additionalEnvironment: [String: String]
    let standardInput: ExtensionChildStream
    let standardOutput: ExtensionChildStream
    let standardError: ExtensionChildStream
    /// Descriptors beyond the three standard streams, keyed by the number the child must see.
    ///
    /// This is how the host broker socket reaches a runner-launched extension. The policy
    /// installs each one and closes its own copy; a policy which cannot must refuse the
    /// request, because a child that silently lacks its broker would report every host call as
    /// a configuration failure rather than as a launch failure.
    let extraDescriptors: [Int32: Int32]

    init(
        bundle: SkalmanExtensionBundle,
        arguments: [String],
        additionalEnvironment: [String: String] = [:],
        standardInput: ExtensionChildStream = .nullDevice,
        standardOutput: ExtensionChildStream,
        standardError: ExtensionChildStream,
        extraDescriptors: [Int32: Int32] = [:]
    ) {
        self.bundle = bundle
        self.arguments = arguments
        self.additionalEnvironment = additionalEnvironment
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.extraDescriptors = extraDescriptors
    }
}

enum ExtensionLaunchPolicyError: LocalizedError {
    case descriptorPassingUnsupported

    var errorDescription: String? {
        switch self {
        case .descriptorPassingUnsupported:
            return "The experimental sandbox-exec launcher cannot pass the host broker socket "
                + "to an extension. Descriptor-mode brokering requires the signed runner."
        }
    }
}

/// A running extension child, described by what a supervisor does to it.
///
/// This is deliberately not `Process`. Under the supported runner the child is spawned by a
/// separately signed XPC service, so the app cannot `waitpid` it and its exit arrives as a
/// message. Every supervision decision in `ExtensionRegistrationLoader` and
/// `ExtensionProcessSession` is expressible through these six members, which is what makes the
/// runner a policy swap rather than a rewrite.
protocol ExtensionChildProcess: AnyObject {
    var isRunning: Bool { get }
    /// Valid only once the child has exited.
    var terminationStatus: Int32 { get }
    /// Blocks until the child exits. Callers must not invoke this on the main thread.
    func waitUntilExit()
    /// Requests a graceful exit.
    func terminate()
    /// Ends the child immediately. Safe to call when it has already exited.
    func kill()
    /// Delivers the exit status exactly once, including when the child has already exited.
    /// Replaces any previously installed observer; pass `nil` to stop observing.
    func observeExit(_ handler: ((Int32) -> Void)?)
}

/// Turns a launch request into a contained running child.
///
/// Implementations own containment and only containment. Validation of the package, the
/// process generation, the host token, and the capability set all happen before a request is
/// built, so a policy is free to re-check them but never to originate them.
protocol ExtensionLaunchPolicy {
    /// How a child launched by this policy can reach the host broker.
    ///
    /// The policy answers because containment decides it: a policy that can install a
    /// descriptor uses one, and a policy that cannot must be given a port instead. Asking the
    /// launcher keeps that one fact in one place rather than having the manager infer it.
    var hostTransport: ExtensionHostTransport { get }

    /// The transport for this inspected runtime.
    ///
    /// Most policies have one answer. The product policy dispatches native compatibility
    /// packages and WebAssembly packages to different boundaries, so it answers per bundle.
    func hostTransport(for bundle: SkalmanExtensionBundle) -> ExtensionHostTransport

    func spawn(_ request: ExtensionLaunchRequest) throws -> ExtensionChildProcess
}

extension ExtensionLaunchPolicy {
    func hostTransport(for bundle: SkalmanExtensionBundle) -> ExtensionHostTransport {
        _ = bundle
        return hostTransport
    }
}

enum ExtensionLaunchEnvironment {
    /// The child's environment before host additions.
    ///
    /// An extension inherits nothing from the user's shell: a GUI app's environment is not the
    /// user's interactive one, and an extension that behaved differently depending on which it
    /// got would be unreproducible. `PATH` exists for the `/bin/sh` shim a script package
    /// execs through, not as a search path for the extension's own work.
    static let base: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
        "SKALMAN_EXTENSION_PROTOCOL": "1"
    ]

    static func composed(with additional: [String: String]) -> [String: String] {
        var environment = base
        environment.merge(additional) { _, hostValue in hostValue }
        return environment
    }
}

/// The experimental containment: `sandbox-exec` with a generated Seatbelt profile.
///
/// Retained as the reference implementation until the signed XPC runner is proven. See
/// `docs/extensions/SANDBOX_RUNNER.md` for why it cannot be the distribution boundary.
struct SandboxExecLaunchPolicy: ExtensionLaunchPolicy {
    let hostTransport: ExtensionHostTransport = .loopback

    private let sandboxExecutableURL: URL
    private let fileManager: FileManager

    init(
        sandboxExecutableURL: URL = ExtensionSandboxPolicy.executableURL,
        fileManager: FileManager = .default
    ) {
        self.sandboxExecutableURL = sandboxExecutableURL
        self.fileManager = fileManager
    }

    func spawn(_ request: ExtensionLaunchRequest) throws -> ExtensionChildProcess {
        // `Process` spawns with `POSIX_SPAWN_CLOEXEC_DEFAULT` and exposes no API for
        // descriptors past the three standard streams, so this cannot be worked around here —
        // it is precisely the authority the signed runner adds.
        guard request.extraDescriptors.isEmpty else {
            throw ExtensionLaunchPolicyError.descriptorPassingUnsupported
        }
        let launch = try ExtensionSandboxPolicy.launch(
            bundle: request.bundle,
            commandArguments: request.arguments,
            environment: request.additionalEnvironment,
            sandboxExecutableURL: sandboxExecutableURL,
            fileManager: fileManager
        )

        let process = Process()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = request.bundle.rootURL
        process.standardInput = request.standardInput.processValue
        process.standardOutput = request.standardOutput.processValue
        process.standardError = request.standardError.processValue
        process.environment = ExtensionLaunchEnvironment.composed(
            with: request.additionalEnvironment
        )

        let child = LocalChildProcess(process: process)
        try child.run()
        return child
    }
}

/// A child this process forked itself.
///
/// The exit status is latched rather than read back from `Process` on demand, so an observer
/// installed after the child has already exited still receives it. Installing the observer
/// before `run()` would be simpler and is not available to the runner policy, which learns of
/// the exit from a message; latching is what lets both share one supervisor.
final class LocalChildProcess: ExtensionChildProcess, @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var exitHandler: ((Int32) -> Void)?

    init(process: Process) {
        self.process = process
    }

    func run() throws {
        process.terminationHandler = { [weak self] child in
            self?.recordExit(child.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw error
        }
    }

    var isRunning: Bool {
        process.isRunning
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    func waitUntilExit() {
        process.waitUntilExit()
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    func observeExit(_ handler: ((Int32) -> Void)?) {
        lock.lock()
        guard let handler else {
            exitHandler = nil
            lock.unlock()
            return
        }
        if let exitStatus {
            lock.unlock()
            handler(exitStatus)
            return
        }
        exitHandler = handler
        lock.unlock()
    }

    private func recordExit(_ status: Int32) {
        lock.lock()
        guard exitStatus == nil else {
            lock.unlock()
            return
        }
        exitStatus = status
        let handler = exitHandler
        exitHandler = nil
        lock.unlock()
        handler?(status)
    }
}
