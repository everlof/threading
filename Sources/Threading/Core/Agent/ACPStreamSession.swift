import Foundation

/// Runs one Agent Client Protocol CLI and adapts it to native Chat.
///
/// ACP owns the common conversation contract, so this type contains only process lifecycle and
/// the translation from standard ACP updates into Threading's provider-neutral stream events.
/// Everything one agent does differently — its name in prose, its `_meta` extensions, which of
/// its commands the host refuses — arrives as an `ACPProviderProfile`, so nothing here asks which
/// runtime it is running. An agent's own metadata is an optional source of model information,
/// never a requirement for opening or resuming a conversation.
@MainActor
final class ACPStreamSession:
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
    var onInteractionAvailabilityChange: (() -> Void)?
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
    private let profile: ACPProviderProfile
    private let plan: () throws -> AgentLaunchPlan

    private var process: AgentChildProcess?
    private var input: FileHandle?
    private var buffer = Data()
    private var errorBuffer = Data()
    private var parseDiagnostics = StreamParseDiagnostics()

    private var requestSequence: Int64 = 0
    private var pendingRequests: [JSONRPCRequestID: ACPRequestPurpose] = [:]
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
    private var pendingAssistantBlocks: [ACPPendingBlock] = []
    private var toolCalls: [String: ACPToolCallState] = [:]

    // MARK: - Initialization

    init(
        sessionID: SessionID,
        workingDirectory: String,
        profile: ACPProviderProfile,
        plan: @escaping () throws -> AgentLaunchPlan
    ) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.profile = profile
        self.plan = plan
    }

    // MARK: - Public Methods

    func start() {
        guard !isRunning else { return }

        let process: AgentChildProcess
        do {
            let launchPlan = try plan()
            resetForLaunch(resumeState: launchPlan.resumeState)
            process = try AgentChildProcess.launch(
                executable: launchPlan.executable,
                arguments: launchPlan.arguments,
                environment: AgentEnvironment.launchEnvironment(),
                sessionID: sessionID
            ) { [weak self] status in
                Task { @MainActor [weak self] in self?.handleTermination(status: status) }
            }
        } catch {
            let label = profile.diagnosticsLabel
            let reason = error.localizedDescription
            ThreadingLogger.agent.error(
                "\(label, privacy: .public) failed to start: \(reason, privacy: .private(mask: .hash))"
            )
            // Match every other native transport: start never calls an external lifecycle
            // callback re-entrantly before its caller has finished installing the surface.
            Task { @MainActor [weak self] in
                self?.onExit?(AgentChildProcessDefaults.spawnFailureStatus)
            }
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
        onInteractionAvailabilityChange?()
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
        onInteractionAvailabilityChange?()
        sendPendingPromptIfReady()
        return true
    }

    @discardableResult
    func send(
        _ invocation: ComposerInvocation,
        identifiedBy id: ConversationMessageID
    ) -> Bool {
        guard composerCapabilities.contains(where: {
            $0.id == invocation.capability.id && $0.isEnabled
        }) else { return false }
        // ACP has no client message-id field. The durable checkpoint still owns `id`; the wire
        // transport cannot echo it back the way Claude and Codex do.
        _ = id
        return send(invocation.sourceText)
    }

    // MARK: - Turn Control

    var canInterrupt: Bool {
        isRunning && input != nil && isTurnInFlight && activeSessionID != nil
    }

    /// ACP has no steering primitive: the specification allows one prompt turn per session at a
    /// time, and names nothing for adding to the one in flight. Saying so is the point — the
    /// composer offers no steer for an ACP agent rather than one that quietly queues.
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
        onInteractionAvailabilityChange?()
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
        var clientCapabilities: [String: Any] = [
            "fs": ["readTextFile": false, "writeTextFile": false],
            "terminal": false,
            "session": ["configOptions": ["boolean": [:]]]
        ]
        if !profile.clientCapabilitiesMeta.isEmpty {
            clientCapabilities["_meta"] = profile.clientCapabilitiesMeta
        }
        let parameters: [String: Any] = [
            "protocolVersion": ACPDefaults.protocolVersion,
            "clientCapabilities": clientCapabilities,
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
            finishTurnWithTransportError(
                ACPTransportMessage.promptNotSent(profile.displayName)
            )
            return
        }
        pendingPrompt = nil
    }

    // MARK: - JSON-RPC

    @discardableResult
    private func sendRequest(
        method: String,
        parameters: [String: Any],
        purpose: ACPRequestPurpose
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
            let label = profile.diagnosticsLabel
            let reason = error.localizedDescription
            ThreadingLogger.agent.error(
                "\(label, privacy: .public) write failed: \(reason, privacy: .private(mask: .hash))"
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
                parseDiagnostics.recordMalformedLine(provider: profile.diagnosticsLabel)
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
            if let commands = profile.initializeCommands(result) {
                replaceComposerCapabilities(composerCapabilities(from: commands))
            }
            openSession()

        case .openSession:
            flushPendingMessages()
            isLoadingHistory = false
            let providerID = result?["sessionId"] as? String
                ?? launchResumeState.transcriptID?.rawValue
            guard let providerID, !providerID.isEmpty else {
                finishTurnWithTransportError(
                    ACPTransportMessage.noConversationSession(profile.displayName)
                )
                terminate()
                return
            }
            activeSessionID = providerID
            onEvent?(.initialised(
                sessionID: TranscriptID(providerID),
                model: ACPWireAdapter.currentModel(in: result)
                    ?? profile.extendedModelID(result)
            ))
            sendPendingPromptIfReady()
            onInteractionAvailabilityChange?()

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
            onEvent?(.runPlanUpdated(ACPWireAdapter.planSteps(in: update)))
        case "available_commands_update":
            let commands = update["availableCommands"] as? [[String: Any]] ?? []
            replaceComposerCapabilities(composerCapabilities(from: commands))
        case "usage_update":
            lastContextTokens = ACPWireAdapter.integer(update["used"])
            lastContextWindow = ACPWireAdapter.integer(update["size"])
        case "session_info_update":
            if let title = ACPWireAdapter.sessionTitle(in: update) {
                onSessionTitleChange?(title)
            }
        case "current_mode_update", "config_option_update":
            break
        case .some(let value):
            onEvent?(.unknown(type: "\(profile.unknownEventPrefix)\(value)"))
        case .none:
            onEvent?(.unknown(type: "\(profile.unknownEventPrefix)session_update"))
        }
    }

    // MARK: - Messages

    private func handleUserChunk(_ update: [String: Any]) {
        guard isLoadingHistory,
              let text = ACPWireAdapter.textContent(in: update) else { return }
        flushAssistantMessage()
        let messageID = update["messageId"] as? String
        if userMessageID != nil, messageID != userMessageID { flushUserMessage() }
        userMessageID = messageID ?? userMessageID
        pendingUserText += text
    }

    private func handleAssistantChunk(_ update: [String: Any], thinking: Bool) {
        guard let text = ACPWireAdapter.textContent(in: update), !text.isEmpty else { return }
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
        var state = ACPToolCallState(update: update)
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
                tool: ACPWireAdapter.toolIdentity(kind: state.kind, title: state.title),
                input: ACPWireAdapter.toolInput(from: update)
            )
        ]))
        finishToolIfNeeded(id: id)
    }

    private func handleToolCallUpdate(_ update: [String: Any]) {
        guard let id = update["toolCallId"] as? String, !id.isEmpty else { return }
        var state = toolCalls[id] ?? ACPToolCallState(update: update)
        state.merge(update)
        if !state.didEmitCall {
            state.didEmitCall = true
            reportProviderExecution(update: update, state: state, phase: .requested, asInput: true)
            onEvent?(.assistantMessage(blocks: [
                .toolUse(
                    id: id,
                    tool: ACPWireAdapter.toolIdentity(kind: state.kind, title: state.title),
                    input: ACPWireAdapter.toolInput(from: update)
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
        state: ACPToolCallState,
        phase: ExecutionAuditRecord.Phase,
        asInput: Bool
    ) {
        guard let event = ACPProviderExecutionAdapter.event(
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
                text: ACPWireAdapter.toolResultText(from: state.payload),
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
        var state = toolCallID.flatMap { toolCalls[$0] } ?? ACPToolCallState(update: toolCall)
        state.merge(toolCall)
        if let toolCallID { toolCalls[toolCallID] = state }
        let input = JSONValue.object(
            from: ACPWireAdapter.toolInputFoundation(from: state.payload)
        ) ?? [:]

        let request = PermissionRequest(
            sessionID: sessionID,
            tool: ACPWireAdapter.toolIdentity(kind: state.kind, title: state.title),
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
            ? ACPDefaults.allowOptionKinds
            : ACPDefaults.rejectOptionKinds
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
        onInteractionAvailabilityChange?()
    }

    private func receivedError(_ chunk: Data) {
        guard errorBuffer.count < ACPDefaults.maximumErrorBytes else { return }
        let remaining = ACPDefaults.maximumErrorBytes - errorBuffer.count
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
                    ? ACPTransportMessage.exited(
                        profile.diagnosticsLabel,
                        status: status
                    )
                    : diagnostics
            )
        }
        onInteractionAvailabilityChange?()
        onExit?(status)
    }

    private func composerCapabilities(
        from commands: [[String: Any]]
    ) -> [ComposerCapability] {
        ACPWireAdapter.composerCapabilities(
            from: commands,
            policy: profile.commandCatalog
        )
    }

    private func replaceComposerCapabilities(_ capabilities: [ComposerCapability]) {
        let normalization = ComposerCapabilityCatalogPolicy.normalize(capabilities)
        if normalization.wasTruncated {
            let label = profile.diagnosticsLabel
            ThreadingLogger.agent.warning(
                "\(label, privacy: .public) command catalog exceeded local presentation limits; truncated"
            )
        }
        guard composerCapabilities != normalization.capabilities else { return }
        composerCapabilities = normalization.capabilities
        onComposerCapabilitiesChange?()
    }
}

// MARK: - Transport Messages

/// What the user is told when the transport itself fails, rather than the model.
///
/// One place, because these strings are the only ones a provider's name reaches, and their
/// wording is pinned by test.
enum ACPTransportMessage {
    static func noConversationSession(_ displayName: String) -> String {
        "\(displayName) opened no conversation session."
    }

    static func promptNotSent(_ displayName: String) -> String {
        "Threading could not send the \(displayName) turn."
    }

    static func exited(_ diagnosticsLabel: String, status: Int32) -> String {
        "\(diagnosticsLabel) exited with status \(status)."
    }
}

private enum ACPPendingBlock {
    case text(String)
    case thinking(String)

    var streamBlock: ContentBlock {
        switch self {
        case .text(let text): return .text(text)
        case .thinking(let text): return .thinking(text)
        }
    }
}

private enum ACPRequestPurpose {
    case initialize
    case openSession
    case prompt
}

/// Internal rather than private so a focused test can pin the real bound it asserts against.
enum ACPDefaults {
    static let protocolVersion = 1
    static let maximumErrorBytes = 64 * 1024

    /// The option kinds the protocol itself names, in the order a decision prefers them.
    ///
    /// Standard vocabulary rather than provider policy, so it stays out of `ACPProviderProfile`.
    /// Another ACP client answers hyphenated kinds ("allow-once") as well; a CLI that deviates
    /// that way earns a profile member then, not before.
    static let allowOptionKinds = ["allow_once", "allow_always"]
    static let rejectOptionKinds = ["reject_once", "reject_always"]
}
