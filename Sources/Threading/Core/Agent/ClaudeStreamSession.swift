import Foundation

/// Runs Claude Code headless, speaking `stream-json` over pipes rather than driving a terminal.
///
/// This is the alternative to the PTY: instead of rendering the CLI's own text interface,
/// Threading receives structured events and draws the conversation itself. The process stays
/// alive across turns — verified — so one instance serves a whole conversation rather than
/// being respawned per message.
///
/// Two things the TUI provides free are lost here and must be rebuilt: input handling, and
/// permission prompts. Permissions arrive instead through `PermissionBroker`, because a
/// headless run has nowhere to ask and silently blocks tools it would otherwise prompt for.
///
/// It also speaks the CLI's **control channel** — the same line-delimited stdin the turns use,
/// carrying `control_request` objects the CLI answers with a `control_response`. Verified against
/// CLI 2.1.220: `initialize` returns the session's rich slash-command catalog before the first
/// prompt, `set_model` switches the model mid-conversation without a respawn — the next model
/// round-trip uses it — `apply_flag_settings` carries the fast-mode flag, and
/// `set_permission_mode` moves the conversation's permission posture (re-verified against 2.1.221,
/// where the accepted subtype list holds `set_model` and `set_permission_mode` side by side).
@MainActor
final class ClaudeStreamSession:
    ConversationStreamSession,
    ProviderExecutionReportingConversation,
    ComposerCapabilityProviding,
    ModelSwitchableConversation,
    FastModeConversation,
    PermissionModeSwitchableConversation,
    InterruptibleConversation,
    SteerableConversation,
    MessageLifecycleReportingConversation,
    SubagentReportingConversation,
    SubagentHistoryConversation {

    // MARK: - Properties

    let sessionID: SessionID

    private let plan: () throws -> AgentLaunchPlan
    private let effort: String?
    private let subagentTranscriptPlan: () -> ClaudeSubagentTranscriptPlan?

    /// Whether this conversation's CLI belongs in `threading-ptyd`, asked once per launch.
    ///
    /// A closure rather than a value for `plan`'s reason: it is resolved at launch time, so a
    /// dormant conversation reopened an hour later asks the current setting and the current
    /// daemon rather than the ones that were true when the controller was built. Nil is the
    /// deliberate local route; an unavailable selected host throws before any child starts.
    private let hostPlan: () throws -> PTYHostChildPlan?

    /// Fired on the main queue for every parsed event.
    var onEvent: ((StreamEvent) -> Void)?
    var onProviderExecution: ((ProviderExecutionEvent) -> Void)?
    var onLaunchFailure: ((Error) -> Void)?

    /// Fired on the main queue for child-agent events. Forwarded child output is deliberately
    /// absent from `onEvent`, because it belongs to the child's drill-in transcript.
    var onSubagentEvent: ((SubagentEvent) -> Void)?

    /// Fired when the process ends, for any reason.
    var onExit: ((Int32) -> Void)?

    var onInteractionAvailabilityChange: (() -> Void)?
    var onComposerCapabilitiesChange: (() -> Void)?
    private(set) var composerCapabilities: [ComposerCapability] = []
    var isComposerCapabilityCatalogReady: Bool { capabilityInitializationFinished }

    private(set) var isRunning = false

    private var process: AgentChildProcess?
    private var transport: AgentStreamTransport<ClaudeParsedLine>?
    private var acceptsInput = false

    /// Partial line carried between reads: a chunk boundary lands mid-JSON far more often
    /// than not, so lines are only parsed once their newline has arrived.
    private var parseDiagnostics = StreamParseDiagnostics()
    var malformedLineCount: Int { parseDiagnostics.malformedLineCount }

    private var subagentAdapter = ClaudeSubagentEventAdapter()

    /// In-flight control requests, keyed by the id the response echoes back. Everything here runs
    /// on the main queue — reads, writes and the response routing all hop there — so the map needs
    /// no locking. A monotonic counter mints the ids rather than a UUID, so the wire is legible.
    private var controlRequestSequence = 0
    private var pendingControl: [String: PendingControlRequest] = [:]

    private struct PendingControlRequest {
        let launch: Int
        let writtenAt: TimeInterval
        let completion: (Result<ControlResponse, Error>) -> Void
    }

    /// A request is written the moment the process exists, but the CLI reads none until it has
    /// booted — so how long a request may wait depends on whether this launch has answered one
    /// yet. See `controlDeadline(for:)`.
    private let controlTimeouts: ClaudeControlTimeouts
    private var controlLaunch = 0
    private var controlLaunchStartedAt: TimeInterval = 0
    private var controlChannelAnsweredAt: TimeInterval?

    /// Rich metadata arrives before the first turn through the control channel. `system/init`
    /// later identifies which advertised names are user-invocable skills.
    private var commandMetadata: [String: ClaudeCommandMetadata] = [:]
    private var knownSkillNames: Set<String> = []
    private var hasAuthoritativeSkillMembership = false
    private var didRequestComposerCapabilities = false
    private var capabilityInitializationFinished = true
    private var pendingPrompt: String?

    /// Diagnostic fallback for a child that exits before stream-json can explain why.
    private var turnStartedAt: TimeInterval?
    private var isTurnInFlight = false

    /// Set between asking the CLI to interrupt and the turn's terminal event arriving. It is the
    /// only thing that distinguishes a turn the user stopped from one that broke — see
    /// `outcome(for:)`.
    private var didRequestInterrupt = false

    var onMessageLifecycle: ((ConversationMessageID, MessageLifecycleState) -> Void)?

    /// The identifier travelling with `pendingPrompt`, so a turn held back by capability
    /// discovery still reaches the wire under the id the outbox knows it by.
    private var pendingMessageID: ConversationMessageID?

    /// What `system/init` says this build of the CLI can do.
    ///
    /// Read rather than assumed, because the CLI's own schema says older versions answer an
    /// interrupt with a bare success and no `still_queued` field. Absent a capability, Threading
    /// reports what it actually knows instead of an empty list that reads as "nothing survived".
    private var advertisedCapabilities: Set<String> = []

    /// Background work the CLI has told us is running, newest list wins.
    ///
    /// Kept so Stop can end the fleet rather than only the parent turn. Positional fallbacks
    /// (`#0`) are filtered out on the way in: they are display placeholders for an entry with no
    /// `task_id`, and sending one to `stop_task` would ask the CLI to stop a task called "#0".
    private var liveTaskIDs: [String] = []

    // MARK: - Initialization

    init(
        sessionID: SessionID,
        effort: String? = nil,
        subagentTranscriptPlan: @escaping () -> ClaudeSubagentTranscriptPlan? = { nil },
        hostPlan: @escaping () throws -> PTYHostChildPlan? = { nil },
        controlTimeouts: ClaudeControlTimeouts = .standard,
        plan: @escaping () throws -> AgentLaunchPlan
    ) {
        self.sessionID = sessionID
        self.effort = effort
        self.subagentTranscriptPlan = subagentTranscriptPlan
        self.hostPlan = hostPlan
        self.controlTimeouts = controlTimeouts
        self.plan = plan
    }

    // MARK: - Public Methods

    /// Starts the CLI. Does nothing if it is already running.
    func start() {
        guard !isRunning else { return }

        transport = nil
        acceptsInput = false
        parseDiagnostics.reset()
        subagentAdapter.reset()
        pendingPrompt = nil
        commandMetadata.removeAll()
        knownSkillNames.removeAll()
        hasAuthoritativeSkillMembership = false
        didRequestComposerCapabilities = false
        capabilityInitializationFinished = onComposerCapabilitiesChange == nil
        replaceComposerCapabilities([])

        let process: AgentChildProcess
        do {
            let plan = try plan()
            process = try AgentChildProcess.launch(
                executable: plan.executable,
                arguments: plan.arguments,
                environment: plan.launchEnvironment(),
                sessionID: sessionID,
                host: try hostPlan()
            ) { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.handleTermination(status: status)
                }
            }
        } catch {
            ThreadingLogger.agent.error(
                "Stream session failed to start: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let handler = self.onLaunchFailure { handler(error) }
                else { self.onExit?(AgentChildProcessDefaults.spawnFailureStatus) }
            }
            return
        }

        let transport = AgentStreamTransport(
            label: "codes.threading.agent.claude-stream",
            input: process.standardInput,
            output: process.standardOutput,
            error: process.standardError,
            maximumErrorBytes: ClaudeStreamDefaults.maximumErrorBytes,
            parser: { ClaudeParsedLine.parse($0) },
            onLine: { [weak self] line in self?.received(line) },
            onMalformedLine: { [weak self] in
                self?.parseDiagnostics.recordMalformedLine(provider: "Claude")
            },
            onFailure: { [weak self] failure in self?.transportFailed(failure) }
        )
        self.process = process
        self.transport = transport
        controlLaunch += 1
        controlLaunchStartedAt = ProcessInfo.processInfo.systemUptime
        controlChannelAnsweredAt = nil
        acceptsInput = true
        self.isRunning = true
        transport.start()
        onInteractionAvailabilityChange?()
        if onComposerCapabilitiesChange != nil {
            requestComposerCapabilities()
        }
    }

    /// Sends a user turn.
    ///
    /// The CLI accepts the same message envelope the API uses, one JSON object per line.
    var canSend: Bool {
        isRunning && acceptsInput && !isTurnInFlight && pendingPrompt == nil
    }

    /// The control channel accepts a request while a turn is active; it applies to the next
    /// model round-trip without restarting the persistent process. So this asks only that the
    /// conversation is open, not that it is idle.
    var acceptsConfigurationChange: Bool { isRunning }

    /// One process serves the whole conversation here, so this is stable across turns.
    var rootProcessIdentifier: pid_t? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        send(text, identifiedBy: ConversationMessageID())
    }

    @discardableResult
    func send(_ prompt: ConversationPrompt, identifiedBy id: ConversationMessageID) -> Bool {
        send(prompt.transportText, identifiedBy: id)
    }

    @discardableResult
    private func send(_ text: String, identifiedBy id: ConversationMessageID) -> Bool {
        guard canSend else { return false }

        pendingPrompt = text
        pendingMessageID = id
        turnStartedAt = ProcessInfo.processInfo.systemUptime
        isTurnInFlight = true
        onInteractionAvailabilityChange?()
        sendPendingTurnIfReady()
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
        return send(invocation.sourceText, identifiedBy: id)
    }

    private func sendPendingTurnIfReady() {
        guard capabilityInitializationFinished,
              let text = pendingPrompt,
              let id = pendingMessageID else { return }

        guard writeUserMessage(text, identifiedBy: id) else {
            pendingPrompt = nil
            pendingMessageID = nil
            isTurnInFlight = false
            turnStartedAt = nil
            onInteractionAvailabilityChange?()
            return
        }
        pendingPrompt = nil
        pendingMessageID = nil
    }

    /// Writes one user envelope, carrying the identifier the CLI echoes back on
    /// `command_lifecycle`.
    ///
    /// The `uuid` is the whole reason a queue here can state what a provider is doing with a
    /// message rather than infer it. Measured against 2.1.223: a message written with
    /// `"uuid": "u-1"` produces `command_lifecycle` records with `command_uuid: "u-1"` for
    /// `queued`, `started` and `completed`, and `cancel_async_message` will drop it by the same
    /// value while it is still pending.
    @discardableResult
    private func writeUserMessage(_ text: String, identifiedBy id: ConversationMessageID) -> Bool {
        guard acceptsInput, let transport else { return false }

        let message: [String: Any] = [
            "type": "user",
            "uuid": id.wireValue,
            "message": ["role": "user", "content": [["type": "text", "text": text]]]
        ]

        return transport.writeJSONObject(message)
    }

    // MARK: - Turn Control

    var canInterrupt: Bool { isRunning && acceptsInput && isTurnInFlight }

    /// Claude names no non-steerable turn kinds, so the only refusal here is having nothing to
    /// steer.
    var steerAvailability: SteerAvailability {
        guard isRunning, acceptsInput else { return .unavailable(.noActiveTurn) }
        return isTurnInFlight ? .available : .unavailable(.noActiveTurn)
    }

    /// Adds to the turn in flight.
    ///
    /// The wire shape is an ordinary user message — there is no separate steer verb. What makes
    /// it a steer rather than a queued turn is only that the CLI is busy when it arrives:
    /// measured against 2.1.223 it goes `queued` → `started` at the instant the next tool result
    /// lands, joins that turn, and settles under the same terminal event.
    ///
    /// Turn state is deliberately untouched. A steer opens no turn, so `turnStartedAt` keeps
    /// timing the turn it joined and `isTurnInFlight` was already true.
    @discardableResult
    func steer(_ prompt: ConversationPrompt, identifiedBy id: ConversationMessageID) -> Bool {
        guard steerAvailability.isAvailable else { return false }
        return writeUserMessage(prompt.transportText, identifiedBy: id)
    }

    /// Stops the running turn and everything it started.
    ///
    /// Children first, then the parent. Interrupting only the parent leaves backgrounded shells
    /// and subagents running — and Stop is reached for precisely when a fleet has run away, so
    /// the case where this matters most is the case where the parent-only version does least.
    ///
    /// Each child stop is best-effort and independently bounded by the control channel's own
    /// timeout, and the parent interrupt runs whatever they answered: one wedged child must not
    /// strand the rest or hold up the thing the user actually pressed.
    func interrupt(completion: @escaping @MainActor (InterruptReceipt) -> Void) {
        guard canInterrupt else {
            completion(.failed(reason: L10n.string("There is nothing running to stop.")))
            return
        }

        didRequestInterrupt = true

        let tasks = liveTaskIDs
        guard !tasks.isEmpty else {
            sendInterrupt(completion: completion)
            return
        }

        var remaining = tasks.count
        for task in tasks {
            sendControl(subtype: ClaudeControlRequest.stopTask, body: ["task_id": task]) {
                [weak self] _ in
                remaining -= 1
                guard remaining == 0 else { return }
                self?.sendInterrupt(completion: completion)
            }
        }
    }

    private func sendInterrupt(completion: @escaping @MainActor (InterruptReceipt) -> Void) {
        sendControl(subtype: ClaudeControlRequest.interrupt, body: [:]) { [weak self] result in
            switch result {
            case .success(let response):
                completion(self?.receipt(from: response) ?? .acknowledged)
            case .failure(let error):
                // The turn may well have ended on its own between the press and the write, so
                // the flag is cleared: leaving it set would relabel the *next* failure as a stop.
                self?.didRequestInterrupt = false
                completion(.failed(reason: error.localizedDescription))
            }
        }
    }

    /// Reads the interrupt's receipt.
    ///
    /// `still_queued` is only meaningful when the CLI advertised `interrupt_receipt_v1` on
    /// `system/init`. Without it an empty payload means "this build says nothing", which must not
    /// be read as "nothing survived" — so it answers `.acknowledged` and the outbox keeps what it
    /// is holding.
    private func receipt(from response: ControlResponse) -> InterruptReceipt {
        guard advertisedCapabilities.contains(ClaudeStreamDefaults.interruptReceiptCapability),
              let payload = response.payload,
              let queued = payload["still_queued"] as? [Any] else {
            return .acknowledged
        }
        return .reported(stillQueued: queued.compactMap { entry in
            (entry as? String).flatMap(ConversationMessageID.init(uuidString:))
        })
    }

    /// Drops a message the CLI has been handed but has not started.
    ///
    /// Used only for a message already on the wire. Anything still in Threading's own outbox is
    /// removed there, without the provider ever hearing about it.
    func cancelQueuedMessage(
        _ id: ConversationMessageID,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        sendControl(
            subtype: ClaudeControlRequest.cancelAsyncMessage,
            body: ["uuid": id.wireValue]
        ) { result in
            guard case .success(let response) = result else {
                completion(false)
                return
            }
            // "cancelled=false means the message was not in the queue (already dequeued or
            // never enqueued)" — the CLI's own words, and the answer to the race where the user
            // clicks remove as the message begins.
            completion(response.payload?["cancelled"] as? Bool ?? false)
        }
    }

    /// Ends the conversation. Closing stdin is the graceful route — the CLI finishes its
    /// current turn and exits on end-of-input.
    func finish() {
        guard acceptsInput, let transport else { return }
        acceptsInput = false
        transport.closeInput()
        onInteractionAvailabilityChange?()
    }

    func terminate() {
        guard isRunning else { return }
        finish()
        process?.terminate()
    }

    var isHostBacked: Bool { process?.isHostBacked ?? false }

    /// Hands the CLI to `threading-ptyd` rather than ending it.
    ///
    /// Deliberately **not** `finish()` first. Closing standard input is how this conversation is
    /// ended gracefully — the CLI reads end-of-input and exits — and that is precisely what must
    /// not happen here. The transport lets go of its own three descriptors when this process
    /// does; the child keeps the daemon's, and the next launch resumes the conversation with
    /// whatever the turn finished writing.
    func detachFromBackgroundHost(by deadline: Date) -> Bool {
        detachFromBackgroundHost(by: deadline, idleExpiresAt: nil)
    }

    func detachFromBackgroundHost(by deadline: Date, idleExpiresAt: Date?) -> Bool {
        guard isRunning, let process,
              process.detachFromBackgroundHost(
                by: deadline,
                idleExpiresAt: idleExpiresAt
              ) else {
            return false
        }
        isRunning = false
        transport?.detach()
        transport = nil
        acceptsInput = false
        onInteractionAvailabilityChange?()
        return true
    }

    // MARK: - Child Transcript History

    func loadSubagentHistory(
        completion: @escaping @MainActor @Sendable ([SubagentEvent]) -> Void
    ) {
        guard let plan = subagentTranscriptPlan() else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        ClaudeSubagentTranscriptReplay.loadIndex(plan: plan, completion: completion)
    }

    func loadSubagentTranscript(
        for descriptor: SubagentDescriptor,
        completion: @escaping @MainActor @Sendable ([StreamEvent], Bool) -> Void
    ) {
        guard let path = descriptor.path, !path.isEmpty else {
            DispatchQueue.main.async { completion([], false) }
            return
        }
        ClaudeSubagentTranscriptReplay.loadConversation(
            at: URL(fileURLWithPath: path),
            completion: completion
        )
    }

    // MARK: - Control Channel

    /// Switches the model for the rest of the conversation, without a respawn. `nil` (or the
    /// literal `"default"`) resets to the session's default model, per the CLI's own field
    /// contract. The completion fires when the CLI answers, so a caller can report what actually
    /// happened rather than assume it worked — a model id the CLI does not recognise is rejected.
    ///
    /// Unlike a turn, this is not gated on `isTurnInFlight`: the CLI applies it on the next model
    /// round-trip, so switching mid-turn is legitimate.
    func setModel(_ model: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        let body: [String: Any] = ["model": model.map { $0 as Any } ?? NSNull()]
        sendControl(subtype: ClaudeControlRequest.setModel, body: body) { result in
            completion(result.map { _ in () })
        }
    }

    /// Toggles Claude Code's fast mode for the rest of the conversation. Threading's startup
    /// policy may already have set the same value through `--settings`; this control request
    /// restates it for the live transport and carries later per-chat changes. Fast only engages
    /// on a supported Opus model, so a `.success` here means the flag was accepted — not that
    /// fast mode is actively drawing, which the account's subscription, usage credits and org
    /// policy still gate.
    func setFastMode(_ enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        let body: [String: Any] = ["settings": ["fastMode": enabled]]
        sendControl(subtype: ClaudeControlRequest.applyFlagSettings, body: body) { result in
            completion(result.map { _ in () })
        }
    }

    /// Moves the permission posture for the rest of the conversation, without a respawn.
    ///
    /// The mode travels as Claude's own **external** flag value, which is what `rawValue` is —
    /// the CLI normalises `manual` to its internal `default` on the way in, and rejects anything
    /// outside its six with `Cannot set permission mode: must be one of …`.
    ///
    /// A mode the session may not have is refused rather than silently kept: `bypassPermissions`
    /// on a session not launched with `--dangerously-skip-permissions`, or either of the two
    /// gated modes where settings disable them, comes back as a `control_response` of subtype
    /// `error` carrying the CLI's own sentence. That is why the completion reports the verdict
    /// instead of assuming one — the caller must not claim a change the agent declined.
    func setPermissionMode(
        _ mode: AgentPermissionMode,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let body: [String: Any] = ["mode": mode.claudeFlagValue]
        sendControl(subtype: ClaudeControlRequest.setPermissionMode, body: body) { result in
            completion(result.map { _ in () })
        }
    }

    private func requestComposerCapabilities() {
        guard !didRequestComposerCapabilities else { return }
        didRequestComposerCapabilities = true
        capabilityInitializationFinished = false
        sendControl(subtype: ClaudeControlRequest.initialize, body: [:]) { [weak self] result in
            guard let self else { return }
            if case .success(let response) = result,
               let commands = ClaudeCapabilityWire.commands(from: response.payload) {
                self.applyCommandMetadata(commands, replacing: true)
            }
            // Discovery never blocks ordinary chat indefinitely. An older CLI falls through
            // after the startup control timeout, and system/init still provides a name-only
            // fallback.
            self.capabilityInitializationFinished = true
            self.sendPendingTurnIfReady()
            self.onInteractionAvailabilityChange?()
        }
    }

    private func sendControl(
        subtype: String,
        body: [String: Any],
        completion: @escaping (Result<ControlResponse, Error>) -> Void
    ) {
        guard isRunning, acceptsInput, let transport else {
            completion(.failure(ClaudeControlError.notRunning))
            return
        }

        controlRequestSequence += 1
        let requestID = "\(ClaudeControlRequest.requestIDPrefix)\(controlRequestSequence)"

        guard transport.writeJSONObject(
            ClaudeControlRequest.object(subtype: subtype, requestID: requestID, body: body)
        ) else {
            completion(.failure(ClaudeControlError.writeFailed(
                AgentStreamTransportFailure.inputBackpressure.userFacingDescription
            )))
            return
        }

        pendingControl[requestID] = PendingControlRequest(
            launch: controlLaunch,
            writtenAt: ProcessInfo.processInfo.systemUptime,
            completion: completion
        )
        scheduleControlExpiry(for: requestID)
    }

    private func routeControlResponse(_ response: ControlResponse) {
        let request = response.requestID.flatMap { pendingControl.removeValue(forKey: $0) }
        noteControlChannelAnswered()
        guard let request else { return }
        if response.isError {
            request.completion(.failure(ClaudeControlError.rejected(response.error ?? "unknown error")))
        } else {
            request.completion(.success(response))
        }
    }

    /// Any answer — even a late one to a request that already expired — proves this launch reads
    /// its control channel. Requests written while it was booting move from the startup bound to
    /// the response bound, counted from now rather than from a write the CLI could not yet read.
    private func noteControlChannelAnswered() {
        guard controlChannelAnsweredAt == nil else { return }
        controlChannelAnsweredAt = ProcessInfo.processInfo.systemUptime
        for requestID in pendingControl.keys { scheduleControlExpiry(for: requestID) }
    }

    /// The timeout only bounds a reply that never comes, so a completion cannot be stranded. A
    /// child that exits fails its requests at once (`finishTermination`); this is for one that
    /// stays alive and silent.
    ///
    /// It is not measured from the write. Before the CLI has answered anything, a request is
    /// sitting unread in the pipe while the CLI boots, and a boot slower than the response
    /// timeout used to fail requests — the launch's own fast-mode restatement among them — that
    /// the CLI then answered moments later.
    private func controlDeadline(for request: PendingControlRequest) -> TimeInterval {
        // Written to a launch this session has since let go of: no answer can reach it.
        guard request.launch == controlLaunch else { return request.writtenAt }
        guard let answeredAt = controlChannelAnsweredAt else {
            return controlLaunchStartedAt + controlTimeouts.startup
        }
        return max(request.writtenAt, answeredAt) + controlTimeouts.response
    }

    private func scheduleControlExpiry(for requestID: String) {
        guard let request = pendingControl[requestID] else { return }
        let delay = max(0, controlDeadline(for: request) - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.expireControlRequestIfDue(requestID)
        }
    }

    /// A deadline can move after its check was scheduled — the channel's first answer brings a
    /// booting request's forward — so a check that finds it not yet due reschedules rather than
    /// failing early. Answered requests are gone from the map, which makes a stale check inert.
    private func expireControlRequestIfDue(_ requestID: String) {
        guard let request = pendingControl[requestID] else { return }
        guard ProcessInfo.processInfo.systemUptime >= controlDeadline(for: request) else {
            scheduleControlExpiry(for: requestID)
            return
        }
        pendingControl.removeValue(forKey: requestID)
        request.completion(.failure(ClaudeControlError.timedOut))
    }

    private func failPendingControlRequests(with error: Error) {
        let pending = pendingControl
        pendingControl.removeAll()
        for request in pending.values { request.completion(.failure(error)) }
    }

    // MARK: - Private Methods

    private func received(_ parsed: ClaudeParsedLine) {
        // The control channel's replies share this stream. Route them to their pending request
        // and keep them out of the conversation model — they are transport, not content.
        if let response = parsed.controlResponse {
            routeControlResponse(response)
            return
        }

        // The provider's own answer about a message we named. Also transport rather than
        // content: it says where a message has got to, not what was said.
        if let lifecycle = parsed.lifecycle {
            onMessageLifecycle?(lifecycle.id, lifecycle.state)
            return
        }

        updateAdvertisedCapabilities(from: parsed.line)
        updateComposerCapabilities(from: parsed.line)

        HookOutcomeLog.note(line: parsed.line, sessionID: sessionID)

        // Audit parsing shares the transport worker with the conversation parse. Only the typed,
        // immutable events cross main; display/state mutation remains actor-confined here.
        for event in parsed.providerEvents { onProviderExecution?(event) }

        if let route = subagentAdapter.route(parsed.line) {
            for event in route.events { onSubagentEvent?(event) }
            guard route.belongsToParent else { return }
        }

        switch parsed.streamResult {
        case .events(let events):
            for event in events {
                noteBackgroundWork(in: event)
                onEvent?(completingTurnMetrics(in: event))
            }
        case .malformed:
            parseDiagnostics.recordMalformedLine(provider: "Claude")
        }
    }

    /// Keeps the list Stop stops.
    ///
    /// `background_tasks_changed` restates the whole in-flight set every time, so this is an
    /// assignment rather than an accumulation. Positional placeholders are dropped: they stand
    /// for an entry the CLI gave no `task_id`, and there is no such task to stop.
    private func noteBackgroundWork(in event: StreamEvent) {
        guard case .backgroundWork(let inFlight) = event else { return }
        liveTaskIDs = inFlight.map(\.id).filter { !$0.hasPrefix("#") }
    }

    /// Records what this build of the CLI says it can do.
    ///
    /// Capabilities are read once from `system/init` rather than probed, and re-read on every
    /// init because the CLI emits a fresh one after an interrupt.
    private func updateAdvertisedCapabilities(from line: String) {
        guard line.contains("\"capabilities\""),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "system",
              object["subtype"] as? String == "init" else { return }
        // Per element. The names this client does not recognise are inert either way, so the
        // strict cast bought nothing and cost everything: one number in the list disabled every
        // capability the CLI had just said it has, including the interrupt receipt.
        guard let names = WireList.stringsIfListed(
            object["capabilities"],
            site: WireListSite.claudeCapabilities,
            log: ThreadingLogger.agent
        ) else { return }
        advertisedCapabilities = Set(names)
    }

    private func handleTermination(status: Int32) {
        guard isRunning else { return }
        acceptsInput = false
        isRunning = false
        let transport = self.transport
        guard let transport else {
            finishTermination(status: status, diagnostics: "")
            return
        }
        transport.finish { [weak self] diagnostics in
            self?.finishTermination(status: status, diagnostics: diagnostics)
        }
    }

    private func finishTermination(status: Int32, diagnostics: String) {
        guard process != nil else { return }
        process = nil
        transport = nil
        pendingPrompt = nil
        onInteractionAvailabilityChange?()

        // A request whose reply will now never arrive fails rather than sitting on its timeout.
        failPendingControlRequests(with: ClaudeControlError.notRunning)

        for event in subagentAdapter.terminationEvents(status: status) {
            onSubagentEvent?(event)
        }

        if status != 0 {
            if !diagnostics.isEmpty {
                onEvent?(completingTurnMetrics(in: .turnFinished(
                    text: diagnostics,
                    outcome: .failed,
                    metrics: .empty
                )))
            }
        }

        onExit?(status)
    }

    private func transportFailed(_ failure: AgentStreamTransportFailure) {
        guard process != nil else { return }
        let reason = failure.userFacingDescription
        ThreadingLogger.agent.error(
            "Claude stream transport failed: \(reason, privacy: .private(mask: .hash))"
        )
        if isTurnInFlight {
            onEvent?(completingTurnMetrics(in: .turnFinished(
                text: reason,
                outcome: .failed,
                metrics: .empty
            )))
        }
        terminate()
    }

    /// Claude supplies its own `duration_ms` on an ordinary result. The monotonic local clock
    /// fills failures and protects against a future result shape omitting it.
    private func completingTurnMetrics(in event: StreamEvent) -> StreamEvent {
        guard case .turnFinished(let text, let outcome, let metrics) = event else {
            return event
        }

        let duration = turnStartedAt.map {
            max(0, ProcessInfo.processInfo.systemUptime - $0)
        }
        turnStartedAt = nil
        isTurnInFlight = false
        pendingPrompt = nil

        let settled = self.outcome(for: outcome)
        onInteractionAvailabilityChange?()

        return .turnFinished(
            text: settled == .stopped ? nil : text,
            outcome: settled,
            metrics: metrics.filling(duration: duration, effort: effort)
        )
    }

    /// Restates the wire's outcome with the one fact the wire does not carry: whether *we* asked.
    ///
    /// Claude answers an interrupt with `result` / `subtype: "error_during_execution"`, which is
    /// also what a genuine execution fault produces — the parser therefore cannot tell them
    /// apart and honestly reports `.failed` (see `StreamEvent` `case "result"`). The session
    /// can: it sent the `interrupt` control request, so a failure arriving while that request is
    /// outstanding is the one it asked for.
    ///
    /// The flag is cleared here rather than on the control response, because the response is
    /// acknowledgement and this event is completion — measured at 10ms apart, always in that
    /// order. Clearing on the response would leave the terminal event to be read as a failure.
    private func outcome(for wire: TurnOutcome) -> TurnOutcome {
        defer { didRequestInterrupt = false }
        guard didRequestInterrupt, wire == .failed else { return wire }
        return .stopped
    }

    // MARK: - Composer Capabilities

    private func updateComposerCapabilities(from line: String) {
        guard let update = ClaudeCapabilityWire.update(from: line) else { return }
        if let skills = update.skillNames {
            knownSkillNames = ComposerCapabilityCatalogPolicy.boundedNames(skills)
            hasAuthoritativeSkillMembership = true
        } else if update.newCommandsAreSkills {
            // `commands_changed` carries the complete command metadata but no kind field. Claude
            // emits it when its live registry discovers commands such as skills in a newly
            // entered subdirectory. Preserve known memberships, discard removed names, and mark
            // newly introduced rows as skills rather than silently presenting them as commands.
            let names = ComposerCapabilityCatalogPolicy.boundedNames(
                update.commands?.map(\.name) ?? update.commandNames ?? []
            )
            let additions = names.subtracting(commandMetadata.keys)
            knownSkillNames.formIntersection(names)
            knownSkillNames.formUnion(additions)
        }
        if let commands = update.commands {
            applyCommandMetadata(commands, replacing: update.replacesCommands)
        } else if let names = update.commandNames {
            let metadata = names.map { name in
                commandMetadata[name] ?? ClaudeCommandMetadata(
                    name: name,
                    description: "",
                    argumentHint: "",
                    aliases: []
                )
            }
            applyCommandMetadata(metadata, replacing: true)
        } else if !composerCapabilities.isEmpty {
            rebuildComposerCapabilities()
        }
    }

    private func applyCommandMetadata(
        _ commands: [ClaudeCommandMetadata],
        replacing: Bool
    ) {
        if replacing { commandMetadata.removeAll() }
        let inspected = commands.prefix(
            ComposerCapabilityCatalogPolicy.maximumInspectedCapabilities
        )
        for command in inspected { commandMetadata[command.name] = command }
        rebuildComposerCapabilities(order: inspected.map(\.name))
    }

    private func rebuildComposerCapabilities(order preferredOrder: [String] = []) {
        var seenPreferredNames: Set<String> = []
        let preferred = preferredOrder.filter { name in
            commandMetadata[name] != nil && seenPreferredNames.insert(name).inserted
        }
        let remainder = commandMetadata.keys
            .filter { !seenPreferredNames.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let capabilities = (preferred + remainder).compactMap { name -> ComposerCapability? in
            guard let command = commandMetadata[name] else { return nil }
            guard !ClaudeComposerCommandPolicy.hiddenNames.contains(name) else { return nil }
            let isSkill = knownSkillNames.contains(name)
            // A project can choose a skill name that collides with a built-in command. Claude's
            // slash resolver, not the catalog's kind label, decides what raw `/name` ultimately
            // invokes, so the lifecycle/sensitive denylist must win over skill membership.
            let availability: ComposerCapability.Availability =
                ClaudeComposerCommandPolicy.nativeUnsafeNames.contains(name)
                    ? .unavailable(reason: L10n.string(
                        "Available in Claude Terminal; not safe in native Chat yet"
                    ))
                    : .available
            return ComposerCapability(
                id: "claude.command:\(name)",
                name: name,
                description: command.description,
                argumentHint: command.argumentHint,
                aliases: command.aliases,
                kind: isSkill ? .skill : .command,
                isAvailableInSkillCatalog: isSkill || !hasAuthoritativeSkillMembership,
                trigger: .slash,
                presentation: ClaudeComposerCommandPolicy.presentation(
                    for: name,
                    isSkill: isSkill
                ),
                availability: availability
            )
        }
        replaceComposerCapabilities(capabilities)
    }

    private func replaceComposerCapabilities(_ capabilities: [ComposerCapability]) {
        let normalization = ComposerCapabilityCatalogPolicy.normalize(capabilities)
        if normalization.wasTruncated {
            ThreadingLogger.agent.warning(
                "Claude composer catalog exceeded local presentation limits; truncated"
            )
        }
        let names = Set(normalization.capabilities.map(\.name))
        // Retain the normalized values too. Filtering only the keys would leave a provider's
        // multi-megabyte description alive in `commandMetadata` even though the UI saw a bound
        // copy, and the next membership update would expand it again.
        commandMetadata = Dictionary(uniqueKeysWithValues: normalization.capabilities.map { capability in
            (
                capability.name,
                ClaudeCommandMetadata(
                    name: capability.name,
                    description: capability.description,
                    argumentHint: capability.argumentHint,
                    aliases: capability.aliases
                )
            )
        })
        knownSkillNames.formIntersection(names)
        guard composerCapabilities != normalization.capabilities else { return }
        composerCapabilities = normalization.capabilities
        onComposerCapabilitiesChange?()
    }
}

