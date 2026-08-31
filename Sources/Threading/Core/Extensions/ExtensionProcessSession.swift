import Darwin
import Foundation
import ThreadingExtensionKit

enum ExtensionProcessError: LocalizedError {
    case launchFailed(String)
    case registrationTimedOut
    case actionTimedOut(String)
    case commandTimedOut(String)
    case settingsTimedOut
    case serviceTimedOut(String)
    case toolTimedOut(String)
    case outputLineTooLarge(maximum: Int)
    case invalidMessage(String)
    case responseForUnknownRequest(String)
    case responsePanelMismatch(expected: String, actual: String)
    case responseNavigatorMismatch(expected: String, actual: String)
    case responseCommandMismatch(expected: String, actual: String)
    case responseSettingsMismatch(expected: [String], actual: [String])
    case responseServiceMismatch(
        expectedID: String,
        expectedVersion: Int,
        actualID: String,
        actualVersion: Int
    )
    case processEnded(status: Int32, message: String)
    case outputClosed
    case notRunning
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "The extension could not be started: \(message)"
        case .registrationTimedOut:
            return "The extension took too long to start."
        case .actionTimedOut(let action):
            return "The extension took too long to handle “\(action)”."
        case .commandTimedOut(let command):
            return "The extension took too long to run command “\(command)”."
        case .settingsTimedOut:
            return "The extension took too long to apply a settings change."
        case .serviceTimedOut(let service):
            return "The extension took too long to handle service “\(service)”."
        case .toolTimedOut(let tool):
            return "The extension took too long to run MCP tool “\(tool)”."
        case .outputLineTooLarge(let maximum):
            return "The extension wrote a protocol message larger than \(maximum) bytes."
        case .invalidMessage(let message):
            return "The extension wrote an invalid protocol message: \(message)"
        case .responseForUnknownRequest(let requestID):
            return "The extension responded to unknown request “\(requestID)”."
        case .responsePanelMismatch(let expected, let actual):
            return "The extension action for panel “\(expected)” returned panel “\(actual)”."
        case .responseNavigatorMismatch(let expected, let actual):
            return """
            The extension action for navigator “\(expected)” returned navigator “\(actual)”.
            """
        case .responseCommandMismatch(let expected, let actual):
            return "The extension response for command “\(expected)” named command “\(actual)”."
        case .responseSettingsMismatch(let expected, let actual):
            return "The extension settings response named \(actual) instead of \(expected)."
        case .responseServiceMismatch(
            let expectedID,
            let expectedVersion,
            let actualID,
            let actualVersion
        ):
            return "The extension service response named \(actualID) v\(actualVersion) instead of \(expectedID) v\(expectedVersion)."
        case .processEnded(let status, let message):
            let diagnostic = message.isEmpty ? "No diagnostic was written." : message
            return "The extension exited with status \(status): \(diagnostic)"
        case .outputClosed:
            return "The extension closed its protocol output."
        case .notRunning:
            return "The extension is not running."
        case .writeFailed(let message):
            return "Threading could not send an action to the extension: \(message)"
        }
    }
}

/// A supervised, persistent extension process speaking newline-delimited JSON.
///
/// The first stdout line is `ExtensionRegistration`. Later lines are correlated action or MCP
/// responses. stdin accepts commands, settings, service, panel/component action, and MCP tool
/// requests. This class
/// owns every pipe, drains stderr so an extension cannot block on diagnostics, caps each
/// protocol line, times out registration and individual actions, and fails every pending
/// request if the child exits.
final class ExtensionProcessSession: @unchecked Sendable {
    static let defaultTimeout: TimeInterval = 3
    /// Shorter than an action's, because a preview offer happens while the user is looking at a
    /// row they just selected: a candidate that has not answered by now is one the shell should
    /// already have moved past.
    static let attachmentPreviewTimeout: TimeInterval = 1.5
    static let maximumLineBytes = 1024 * 1024
    private static let maximumDiagnosticBytes = 64 * 1024

    struct Started {
        let session: ExtensionProcessSession
        let registration: ExtensionRegistration
    }

    typealias ActionCompletion = @MainActor @Sendable (
        Result<ExtensionActionResponse, Error>
    ) -> Void
    typealias NavigatorCompletion = @MainActor @Sendable (
        Result<ExtensionWorkspaceNavigatorActionResponse, Error>
    ) -> Void
    typealias CommandCompletion = @MainActor @Sendable (
        Result<ExtensionCommandResponse, Error>
    ) -> Void
    typealias SettingsCompletion = @MainActor @Sendable (
        Result<ExtensionSettingsUpdateResponse, Error>
    ) -> Void
    typealias ServiceCompletion = @MainActor @Sendable (
        Result<ExtensionServiceResponse, Error>
    ) -> Void
    typealias ToolCompletion = @MainActor @Sendable (
        Result<ExtensionMCPToolResponse, Error>
    ) -> Void
    typealias AttachmentPreviewCompletion = @MainActor @Sendable (
        Result<ExtensionAttachmentPreviewResponse, Error>
    ) -> Void

    private struct PendingAction {
        let actionID: String
        let panelID: String?
        let completion: ActionCompletion
        let timeoutItem: DispatchWorkItem
    }

    private struct PendingNavigator {
        let actionID: String
        let navigatorID: String
        let completion: NavigatorCompletion
        let timeoutItem: DispatchWorkItem
    }

