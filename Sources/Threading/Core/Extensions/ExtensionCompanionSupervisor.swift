import Darwin
import Foundation
import ThreadingExtensionKit

enum ExtensionCompanionSupervisorError: LocalizedError {
    case launchFailed(String)
    case handshakeTimedOut
    case outputLineTooLarge(maximum: Int)
    case invalidHandshake(String)
    case invalidOperationResponse(String)
    case invalidRemoteSurface(String)
    case operationTimedOut(String)
    case operationFailed(String)
    case operationNotDeclared(String)
    case operationQueueFull(maximum: Int)
    case notRunning
    case processEnded(status: Int32, message: String)
    case outputClosed

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "The companion could not be started: \(message)"
        case .handshakeTimedOut:
            return "The companion did not become ready in time."
        case .outputLineTooLarge(let maximum):
            return "The companion wrote a protocol message larger than \(maximum) bytes."
        case .invalidHandshake(let message):
            return "The companion returned an invalid startup handshake: \(message)"
        case .invalidOperationResponse(let message):
            return "The companion returned an invalid operation response: \(message)"
        case .invalidRemoteSurface(let message):
            return "The companion remote-surface channel failed: \(message)"
        case .operationTimedOut(let operationID):
            return "The companion took too long to run operation “\(operationID)”."
        case .operationFailed(let message):
            return message
        case .operationNotDeclared(let operationID):
            return "The companion did not declare operation “\(operationID)”."
        case .operationQueueFull(let maximum):
            return "The companion already has the maximum \(maximum) operations in flight."
        case .notRunning:
            return "The companion is not running."
        case .processEnded(let status, let message):
            let detail = message.isEmpty ? "No diagnostic was written." : message
            return "The companion exited with status \(status): \(detail)"
        case .outputClosed:
            return "The companion closed its control output."
        }
    }
}

struct ExtensionCompanionLaunchRequest {
    let companion: ThreadingExtensionCompanionBundle
    let arguments: [String]
    let environment: [String: String]
    let standardInput: ExtensionChildStream
    let standardOutput: ExtensionChildStream
    let standardError: ExtensionChildStream
    /// Child end of the dedicated full-duplex remote-surface socket, when declared.
    /// It carries no core bearer or host API.
    let remoteSurfaceDescriptor: Int32?
}

/// Launch boundary for an advanced companion.
///
/// This is intentionally not `ExtensionLaunchPolicy`. The latter is allowed to install the
/// Wasm core's broker descriptor and environment; a companion request has no field capable of
/// carrying either. Keeping the types apart prevents a future call site from granting host-data
/// authority by accidentally reusing the core launch request.
protocol ExtensionCompanionLaunchPolicy: Sendable {
    func spawn(_ request: ExtensionCompanionLaunchRequest) throws -> ExtensionChildProcess
}

struct LocalExtensionCompanionLaunchPolicy: ExtensionCompanionLaunchPolicy {
    func spawn(_ request: ExtensionCompanionLaunchRequest) throws -> ExtensionChildProcess {
        if let remoteSurfaceDescriptor = request.remoteSurfaceDescriptor {
            defer { closeChildPipeEnds(request) }
            return try ExtensionChildSpawner.spawn(
                executableURL: request.companion.executableURL,
                arguments: request.arguments,
                environment: ExtensionLaunchEnvironment.composed(with: request.environment),
                workingDirectory: request.companion.bundleURL,
                descriptors: [
                    0: descriptor(for: request.standardInput, childReads: true),
                    1: descriptor(for: request.standardOutput, childReads: false),
                    2: descriptor(for: request.standardError, childReads: false),
                    ExtensionRemoteSurfaceConnection.childDescriptorNumber:
                        .inherited(remoteSurfaceDescriptor)
                ]
            )
        }

        let process = Process()
        process.executableURL = request.companion.executableURL
        process.arguments = request.arguments
        process.currentDirectoryURL = request.companion.bundleURL
        process.standardInput = request.standardInput.processValue
        process.standardOutput = request.standardOutput.processValue
        process.standardError = request.standardError.processValue
        process.environment = ExtensionLaunchEnvironment.composed(with: request.environment)

        let child = LocalChildProcess(process: process)
        try child.run()
        return child
    }