/// A small native-surface override over Claude's live catalog. The provider remains the source
/// of truth for membership; these sets only state where raw passthrough would desynchronize
/// Threading's transcript/session ownership or expose an internal transport command.
enum ClaudeComposerCommandPolicy {
    static let hiddenNames: Set<String> = [
        "__remote-workflow",
        "workflow-launch-exec"
    ]

    static let nativeUnsafeNames: Set<String> = [
        "clear", "reset", "new",
        "background", "bg", "branch", "fork", "btw", "cd",
        "exit", "quit", "remote-control", "rc", "resume", "continue",
        "rewind", "checkpoint", "undo", "stop", "subtask", "tasks", "bashes",
        "teleport", "tp", "tui", "workflows",
        "heapdump", "ultrareview", "usage-credits", "extra-usage", "upgrade",
        "autofix-pr", "bug", "share", "feedback", "install-github-app",
        "install-slack-app", "web-setup", "design", "design-consent", "design-revoke"
    ]

    /// Command-versus-skill does not answer whether a user-visible agent turn follows. These
    /// measured commands and bundled workflows do, so their invocation remains a user bubble
    /// rather than being reduced to a muted session-control notice.
    static let turnNames: Set<String> = [
        "init", "review", "security-review", "insights", "recap", "goal",
        "team-onboarding", "deep-research", "design-sync", "dataviz", "verify",
        "debug", "code-review", "simplify", "batch", "fewer-permission-prompts",
        "doctor", "checkup", "loop", "proactive", "schedule", "routines",
        "claude-api", "run", "run-skill-generator"
    ]