    private struct PendingTool {
        let toolID: String
        let completion: ToolCompletion
        let timeoutItem: DispatchWorkItem
    }

    private struct PendingAttachmentPreview {
        let attachmentID: String
        let completion: AttachmentPreviewCompletion
        let timeoutItem: DispatchWorkItem
    }

    private struct PendingCommand {
        let commandID: String
        let completion: CommandCompletion
        let timeoutItem: DispatchWorkItem
    }

    private struct PendingSettings {
        let settingIDs: [String]
        let completion: SettingsCompletion
        let timeoutItem: DispatchWorkItem
    }

    private struct PendingService {
        let serviceID: String
        let serviceVersion: Int
        let completion: ServiceCompletion
        let timeoutItem: DispatchWorkItem
    }

    private struct ResponseEnvelope: Decodable {
        let requestID: String
    }

    private let bundle: ThreadingExtensionBundle
    private let child: ExtensionChildProcess
    private let stdin: Pipe
    private let stdout: Pipe
    private let stderr: Pipe
    private let stderrCapture = DiagnosticCapture(maximum: maximumDiagnosticBytes)
    private let startupSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let readQueue = DispatchQueue(
        label: "codes.threading.extension.stdout",
        qos: .userInitiated
    )
    private let writeQueue = DispatchQueue(
        label: "codes.threading.extension.stdin",
        qos: .userInitiated
    )

    private var startupResult: Result<ExtensionRegistration, Error>?
    /// The raw, validated registration for this exact child generation. Localized inventory is
    /// deliberately not stored here: action responses must be compared with the wire contract
    /// accepted before host presentation transforms it.
    private var acceptedRegistration: ExtensionRegistration?
    private var pendingActions: [String: PendingAction] = [:]
    private var pendingNavigators: [String: PendingNavigator] = [:]
    private var pendingAttachmentPreviews: [String: PendingAttachmentPreview] = [:]
    private var pendingCommands: [String: PendingCommand] = [:]
    private var pendingSettings: [String: PendingSettings] = [:]
    private var pendingServices: [String: PendingService] = [:]
    private var pendingTools: [String: PendingTool] = [:]
    private var isStopped = false
    private var terminalError: Error?
    private var terminationObserver: (@MainActor @Sendable (Error) -> Void)?

    /// Spawning in the initializer is what makes `child` a `let`: a supervisor that could
    /// exist without a running child would need every member to answer "not started yet",
    /// which is a state this type has never had.
    private init(
        bundle: ThreadingExtensionBundle,
        policy: ExtensionLaunchPolicy,
        additionalEnvironment: [String: String],
        hostDescriptor: Int32?
    ) throws {
        self.bundle = bundle
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.child = try policy.spawn(
            ExtensionLaunchRequest(
                bundle: bundle,
                arguments: ["--threading-serve"],
                additionalEnvironment: additionalEnvironment,
                standardInput: .pipe(stdin),
                standardOutput: .pipe(stdout),
                standardError: .pipe(stderr),
                // The broker socket, when the launcher can install one. A policy that cannot
                // refuses the request rather than starting an extension whose every host call
                // would fail for a reason it could not report.
                extraDescriptors: hostDescriptor.map {
                    [ExtensionHostDescriptorConnection.childDescriptorNumber: $0]
                } ?? [:]
            )
        )
    }

    deinit {
        child.observeExit(nil)
        stopProcess()
    }

    /// Starts the child and blocks until its first JSONL registration arrives.
    ///
    /// Callers must invoke this off the main thread.
    static func start(
        bundle: ThreadingExtensionBundle,
        policy: ExtensionLaunchPolicy = RuntimeSelectingLaunchPolicy(),
        additionalEnvironment: [String: String] = [:],
        hostDescriptor: Int32? = nil,
        timeout: TimeInterval = defaultTimeout,
        maximumLine: Int = maximumLineBytes
    ) throws -> Started {
        let session: ExtensionProcessSession
        do {
            session = try ExtensionProcessSession(
                bundle: bundle,
                policy: policy,
                additionalEnvironment: additionalEnvironment,
                hostDescriptor: hostDescriptor
            )
        } catch {
            throw ExtensionProcessError.launchFailed(error.localizedDescription)
        }

        // Drains start before the exit observer so a child which has already died reports its
        // diagnostic rather than an empty one. `observeExit` latches, so ordering these the
        // other way would be safe but quieter about why the extension failed.
        session.beginReading(maximumLine: maximumLine)
        session.child.observeExit { [weak session] status in
            session?.processDidExit(status: status)
        }

        guard session.startupSemaphore.wait(timeout: .now() + timeout) == .success else {
            session.finish(with: ExtensionProcessError.registrationTimedOut, terminate: true)
            throw ExtensionProcessError.registrationTimedOut
        }

        switch session.lockedStartupResult {
        case .success(let registration):
            return Started(session: session, registration: registration)
        case .failure(let error):
            throw error
        case nil:
            session.finish(with: ExtensionProcessError.outputClosed, terminate: true)
            throw ExtensionProcessError.outputClosed
        }
    }

