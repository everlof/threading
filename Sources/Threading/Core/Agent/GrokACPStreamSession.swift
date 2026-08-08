import Foundation

/// Runs Grok's supported Agent Client Protocol transport and adapts it to native Chat.
///
/// ACP owns the common conversation contract; this type contains only process lifecycle and the
/// small translation from standard ACP updates into Threading's provider-neutral stream events.
/// xAI-specific metadata is treated as an optional source of model information, never as a
/// requirement for opening or resuming a conversation.
@MainActor
final class GrokACPStreamSession:
    ConversationStreamSession,
    ProviderExecutionReportingConversation,
    ComposerCapabilityProviding,
    InterruptibleConversation,
    SessionTitleReportingConversation
{

    // MARK: - Properties

    let sessionID: SessionID

    var onEvent: ((StreamEvent) -> Void)?
    var onProviderExecution: ((ProviderExecutionEvent) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onSendAvailabilityChange: (() -> Void)?
    var onComposerCapabilitiesChange: (() -> Void)?
    var onSessionTitleChange: ((String) -> Void)?
    private(set) var composerCapabilities: [ComposerCapability] = []

    private(set) var isRunning = false
    var canSend: Bool {
        isRunning && input != nil && !isTurnInFlight && pendingPrompt == nil
    }

    var rootProcessIdentifier: pid_t? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    private let workingDirectory: String
    private let plan: () -> AgentLaunchPlan

    private var process: AgentChildProcess?
    private var input: FileHandle?
    private var buffer = Data()
    private var errorBuffer = Data()
    private var parseDiagnostics = StreamParseDiagnostics()

    private var requestSequence: Int64 = 0
    private var pendingRequests: [JSONRPCRequestID: GrokACPRequestPurpose] = [:]
    private var launchResumeState: ResumeState = .unavailable
    private var activeSessionID: String?
    private var pendingPrompt: String?
    private var isTurnInFlight = false
    private var isLoadingHistory = false
    private var isTerminating = false
    private var receivedTurnFinished = false

    private var turnStartedAt: TimeInterval?
    private var lastContextTokens: Int?
    private var lastContextWindow: Int?

    private var userMessageID: String?
    private var pendingUserText = ""
    private var assistantMessageID: String?
    private var pendingAssistantBlocks: [GrokACPPendingBlock] = []
    private var toolCalls: [String: GrokACPToolState] = [:]

    // MARK: - Initialization

    init(
        sessionID: SessionID,
        workingDirectory: String,
        plan: @escaping () -> AgentLaunchPlan
    ) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.plan = plan
    }

    // MARK: - Public Methods

    func start() {
        guard !isRunning else { return }

        let launchPlan = plan()

        resetForLaunch(resumeState: launchPlan.resumeState)

        let process: AgentChildProcess
        do {
            process = try AgentChildProcess.launch(
                executable: launchPlan.executable,
                arguments: launchPlan.arguments,
                environment: AgentEnvironment.launchEnvironment(),
                sessionID: sessionID
            ) { [weak self] status in
                Task { @MainActor [weak self] in self?.handleTermination(status: status) }
            }
        } catch {
            ThreadingLogger.agent.error(
                "Grok ACP failed to start: \(error.localizedDescription)"
            )
            onExit?(AgentChildProcessDefaults.spawnFailureStatus)
            return
        }

        process.standardOutput.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in self?.received(chunk) }
        }
        // Kept apart from stdout: a diagnostic line landing inside the JSON-RPC stream would
        // corrupt the message it interrupted.
        process.standardError.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in self?.receivedError(chunk) }
        }

        self.process = process
        input = process.standardInput
        isRunning = true
        onSendAvailabilityChange?()
        sendInitialize()
    }

    /// Prompts may arrive while ACP is still initializing. One is retained and sent as soon as
    /// `session/new` or `session/load` supplies the provider session id.
    @discardableResult
    func send(_ text: String) -> Bool {
        guard canSend else { return false }

        pendingPrompt = text
        isTurnInFlight = true
        receivedTurnFinished = false
        turnStartedAt = ProcessInfo.processInfo.systemUptime
        onSendAvailabilityChange?()
        sendPendingPromptIfReady()
        return true
    }

    @discardableResult
    func send(_ invocation: ComposerInvocation) -> Bool {
        guard composerCapabilities.contains(where: {
            $0.id == invocation.capability.id && $0.isEnabled
        }) else { return false }
        return send(invocation.sourceText)
    }

    // MARK: - Turn Control

    var canInterrupt: Bool {
        isRunning && input != nil && isTurnInFlight && activeSessionID != nil
    }

    /// ACP has no steering primitive: the specification allows one prompt turn per session at a
    /// time, and names nothing for adding to the one in flight. Saying so is the point — the
    /// composer offers no steer for Grok rather than offering one that quietly queues.
    var steerAvailability: SteerAvailability { .unavailable(.unsupported) }

    /// Stops the turn in flight, leaving the session open.
    ///
    /// `session/cancel` is a **notification**: there is nothing to await, and the protocol is
    /// explicit that the agent answers the still-pending `session/prompt` with
    /// `stopReason: "cancelled"` rather than with an error, precisely so a client can tell a
    /// deliberate stop from a failure. That reply is what settles the turn as `.stopped` — see
    /// `TurnOutcome(acpStopReason:)`.
    ///
    /// The distinction from `terminate()`, which sends the same notification, is that this one
    /// keeps the process: Stop ends the work, not the conversation.
    func interrupt(completion: @escaping @MainActor (InterruptReceipt) -> Void) {
        guard canInterrupt, let activeSessionID else {
            completion(.failed(reason: L10n.string("There is nothing running to stop.")))
            return
        }

        sendNotification(
            method: "session/cancel",
            parameters: ["sessionId": activeSessionID]
        )

        // A notification is acknowledged by definition, and ACP holds nothing queued behind the
        // turn for it to report on.
        completion(.acknowledged)
    }

    func finish() {
        guard input != nil else { return }
        try? input?.close()
        input = nil
        onSendAvailabilityChange?()
    }

    func terminate() {
        guard isRunning else { return }

        isTerminating = true
        isRunning = false
        if isTurnInFlight, let activeSessionID {
            sendNotification(
                method: "session/cancel",
                parameters: ["sessionId": activeSessionID]
            )
        }
        finish()
        process?.terminate()
    }

    // MARK: - Handshake

    private func resetForLaunch(resumeState: ResumeState) {
        launchResumeState = resumeState
        buffer.removeAll(keepingCapacity: true)
        errorBuffer.removeAll(keepingCapacity: true)
        parseDiagnostics.reset()
        requestSequence = 0
        pendingRequests.removeAll()
        activeSessionID = nil
        pendingPrompt = nil
        isTurnInFlight = false
        isLoadingHistory = resumeState.isResumable
        isTerminating = false
        receivedTurnFinished = false
        turnStartedAt = nil
        lastContextTokens = nil
        lastContextWindow = nil
        resetMessageAccumulators()
        toolCalls.removeAll()
        replaceComposerCapabilities([])
    }

    private func sendInitialize() {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        let parameters: [String: Any] = [
            "protocolVersion": GrokACPDefaults.protocolVersion,
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false,
                "session": ["configOptions": ["boolean": [:]]]
            ],
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

    private func openSession() {
        var parameters: [String: Any] = [
            "cwd": workingDirectory,
            "mcpServers": mcpServers()
        ]
        let method: String
        if let transcriptID = launchResumeState.transcriptID {
            method = "session/load"
            parameters["sessionId"] = transcriptID.rawValue
        } else {
            method = "session/new"
        }
        _ = sendRequest(method: method, parameters: parameters, purpose: .openSession)
    }

    private func mcpServers() -> [[String: Any]] {
        guard !MCPToolCatalog.enabledToolNames.isEmpty,
              let url = MCPSessionRegistry.endpointURL(for: sessionID) else { return [] }
        return [[
            "type": "http",
            "name": MCPDefaults.serverName,
            "url": url,
            "headers": []
        ]]
    }

    private func sendPendingPromptIfReady() {
        guard let prompt = pendingPrompt, let activeSessionID else { return }
        guard sendRequest(
            method: "session/prompt",
            parameters: [
                "sessionId": activeSessionID,
                "prompt": [["type": "text", "text": prompt]]
            ],
            purpose: .prompt
        ) != nil else {
            finishTurnWithTransportError("Threading could not send the Grok turn.")
            return
        }
        pendingPrompt = nil
    }

    // MARK: - JSON-RPC

    @discardableResult
    private func sendRequest(
        method: String,
        parameters: [String: Any],
        purpose: GrokACPRequestPurpose
    ) -> JSONRPCRequestID? {
        requestSequence += 1
        let id = JSONRPCRequestID.integer(requestSequence)
        guard writeLine([
            "jsonrpc": "2.0",
            "id": id.foundationValue,
            "method": method,
            "params": parameters
        ]) else { return nil }
        pendingRequests[id] = purpose
        return id
    }

    private func sendNotification(method: String, parameters: [String: Any]) {
        _ = writeLine([
            "jsonrpc": "2.0",
            "method": method,
            "params": parameters
        ])
    }

    private func sendResponse(
        id: JSONRPCRequestID,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.foundationValue
        ]
        if let error {
            object["error"] = error
        } else {
            object["result"] = result ?? [:]
        }
        _ = writeLine(object)
    }

    private func writeLine(_ object: [String: Any]) -> Bool {
        guard let input,
              JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object)
        else { return false }
        data.append(0x0A)

        do {
            try input.write(contentsOf: data)
            return true
        } catch {
            ThreadingLogger.agent.error(
                "Grok ACP write failed: \(error.localizedDescription)"
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
                  let envelope = JSONRPCLineEnvelope.parse(line) else {
                parseDiagnostics.recordMalformedLine(provider: "Grok ACP")
                continue
            }
            route(envelope)
        }
    }

    private func route(_ envelope: JSONRPCLineEnvelope) {
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
        id: JSONRPCRequestID,
        result: [String: Any]?,
        error: String?
    ) {
        guard let purpose = pendingRequests.removeValue(forKey: id) else { return }

        if let error {
            switch purpose {
            case .initialize, .openSession:
                finishTurnWithTransportError(error)
                terminate()
            case .prompt:
                flushPendingMessages()
                finishTurnWithTransportError(error)
            }
            return
        }

        switch purpose {
        case .initialize:
            if let commands = GrokACPAdapter.availableCommands(in: result) {
                replaceComposerCapabilities(GrokACPComposerCatalog.capabilities(from: commands))
            }
            openSession()

        case .openSession:
            flushPendingMessages()
            isLoadingHistory = false
            let providerID = result?["sessionId"] as? String
                ?? launchResumeState.transcriptID?.rawValue
            guard let providerID, !providerID.isEmpty else {
                finishTurnWithTransportError("Grok opened no conversation session.")
                terminate()
                return
            }
            activeSessionID = providerID
            onEvent?(.initialised(
                sessionID: TranscriptID(providerID),
                model: GrokACPAdapter.currentModel(in: result)
            ))
            sendPendingPromptIfReady()
            onSendAvailabilityChange?()

        case .prompt:
            flushPendingMessages()
            finishTurn(
                text: nil,
                outcome: TurnOutcome(acpStopReason: result?["stopReason"] as? String)
            )
        }
    }

    private func handleNotification(method: String, parameters: [String: Any]) {
        guard method == "session/update",
              let update = parameters["update"] as? [String: Any]
        else { return }
        if let providerID = activeSessionID,
           let updateSessionID = parameters["sessionId"] as? String,
           updateSessionID != providerID { return }

        switch update["sessionUpdate"] as? String {
        case "user_message_chunk":
            handleUserChunk(update)
        case "agent_message_chunk":
            handleAssistantChunk(update, thinking: false)
        case "agent_thought_chunk":
            handleAssistantChunk(update, thinking: true)
        case "tool_call":
            flushPendingMessages()
            handleToolCall(update)
        case "tool_call_update":
            handleToolCallUpdate(update)
        case "plan":
            onEvent?(.runPlanUpdated(GrokACPAdapter.planSteps(in: update)))
        case "available_commands_update":
            let commands = update["availableCommands"] as? [[String: Any]] ?? []
            replaceComposerCapabilities(GrokACPComposerCatalog.capabilities(from: commands))
        case "usage_update":
            lastContextTokens = GrokACPAdapter.integer(update["used"])
            lastContextWindow = GrokACPAdapter.integer(update["size"])
        case "session_info_update":
            if let title = GrokACPAdapter.sessionTitle(in: update) {
                onSessionTitleChange?(title)
            }
        case "current_mode_update", "config_option_update":
            break
        case .some(let value):
            onEvent?(.unknown(type: "grok.acp.\(value)"))
        case .none:
            onEvent?(.unknown(type: "grok.acp.session_update"))
        }
    }

    // MARK: - Messages

    private func handleUserChunk(_ update: [String: Any]) {
        guard isLoadingHistory,
              let text = GrokACPAdapter.textContent(in: update) else { return }
        flushAssistantMessage()
        let messageID = update["messageId"] as? String
        if userMessageID != nil, messageID != userMessageID { flushUserMessage() }
        userMessageID = messageID ?? userMessageID
        pendingUserText += text
    }

    private func handleAssistantChunk(_ update: [String: Any], thinking: Bool) {
        guard let text = GrokACPAdapter.textContent(in: update), !text.isEmpty else { return }
        flushUserMessage()
        let messageID = update["messageId"] as? String
        if assistantMessageID != nil, messageID != assistantMessageID {
            flushAssistantMessage()
        }
        assistantMessageID = messageID ?? assistantMessageID
        appendAssistant(text, thinking: thinking)

        guard !isLoadingHistory else { return }
        onEvent?(thinking ? .thinkingDelta(text) : .textDelta(text))
    }

    private func appendAssistant(_ text: String, thinking: Bool) {
        if let last = pendingAssistantBlocks.indices.last {
            switch (pendingAssistantBlocks[last], thinking) {
            case (.text(let existing), false):
                pendingAssistantBlocks[last] = .text(existing + text)
                return
            case (.thinking(let existing), true):
                pendingAssistantBlocks[last] = .thinking(existing + text)
                return
            default:
                break
            }
        }
        pendingAssistantBlocks.append(thinking ? .thinking(text) : .text(text))
    }

    private func flushPendingMessages() {
        flushUserMessage()
        flushAssistantMessage()
    }

    private func flushUserMessage() {
        guard !pendingUserText.isEmpty else {
            userMessageID = nil
            return
        }
        onEvent?(.userMessage(pendingUserText))
        pendingUserText = ""
        userMessageID = nil
    }

    private func flushAssistantMessage() {
        guard !pendingAssistantBlocks.isEmpty else {
            assistantMessageID = nil
            return
        }
        onEvent?(.assistantMessage(blocks: pendingAssistantBlocks.map(\.streamBlock)))
        pendingAssistantBlocks.removeAll(keepingCapacity: true)
        assistantMessageID = nil
    }

    private func resetMessageAccumulators() {
        userMessageID = nil
        pendingUserText = ""
        assistantMessageID = nil
        pendingAssistantBlocks.removeAll(keepingCapacity: true)
    }

    // MARK: - Tool Calls

    private func handleToolCall(_ update: [String: Any]) {
        guard let id = update["toolCallId"] as? String, !id.isEmpty else { return }
        var state = GrokACPToolState(update: update)
        state.didEmitCall = true
        toolCalls[id] = state
        reportProviderExecution(update: update, state: state, phase: .requested, asInput: true)
        if state.status == "completed" || state.status == "failed" {
            reportProviderExecution(
                update: update,
                state: state,
                phase: state.status == "failed" ? .failed : .completed,
                asInput: false
            )
        }
        onEvent?(.assistantMessage(blocks: [
            .toolUse(
                id: id,
                tool: GrokACPAdapter.toolIdentity(kind: state.kind, title: state.title),
                input: GrokACPAdapter.toolInput(from: update)
            )
        ]))
        finishToolIfNeeded(id: id)
    }

    private func handleToolCallUpdate(_ update: [String: Any]) {
        guard let id = update["toolCallId"] as? String, !id.isEmpty else { return }
        var state = toolCalls[id] ?? GrokACPToolState(update: update)
        state.merge(update)
        if !state.didEmitCall {
            state.didEmitCall = true
            reportProviderExecution(update: update, state: state, phase: .requested, asInput: true)
            onEvent?(.assistantMessage(blocks: [
                .toolUse(
                    id: id,
                    tool: GrokACPAdapter.toolIdentity(kind: state.kind, title: state.title),
                    input: GrokACPAdapter.toolInput(from: update)
                )
            ]))
        }
        let phase: ExecutionAuditRecord.Phase
        switch state.status {
        case "completed": phase = .completed
        case "failed": phase = .failed
        default: phase = .progressed
        }
        if phase == .progressed || !state.didEmitResult {
            reportProviderExecution(update: update, state: state, phase: phase, asInput: false)
        }
        toolCalls[id] = state
        finishToolIfNeeded(id: id)
    }

    private func reportProviderExecution(
        update: [String: Any],
        state: GrokACPToolState,
        phase: ExecutionAuditRecord.Phase,
        asInput: Bool
    ) {
        guard let event = GrokProviderExecutionAdapter.event(
            update: update,
            operation: state.title,
            kind: state.kind,
            phase: phase,
            asInput: asInput
        ) else { return }
        onProviderExecution?(event)
    }

    private func finishToolIfNeeded(id: String) {
        guard var state = toolCalls[id], !state.didEmitResult,
              state.status == "completed" || state.status == "failed" else { return }
        state.didEmitResult = true
        toolCalls[id] = state
        onEvent?(.toolResults([
            ToolResult(
                toolUseID: id,
                text: GrokACPAdapter.toolResultText(from: state.payload),
                isError: state.status == "failed"
            )
        ]))
    }

    // MARK: - Permissions

    private func handleServerRequest(
        id: JSONRPCRequestID,
        method: String,
        parameters: [String: Any]
    ) {
        guard method == "session/request_permission",
              let toolCall = parameters["toolCall"] as? [String: Any]
        else {
            sendResponse(
                id: id,
                error: ["code": -32601, "message": "Threading does not handle \(method)."]
            )
            return
        }

        let toolCallID = toolCall["toolCallId"] as? String
        var state = toolCallID.flatMap { toolCalls[$0] } ?? GrokACPToolState(update: toolCall)
        state.merge(toolCall)
        if let toolCallID { toolCalls[toolCallID] = state }
        let input = JSONValue.object(
            from: GrokACPAdapter.toolInputFoundation(from: state.payload)
        ) ?? [:]

        let request = PermissionRequest(
            sessionID: sessionID,
            tool: GrokACPAdapter.toolIdentity(kind: state.kind, title: state.title),
            input: input
        )
        let options = parameters["options"] as? [[String: Any]] ?? []

        PermissionBroker.decide(request) { [weak self] decision in
            self?.answerPermission(id: id, options: options, decision: decision)
        }
    }

    private func answerPermission(
        id: JSONRPCRequestID,
        options: [[String: Any]],
        decision: PermissionDecision
    ) {
        let allowed: Bool
        switch decision {
        case .allow: allowed = true
        case .deny: allowed = false
        }
        let preferredKinds = allowed
            ? ["allow_once", "allow_always"]
            : ["reject_once", "reject_always"]
        let selected = preferredKinds.lazy.compactMap { kind in
            options.first { $0["kind"] as? String == kind }
        }.first

        if let optionID = selected?["optionId"] as? String {
            sendResponse(id: id, result: [
                "outcome": ["outcome": "selected", "optionId": optionID]
            ])
        } else {
            sendResponse(id: id, result: ["outcome": ["outcome": "cancelled"]])
        }
    }

    // MARK: - Completion

    private func finishTurnWithTransportError(_ message: String) {
        flushPendingMessages()
        finishTurn(text: message, outcome: .failed)
    }

    private func finishTurn(text: String?, outcome: TurnOutcome) {
        guard isTurnInFlight || text != nil else { return }
        pendingPrompt = nil
        isTurnInFlight = false
        receivedTurnFinished = true
        toolCalls.removeAll(keepingCapacity: true)
        let duration = turnStartedAt.map {
            max(0, ProcessInfo.processInfo.systemUptime - $0)
        }
        turnStartedAt = nil
        onEvent?(.turnFinished(
            text: text,
            outcome: outcome,
            metrics: TurnMetrics(
                duration: duration,
                outputTokens: nil,
                effort: nil,
                contextTokens: lastContextTokens,
                contextWindow: lastContextWindow
            )
        ))
        onSendAvailabilityChange?()
    }

    private func receivedError(_ chunk: Data) {
        guard errorBuffer.count < GrokACPDefaults.maximumErrorBytes else { return }
        let remaining = GrokACPDefaults.maximumErrorBytes - errorBuffer.count
        errorBuffer.append(chunk.prefix(remaining))
    }

    private func handleTermination(status: Int32) {
        guard process != nil else { return }
        process?.standardOutput.readabilityHandler = nil
        process?.standardError.readabilityHandler = nil
        process = nil
        input = nil

        let wasTerminating = isTerminating
        isTerminating = false
        isRunning = false
        if !wasTerminating, isTurnInFlight, !receivedTurnFinished {
            let diagnostics = String(decoding: errorBuffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            finishTurnWithTransportError(
                diagnostics.isEmpty
                    ? "Grok ACP exited with status \(status)."
                    : diagnostics
            )
        }
        onSendAvailabilityChange?()
        onExit?(status)
    }

    private func replaceComposerCapabilities(_ capabilities: [ComposerCapability]) {
        let normalization = ComposerCapabilityCatalogPolicy.normalize(capabilities)
        if normalization.wasTruncated {
            ThreadingLogger.agent.warning(
                "Grok ACP command catalog exceeded local presentation limits; truncated"
            )
        }
        guard composerCapabilities != normalization.capabilities else { return }
        composerCapabilities = normalization.capabilities
        onComposerCapabilitiesChange?()
    }
}