    private func descriptor(
        for stream: ExtensionChildStream,
        childReads: Bool
    ) -> ChildDescriptorSource {
        switch stream {
        case .nullDevice:
            return .nullDevice
        case .pipe(let pipe):
            return .inherited(childReads
                ? pipe.fileHandleForReading.fileDescriptor
                : pipe.fileHandleForWriting.fileDescriptor)
        }
    }

    private func closeChildPipeEnds(_ request: ExtensionCompanionLaunchRequest) {
        if case .pipe(let pipe) = request.standardInput {
            try? pipe.fileHandleForReading.close()
        }
        if case .pipe(let pipe) = request.standardOutput {
            try? pipe.fileHandleForWriting.close()
        }
        if case .pipe(let pipe) = request.standardError {
            try? pipe.fileHandleForWriting.close()
        }
    }
}

/// One supervised generation of one separately signed companion process.
///
/// Startup is a bounded, generation-bound handshake. Shutdown first sends the protocol message,
/// then escalates to SIGTERM and SIGKILL. Any unexpected exit is latched and delivered once, so
/// the manager can update status without racing a short-lived worker.
final class ExtensionCompanionSupervisor: @unchecked Sendable {
    static let defaultStartupTimeout: TimeInterval = 3
    static let defaultOperationTimeout: TimeInterval = 30
    static let maximumLineBytes = 64 * 1024
    static let maximumPendingOperations = 32
    private static let maximumDiagnosticBytes = 64 * 1024

    typealias Validator = (
        ThreadingExtensionCompanionBundle,
        ThreadingExtensionBundle
    ) throws -> ThreadingExtensionCompanionBundle

    let extensionIdentifier: String
    let companionID: String
    let generation: String
    let capabilities: Set<ExtensionCompanionCapability>
    let operationIDs: Set<String>
    let surfaces: [ExtensionRemoteSurface]

    typealias OperationCompletion = @MainActor @Sendable (
        Result<ExtensionCompanionOperationResponse, Error>
    ) -> Void

    private struct PendingOperation {
        let operationID: String
        let completion: OperationCompletion
        let timeoutItem: DispatchWorkItem
    }

    private let child: ExtensionChildProcess
    private let stdin: Pipe
    private let stdout: Pipe
    private let stderr: Pipe
    private let remoteSurfaceConnection: ExtensionRemoteSurfaceConnection?
    private let startupSemaphore = DispatchSemaphore(value: 0)
    private let diagnosticsFinished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let readQueue = DispatchQueue(
        label: "codes.threading.extension-companion.stdout",
        qos: .userInitiated
    )
    private let writeQueue = DispatchQueue(
        label: "codes.threading.extension-companion.stdin",
        qos: .userInitiated
    )

    private var startupResult: Result<Void, Error>?
    private var terminalError: Error?
    private var terminationObserver: (@MainActor @Sendable (Error) -> Void)?
    private var isStopped = false
    private var diagnostic = Data()
    private var pendingOperations: [String: PendingOperation] = [:]