    /// Claude does not identify which non-skill rows are prompt workflows and which are
    /// immediate CLI controls. Keep a bounded allowlist for commands measured/documented as
    /// session UI or state operations; an unknown name (including a legacy `.claude/commands`
    /// entry) is conservatively presented as a user turn so its prompt is not hidden as chrome.
    static let sessionCommandNames: Set<String> = [
        "add-dir", "advisor", "agents", "allowed-tools", "app", "chrome", "color",
        "compact", "config", "context", "copy", "cost", "desktop", "diff", "effort",
        "export", "fast", "focus", "help", "hooks", "ide", "ios", "android",
        "keybindings", "login", "logout", "mcp", "memory", "mobile", "model", "passes",
        "permissions", "plan", "plugin", "powerup", "privacy-settings", "radio",
        "release-notes", "reload-plugins", "reload-skills", "remote-env", "rename",
        "sandbox", "scroll-speed", "settings", "skills", "stats", "status", "statusline",
        "stickers", "tasks", "usage"
    ]

    static func presentation(
        for name: String,
        isSkill: Bool
    ) -> ComposerCapability.Presentation {
        if isSkill || turnNames.contains(name) { return .turn }
        return sessionCommandNames.contains(name) ? .command : .turn
    }
}

/// Everything expensive and stateless one stdout line can become. Stateful subagent correlation
/// remains in the main-actor session, but JSON decoding for the visible stream and execution
/// audit is complete before this value crosses the transport boundary.
struct ClaudeParsedLine: Sendable {
    let line: String
    let controlResponse: ControlResponse?
    let lifecycle: ClaudeMessageLifecycleRecord?
    let providerEvents: [ProviderExecutionEvent]
    let streamResult: StreamLineParseResult