// MARK: - Turn Outcome

extension TurnOutcome {
    /// Reads the stop reason ACP answers a `session/prompt` with.
    ///
    /// `cancelled` is the protocol's own word for a turn the client ended through
    /// `session/cancel`, and the spec is explicit that an agent must answer with it rather than
    /// with an error precisely so the two can be told apart. A refusal is a real failure; an
    /// unrecognised reason completes rather than inventing one.
    init(acpStopReason reason: String?) {
        switch reason {
        case "cancelled": self = .stopped
        case "refusal": self = .failed
        default: self = .completed
        }
    }
}

// MARK: - ACP Adapter

enum GrokACPAdapter {
    static func currentModel(in result: [String: Any]?) -> String? {
        let models = result?["models"] as? [String: Any]
        if let model = models?["currentModelId"] as? String { return model }
        let metadata = result?["_meta"] as? [String: Any]
        let modelState = metadata?["modelState"] as? [String: Any]
        return modelState?["currentModelId"] as? String
    }

    static func availableCommands(in result: [String: Any]?) -> [[String: Any]]? {
        let metadata = result?["_meta"] as? [String: Any]
        return metadata?["availableCommands"] as? [[String: Any]]
    }

    static func textContent(in update: [String: Any]) -> String? {
        guard let content = update["content"] as? [String: Any],
              content["type"] as? String == "text" else { return nil }
        return content["text"] as? String
    }