    private init(
        extensionBundle: ThreadingExtensionBundle,
        companion: ThreadingExtensionCompanionBundle,
        generation: String,
        policy: ExtensionCompanionLaunchPolicy,
        validator: Validator
    ) throws {
        extensionIdentifier = extensionBundle.manifest.identifier
        companionID = companion.declaration.id
        self.generation = generation
        capabilities = companion.declaration.capabilities
        operationIDs = Set(companion.declaration.operations.map(\.id))
        surfaces = companion.declaration.surfaces
        stdin = Pipe()
        stdout = Pipe()
        stderr = Pipe()
        // A worker may exit between the generation check and a control write. Without this,
        // writing an operation or graceful shutdown to its closed stdin terminates Threading with
        // SIGPIPE instead of taking the ordinary error path below.
        _ = fcntl(
            stdin.fileHandleForWriting.fileDescriptor,
            F_SETNOSIGPIPE,
            1
        )
        let remoteSurfacePair = companion.declaration.surfaces.isEmpty
            ? nil
            : try ExtensionRemoteSurfaceConnection.makePair()
        remoteSurfaceConnection = remoteSurfacePair?.connection

        // This is deliberately the last package operation before spawn.
        let launchCompanion = try validator(companion, extensionBundle)
        let capabilityNames = launchCompanion.declaration.capabilities
            .map(\.rawValue)
            .sorted()
        let capabilityJSON = String(
            decoding: try JSONEncoder().encode(capabilityNames),
            as: UTF8.self
        )
        var environment = [
            ExtensionCompanionEnvironment.extensionIdentifier:
                extensionBundle.manifest.identifier,
            ExtensionCompanionEnvironment.companionIdentifier:
                launchCompanion.declaration.id,
            ExtensionCompanionEnvironment.generation: generation,
            ExtensionCompanionEnvironment.capabilitiesJSON: capabilityJSON
        ]
        if remoteSurfacePair != nil {
            environment[ExtensionCompanionEnvironment.remoteSurfaceDescriptor] = String(
                ExtensionRemoteSurfaceConnection.childDescriptorNumber
            )
        }
        defer {
            if let descriptor = remoteSurfacePair?.childDescriptor {
                Darwin.close(descriptor)
            }
        }
        do {
            child = try policy.spawn(ExtensionCompanionLaunchRequest(
                companion: launchCompanion,
                arguments: ["--threading-companion-serve"],
                environment: environment,
                standardInput: .pipe(stdin),
                standardOutput: .pipe(stdout),
                standardError: .pipe(stderr),
                remoteSurfaceDescriptor: remoteSurfacePair?.childDescriptor
            ))
        } catch {
            remoteSurfaceConnection?.close()
            throw error
        }
    }

    deinit {
        child.observeExit(nil)
        stop()
    }

    /// Starts and verifies one companion. Call off the main thread.
    static func start(
        extensionBundle: ThreadingExtensionBundle,
        companion: ThreadingExtensionCompanionBundle,
        generation: String = UUID().uuidString.lowercased(),
        policy: ExtensionCompanionLaunchPolicy = LocalExtensionCompanionLaunchPolicy(),
        validator: @escaping Validator = ExtensionBundleInspector
            .revalidateCompanionForLaunch,
        timeout: TimeInterval = defaultStartupTimeout,
        maximumLine: Int = maximumLineBytes
    ) throws -> ExtensionCompanionSupervisor {
        let supervisor: ExtensionCompanionSupervisor
        do {
            supervisor = try ExtensionCompanionSupervisor(
                extensionBundle: extensionBundle,
                companion: companion,
                generation: generation,
                policy: policy,
                validator: validator
            )
        } catch {
            throw ExtensionCompanionSupervisorError.launchFailed(error.localizedDescription)
        }

        supervisor.beginReading(maximumLine: maximumLine)
        supervisor.child.observeExit { [weak supervisor] status in
            supervisor?.processDidExit(status: status)
        }

        guard supervisor.startupSemaphore.wait(timeout: .now() + timeout) == .success else {
            supervisor.finish(
                with: ExtensionCompanionSupervisorError.handshakeTimedOut,
                terminate: true
            )
            throw ExtensionCompanionSupervisorError.handshakeTimedOut
        }
        switch supervisor.lockedStartupResult {
        case .success:
            return supervisor
        case .failure(let error):
            throw error
        case nil:
            supervisor.finish(
                with: ExtensionCompanionSupervisorError.outputClosed,
                terminate: true
            )
            throw ExtensionCompanionSupervisorError.outputClosed
        }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isStopped && child.isRunning
    }