    func invoke(
        panelID: String,
        actionID: String,
        value: ExtensionJSONValue? = nil,
        context: ExtensionCommandContext = .init(),
        requestID: String = UUID().uuidString.lowercased(),
        timeout: TimeInterval = defaultTimeout,
        completion: @escaping ActionCompletion
    ) {
        let request = ExtensionActionRequest(
            requestID: requestID,
            panelID: panelID,
            actionID: actionID,
            value: value,
            context: context
        )

        do {
            try request.validate()
            var encoded = try JSONEncoder().encode(request)
            encoded.append(0x0A)
            let data = encoded

            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.timeOut(requestID: requestID)
            }
            let action = PendingAction(
                actionID: actionID,
                panelID: panelID,
                completion: completion,
                timeoutItem: timeoutItem
            )

            lock.lock()
            guard !isStopped, child.isRunning else {
                lock.unlock()
                deliver(.failure(ExtensionProcessError.notRunning), to: completion)
                return
            }
            guard requestIDIsAvailableLocked(requestID) else {
                lock.unlock()
                deliver(.failure(ExtensionProcessError.invalidMessage(
                    "request id “\(requestID)” is already pending"
                )), to: completion)
                return
            }
            pendingActions[requestID] = action
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
                        with: ExtensionProcessError.writeFailed(error.localizedDescription),
                        terminate: true
                    )
                }
            }
        } catch {
            deliver(.failure(error), to: completion)
        }
    }

    func invokeComponentAction(
        target: ExtensionComponentTarget,
        actionID: String,
        value: ExtensionJSONValue? = nil,
        requestID: String = UUID().uuidString.lowercased(),
        timeout: TimeInterval = defaultTimeout,
        completion: @escaping ActionCompletion
    ) {
        let request = ExtensionComponentActionRequest(
            requestID: requestID,
            target: target,
            actionID: actionID,
            value: value
        )

        do {
            try request.validate()
            var encoded = try JSONEncoder().encode(request)
            encoded.append(0x0A)
            let data = encoded

            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.timeOut(requestID: requestID)
            }
            let action = PendingAction(
                actionID: actionID,
                panelID: nil,
                completion: completion,
                timeoutItem: timeoutItem
            )

            lock.lock()
            guard !isStopped, child.isRunning else {
                lock.unlock()
                deliver(.failure(ExtensionProcessError.notRunning), to: completion)
                return
            }
            guard requestIDIsAvailableLocked(requestID) else {
                lock.unlock()
                deliver(.failure(ExtensionProcessError.invalidMessage(
                    "request id “\(requestID)” is already pending"
                )), to: completion)
                return
            }
            pendingActions[requestID] = action
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
                        with: ExtensionProcessError.writeFailed(error.localizedDescription),
                        terminate: true
                    )
                }
            }
        } catch {
            deliver(.failure(error), to: completion)
        }
    }

    /// Offers one attachment to this extension and waits for its answer.
    ///
    /// The timeout is shorter than an action's: a preview offer happens while the user is looking
    /// at a selected row, and a candidate that has not answered promptly is one the shell should
    /// have moved past already.
    func invokeAttachmentPreview(
        _ attachment: ExtensionAttachmentContext,
        requestID: String = UUID().uuidString.lowercased(),
        timeout: TimeInterval = attachmentPreviewTimeout,
        completion: @escaping AttachmentPreviewCompletion
    ) {
        let request = ExtensionAttachmentPreviewRequest(
            requestID: requestID,
            attachment: attachment
        )
        do {
            try request.validate()
            var encoded = try JSONEncoder().encode(request)
            encoded.append(0x0A)
            let data = encoded

            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.timeOutAttachmentPreview(requestID: requestID)
            }
            let pending = PendingAttachmentPreview(
                attachmentID: attachment.attachmentID,
                completion: completion,
                timeoutItem: timeoutItem
            )

            lock.lock()
            guard !isStopped, child.isRunning else {
                lock.unlock()
                deliverAttachmentPreview(
                    .failure(ExtensionProcessError.notRunning),
                    to: completion
                )
                return
            }
            guard requestIDIsAvailableLocked(requestID) else {
                lock.unlock()
                deliverAttachmentPreview(
                    .failure(ExtensionProcessError.invalidMessage(
                        "request id “\(requestID)” is already pending"
                    )),
                    to: completion
                )
                return
            }
            pendingAttachmentPreviews[requestID] = pending
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
                        with: ExtensionProcessError.writeFailed(error.localizedDescription),
                        terminate: true
                    )
                }
            }
        } catch {
            deliverAttachmentPreview(.failure(error), to: completion)
        }
    }

    func invokeWorkspaceNavigatorAction(
        navigatorID: String,
        actionID: String,
        value: ExtensionJSONValue? = nil,
        context: ExtensionCommandContext = .init(),
        requestID: String = UUID().uuidString.lowercased(),
        timeout: TimeInterval = defaultTimeout,
        completion: @escaping NavigatorCompletion
    ) {
        let request = ExtensionWorkspaceNavigatorActionRequest(
            requestID: requestID,
            navigatorID: navigatorID,
            actionID: actionID,
            value: value,
            context: context
        )

        do {
            try request.validate()
            var encoded = try JSONEncoder().encode(request)
            encoded.append(0x0A)
            let data = encoded

            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.timeOutNavigator(requestID: requestID)
            }
            let pending = PendingNavigator(
                actionID: actionID,
                navigatorID: navigatorID,
                completion: completion,
                timeoutItem: timeoutItem
            )

            lock.lock()
            guard !isStopped, child.isRunning else {
                lock.unlock()
                deliverNavigator(.failure(ExtensionProcessError.notRunning), to: completion)
                return
            }
            guard requestIDIsAvailableLocked(requestID) else {
                lock.unlock()
                deliverNavigator(.failure(ExtensionProcessError.invalidMessage(
                    "request id “\(requestID)” is already pending"
                )), to: completion)
                return
            }
            pendingNavigators[requestID] = pending
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
                        with: ExtensionProcessError.writeFailed(error.localizedDescription),
                        terminate: true
                    )
                }
            }
        } catch {
            deliverNavigator(.failure(error), to: completion)
        }
    }

    func invokeCommand(
        commandID: String,
        context: ExtensionCommandContext,
        input: ExtensionCommandInputValue? = nil,
        requestID: String = UUID().uuidString.lowercased(),
        timeout: TimeInterval = defaultTimeout,
        completion: @escaping CommandCompletion
    ) {
        let request = ExtensionCommandRequest(
            requestID: requestID,
            commandID: commandID,
            context: context,
            input: input
        )

        do {
            try request.validate()
            var encoded = try JSONEncoder().encode(request)
            encoded.append(0x0A)
            let data = encoded

            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.timeOutCommand(requestID: requestID)
            }
            let command = PendingCommand(
                commandID: commandID,
                completion: completion,
                timeoutItem: timeoutItem
            )

            lock.lock()
            guard !isStopped, child.isRunning else {
                lock.unlock()
                deliverCommand(.failure(ExtensionProcessError.notRunning), to: completion)
                return
            }
            guard requestIDIsAvailableLocked(requestID) else {
                lock.unlock()
                deliverCommand(.failure(ExtensionProcessError.invalidMessage(
                    "request id “\(requestID)” is already pending"
                )), to: completion)
                return
            }
            pendingCommands[requestID] = command
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
                        with: ExtensionProcessError.writeFailed(error.localizedDescription),
                        terminate: true
                    )
                }
            }
        } catch {
            deliverCommand(.failure(error), to: completion)
        }
    }

    func invokeMCPTool(
        sessionID: String,
        toolID: String,
        arguments: ExtensionJSONValue,
        requestID: String = UUID().uuidString.lowercased(),
        timeout: TimeInterval = defaultTimeout,
        completion: @escaping ToolCompletion
    ) {
        let request = ExtensionMCPToolRequest(
            requestID: requestID,
            sessionID: sessionID,
            toolID: toolID,
            arguments: arguments
        )

        do {
            try request.validate()
            var encoded = try JSONEncoder().encode(request)
            encoded.append(0x0A)
            let data = encoded

            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.timeOutTool(requestID: requestID)
            }
            let tool = PendingTool(
                toolID: toolID,
                completion: completion,
                timeoutItem: timeoutItem
            )

            lock.lock()
            guard !isStopped, child.isRunning else {
                lock.unlock()
                deliverTool(.failure(ExtensionProcessError.notRunning), to: completion)
                return
            }
            guard requestIDIsAvailableLocked(requestID) else {
                lock.unlock()
                deliverTool(.failure(ExtensionProcessError.invalidMessage(
                    "request id “\(requestID)” is already pending"
                )), to: completion)
                return
            }
            pendingTools[requestID] = tool
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
                        with: ExtensionProcessError.writeFailed(error.localizedDescription),
                        terminate: true
                    )
                }
            }
        } catch {
            deliverTool(.failure(error), to: completion)
        }
    }

    func invokeService(
        callerExtensionIdentifier: String,
        serviceID: String,
        serviceVersion: Int,
        arguments: ExtensionJSONValue,
        requestID: String = UUID().uuidString.lowercased(),
        timeout: TimeInterval = defaultTimeout,
        completion: @escaping ServiceCompletion
    ) {
        let request = ExtensionServiceRequest(
            requestID: requestID,
            callerExtensionIdentifier: callerExtensionIdentifier,
            serviceID: serviceID,
            serviceVersion: serviceVersion,
            arguments: arguments
        )

        do {
            try request.validate()
            guard bundle.manifest.services.contains(where: {
                $0.id == serviceID && $0.version == serviceVersion
            }) else {
                throw ExtensionProcessError.invalidMessage(
                    "service “\(serviceID)” v\(serviceVersion) is not declared"
                )
            }
            var encoded = try JSONEncoder().encode(request)
            encoded.append(0x0A)
            let data = encoded

            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.timeOutService(requestID: requestID)
            }
            let pending = PendingService(
                serviceID: serviceID,
                serviceVersion: serviceVersion,
                completion: completion,
                timeoutItem: timeoutItem
            )

            lock.lock()
            guard !isStopped, child.isRunning else {
                lock.unlock()
                deliverService(.failure(ExtensionProcessError.notRunning), to: completion)
                return
            }
            guard requestIDIsAvailableLocked(requestID) else {
                lock.unlock()
                deliverService(.failure(ExtensionProcessError.invalidMessage(
                    "request id “\(requestID)” is already pending"
                )), to: completion)
                return
            }
            pendingServices[requestID] = pending
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
                        with: ExtensionProcessError.writeFailed(error.localizedDescription),
                        terminate: true
                    )
                }
            }
        } catch {
            deliverService(.failure(error), to: completion)
        }
    }

    func updateSettings(
        values: [String: ExtensionJSONValue],
        requestID: String = UUID().uuidString.lowercased(),
        timeout: TimeInterval = defaultTimeout,
        completion: @escaping SettingsCompletion
    ) {
        let request = ExtensionSettingsUpdateRequest(
            requestID: requestID,
            values: values
        )

        do {
            try request.validate(against: bundle.manifest.settings)
            var encoded = try JSONEncoder().encode(request)
            encoded.append(0x0A)
            let data = encoded

            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.timeOutSettings(requestID: requestID)
            }
            let pending = PendingSettings(
                settingIDs: values.keys.sorted(),
                completion: completion,
                timeoutItem: timeoutItem
            )

            lock.lock()
            guard !isStopped, child.isRunning else {
                lock.unlock()
                deliverSettings(.failure(ExtensionProcessError.notRunning), to: completion)
                return
            }
            guard requestIDIsAvailableLocked(requestID) else {
                lock.unlock()
                deliverSettings(.failure(ExtensionProcessError.invalidMessage(
                    "request id “\(requestID)” is already pending"
                )), to: completion)
                return
            }
            pendingSettings[requestID] = pending
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
                        with: ExtensionProcessError.writeFailed(error.localizedDescription),
                        terminate: true
                    )
                }
            }
        } catch {
            deliverSettings(.failure(error), to: completion)
        }
    }

    func terminate() {
        finish(with: ExtensionProcessError.notRunning, terminate: true)
    }

    /// Observes the one terminal outcome of this supervised process.
    ///
    /// Registering after a very short-lived child has already exited is safe: the stored
    /// outcome is delivered immediately on the main queue. The observer is intentionally
    /// one-shot so a manager cannot accidentally turn repeated pipe failures into repeated
    /// state transitions.
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

    private func beginReading(maximumLine: Int) {
        readQueue.async { [weak self] in
            self?.readProtocolLines(maximum: maximumLine)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.stderrCapture.drain(self.stderr.fileHandleForReading)
        }
    }

    private func readProtocolLines(maximum: Int) {
        let handle = stdout.fileHandleForReading
        var buffer = Data()

        while true {
            // `readData(ofLength:)` may wait for the requested byte count on a pipe. A live
            // extension deliberately keeps stdout open, so consume whatever is currently
            // available instead.
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                finish(with: ExtensionProcessError.outputClosed, terminate: true)
                return
            }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard line.count <= maximum else {
                    finish(
                        with: ExtensionProcessError.outputLineTooLarge(maximum: maximum),
                        terminate: true
                    )
                    return
                }
                handleProtocolLine(
                    line.last == 0x0D ? line.dropLast() : line[...]
                )
                if lockedIsStopped { return }
            }

            guard buffer.count <= maximum else {
                finish(
                    with: ExtensionProcessError.outputLineTooLarge(maximum: maximum),
                    terminate: true
                )
                return
            }
        }
    }

    private func handleProtocolLine(_ bytes: Data.SubSequence) {
        let data = Data(bytes)

        if !hasCompletedStartup {
            do {
                let registration = try JSONDecoder().decode(
                    ExtensionRegistration.self,
                    from: data
                )
                try registration.validate(for: bundle.manifest)
                completeStartup(.success(registration))
            } catch {
                let detail = (error as? ExtensionValidationError)?.description
                    ?? error.localizedDescription
                finish(
                    with: ExtensionProcessError.invalidMessage(detail),
                    terminate: true
                )
            }
            return
        }

        do {
            let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
            if hasPendingNavigator(requestID: envelope.requestID) {
                try handleNavigatorResponse(data)
                return
            }
            if hasPendingAttachmentPreview(requestID: envelope.requestID) {
                try handleAttachmentPreviewResponse(data)
                return
            }
            if hasPendingCommand(requestID: envelope.requestID) {
                try handleCommandResponse(data)
                return
            }
            if hasPendingTool(requestID: envelope.requestID) {
                try handleToolResponse(data)
                return
            }
            if hasPendingSettings(requestID: envelope.requestID) {
                try handleSettingsResponse(data)
                return
            }
            if hasPendingService(requestID: envelope.requestID) {
                try handleServiceResponse(data)
                return
            }

            let response = try JSONDecoder().decode(
                ExtensionActionResponse.self,
                from: data
            )
            try response.validate()

            guard let action = takePendingAction(requestID: response.requestID) else {
                finish(
                    with: ExtensionProcessError.responseForUnknownRequest(response.requestID),
                    terminate: true
                )
                return
            }

            if let panel = response.panel {
                guard let panelID = action.panelID else {
                    deliver(
                        .failure(ExtensionProcessError.invalidMessage(
                            "a component action cannot return a panel"
                        )),
                        to: action.completion
                    )
                    return
                }
                guard panel.id == panelID else {
                    let error = ExtensionProcessError.responsePanelMismatch(
                        expected: panelID,
                        actual: panel.id
                    )
                    deliver(.failure(error), to: action.completion)
                    return
                }
                do {
                    try ExtensionRegistration(panels: [panel]).validate(for: bundle.manifest)
                } catch {
                    let detail = (error as? ExtensionValidationError)?.description
                        ?? error.localizedDescription
                    deliver(
                        .failure(ExtensionProcessError.invalidMessage(detail)),
                        to: action.completion
                    )
                    return
                }
            }

            deliver(.success(response), to: action.completion)
        } catch {
            let detail = (error as? ExtensionValidationError)?.description
                ?? error.localizedDescription
            finish(
                with: ExtensionProcessError.invalidMessage(detail),
                terminate: true
            )
        }
    }

    private func timeOut(requestID: String) {
        guard let action = takePendingAction(requestID: requestID) else { return }
        deliver(
            .failure(ExtensionProcessError.actionTimedOut(action.actionID)),
            to: action.completion
        )
    }

    private func takePendingAction(requestID: String) -> PendingAction? {
        lock.lock()
        let action = pendingActions.removeValue(forKey: requestID)
        lock.unlock()
        action?.timeoutItem.cancel()
        return action
    }

    /// One candidate's answer to a preview offer.
    ///
    /// A **decline is not a failure**: an extension that previews Lottie declines every PDF it is
    /// offered, and the shell simply moves to the next candidate. What is refused here is an
    /// answer about a different attachment, or a body outside the contract's vocabulary — either
    /// would let the ordering that decides the winner be decided by the candidate instead.
    private func handleAttachmentPreviewResponse(_ data: Data) throws {
        let response = try JSONDecoder().decode(
            ExtensionAttachmentPreviewResponse.self,
            from: data
        )
        guard let pending = takePendingAttachmentPreview(requestID: response.requestID) else {
            finish(
                with: ExtensionProcessError.responseForUnknownRequest(response.requestID),
                terminate: true
            )
            return
        }
        do {
            try response.validate()
        } catch {
            let detail = (error as? ExtensionValidationError)?.description
                ?? error.localizedDescription
            deliverAttachmentPreview(
                .failure(ExtensionProcessError.invalidMessage(detail)),
                to: pending.completion
            )
            return
        }
        guard response.attachmentID == pending.attachmentID else {
            deliverAttachmentPreview(
                .failure(ExtensionProcessError.invalidMessage(
                    "the preview answered for a different attachment"
                )),
                to: pending.completion
            )
            return
        }
        deliverAttachmentPreview(.success(response), to: pending.completion)
    }

    private func timeOutAttachmentPreview(requestID: String) {
        guard let pending = takePendingAttachmentPreview(requestID: requestID) else { return }
        deliverAttachmentPreview(
            .failure(ExtensionProcessError.actionTimedOut(pending.attachmentID)),
            to: pending.completion
        )
    }

    private func takePendingAttachmentPreview(
        requestID: String
    ) -> PendingAttachmentPreview? {
        lock.lock()
        let pending = pendingAttachmentPreviews.removeValue(forKey: requestID)
        lock.unlock()
        pending?.timeoutItem.cancel()
        return pending
    }

    private func hasPendingAttachmentPreview(requestID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingAttachmentPreviews[requestID] != nil
    }

    private func deliverAttachmentPreview(
        _ result: Result<ExtensionAttachmentPreviewResponse, Error>,
        to completion: @escaping AttachmentPreviewCompletion
    ) {
        Task { @MainActor in
            completion(result)
        }
    }

    private func handleNavigatorResponse(_ data: Data) throws {
        let response = try JSONDecoder().decode(
            ExtensionWorkspaceNavigatorActionResponse.self,
            from: data
        )
        try response.validate()
        guard let pending = takePendingNavigator(requestID: response.requestID) else {
            finish(
                with: ExtensionProcessError.responseForUnknownRequest(response.requestID),
                terminate: true
            )
            return
        }
        guard response.navigatorID == pending.navigatorID else {
            deliverNavigator(
                .failure(ExtensionProcessError.responseNavigatorMismatch(
                    expected: pending.navigatorID,
                    actual: response.navigatorID
                )),
                to: pending.completion
            )
            return
        }
        if let navigator = response.navigator {
            guard navigator.id == pending.navigatorID else {
                deliverNavigator(
                    .failure(ExtensionProcessError.responseNavigatorMismatch(
                        expected: pending.navigatorID,
                        actual: navigator.id
                    )),
                    to: pending.completion
                )
                return
            }
            guard let original = acceptedNavigator(id: pending.navigatorID) else {
                deliverNavigator(
                    .failure(ExtensionProcessError.invalidMessage(
                        "navigator '\(pending.navigatorID)' was not registered by this process"
                    )),
                    to: pending.completion
                )
                return
            }
            do {
                try ExtensionRegistration(
                    workspaceNavigators: [navigator]
                ).validateWorkspaceNavigatorReplacement(
                    for: bundle.manifest,
                    replacing: original
                )
            } catch {
                let detail = (error as? ExtensionValidationError)?.description
                    ?? error.localizedDescription
                deliverNavigator(
                    .failure(ExtensionProcessError.invalidMessage(detail)),
                    to: pending.completion
                )
                return
            }
        }
        deliverNavigator(.success(response), to: pending.completion)
    }

    private func timeOutNavigator(requestID: String) {
        guard let pending = takePendingNavigator(requestID: requestID) else { return }
        deliverNavigator(
            .failure(ExtensionProcessError.actionTimedOut(pending.actionID)),
            to: pending.completion
        )
    }

    private func takePendingNavigator(requestID: String) -> PendingNavigator? {
        lock.lock()
        let pending = pendingNavigators.removeValue(forKey: requestID)
        lock.unlock()
        pending?.timeoutItem.cancel()
        return pending
    }

    private func hasPendingNavigator(requestID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingNavigators[requestID] != nil
    }

    private func handleCommandResponse(_ data: Data) throws {
        let response = try JSONDecoder().decode(ExtensionCommandResponse.self, from: data)
        try response.validate()
        guard let command = takePendingCommand(requestID: response.requestID) else {
            finish(
                with: ExtensionProcessError.responseForUnknownRequest(response.requestID),
                terminate: true
            )
            return
        }
        guard response.commandID == command.commandID else {
            deliverCommand(
                .failure(ExtensionProcessError.responseCommandMismatch(
                    expected: command.commandID,
                    actual: response.commandID
                )),
                to: command.completion
            )
            return
        }
        deliverCommand(.success(response), to: command.completion)
    }

    private func timeOutCommand(requestID: String) {
        guard let command = takePendingCommand(requestID: requestID) else { return }
        deliverCommand(
            .failure(ExtensionProcessError.commandTimedOut(command.commandID)),
            to: command.completion
        )
    }

    private func takePendingCommand(requestID: String) -> PendingCommand? {
        lock.lock()
        let command = pendingCommands.removeValue(forKey: requestID)
        lock.unlock()
        command?.timeoutItem.cancel()
        return command
    }

    private func hasPendingCommand(requestID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingCommands[requestID] != nil
    }

    private func handleToolResponse(_ data: Data) throws {
        let response = try JSONDecoder().decode(ExtensionMCPToolResponse.self, from: data)
        try response.validate()
        guard let tool = takePendingTool(requestID: response.requestID) else {
            finish(
                with: ExtensionProcessError.responseForUnknownRequest(response.requestID),
                terminate: true
            )
            return
        }
        deliverTool(.success(response), to: tool.completion)
    }

    private func handleSettingsResponse(_ data: Data) throws {
        let response = try JSONDecoder().decode(
            ExtensionSettingsUpdateResponse.self,
            from: data
        )
        try response.validate()
        guard let pending = takePendingSettings(requestID: response.requestID) else {
            finish(
                with: ExtensionProcessError.responseForUnknownRequest(response.requestID),
                terminate: true
            )
            return
        }
        let actual = response.settingIDs.sorted()
        guard actual == pending.settingIDs else {
            deliverSettings(
                .failure(ExtensionProcessError.responseSettingsMismatch(
                    expected: pending.settingIDs,
                    actual: actual
                )),
                to: pending.completion
            )
            return
        }
        deliverSettings(.success(response), to: pending.completion)
    }

    private func timeOutSettings(requestID: String) {
        guard let pending = takePendingSettings(requestID: requestID) else { return }
        deliverSettings(
            .failure(ExtensionProcessError.settingsTimedOut),
            to: pending.completion
        )
    }

    private func takePendingSettings(requestID: String) -> PendingSettings? {
        lock.lock()
        let pending = pendingSettings.removeValue(forKey: requestID)
        lock.unlock()
        pending?.timeoutItem.cancel()
        return pending
    }

    private func hasPendingSettings(requestID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingSettings[requestID] != nil
    }

    private func handleServiceResponse(_ data: Data) throws {
        let response = try JSONDecoder().decode(ExtensionServiceResponse.self, from: data)
        try response.validate()
        guard let pending = takePendingService(requestID: response.requestID) else {
            finish(
                with: ExtensionProcessError.responseForUnknownRequest(response.requestID),
                terminate: true
            )
            return
        }
        guard response.serviceID == pending.serviceID,
              response.serviceVersion == pending.serviceVersion else {
            deliverService(
                .failure(ExtensionProcessError.responseServiceMismatch(
                    expectedID: pending.serviceID,
                    expectedVersion: pending.serviceVersion,
                    actualID: response.serviceID,
                    actualVersion: response.serviceVersion
                )),
                to: pending.completion
            )
            return
        }
        deliverService(.success(response), to: pending.completion)
    }

    private func timeOutService(requestID: String) {
        guard let pending = takePendingService(requestID: requestID) else { return }
        deliverService(
            .failure(ExtensionProcessError.serviceTimedOut(pending.serviceID)),
            to: pending.completion
        )
    }

    private func takePendingService(requestID: String) -> PendingService? {
        lock.lock()
        let pending = pendingServices.removeValue(forKey: requestID)
        lock.unlock()
        pending?.timeoutItem.cancel()
        return pending
    }

    private func hasPendingService(requestID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingServices[requestID] != nil
    }

    private func timeOutTool(requestID: String) {
        guard let tool = takePendingTool(requestID: requestID) else { return }
        deliverTool(
            .failure(ExtensionProcessError.toolTimedOut(tool.toolID)),
            to: tool.completion
        )
    }

    private func takePendingTool(requestID: String) -> PendingTool? {
        lock.lock()
        let tool = pendingTools.removeValue(forKey: requestID)
        lock.unlock()
        tool?.timeoutItem.cancel()
        return tool
    }

    private func hasPendingTool(requestID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingTools[requestID] != nil
    }

    /// The caller holds `lock`; keeping this non-locking avoids recursive `NSLock` acquisition.
    private func requestIDIsAvailableLocked(_ requestID: String) -> Bool {
        pendingActions[requestID] == nil
            && pendingNavigators[requestID] == nil
            && pendingCommands[requestID] == nil
            && pendingSettings[requestID] == nil
            && pendingServices[requestID] == nil
            && pendingTools[requestID] == nil
            && pendingAttachmentPreviews[requestID] == nil
    }

    private func completeStartup(_ result: Result<ExtensionRegistration, Error>) {
        lock.lock()
        guard startupResult == nil, !isStopped else {
            lock.unlock()
            return
        }
        if case .success(let registration) = result {
            acceptedRegistration = registration
        }
        startupResult = result
        lock.unlock()
        startupSemaphore.signal()
    }

    private func processDidExit(status: Int32) {
        finish(
            with: ExtensionProcessError.processEnded(
                status: status,
                message: stderrCapture.string
            ),
            terminate: false
        )
    }

    private func finish(with error: Error, terminate: Bool) {
        let actions: [PendingAction]
        let navigators: [PendingNavigator]
        let commands: [PendingCommand]
        let settings: [PendingSettings]
        let services: [PendingService]
        let tools: [PendingTool]
        let previews: [PendingAttachmentPreview]
        let observer: (@MainActor @Sendable (Error) -> Void)?
        var shouldSignalStartup = false

        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        if startupResult == nil {
            startupResult = .failure(error)
            shouldSignalStartup = true
        }
        actions = Array(pendingActions.values)
        pendingActions.removeAll()
        navigators = Array(pendingNavigators.values)
        pendingNavigators.removeAll()
        commands = Array(pendingCommands.values)
        pendingCommands.removeAll()
        settings = Array(pendingSettings.values)
        pendingSettings.removeAll()
        services = Array(pendingServices.values)
        pendingServices.removeAll()
        tools = Array(pendingTools.values)
        pendingTools.removeAll()
        previews = Array(pendingAttachmentPreviews.values)
        pendingAttachmentPreviews.removeAll()
        terminalError = error
        observer = terminationObserver
        terminationObserver = nil
        lock.unlock()

        actions.forEach {
            $0.timeoutItem.cancel()
            deliver(.failure(error), to: $0.completion)
        }
        navigators.forEach {
            $0.timeoutItem.cancel()
            deliverNavigator(.failure(error), to: $0.completion)
        }
        commands.forEach {
            $0.timeoutItem.cancel()
            deliverCommand(.failure(error), to: $0.completion)
        }
        settings.forEach {
            $0.timeoutItem.cancel()
            deliverSettings(.failure(error), to: $0.completion)
        }
        services.forEach {
            $0.timeoutItem.cancel()
            deliverService(.failure(error), to: $0.completion)
        }
        tools.forEach {
            $0.timeoutItem.cancel()
            deliverTool(.failure(error), to: $0.completion)
        }
        previews.forEach {
            $0.timeoutItem.cancel()
            deliverAttachmentPreview(.failure(error), to: $0.completion)
        }
        if shouldSignalStartup {
            startupSemaphore.signal()
        }
        if terminate {
            stopProcess()
        }
        if let observer {
            Task { @MainActor in
                observer(error)
            }
        }
    }

    private func stopProcess() {
        try? stdin.fileHandleForWriting.close()
        guard child.isRunning else { return }
        child.terminate()
        let handle = child
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            handle.kill()
        }
    }

    private func deliver(
        _ result: Result<ExtensionActionResponse, Error>,
        to completion: @escaping ActionCompletion
    ) {
        Task { @MainActor in
            completion(result)
        }
    }

    private func deliverNavigator(
        _ result: Result<ExtensionWorkspaceNavigatorActionResponse, Error>,
        to completion: @escaping NavigatorCompletion
    ) {
        Task { @MainActor in
            completion(result)
        }
    }

    private func deliverTool(
        _ result: Result<ExtensionMCPToolResponse, Error>,
        to completion: @escaping ToolCompletion
    ) {
        Task { @MainActor in
            completion(result)
        }
    }

    private func deliverCommand(
        _ result: Result<ExtensionCommandResponse, Error>,
        to completion: @escaping CommandCompletion
    ) {
        Task { @MainActor in
            completion(result)
        }
    }

    private func deliverSettings(
        _ result: Result<ExtensionSettingsUpdateResponse, Error>,
        to completion: @escaping SettingsCompletion
    ) {
        Task { @MainActor in
            completion(result)
        }
    }

    private func deliverService(
        _ result: Result<ExtensionServiceResponse, Error>,
        to completion: @escaping ServiceCompletion
    ) {
        Task { @MainActor in
            completion(result)
        }
    }

    private var lockedStartupResult: Result<ExtensionRegistration, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return startupResult
    }

    private func acceptedNavigator(id: String) -> ExtensionWorkspaceNavigator? {
        lock.lock()
        defer { lock.unlock() }
        return acceptedRegistration?.workspaceNavigators.first { $0.id == id }
    }

    private var hasCompletedStartup: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .success = startupResult {
            return true
        }
        return false
    }

    private var lockedIsStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    private final class DiagnosticCapture: @unchecked Sendable {
        private let maximum: Int
        private let lock = NSLock()
        private var data = Data()

        init(maximum: Int) {
            self.maximum = maximum
        }

        func drain(_ handle: FileHandle) {
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                lock.lock()
                let remaining = max(0, maximum - data.count)
                data.append(chunk.prefix(remaining))
                lock.unlock()
            }
        }

        var string: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