    static func sessionTitle(in update: [String: Any]) -> String? {
        guard let title = update["title"] as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    static func planSteps(in update: [String: Any]) -> [RunProgress.Step] {
        let entries = update["entries"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let title = entry["content"] as? String,
                  let rawStatus = entry["status"] as? String,
                  let status = RunProgress.Step.Status(providerValue: rawStatus)
            else { return nil }
            return RunProgress.Step(id: nil, title: title, status: status)
        }
    }

    static func toolIdentity(kind: String?, title: String) -> ToolIdentity {
        switch kind {
        case "read": return .read
        case "edit", "delete", "move": return .edit
        case "search": return .grep
        case "execute": return .bash
        case "think": return .plan
        case "fetch": return .webFetch
        default: return ToolIdentity(title)
        }
    }

    static func toolInput(from payload: [String: Any]) -> [String: JSONValue] {
        JSONValue.object(from: toolInputFoundation(from: payload)) ?? [:]
    }

    static func toolInputFoundation(from payload: [String: Any]) -> [String: Any] {
        var input: [String: Any]
        if let object = payload["rawInput"] as? [String: Any] {
            input = object
        } else if let rawInput = payload["rawInput"], !(rawInput is NSNull) {
            input = ["input": rawInput]
        } else {
            input = [:]
        }

        if input["title"] == nil, let title = payload["title"] as? String {
            input["title"] = title
        }
        if input["kind"] == nil, let kind = payload["kind"] as? String {
            input["kind"] = kind
        }
        if input["file_path"] == nil,
           let locations = payload["locations"] as? [[String: Any]],
           let path = locations.first?["path"] as? String {
            input["file_path"] = path
        }
        if let contents = payload["content"] as? [[String: Any]],
           let diff = contents.first(where: { $0["type"] as? String == "diff" }) {
            input["file_path"] = input["file_path"] ?? diff["path"]
            input["old_string"] = input["old_string"] ?? diff["oldText"]
            input["new_string"] = input["new_string"] ?? diff["newText"]
        }
        return input
    }

    static func toolResultText(from payload: [String: Any]) -> String {
        if let rawOutput = payload["rawOutput"], !(rawOutput is NSNull) {
            if let text = rawOutput as? String { return text }
            return JSONRPCLineEnvelope.encodedText(rawOutput)
        }

        let contents = payload["content"] as? [[String: Any]] ?? []
        return contents.compactMap { item -> String? in
            switch item["type"] as? String {
            case "content":
                guard let content = item["content"] as? [String: Any] else { return nil }
                if content["type"] as? String == "text" {
                    return content["text"] as? String
                }
                return nil
            case "diff":
                return item["path"] as? String
            case "terminal":
                return item["terminalId"] as? String
            default:
                return nil
            }
        }.joined(separator: "\n")
    }
}

enum GrokACPComposerCatalog {
    private static let terminalOnlyNames: Set<String> = [
        "always-approve", "clear", "exit", "feedback", "fork", "login", "logout",
        "model", "new", "permissions", "quit", "resume"
    ]
    private static let sessionCommandNames: Set<String> = [
        "compact", "context", "session-info"
    ]