    func invokeOperation(
        id operationID: String,
        arguments: ExtensionJSONValue,
        requestID: String = UUID().uuidString.lowercased(),
        timeout: TimeInterval = defaultOperationTimeout,
        completion: @escaping OperationCompletion
    ) {
        guard operationIDs.contains(operationID) else {
            deliver(
                .failure(
                    ExtensionCompanionSupervisorError
                        .operationNotDeclared(operationID)
                ),
                to: completion
            )
            return
        }

        let request = ExtensionCompanionOperationRequest(
            requestID: requestID,
            generation: generation,
            operationID: operationID,
            arguments: arguments
        )
        do {
            try request.validate()
            var encoded = try JSONEncoder().encode(request)
            guard encoded.count <= Self.maximumLineBytes else {
                throw ExtensionCompanionSupervisorError.outputLineTooLarge(
                    maximum: Self.maximumLineBytes
                )
            }
            encoded.append(0x0A)
            let data = encoded
            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.timeOutOperation(requestID: requestID)
            }
            let pending = PendingOperation(
                operationID: operationID,
                completion: completion,
                timeoutItem: timeoutItem
            )

            lock.lock()
            guard !isStopped, child.isRunning,
                  case .success? = startupResult else {
                lock.unlock()
                deliver(
                    .failure(ExtensionCompanionSupervisorError.notRunning),
                    to: completion
                )
                return
            }
            guard pendingOperations[requestID] == nil else {
                lock.unlock()
                deliver(
                    .failure(ExtensionCompanionSupervisorError.invalidOperationResponse(
                        "request id “\(requestID)” is already pending"
                    )),
                    to: completion
                )
                return
            }
            guard pendingOperations.count < Self.maximumPendingOperations else {
                lock.unlock()
                deliver(
                    .failure(ExtensionCompanionSupervisorError.operationQueueFull(
                        maximum: Self.maximumPendingOperations
                    )),
                    to: completion
                )
                return
            }
            pendingOperations[requestID] = pending
            lock.unlock()

            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutItem
            )
            writeQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.stdin.fileHandleForWriting.write(contentsOf: data)
                } catch {
                    self.finish(
                        with: ExtensionCompanionSupervisorError.notRunning,
                        terminate: true
                    )
                }
            }
        } catch {
            deliver(.failure(error), to: completion)
        }
    }

    func startRemoteSurfaces(
        onFrame: @escaping (ExtensionRemoteSurfacePacket) -> Void
    ) {
        remoteSurfaceConnection?.start(
            onPacket: onFrame,
            onFailure: { [weak self] error in
                self?.finish(
                    with: ExtensionCompanionSupervisorError.invalidRemoteSurface(
                        error.localizedDescription
                    ),
                    terminate: true
                )
            }
        )
    }

    func sendRemoteSurface(_ message: ExtensionRemoteSurfaceMessage) {
        remoteSurfaceConnection?.send(message)
    }

    func acknowledgeRemoteSurfaceFrame(
        presentationID: String,
        sequence: UInt64,
        disposition: ExtensionRemoteSurfaceFrameDisposition
    ) {
        remoteSurfaceConnection?.acknowledge(
            presentationID: presentationID,
            sequence: sequence,
            disposition: disposition
        )
    }

    func observeTermination(_ observer: @escaping @MainActor @Sendable (Error) -> Void) {
        let completed: Error?
        lock.lock()
        if let terminalError {
            completed = terminalError
        } else {
            terminationObserver = observer
            completed = nil
        }
        lock.unlock()

        if let completed {
            Task { @MainActor in
                observer(completed)
            }
        }
    }

    func stop() {
        let pending: [PendingOperation]
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        terminationObserver = nil
        pending = Array(pendingOperations.values)
        pendingOperations.removeAll()
        lock.unlock()
        for operation in pending {
            operation.timeoutItem.cancel()
            deliver(
                .failure(ExtensionCompanionSupervisorError.notRunning),
                to: operation.completion
            )
        }
        remoteSurfaceConnection?.close()

        let message = ExtensionCompanionHostMessage(
            type: .shutdown,
            generation: generation
        )
        if var encoded = try? JSONEncoder().encode(message) {
            encoded.append(0x0A)
            let data = encoded
            writeQueue.async { [stdin] in
                try? stdin.fileHandleForWriting.write(contentsOf: data)
                try? stdin.fileHandleForWriting.close()
            }
        } else {
            try? stdin.fileHandleForWriting.close()
        }

        let child = child
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            guard child.isRunning else { return }
            child.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                guard child.isRunning else { return }
                child.kill()
            }
        }
    }

    private var lockedStartupResult: Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return startupResult
    }

    private func beginReading(maximumLine: Int) {
        readQueue.async { [weak self] in
            self?.readProtocolLines(maximum: maximumLine)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.drainDiagnostics()
        }
    }

    private func readProtocolLines(maximum: Int) {
        let handle = stdout.fileHandleForReading
        var buffer = Data()

        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handleOutputClosed()
                return
            }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard line.count <= maximum else {
                    finish(
                        with: ExtensionCompanionSupervisorError
                            .outputLineTooLarge(maximum: maximum),
                        terminate: true
                    )
                    return
                }
                handleProtocolLine(line.last == 0x0D ? line.dropLast() : line[...])
                if lockedIsStopped { return }
            }
            guard buffer.count <= maximum else {
                finish(
                    with: ExtensionCompanionSupervisorError
                        .outputLineTooLarge(maximum: maximum),
                    terminate: true
                )
                return
            }
        }
    }

    private func handleProtocolLine(_ bytes: Data.SubSequence) {
        guard lockedStartupResult == nil else {
            handleOperationResponse(Data(bytes))
            return
        }
        do {
            let hello = try JSONDecoder().decode(
                ExtensionCompanionHello.self,
                from: Data(bytes)
            )
            guard hello.protocolVersion == ThreadingCompanionAPI.protocolVersion else {
                throw ExtensionCompanionSupervisorError.invalidHandshake(
                    "protocol version \(hello.protocolVersion) is unsupported"
                )
            }
            guard hello.companionID == companionID else {
                throw ExtensionCompanionSupervisorError.invalidHandshake(
                    "expected companion \(companionID), received \(hello.companionID)"
                )
            }
            guard hello.generation == generation else {
                throw ExtensionCompanionSupervisorError.invalidHandshake(
                    "the process answered for a stale generation"
                )
            }
            completeStartup(.success(()))
        } catch let error as ExtensionCompanionSupervisorError {
            finish(with: error, terminate: true)
        } catch {
            finish(
                with: ExtensionCompanionSupervisorError.invalidHandshake(
                    error.localizedDescription
                ),
                terminate: true
            )
        }
    }

    private func handleOperationResponse(_ data: Data) {
        do {
            let response = try JSONDecoder().decode(
                ExtensionCompanionOperationResponse.self,
                from: data
            )
            try response.validate()
            guard response.generation == generation else {
                throw ExtensionCompanionSupervisorError.invalidOperationResponse(
                    "the response belongs to a stale generation"
                )
            }
            guard let pending = takePendingOperation(requestID: response.requestID) else {
                throw ExtensionCompanionSupervisorError.invalidOperationResponse(
                    "request id “\(response.requestID)” is not pending"
                )
            }
            guard response.operationID == pending.operationID else {
                let error = ExtensionCompanionSupervisorError.invalidOperationResponse(
                    "expected operation \(pending.operationID), received \(response.operationID)"
                )
                deliver(.failure(error), to: pending.completion)
                finish(with: error, terminate: true)
                return
            }
            if let error = response.error {
                deliver(
                    .failure(ExtensionCompanionSupervisorError.operationFailed(error)),
                    to: pending.completion
                )
            } else {
                deliver(.success(response), to: pending.completion)
            }
        } catch let error as ExtensionCompanionSupervisorError {
            finish(with: error, terminate: true)
        } catch {
            finish(
                with: ExtensionCompanionSupervisorError.invalidOperationResponse(
                    error.localizedDescription
                ),
                terminate: true
            )
        }
    }

    private func timeOutOperation(requestID: String) {
        guard let pending = takePendingOperation(requestID: requestID) else { return }
        deliver(
            .failure(
                ExtensionCompanionSupervisorError
                    .operationTimedOut(pending.operationID)
            ),
            to: pending.completion
        )
    }

    private func takePendingOperation(requestID: String) -> PendingOperation? {
        lock.lock()
        let pending = pendingOperations.removeValue(forKey: requestID)
        lock.unlock()
        pending?.timeoutItem.cancel()
        return pending
    }

    private func deliver(
        _ result: Result<ExtensionCompanionOperationResponse, Error>,
        to completion: @escaping OperationCompletion
    ) {
        Task { @MainActor in
            completion(result)
        }
    }

    private func drainDiagnostics() {
        defer { diagnosticsFinished.signal() }
        let handle = stderr.fileHandleForReading
        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            let remaining = max(0, Self.maximumDiagnosticBytes - diagnostic.count)
            diagnostic.append(chunk.prefix(remaining))
            lock.unlock()
        }
    }

    private var lockedIsStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    private func completeStartup(_ result: Result<Void, Error>) {
        lock.lock()
        guard startupResult == nil else {
            lock.unlock()
            return
        }
        startupResult = result
        lock.unlock()
        startupSemaphore.signal()
    }

    private func processDidExit(status: Int32) {
        // `Process` can report its exit before the stderr drain has consumed the final write.
        // Keep exit delivery off the callback queue and give the already-running drain a
        // bounded chance to finish so the user sees the companion's actionable diagnostic.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            _ = self.diagnosticsFinished.wait(timeout: .now() + 0.25)
            self.finish(
                with: ExtensionCompanionSupervisorError.processEnded(
                    status: status,
                    message: self.diagnosticText
                ),
                terminate: false
            )
        }
    }

    private func handleOutputClosed() {
        // stdout normally reaches EOF a few instants before the child-exit callback. Let that
        // callback own the terminal result so it can include the exit status and stderr. A
        // process which closes its protocol output but keeps running is still malformed and is
        // stopped after this small grace period.
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 0.25
        ) { [weak self] in
            guard let self, self.child.isRunning else { return }
            self.finish(
                with: ExtensionCompanionSupervisorError.outputClosed,
                terminate: true
            )
        }
    }

    private var diagnosticText: String {
        lock.lock()
        let data = diagnostic
        lock.unlock()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finish(with error: Error, terminate: Bool) {
        let observer: (@MainActor @Sendable (Error) -> Void)?
        let mustSignalStartup: Bool
        let pending: [PendingOperation]
        lock.lock()
        guard terminalError == nil else {
            lock.unlock()
            return
        }
        terminalError = error
        mustSignalStartup = startupResult == nil
        if mustSignalStartup {
            startupResult = .failure(error)
        }
        observer = terminationObserver
        terminationObserver = nil
        pending = Array(pendingOperations.values)
        pendingOperations.removeAll()
        lock.unlock()

        if mustSignalStartup {
            startupSemaphore.signal()
        }
        if terminate {
            stop()
        }
        for operation in pending {
            operation.timeoutItem.cancel()
            deliver(.failure(error), to: operation.completion)
        }
        if let observer {
            Task { @MainActor in
                observer(error)
            }
        }
    }
}