    static func parse(_ data: Data) -> ClaudeParsedLine? {
        guard let line = String(data: data, encoding: .utf8) else { return nil }
        return ClaudeParsedLine(
            line: line,
            controlResponse: ControlResponse.parse(line),
            lifecycle: ClaudeMessageLifecycleRecord.parse(line),
            providerEvents: ClaudeProviderExecutionAdapter.events(line: line),
            streamResult: StreamEvent.parse(line)
        )
    }
}

enum ClaudeStreamDefaults {
    /// Stderr is diagnostic fallback only, so a broken child cannot grow memory without bound.
    static let maximumErrorBytes = 64 * 1024

    /// Once a launch has answered one control request it answers the next in milliseconds; this
    /// only bounds the wait on a reply that never comes, so a completion cannot be stranded.
    static let controlResponseTimeout: TimeInterval = 5

    /// How long a fresh launch has to answer its first control request. The CLI reads nothing
    /// until it has booted: about a second on an idle Mac (CLI 2.1.274, this app's own `--settings`
    /// and `--mcp-config`), but seven seconds under load on 2026-09-17 — past the response bound.
    static let controlStartupTimeout: TimeInterval = 30

    /// The `system/init` capability that promises an interrupt answers with `still_queued`.
    /// Without it the same request succeeds and names nothing, which is a different fact.
    static let interruptReceiptCapability = "interrupt_receipt_v1"