    static func capabilities(from commands: [[String: Any]]) -> [ComposerCapability] {
        commands.compactMap { command in
            guard let name = command["name"] as? String, !name.isEmpty,
                  let description = command["description"] as? String else { return nil }
            let input = command["input"] as? [String: Any]
            let availability: ComposerCapability.Availability =
                terminalOnlyNames.contains(name)
                    ? .unavailable(reason: L10n.string(
                        "Available in Grok Terminal; not available in native Chat yet"
                    ))
                    : .available
            return ComposerCapability(
                id: "grok.command:\(name)",
                name: name,
                description: description,
                argumentHint: input?["hint"] as? String ?? "",
                kind: .command,
                trigger: .slash,
                presentation: sessionCommandNames.contains(name) ? .command : .turn,
                availability: availability
            )
        }
    }
}

private enum GrokACPPendingBlock {
    case text(String)
    case thinking(String)

    var streamBlock: ContentBlock {
        switch self {
        case .text(let text): return .text(text)
        case .thinking(let text): return .thinking(text)
        }
    }
}

private struct GrokACPToolState {
    var payload: [String: Any]
    var title: String
    var kind: String?
    var status: String?
    var didEmitCall = false
    var didEmitResult = false

    init(update: [String: Any]) {
        payload = update
        title = update["title"] as? String ?? "tool"
        kind = update["kind"] as? String
        status = update["status"] as? String
    }

    mutating func merge(_ update: [String: Any]) {
        payload.merge(update) { _, new in new }
        if let value = update["title"] as? String { title = value }
        if let value = update["kind"] as? String { kind = value }
        if let value = update["status"] as? String { status = value }
    }
}

private enum GrokACPRequestPurpose {
    case initialize
    case openSession
    case prompt
}

private enum GrokACPDefaults {
    static let protocolVersion = 1
    static let maximumErrorBytes = 64 * 1024
}
