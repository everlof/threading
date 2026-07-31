import Foundation

/// The per-turn choices app-server accepts without restarting its persistent process.
struct CodexTurnConfiguration {
    var model: String?
    var effort: String?
    var serviceTier: String?

    init(
        model: String? = nil,
        effort: String? = nil,
        serviceTier: String? = nil
    ) {
        self.model = model
        self.effort = effort
        self.serviceTier = serviceTier
    }

    static let inherited = CodexTurnConfiguration()
}

/// Runs Codex's persistent app-server and adapts its JSON-RPC notifications to a native chat.
///
/// The previous `codex exec --json` transport spawned one process per turn. That stream flattened
/// delegated work into the parent and could not observe child threads. App-server keeps one
/// process subscribed to the thread graph, which gives Threading both a reusable conversation
/// channel and structured subagent lifecycle events.
@MainActor
final class CodexStreamSession: ConversationStreamSession, SubagentReportingConversation {

    // MARK: - Properties

    let sessionID: SessionID

    var onEvent: ((StreamEvent) -> Void)?
    var onSubagentEvent: ((SubagentEvent) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onSendAvailabilityChange: (() -> Void)?

    private(set) var isRunning = false
    var canSend: Bool {
        isRunning && inputPipe != nil && !isTurnInFlight && pendingPrompt == nil
    }

    var rootProcessIdentifier: pid_t? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    private let plan: () -> AgentLaunchPlan
    private let configurationProvider: () -> CodexTurnConfiguration

    private var process: Process?
    private var inputPipe: Pipe?
    private var launchResumeState: ResumeState = .unavailable

    private var buffer = Data()
    private var errorBuffer = Data()
    private var parseDiagnostics = StreamParseDiagnostics()
    var malformedLineCount: Int { parseDiagnostics.malformedLineCount }

    private var requestSequence: Int64 = 0
    private var pendingRequests: [CodexAppServerRequestID: RequestPurpose] = [:]
    private var didInitialize = false
    private var didReportThread = false
    private var rootThreadID: String?
    private var pendingPrompt: String?
    private var isTurnInFlight = false
    private var isTerminating = false
    private var receivedTurnFinished = false

    private var turnStartedAt: TimeInterval?
    private var turnEffort: String?
    private var outputTokensByTurn: [String: Int] = [:]

    /// The most recent request's size and the model's window, from `thread/tokenUsage/updated`
    /// — what the context meter reads at each turn boundary. Session-scoped rather than
    /// per-turn: the newest reading is the truth about the window whenever it arrives.
    private var lastContextTokens: Int?
    private var lastContextWindow: Int?

    // MARK: - Initialization

    init(
        sessionID: SessionID,
        configurationProvider: @escaping () -> CodexTurnConfiguration = { .inherited },
        plan: @escaping () -> AgentLaunchPlan
    ) {
        self.sessionID = sessionID
        self.configurationProvider = configurationProvider
        self.plan = plan
    }

    /// Kept as a source-compatible convenience for focused lifecycle tests and older callers.
    convenience init(
        sessionID: SessionID,
        effortProvider: @escaping () -> String?,
        plan: @escaping () -> AgentLaunchPlan
    ) {
        self.init(
            sessionID: sessionID,
            configurationProvider: {
                CodexTurnConfiguration(effort: effortProvider())
            },
            plan: plan
        )
    }

    // MARK: - Public Methods

    func start() {
        guard !isRunning else { return }

        let launchPlan = plan()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: launchPlan.executable)
        process.arguments = launchPlan.arguments
        process.environment = AgentEnvironment.launchEnvironment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe

        resetForLaunch(resumeState: launchPlan.resumeState)

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.received(chunk)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.receivedError(chunk)
            }
        }

        process.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleTermination(status: status)
            }
        }

        do {
            try process.run()
        } catch {
            ThreadingLogger.agent.error(
                "Codex app-server failed to start: \(error.localizedDescription)"
            )
            output.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                self?.onExit?(-1)
            }
            return
        }

        self.process = process
        self.inputPipe = input
        isRunning = true
        onSendAvailabilityChange?()
        sendInitialize()
    }

    /// Accepts a turn as soon as the process has launched. If app-server is still completing
    /// its initialize/thread handshake, the prompt waits in memory and is sent the moment the
    /// root thread is ready. This preserves the native composer's first-message path.
    @discardableResult
    func send(_ text: String) -> Bool {
        guard canSend else { return false }

        pendingPrompt = text
        isTurnInFlight = true
        receivedTurnFinished = false
        turnStartedAt = ProcessInfo.processInfo.systemUptime
        turnEffort = configurationProvider().effort
        onSendAvailabilityChange?()
        sendPendingTurnIfReady()
        return true
    }

    /// Closing stdin asks the persistent server to shut down after its current work.
    func finish() {
        guard inputPipe != nil else { return }
        try? inputPipe?.fileHandleForWriting.close()
        inputPipe = nil
        onSendAvailabilityChange?()
    }

    func terminate() {
        guard isRunning else { return }

        isTerminating = true
        isRunning = false
        finish()

        if let process {
            process.terminate()
        } else {
            onExit?(0)
        }
    }

    // MARK: - Launch Handshake

    private func resetForLaunch(resumeState: ResumeState) {
        launchResumeState = resumeState
        buffer.removeAll(keepingCapacity: true)
        errorBuffer.removeAll(keepingCapacity: true)
        parseDiagnostics.reset()
        requestSequence = 0
        pendingRequests.removeAll()
        didInitialize = false
        didReportThread = false
        rootThreadID = nil
        pendingPrompt = nil
        isTurnInFlight = false
        isTerminating = false
        receivedTurnFinished = false
        turnStartedAt = nil
        turnEffort = nil
        outputTokensByTurn.removeAll()
    }

    private func sendInitialize() {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        let parameters: [String: Any] = [
            "clientInfo": [
                "name": "threading",
                "title": "Threading",
                "version": version
            ]
        ]
        _ = sendRequest(
            method: "initialize",
            parameters: parameters,
            purpose: .initialize
        )
    }

    private func openThread() {
        let method: String
        let parameters: [String: Any]

        if let transcriptID = launchResumeState.transcriptID {
            method = "thread/resume"
            parameters = ["threadId": transcriptID.rawValue]
        } else {
            method = "thread/start"
            parameters = [:]
        }

        _ = sendRequest(
            method: method,
            parameters: parameters,
            purpose: .openThread
        )
    }

    private func sendPendingTurnIfReady() {
        guard didInitialize,
              let threadID = rootThreadID,
              let prompt = pendingPrompt else { return }

        let configuration = configurationProvider()
        var parameters: [String: Any] = [
            "threadId": threadID,
            "input": [["type": "text", "text": prompt]]
        ]
        if let model = configuration.model { parameters["model"] = model }
        if let effort = configuration.effort { parameters["effort"] = effort }
        if let serviceTier = configuration.serviceTier {
            parameters["serviceTier"] = serviceTier
        }

        guard sendRequest(
            method: "turn/start",
            parameters: parameters,
            purpose: .startTurn
        ) != nil else {
            finishTurnWithTransportError("Threading could not send the Codex turn.")
            return
        }
        pendingPrompt = nil
    }

    private func reportRootThread(_ thread: [String: Any]) {
        guard let threadID = thread["id"] as? String else { return }

        rootThreadID = threadID
        if !didReportThread {
            didReportThread = true
            onEvent?(.initialised(
                sessionID: TranscriptID(threadID),
                model: thread["model"] as? String
            ))
        }
        sendPendingTurnIfReady()
        onSendAvailabilityChange?()
    }

    // MARK: - JSON-RPC

    @discardableResult
    private func sendRequest(
        method: String,
        parameters: [String: Any],
        purpose: RequestPurpose
    ) -> CodexAppServerRequestID? {
        requestSequence += 1
        let id = CodexAppServerRequestID.integer(requestSequence)
        let object: [String: Any] = [
            "id": id.foundationValue,
            "method": method,
            "params": parameters
        ]
        guard writeLine(object) else { return nil }
        pendingRequests[id] = purpose
        return id
    }

    private func sendNotification(method: String, parameters: [String: Any] = [:]) {
        _ = writeLine(["method": method, "params": parameters])
    }

    private func sendResponse(
        id: CodexAppServerRequestID,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) {
        var object: [String: Any] = ["id": id.foundationValue]
        if let error {
            object["error"] = error
        } else {
            object["result"] = result ?? [:]
        }
        _ = writeLine(object)
    }

    private func writeLine(_ object: [String: Any]) -> Bool {
        guard let inputPipe,
              JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object)
        else { return false }
        data.append(0x0A)

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
            return true
        } catch {
            ThreadingLogger.agent.error(
                "Codex app-server write failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    // MARK: - Event Stream

    private func received(_ chunk: Data) {
        buffer.append(chunk)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])

            guard let line = String(data: lineData, encoding: .utf8),
                  let envelope = CodexAppServerEnvelope.parse(line) else {
                parseDiagnostics.recordMalformedLine(provider: "Codex app-server")
                continue
            }
            route(envelope)
        }
    }

    private func route(_ envelope: CodexAppServerEnvelope) {
        switch envelope {
        case .response(let id, let result, let error):
            handleResponse(id: id, result: result, error: error)
        case .request(let id, let method, let parameters):
            handleServerRequest(id: id, method: method, parameters: parameters)
        case .notification(let method, let parameters):
            handleNotification(method: method, parameters: parameters)
        }
    }

    private func handleResponse(
        id: CodexAppServerRequestID,
        result: [String: Any]?,
        error: String?
    ) {
        guard let purpose = pendingRequests.removeValue(forKey: id) else { return }

        if let error {
            switch purpose {
            case .initialize, .openThread:
                finishTurnWithTransportError(error)
                terminate()
            case .startTurn:
                finishTurnWithTransportError(error)
            }
            return
        }

        switch purpose {
        case .initialize:
            didInitialize = true
            sendNotification(method: "initialized")
            openThread()

        case .openThread:
            if let thread = result?["thread"] as? [String: Any] {
                reportRootThread(thread)
            } else {
                finishTurnWithTransportError("Codex opened no conversation thread.")
            }

        case .startTurn:
            break
        }
    }

    private func handleNotification(method: String, parameters: [String: Any]) {
        if method == "thread/started",
           let thread = parameters["thread"] as? [String: Any],
           (thread["parentThreadId"] == nil || thread["parentThreadId"] is NSNull),
           rootThreadID == nil {
            reportRootThread(thread)
        }

        if method == "thread/tokenUsage/updated",
           let turnID = parameters["turnId"] as? String,
           let usage = parameters["tokenUsage"] as? [String: Any] {
            if let last = usage["last"] as? [String: Any] {
                if let output = (last["outputTokens"] as? NSNumber)?.intValue {
                    outputTokensByTurn[turnID] = output
                }
                // `last` is the most recent request, which is what "how full is the window"
                // means — the session's running total exceeds the window on any long
                // conversation. Input already includes what was served from cache here,
                // unlike Claude's accounting.
                if let total = (last["totalTokens"] as? NSNumber)?.intValue {
                    lastContextTokens = total
                } else if let input = (last["inputTokens"] as? NSNumber)?.intValue,
                          let output = (last["outputTokens"] as? NSNumber)?.intValue {
                    lastContextTokens = input + output
                }
            }
            if let window = ((usage["modelContextWindow"] ?? usage["contextWindow"])
                as? NSNumber)?.intValue {
                lastContextWindow = window
            }
        }

        for event in CodexSubagentEvent.events(
            method: method,
            parameters: parameters,
            rootThreadID: rootThreadID
        ) {
            onSubagentEvent?(event)
        }

        guard CodexAppServerEvent.threadID(
            method: method,
            parameters: parameters
        ) == rootThreadID else { return }

        // The parent message is echoed locally when it is accepted by `send`; app-server also
        // reports it as an item, and rendering both would duplicate every prompt.
        if (method == "item/started" || method == "item/completed"),
           let item = parameters["item"] as? [String: Any],
           item["type"] as? String == "userMessage" {
            return
        }

        let turnID = parameters["turnId"] as? String
            ?? (parameters["turn"] as? [String: Any])?["id"] as? String
        let events = CodexAppServerEvent.streamEvents(
            method: method,
            parameters: parameters,
            outputTokens: turnID.flatMap { outputTokensByTurn[$0] },
            effort: turnEffort
        )

        for event in events {
            let completed = completingTurnMetrics(in: event)
            if case .turnFinished = completed {
                receivedTurnFinished = true
                isTurnInFlight = false
                pendingPrompt = nil
                if let turnID { outputTokensByTurn[turnID] = nil }
                onSendAvailabilityChange?()
            }
            onEvent?(completed)
        }
    }

    // MARK: - Approval Requests

    private func handleServerRequest(
        id: CodexAppServerRequestID,
        method: String,
        parameters: [String: Any]
    ) {
        let request: PermissionRequest

        switch method {
        case "item/commandExecution/requestApproval":
            let input: [String: JSONValue] = [
                "command": .string(parameters["command"] as? String ?? ""),
                "cwd": .string(parameters["cwd"] as? String ?? ""),
                "reason": .string(parameters["reason"] as? String ?? "")
            ]
            request = PermissionRequest(
                sessionID: sessionID,
                tool: .bash,
                input: input
            )

        case "item/fileChange/requestApproval":
            let input: [String: JSONValue] = [
                "file_path": .string(parameters["grantRoot"] as? String ?? ""),
                "reason": .string(parameters["reason"] as? String ?? "")
            ]
            request = PermissionRequest(
                sessionID: sessionID,
                tool: .edit,
                input: input
            )

        case "item/permissions/requestApproval":
            guard let input = JSONValue.object(from: parameters) else {
                sendResponse(
                    id: id,
                    error: ["code": -32602, "message": "Permission arguments were not valid JSON."]
                )
                return
            }
            request = PermissionRequest(
                sessionID: sessionID,
                tool: .unknown("permissions"),
                input: input
            )

        default:
            sendResponse(
                id: id,
                error: ["code": -32601, "message": "Threading does not handle \(method)."]
            )
            return
        }

        Task { @MainActor [weak self] in
            PermissionBroker.decide(request) { decision in
                guard let self else { return }
                self.answerApproval(
                    id: id,
                    method: method,
                    parameters: parameters,
                    decision: decision
                )
            }
        }
    }

    private func answerApproval(
        id: CodexAppServerRequestID,
        method: String,
        parameters: [String: Any],
        decision: PermissionDecision
    ) {
        let allowed: Bool
        switch decision {
        case .allow: allowed = true
        case .deny: allowed = false
        }

        if method == "item/permissions/requestApproval" {
            if allowed {
                sendResponse(
                    id: id,
                    result: [
                        "permissions": parameters["permissions"] as? [String: Any] ?? [:],
                        "scope": "turn"
                    ]
                )
            } else {
                sendResponse(
                    id: id,
                    error: ["code": -32000, "message": "Permission declined by the user."]
                )
            }
            return
        }

        sendResponse(id: id, result: ["decision": allowed ? "accept" : "decline"])
    }

    // MARK: - Completion

    private func receivedError(_ chunk: Data) {
        guard errorBuffer.count < CodexStreamDefaults.maximumErrorBytes else { return }
        let remaining = CodexStreamDefaults.maximumErrorBytes - errorBuffer.count
        errorBuffer.append(chunk.prefix(remaining))
    }

    private func handleTermination(status: Int32) {
        guard process != nil else { return }

        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        inputPipe = nil

        let wasTerminating = isTerminating
        isTerminating = false
        isRunning = false

        if !wasTerminating, isTurnInFlight, !receivedTurnFinished {
            let diagnostics = String(decoding: errorBuffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            finishTurnWithTransportError(
                diagnostics.isEmpty
                    ? "Codex app-server exited with status \(status)."
                    : diagnostics
            )
        }

        onSendAvailabilityChange?()
        onExit?(status)
    }

    private func finishTurnWithTransportError(_ message: String) {
        pendingPrompt = nil
        isTurnInFlight = false
        receivedTurnFinished = true
        onEvent?(completingTurnMetrics(in: .turnFinished(
            text: message,
            isError: true,
            metrics: .empty
        )))
        onSendAvailabilityChange?()
    }

    private func completingTurnMetrics(in event: StreamEvent) -> StreamEvent {
        guard case .turnFinished(let text, let isError, let metrics) = event else {
            return event
        }

        let duration = turnStartedAt.map {
            max(0, ProcessInfo.processInfo.systemUptime - $0)
        }
        turnStartedAt = nil
        let effort = turnEffort
        turnEffort = nil

        return .turnFinished(
            text: text,
            isError: isError,
            metrics: metrics.filling(
                duration: duration,
                effort: effort,
                contextTokens: lastContextTokens,
                contextWindow: lastContextWindow
            )
        )
    }
}

private enum RequestPurpose {
    case initialize
    case openThread
    case startTurn
}

enum CodexStreamDefaults {
    /// Stderr is diagnostic fallback only. Capping it prevents a failed server from becoming an
    /// unbounded in-memory log while stdout remains the authoritative protocol stream.
    static let maximumErrorBytes = 64 * 1024
}