    /// The `system/init` capability that promises `command_lifecycle` records for a message sent
    /// with a `uuid`.
    static let messageLifecycleCapability = "msg_lifecycle_v1"
}

/// The two bounds on a control request's wait: `startup` until the launch has answered any
/// request, `response` after. Injectable so tests can drive both without waiting seconds.
struct ClaudeControlTimeouts {
    var response: TimeInterval
    var startup: TimeInterval

    static let standard = ClaudeControlTimeouts(
        response: ClaudeStreamDefaults.controlResponseTimeout,
        startup: ClaudeStreamDefaults.controlStartupTimeout
    )
}

// MARK: - Message Lifecycle Wire

/// One `command_lifecycle` line: where a message we named has got to.
///
/// Measured against CLI 2.1.223, gated behind the `msg_lifecycle_v1` capability:
/// `{"type":"command_lifecycle","command_uuid":"…","state":"queued|started|completed",
///   "uuid":"…","session_id":"…"}`. `command_uuid` is the value *we* put on the user envelope;
/// the sibling `uuid` is the CLI's own record id and is deliberately ignored.
struct ClaudeMessageLifecycleRecord: Sendable {
    let id: ConversationMessageID
    let state: MessageLifecycleState

    /// Nil for anything that is not a lifecycle record, so the caller falls through to the
    /// ordinary event parser. The substring guard keeps the JSON parse off the hot path.
    static func parse(_ line: String) -> ClaudeMessageLifecycleRecord? {
        guard line.contains("\"command_lifecycle\"") else { return nil }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "command_lifecycle",
              let raw = object["command_uuid"] as? String,
              let id = ConversationMessageID(uuidString: raw),
              let state = state(named: object["state"] as? String) else { return nil }
        return ClaudeMessageLifecycleRecord(id: id, state: state)
    }

