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
final class CodexStreamSession:
    ConversationStreamSession,
    ProviderExecutionReportingConversation,
    ComposerCapabilityProviding,
    ReasoningEffortConfigurableConversation,
    InterruptibleConversation,
    SteerableConversation,
    MessageLifecycleReportingConversation,
    SubagentReportingConversation,
    SessionTitleReportingConversation {

    // MARK: - Properties

    let sessionID: SessionID

    var onEvent: ((StreamEvent) -> Void)?
    var onProviderExecution: ((ProviderExecutionEvent) -> Void)?
    var onSubagentEvent: ((SubagentEvent) -> Void)?
    var onSessionTitleChange: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onInteractionAvailabilityChange: (() -> Void)?
    var onComposerCapabilitiesChange: (() -> Void)?
    private(set) var composerCapabilities: [ComposerCapability] = []
    var sessionTitleSource: AgentTitleSource { .provider }

    private(set) var isRunning = false
    var canSend: Bool {
        isRunning && input != nil && !isTurnInFlight && pendingTurn == nil
            && !isCompactionInFlight
    }

    /// Model, effort and service tier ride on the turn request, so a change takes effect on
    /// the next one — which means the same readiness as sending it.
    var acceptsConfigurationChange: Bool { canSend }

    var rootProcessIdentifier: pid_t? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    private let plan: () throws -> AgentLaunchPlan
    private let configurationProvider: () -> CodexTurnConfiguration
    private let workingDirectory: String

    /// Whether this conversation's CLI belongs in `threading-ptyd`, asked once per launch.
    ///
    /// A closure rather than a value for `plan`'s reason: it is resolved at launch time, so a
    /// dormant conversation reopened an hour later asks the current setting and the current
    /// daemon rather than the ones that were true when the controller was built. Nil is today's
    /// in-process child, which every unavailability degrades to.
    private let hostPlan: () -> PTYHostChildPlan?

    private var process: AgentChildProcess?
    private var input: FileHandle?
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
    private var pendingTurn: CodexPendingTurn?
    private var isTurnInFlight = false
    private var isCompactionInFlight = false
    private var isSkillsRequestInFlight = false
    private var shouldReloadSkills = false
    private var isTerminating = false
    private var receivedTurnFinished = false
    private var skillsByCapabilityID: [String: CodexSkillMetadata] = [:]

    private var turnStartedAt: TimeInterval?
    private var turnEffort: String?
    private var outputTokensByTurn: [String: Int] = [:]

    var onMessageLifecycle: ((ConversationMessageID, MessageLifecycleState) -> Void)?

    /// The turn `turn/steer` and `turn/interrupt` name.
    ///
    /// Read from `turn/started`, which the server sends for every turn including ones it opened
    /// itself (a review, a compaction). Cleared when the turn settles, so `steerAvailability`
    /// cannot offer to add to a turn that has ended.
    private var activeTurnID: String?

    /// The kind of the turn in flight, where it is not an ordinary one.
    ///
    /// App-server refuses a steer on `review` and `compact` turns by name
    /// (`NonSteerableTurnKind`), so the composer is told before the user types rather than after
    /// the RPC comes back.
    private var activeTurnKind: CodexTurnKind = .ordinary

    /// Identifiers we handed the server, by the `clientUserMessageId` it echoes on the user
    /// message item. What lets a queued row state the provider's answer rather than an
    /// assumption.
    private var messageIDsInFlight: Set<ConversationMessageID> = []

    /// Live turns on child threads, so Stop can end the fleet. Keyed by thread id because that
    /// is what `turn/interrupt` takes alongside the turn.
    ///
    /// Tracked for *any* foreign conversation rather than only registered children: a child's
    /// `turn/started` can arrive before the activity notification that registers it, and a Stop
    /// that depends on registration timing leaves children running.
    private var childTurnsByThread: [String: String] = [:]

    /// The most recent request's size and the model's window, from `thread/tokenUsage/updated`
    /// — what the context meter reads at each turn boundary. Session-scoped rather than
    /// per-turn: the newest reading is the truth about the window whenever it arrives.
    private var lastContextTokens: Int?
    private var lastContextWindow: Int?

    // MARK: - Initialization

    init(
        sessionID: SessionID,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        configurationProvider: @escaping () -> CodexTurnConfiguration = { .inherited },
        hostPlan: @escaping () -> PTYHostChildPlan? = { nil },
        plan: @escaping () throws -> AgentLaunchPlan
    ) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.configurationProvider = configurationProvider
        self.hostPlan = hostPlan
        self.plan = plan
    }

    /// Kept as a source-compatible convenience for focused lifecycle tests and older callers.
    convenience init(
        sessionID: SessionID,
        effortProvider: @escaping () -> String?,
        plan: @escaping () throws -> AgentLaunchPlan
    ) {
        self.init(
            sessionID: sessionID,
            workingDirectory: FileManager.default.currentDirectoryPath,
            configurationProvider: {
                CodexTurnConfiguration(effort: effortProvider())
            },
            plan: plan
        )
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
                environment: launchPlan.launchEnvironment(),
                sessionID: sessionID,
                host: hostPlan()
            ) { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.handleTermination(status: status)
                }
            }
        } catch {
            ThreadingLogger.agent.error(
                "Codex app-server failed to start: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            Task { @MainActor [weak self] in
                self?.onExit?(AgentChildProcessDefaults.spawnFailureStatus)
            }
            return
        }

        process.standardOutput.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.received(chunk)
            }
        }

        // A separate pipe rather than merged into stdout: diagnostics interleaved with the
        // JSON-RPC stream would corrupt every line they landed inside.
        process.standardError.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.receivedError(chunk)
            }
        }

        self.process = process
        self.input = process.standardInput
        isRunning = true
        onInteractionAvailabilityChange?()
        sendInitialize()
    }

    /// Accepts a turn as soon as the process has launched. If app-server is still completing
    /// its initialize/thread handshake, the prompt waits in memory and is sent the moment the
    /// root thread is ready. This preserves the native composer's first-message path.
    @discardableResult
    func send(_ text: String) -> Bool {
        beginTurn(CodexPendingTurn(
            input: [["type": "text", "text": text]]
        ))
    }

    @discardableResult
    func send(_ prompt: ConversationPrompt, identifiedBy id: ConversationMessageID) -> Bool {
        beginTurn(CodexPendingTurn(
            input: [["type": "text", "text": prompt.transportText]],
            messageID: id
        ))
    }

    @discardableResult
    func send(
        _ invocation: ComposerInvocation,
        identifiedBy id: ConversationMessageID
    ) -> Bool {
        guard composerCapabilities.contains(where: {
            $0.id == invocation.capability.id && $0.isEnabled
        }) else {
            return false
        }

        if let skill = skillsByCapabilityID[invocation.capability.id] {
            return beginTurn(CodexPendingTurn(
                input: [
                    ["type": "text", "text": invocation.sourceText],
                    ["type": "skill", "name": skill.name, "path": skill.path]
                ],
                messageID: id
            ))
        }

        switch invocation.capability.id {
        case CodexComposerCatalog.compactID:
            return startCompact()
        case CodexComposerCatalog.reviewID:
            return startReview(arguments: invocation.arguments)
        default:
            return false
        }
    }

    @discardableResult
    private func beginTurn(_ turn: CodexPendingTurn) -> Bool {
        guard canSend else { return false }

        pendingTurn = turn
        isTurnInFlight = true
        receivedTurnFinished = false
        turnStartedAt = ProcessInfo.processInfo.systemUptime
        turnEffort = configurationProvider().effort
        onInteractionAvailabilityChange?()
        sendPendingTurnIfReady()
        return true
    }

    private func startCompact() -> Bool {
        guard canSend, let threadID = rootThreadID else { return false }
        // The request only acknowledges that compaction started. App-server then treats the
        // work as a turn and settles it through ordinary turn/item notifications.
        isCompactionInFlight = true
        isTurnInFlight = true
        receivedTurnFinished = false
        turnStartedAt = ProcessInfo.processInfo.systemUptime
        turnEffort = nil
        onInteractionAvailabilityChange?()
        guard sendRequest(
            method: "thread/compact/start",
            parameters: ["threadId": threadID],
            purpose: .compact
        ) != nil else {
            isCompactionInFlight = false
            isTurnInFlight = false
            turnStartedAt = nil
            onInteractionAvailabilityChange?()
            return false
        }
        return true
    }

    private func startReview(arguments: String) -> Bool {
        guard canSend, let threadID = rootThreadID else { return false }
        let target: [String: Any] = arguments.isEmpty
            ? ["type": "uncommittedChanges"]
            : ["type": "custom", "instructions": arguments]

        isTurnInFlight = true
        receivedTurnFinished = false
        turnStartedAt = ProcessInfo.processInfo.systemUptime
        turnEffort = configurationProvider().effort
        onInteractionAvailabilityChange?()
        guard sendRequest(
            method: "review/start",
            parameters: [
                "threadId": threadID,
                "delivery": "inline",
                "target": target
            ],
            purpose: .startReview
        ) != nil else {
            isTurnInFlight = false
            turnStartedAt = nil
            turnEffort = nil
            onInteractionAvailabilityChange?()
            return false
        }
        return true
    }

    /// Closing stdin asks the persistent server to shut down after its current work.
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
        finish()

        if let process {
            process.terminate()
        } else {
            onExit?(0)
        }
    }

    var isHostBacked: Bool { process?.isHostBacked ?? false }

    /// Hands the CLI to `threading-ptyd` rather than ending it.
    ///
    /// Deliberately **not** `finish()` first, for the reason `ClaudeStreamSession` states: closing
    /// standard input is how an app-server conversation ends gracefully, and this is the one path
    /// where it must go on running.
    func detachFromBackgroundHost(by deadline: Date) -> Bool {
        guard isRunning, let process, process.detachFromBackgroundHost(by: deadline) else {
            return false
        }
        isRunning = false
        onInteractionAvailabilityChange?()
        return true
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
        pendingTurn = nil
        isTurnInFlight = false
        isCompactionInFlight = false
        isSkillsRequestInFlight = false
        shouldReloadSkills = false
        isTerminating = false
        receivedTurnFinished = false
        skillsByCapabilityID.removeAll()
        replaceComposerCapabilities([])
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
              let pendingTurn else { return }

        let configuration = configurationProvider()
        var parameters: [String: Any] = [
            "threadId": threadID,
            "input": pendingTurn.input
        ]
        if let model = configuration.model { parameters["model"] = model }
        if let effort = configuration.effort { parameters["effort"] = effort }
        if let serviceTier = configuration.serviceTier {
            parameters["serviceTier"] = serviceTier
        }
        if let messageID = pendingTurn.messageID {
            parameters["clientUserMessageId"] = messageID.wireValue
            messageIDsInFlight.insert(messageID)
            onMessageLifecycle?(messageID, .started)
        }

        guard sendRequest(
            method: "turn/start",
            parameters: parameters,
            purpose: .startTurn
        ) != nil else {
            if let messageID = pendingTurn.messageID {
                messageIDsInFlight.remove(messageID)
                onMessageLifecycle?(messageID, .cancelled)
            }
            finishTurnWithTransportError("Threading could not send the Codex turn.")
            return
        }
        self.pendingTurn = nil
    }

    // MARK: - Turn Control

    var canInterrupt: Bool {
        isRunning && input != nil && isTurnInFlight && activeTurnID != nil
    }

    /// Whether app-server will accept an addition to the turn in flight.
    ///
    /// Three separate refusals rather than one boolean, because they mean different things to the
    /// person holding a message: nothing running (wait), or a review/compaction running (this
    /// particular work cannot be steered, but the next turn can).
    var steerAvailability: SteerAvailability {
        guard isRunning, input != nil, isTurnInFlight, activeTurnID != nil else {
            return .unavailable(.noActiveTurn)
        }
        return activeTurnKind.acceptsSteering
            ? .available
            : .unavailable(.turnKindRefusesSteering)
    }

    /// Appends user input to the turn already running.
    ///
    /// `expectedTurnId` is the protocol's own optimistic-concurrency precondition, and it is the
    /// good kind of API: the race Threading would otherwise lose — the turn ending between the
    /// user pressing send and the request landing — becomes an explicit, catchable failure rather
    /// than a message quietly delivered to the wrong turn. The handler for that failure is not to
    /// retry; it is to let the caller queue the message as an ordinary next turn.
    @discardableResult
    func steer(_ prompt: ConversationPrompt, identifiedBy id: ConversationMessageID) -> Bool {
        guard steerAvailability.isAvailable,
              let threadID = rootThreadID,
              let turnID = activeTurnID else { return false }

        let parameters: [String: Any] = [
            "threadId": threadID,
            "expectedTurnId": turnID,
            "clientUserMessageId": id.wireValue,
            "input": [["type": "text", "text": prompt.transportText]]
        ]

        guard sendRequest(
            method: "turn/steer",
            parameters: parameters,
            purpose: .steerTurn(id)
        ) != nil else { return false }

        messageIDsInFlight.insert(id)
        onMessageLifecycle?(id, .handedOver)
        return true
    }

    /// Stops the running turn and every child turn it started.
    ///
    /// Children first and best-effort, then the parent unconditionally: interrupting only the
    /// root leaves a fleet running, and a child that never answers must not hold up the thing the
    /// user pressed. Each child request is fire-and-forget for exactly that reason — the parent
    /// interrupt below is what the receipt reports on.
    func interrupt(completion: @escaping @MainActor (InterruptReceipt) -> Void) {
        guard canInterrupt, let threadID = rootThreadID, let turnID = activeTurnID else {
            completion(.failed(reason: L10n.string("There is nothing running to stop.")))
            return
        }

        for (childThread, childTurn) in childTurnsByThread {
            sendRequest(
                method: "turn/interrupt",
                parameters: ["threadId": childThread, "turnId": childTurn],
                purpose: .interruptTurn
            )
        }
        childTurnsByThread.removeAll()

        guard sendRequest(
            method: "turn/interrupt",
            parameters: ["threadId": threadID, "turnId": turnID],
            purpose: .interruptTurn
        ) != nil else {
            completion(.failed(reason: L10n.string("Threading could not reach Codex to stop it.")))
            return
        }

        // App-server has no `still_queued`: it holds nothing between turns, so there is nothing
        // for it to report on. The outbox keeps everything it is holding, which is the truth.
        completion(.acknowledged)
    }

    /// Keeps the turn identity that `turn/steer` and `turn/interrupt` require.
    ///
    /// A turn belonging to another thread is a child's: recorded so Stop can end it, and
    /// deliberately never allowed to become `activeTurnID`, which names the turn the composer is
    /// adding to. Both facts come off the same notification, so they are read in one place.
    private func noteTurnLifecycle(method: String, parameters: [String: Any]) {
        guard method == "turn/started" || method == "turn/completed" else { return }

        let notificationThreadID = parameters["threadId"] as? String
        let turn = parameters["turn"] as? [String: Any]
        guard let turnID = turn?["id"] as? String else { return }

        let isRoot = notificationThreadID == nil || notificationThreadID == rootThreadID

        if method == "turn/started" {
            if isRoot {
                let previousTurnID = activeTurnID
                activeTurnID = turnID
                // `isCompactionInFlight` is set by the request that asked for it; a review turn
                // is the one we started through `review/start`. Nothing on the wire names the
                // kind, so it is remembered from what we asked for.
                activeTurnKind = isCompactionInFlight ? .compact : activeTurnKind
                if activeTurnID != previousTurnID {
                    onInteractionAvailabilityChange?()
                }
            } else if let threadID = notificationThreadID {
                childTurnsByThread[threadID] = turnID
            }
            return
        }

        if isRoot {
            let hadActiveTurn = activeTurnID != nil
            activeTurnID = nil
            activeTurnKind = .ordinary
            settleMessagesInFlight()
            if hadActiveTurn {
                onInteractionAvailabilityChange?()
            }
        } else if let threadID = notificationThreadID {
            childTurnsByThread[threadID] = nil
        }
    }

    /// Marks every message this turn carried as done.
    ///
    /// App-server reports no per-message completion of its own — `clientUserMessageId` comes back
    /// on the user item, which says the message was accepted rather than finished — so the turn's
    /// own completion is the honest end for everything that rode it, including a steer.
    private func settleMessagesInFlight() {
        let settled = messageIDsInFlight
        messageIDsInFlight.removeAll()
        for id in settled { onMessageLifecycle?(id, .completed) }
    }

    private func reportRootThread(_ thread: [String: Any]) {
        guard let threadID = thread["id"] as? String else { return }

        rootThreadID = threadID
        reportSessionTitle(thread["name"])
        replaceComposerCapabilities(CodexComposerCatalog.builtIns)
        if !didReportThread {
            didReportThread = true
            onEvent?(.initialised(
                sessionID: TranscriptID(threadID),
                model: thread["model"] as? String
            ))
        }
        sendPendingTurnIfReady()
        requestSkillsIfNeeded()
        onInteractionAvailabilityChange?()
    }

    private func requestSkillsIfNeeded(forceReload: Bool = false) {
        if forceReload { shouldReloadSkills = true }
        guard onComposerCapabilitiesChange != nil,
              didInitialize,
              rootThreadID != nil,
              !isSkillsRequestInFlight else { return }

        let reload = shouldReloadSkills
        shouldReloadSkills = false
        isSkillsRequestInFlight = true
        var parameters: [String: Any] = ["cwds": [workingDirectory]]
        if reload { parameters["forceReload"] = true }
        if sendRequest(
            method: "skills/list",
            parameters: parameters,
            purpose: .listSkills
        ) == nil {
            isSkillsRequestInFlight = false
            shouldReloadSkills = reload
        }
    }

    private func applySkills(_ result: [String: Any]?) {
        guard let entries = result?["data"] as? [[String: Any]] else {
            rejectSkillsResponse("missing data")
            return
        }
        let expectedCWD = normalizedCheckoutPath(workingDirectory)
        guard let entry = entries.first(where: { entry in
            guard let cwd = entry["cwd"] as? String else { return false }
            return normalizedCheckoutPath(cwd) == expectedCWD
        }) else {
            // Never borrow the first entry: one request may contain several cwd scopes, and a
            // catalog from another checkout can invoke a same-named skill with a different path.
            rejectSkillsResponse("no matching cwd")
            return
        }
        guard let errors = entry["errors"] as? [[String: Any]], errors.isEmpty else {
            // A partial scan is not authoritative. Keep the last complete snapshot so one broken
            // SKILL.md cannot make unrelated, previously valid skills disappear.
            rejectSkillsResponse("scan errors")
            return
        }
        guard let rawSkills = entry["skills"] as? [[String: Any]] else {
            rejectSkillsResponse("missing skills")
            return
        }

        var metadataByID: [String: CodexSkillMetadata] = [:]
        var capabilities: [ComposerCapability] = CodexComposerCatalog.builtIns
        for object in rawSkills.prefix(
            ComposerCapabilityCatalogPolicy.maximumInspectedCapabilities
        ) {
            guard let name = object["name"] as? String,
                  let path = object["path"] as? String,
                  let rawDescription = object["description"] as? String,
                  let enabled = object["enabled"] as? Bool,
                  object["scope"] as? String != nil,
                  !name.isEmpty,
                  (path as NSString).isAbsolutePath,
                  ComposerCapabilityCatalogPolicy.acceptsPrivatePath(path)
            else {
                rejectSkillsResponse("invalid skill metadata")
                return
            }
            let interface = object["interface"] as? [String: Any]
            let displayName = interface?["displayName"] as? String
            let shortDescription = interface?["shortDescription"] as? String
                ?? object["shortDescription"] as? String
            let description = shortDescription ?? rawDescription
            let id = "codex.skill:\(name)"
            guard metadataByID[id] == nil else {
                rejectSkillsResponse("duplicate skill identity")
                return
            }
            metadataByID[id] = CodexSkillMetadata(name: name, path: path)
            capabilities.append(ComposerCapability(
                id: id,
                name: name,
                displayName: displayName,
                description: description,
                kind: .skill,
                trigger: .dollar,
                presentation: .turn,
                availability: enabled
                    ? .available
                    : .unavailable(reason: L10n.string("Disabled in Codex settings"))
            ))
        }
        if rawSkills.count > ComposerCapabilityCatalogPolicy.maximumInspectedCapabilities {
            ThreadingLogger.agent.warning(
                "Codex skills response exceeded local inspection limits; truncated"
            )
        }
        skillsByCapabilityID = metadataByID
        replaceComposerCapabilities(capabilities)
    }

    private func replaceComposerCapabilities(_ capabilities: [ComposerCapability]) {
        let normalization = ComposerCapabilityCatalogPolicy.normalize(capabilities)
        if normalization.wasTruncated {
            ThreadingLogger.agent.warning(
                "Codex composer catalog exceeded local presentation limits; truncated"
            )
        }
        let allowedIDs = Set(normalization.capabilities.map(\.id))
        skillsByCapabilityID = skillsByCapabilityID.filter { allowedIDs.contains($0.key) }
        guard composerCapabilities != normalization.capabilities else { return }
        composerCapabilities = normalization.capabilities
        onComposerCapabilitiesChange?()
    }

    private func rejectSkillsResponse(_ reason: String) {
        ThreadingLogger.agent.warning(
            "Ignored incomplete Codex skills snapshot: \(reason, privacy: .private(mask: .hash))"
        )
    }

    private func normalizedCheckoutPath(_ path: String) -> String {
        (path as NSString).standardizingPath
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
                "Codex app-server write failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
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
            case .startTurn, .startReview:
                finishTurnWithTransportError(error)
            case .listSkills:
                isSkillsRequestInFlight = false
                if shouldReloadSkills { requestSkillsIfNeeded() }
            case .compact:
                isCompactionInFlight = false
                finishTurnWithTransportError(L10n.format("Compact failed: %@", error))
            case .steerTurn(let messageID):
                // The turn ended, or turned out not to be steerable, between the press and the
                // request landing — which is exactly what `expectedTurnId` exists to catch. The
                // message goes back to the outbox as an ordinary next turn rather than being
                // retried against a turn that is already gone.
                messageIDsInFlight.remove(messageID)
                onMessageLifecycle?(messageID, .cancelled)
                ThreadingLogger.agent.info(
                    "Codex refused a steer; the message returns to the queue: \(error, privacy: .private(mask: .hash))"
                )
            case .interruptTurn:
                // Nothing to settle: the turn's own terminal event still decides how it ended,
                // and a refused interrupt most often means it had already finished.
                ThreadingLogger.agent.info(
                    "Codex refused an interrupt: \(error, privacy: .private(mask: .hash))"
                )
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

        case .startReview:
            activeTurnKind = .review

        case .steerTurn, .interruptTurn:
            // Acceptance, not completion. The turn's own notifications settle both.
            break

        case .listSkills:
            isSkillsRequestInFlight = false
            applySkills(result)
            if shouldReloadSkills { requestSkillsIfNeeded() }

        case .compact:
            // Acceptance is not completion. Standard `turn/completed` settles the operation.
            break
        }
    }

    private func handleNotification(method: String, parameters: [String: Any]) {
        if method == "skills/changed" {
            requestSkillsIfNeeded(forceReload: true)
        }

        noteTurnLifecycle(method: method, parameters: parameters)

        if method == "thread/started",
           let thread = parameters["thread"] as? [String: Any],
           (thread["parentThreadId"] == nil || thread["parentThreadId"] is NSNull),
           rootThreadID == nil {
            reportRootThread(thread)
        }

        if method == "thread/name/updated",
           parameters["threadId"] as? String == rootThreadID {
            reportSessionTitle(parameters["threadName"])
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

        // App-server's item notification is the authoritative execution object. Capture it
        // before the root-thread guard so delegated tools remain auditable too.
        for event in CodexProviderExecutionAdapter.events(
            method: method,
            parameters: parameters
        ) {
            onProviderExecution?(event)
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
            if case .turnFinished(_, let outcome, _) = completed {
                let completedCompaction = isCompactionInFlight
                receivedTurnFinished = true
                isTurnInFlight = false
                isCompactionInFlight = false
                pendingTurn = nil
                if let turnID { outputTokensByTurn[turnID] = nil }
                // A compaction the user stopped compacted nothing, so it says nothing.
                if completedCompaction, outcome == .completed {
                    onEvent?(.transcriptNotice(L10n.string("Context compacted.")))
                }
                onInteractionAvailabilityChange?()
            }
            onEvent?(completed)
        }
    }

    private func reportSessionTitle(_ value: Any?) {
        guard let title = (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return }
        onSessionTitleChange?(title)
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

        process?.standardOutput.readabilityHandler = nil
        process?.standardError.readabilityHandler = nil
        process = nil
        input = nil

        let wasTerminating = isTerminating
        isTerminating = false
        isRunning = false
        isCompactionInFlight = false
        isSkillsRequestInFlight = false
        shouldReloadSkills = false

        if !wasTerminating, isTurnInFlight, !receivedTurnFinished {
            let diagnostics = String(decoding: errorBuffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            finishTurnWithTransportError(
                diagnostics.isEmpty
                    ? "Codex app-server exited with status \(status)."
                    : diagnostics
            )
        }

        onInteractionAvailabilityChange?()
        onExit?(status)
    }

    private func finishTurnWithTransportError(_ message: String) {
        pendingTurn = nil
        isTurnInFlight = false
        receivedTurnFinished = true
        onEvent?(completingTurnMetrics(in: .turnFinished(
            text: message,
            outcome: .failed,
            metrics: .empty
        )))
        onInteractionAvailabilityChange?()
    }

    private func completingTurnMetrics(in event: StreamEvent) -> StreamEvent {
        guard case .turnFinished(let text, let outcome, let metrics) = event else {
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
            outcome: outcome,
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
    case startReview
    case listSkills
    case compact

    /// Carries the message identity so a refused steer can hand that exact message back to the
    /// outbox rather than losing what somebody typed.
    case steerTurn(ConversationMessageID)

    case interruptTurn
}

private struct CodexPendingTurn {
    let input: [[String: Any]]

    /// The identifier the outbox knows this message by, travelling as `clientUserMessageId` so
    /// the server can name it back. Absent for turns the composer did not originate — a review
    /// or a compaction is work, not a message somebody queued.
    var messageID: ConversationMessageID?
}

/// Whether the turn in flight is one app-server will let us add to.
///
/// `NonSteerableTurnKind` in the protocol schema is `review | compact`, and the server answers a
/// steer on either with "cannot steer a review turn" / "cannot steer a compact turn". Knowing it
/// locally means the composer can decline before the round trip rather than after.
private enum CodexTurnKind {
    case ordinary
    case review
    case compact

    var acceptsSteering: Bool { self == .ordinary }
}

private struct CodexSkillMetadata {
    let name: String
    let path: String
}

enum CodexComposerCatalog {
    static let compactID = "codex.command:compact"
    static let reviewID = "codex.command:review"

    /// Codex's TUI owns a much larger command language than app-server. Keep the current
    /// documented names visible as disabled expectations so a known TUI command cannot fall
    /// through as an ordinary model prompt in native Chat. This is deliberately not an
    /// execution catalog: direct app-server mappings graduate into `builtIns` one at a time,
    /// with their own response and lifecycle handling.
    ///
    /// Snapshot: Codex CLI 0.145.0 documentation, 2026-08-01. Aliases share one row so the
    /// completion list stays below its bounded 64-row presentation limit.
    static let terminalOnly: [ComposerCapability] = [
        terminalCommand("permissions"),
        terminalCommand("ide"),
        terminalCommand("keymap"),
        terminalCommand("vim"),
        terminalCommand("setup-default-sandbox"),
        terminalCommand("sandbox-add-read-dir"),
        terminalCommand("agent", aliases: ["subagents"]),
        terminalCommand("apps"),
        terminalCommand("plugins"),
        terminalCommand("hooks"),
        terminalCommand("clear"),
        terminalCommand("rename"),
        terminalCommand("archive"),
        terminalCommand("delete"),
        terminalCommand("copy"),
        terminalCommand("diff"),
        terminalCommand("exit", aliases: ["quit"]),
        terminalCommand("experimental"),
        terminalCommand("approve"),
        terminalCommand("memories"),
        terminalCommand("skills"),
        terminalCommand("import"),
        terminalCommand("feedback"),
        terminalCommand("init"),
        terminalCommand("logout"),
        terminalCommand("mcp"),
        terminalCommand("mention"),
        terminalCommand("model"),
        terminalCommand("fast"),
        terminalCommand("plan"),
        terminalCommand("goal"),
        terminalCommand("personality"),
        terminalCommand("ps"),
        terminalCommand("stop", aliases: ["clean"]),
        terminalCommand("fork"),
        terminalCommand("app"),
        terminalCommand("side", aliases: ["btw"]),
        terminalCommand("raw"),
        terminalCommand("resume"),
        terminalCommand("new"),
        terminalCommand("status"),
        terminalCommand("usage"),
        terminalCommand("debug-config"),
        terminalCommand("statusline"),
        terminalCommand("title"),
        terminalCommand("theme"),
        terminalCommand("pets", aliases: ["pet"])
    ]

    static let builtIns: [ComposerCapability] = [
        ComposerCapability(
            id: compactID,
            name: "compact",
            description: L10n.string("Compact the conversation context"),
            kind: .command,
            trigger: .slash,
            presentation: .command
        ),
        ComposerCapability(
            id: reviewID,
            name: "review",
            description: L10n.string(
                "Review uncommitted changes, or follow custom review instructions"
            ),
            argumentHint: "[instructions]",
            kind: .command,
            trigger: .slash,
            presentation: .turn
        )
    ] + terminalOnly

    private static func terminalCommand(
        _ name: String,
        aliases: [String] = []
    ) -> ComposerCapability {
        ComposerCapability(
            id: "codex.terminal-command:\(name)",
            name: name,
            aliases: aliases,
            kind: .command,
            trigger: .slash,
            presentation: .command,
            availability: .unavailable(reason: L10n.string(
                "Available in Codex Terminal; not available in native Chat yet"
            ))
        )
    }

}

enum CodexStreamDefaults {
    /// Stderr is diagnostic fallback only. Capping it prevents a failed server from becoming an
    /// unbounded in-memory log while stdout remains the authoritative protocol stream.
    static let maximumErrorBytes = 64 * 1024
}