    /// An unrecognised state is dropped rather than guessed at. A queue row that keeps saying
    /// what it last knew is honest; one that invents a transition is not.
    private static func state(named name: String?) -> MessageLifecycleState? {
        switch name {
        case "queued": .handedOver
        case "started": .started
        case "completed": .completed
        case "cancelled", "canceled": .cancelled
        default: nil
        }
    }
}

// MARK: - Capability Protocols

/// A conversation transport that can change its model mid-conversation without a respawn.
///
/// Claude's stream-json control channel supports this; Codex's per-turn `exec` does not (yet), so
/// it deliberately does not conform and the UI offers the control only when the cast succeeds —
/// the same shape as `AgentKind.supportsForking` and its kin.
@MainActor
protocol ModelSwitchableConversation: AnyObject {
    /// `nil` resets to the session default. The completion reports the CLI's own verdict, so a
    /// rejected model id surfaces rather than reading as success.
    func setModel(_ model: String?, completion: @escaping (Result<Void, Error>) -> Void)
}

/// A conversation transport that can toggle Claude Code's fast mode mid-conversation. Claude-only,
/// for the same reason as `ModelSwitchableConversation`.
@MainActor
protocol FastModeConversation: AnyObject {
    func setFastMode(_ enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void)
}

/// A conversation transport that can change how much the agent may do before it has to ask,
/// mid-conversation and without a respawn.
///
/// The mode is **not** optional here, unlike `ModelSwitchableConversation`'s: `set_model` takes an
/// explicit null meaning "back to the session default", and the permission channel has no
/// equivalent. Inherit is therefore a question the caller has to resolve before it reaches the
/// wire, and where it resolves to nothing there is nothing honest to send.
@MainActor
protocol PermissionModeSwitchableConversation: AnyObject {
    func setPermissionMode(
        _ mode: AgentPermissionMode,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

// MARK: - Wire Format

/// Builds the `control_request` line the CLI reads off stdin. Pure and separate from the session so
/// the exact wire shape is unit-testable without standing up a subprocess — the same reason the
/// conversation model is split from its drawing.
enum ClaudeControlRequest {
    static let requestIDPrefix = "threading-ctrl-"
    static let setModel = "set_model"
    static let setPermissionMode = "set_permission_mode"
    static let applyFlagSettings = "apply_flag_settings"
    static let initialize = "initialize"

    /// "Interrupts the currently running conversation turn", in the CLI's own words. Measured
    /// against 2.1.223: answered in ~10ms, settles the turn as `error_during_execution`, and
    /// leaves the process alive to take the next one.
    static let interrupt = "interrupt"

    /// "Drops a pending async user message from the command queue by uuid. No-op if already
    /// dequeued for execution." The provider-side counterpart to removing a queued row.
    static let cancelAsyncMessage = "cancel_async_message"

    /// Stops one background task by id. Reached before `interrupt`, because interrupting the
    /// parent turn leaves its children running.
    static let stopTask = "stop_task"

    /// `{"type":"control_request","request_id":"…","request":{"subtype":"…", …body}}` plus a
    /// trailing newline, matching the one-object-per-line envelope the turns use.
    static func line(subtype: String, requestID: String, body: [String: Any]) -> Data? {
        let envelope = object(subtype: subtype, requestID: requestID, body: body)
        guard var data = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
        data.append(0x0A)
        return data
    }

    static func object(subtype: String, requestID: String, body: [String: Any]) -> [String: Any] {
        var request: [String: Any] = ["subtype": subtype]
        request.merge(body) { _, new in new }
        return [
            "type": "control_request",
            "request_id": requestID,
            "request": request
        ]
    }
}

/// The parsed half of a `control_response` line. `request_id` lives inside `response`, as measured
/// against CLI 2.1.220: `{"type":"control_response","response":{"subtype":"success","request_id":"…"}}`
/// and, on failure, `{"…","response":{"subtype":"error","request_id":"…","error":"…"}}`.
struct ControlResponse: @unchecked Sendable {
    let requestID: String?
    let isError: Bool
    let error: String?
    let payload: [String: Any]?

    /// Returns nil for anything that is not a control response, so the caller falls through to the
    /// ordinary event parser. The substring guard keeps the full JSON parse off the hot path — a
    /// control response is rare next to the stream of turn events.
    static func parse(_ line: String) -> ControlResponse? {
        guard line.contains("\"control_response\"") else { return nil }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any]
        else { return nil }

        return ControlResponse(
            requestID: response["request_id"] as? String,
            isError: response["subtype"] as? String == "error",
            error: response["error"] as? String,
            payload: response["response"] as? [String: Any]
        )
    }
}

struct ClaudeCommandMetadata: Equatable {
    let name: String
    let description: String
    let argumentHint: String
    let aliases: [String]
}

enum ClaudeCapabilityWire {
    struct Update {
        let commandNames: [String]?
        let skillNames: [String]?
        let commands: [ClaudeCommandMetadata]?
        let replacesCommands: Bool
        let newCommandsAreSkills: Bool
    }

    /// **Every list read here is per element.** The catalogue is what the composer offers behind
    /// `/`, and `as? [[String: Any]]` answered one unreadable entry by withdrawing every other
    /// one — a person then picked from a list that had silently lost its whole contents, which is
    /// worse than one entry they could not have named anyway. `objectsIfListed`/`stringsIfListed`
    /// keep the difference between "no list" and "an empty list", so a `["ctx"]` still leaves the
    /// catalogue alone rather than emptying it.
    static func commands(from payload: [String: Any]?) -> [ClaudeCommandMetadata]? {
        guard let raw = WireList.objectsIfListed(
            payload?["commands"], site: WireListSite.claudeCommands, log: ThreadingLogger.agent
        ) else { return nil }
        return commands(from: raw)
    }

    static func update(from line: String) -> Update? {
        guard line.contains("\"system\"") else { return nil }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "system",
              let subtype = object["subtype"] as? String else { return nil }

        switch subtype {
        case "init":
            return Update(
                commandNames: WireList.stringsIfListed(
                    object["slash_commands"],
                    site: WireListSite.claudeSlashCommands,
                    log: ThreadingLogger.agent
                ),
                skillNames: WireList.stringsIfListed(
                    object["skills"], site: WireListSite.claudeSkills, log: ThreadingLogger.agent
                ),
                commands: nil,
                replacesCommands: true,
                newCommandsAreSkills: false
            )
        case "commands_changed":
            guard let raw = WireList.objectsIfListed(
                object["commands"], site: WireListSite.claudeCommands, log: ThreadingLogger.agent
            ) else { return nil }
            return Update(
                commandNames: nil,
                // The current wire has no membership field, but accepting one makes the parser
                // forward-compatible if Claude adds the explicit subset used by `system/init`.
                skillNames: WireList.stringsIfListed(
                    object["skills"], site: WireListSite.claudeSkills, log: ThreadingLogger.agent
                ),
                commands: commands(from: raw),
                replacesCommands: true,
                newCommandsAreSkills: true
            )
        default:
            return nil
        }
    }

    private static func commands(from raw: [[String: Any]]) -> [ClaudeCommandMetadata] {
        raw.compactMap { object in
            guard let name = object["name"] as? String, !name.isEmpty else { return nil }
            return ClaudeCommandMetadata(
                name: name,
                description: object["description"] as? String ?? "",
                argumentHint: object["argumentHint"] as? String
                    ?? object["argument_hint"] as? String
                    ?? "",
                aliases: WireList.stringsIfListed(
                    object["aliases"],
                    site: WireListSite.claudeCommandAliases,
                    log: ThreadingLogger.agent
                ) ?? []
            )
        }
    }
}

enum ClaudeControlError: LocalizedError {
    case notRunning
    case encodingFailed
    case writeFailed(String)
    case rejected(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return L10n.string("The conversation is not running.")
        case .encodingFailed:
            return L10n.string("Could not encode the control request.")
        case .writeFailed(let detail):
            return L10n.format("Could not send the control request: %@.", detail)
        case .rejected(let reason):
            return reason
        case .timedOut:
            return L10n.string("The agent did not answer the control request.")
        }
    }
}
