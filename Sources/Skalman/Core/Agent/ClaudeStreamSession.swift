import Foundation

/// Runs Claude Code headless, speaking `stream-json` over pipes rather than driving a terminal.
///
/// This is the alternative to the PTY: instead of rendering the CLI's own text interface,
/// Skalman receives structured events and draws the conversation itself. The process stays
/// alive across turns — verified — so one instance serves a whole conversation rather than
/// being respawned per message.
///
/// Two things the TUI provides free are lost here and must be rebuilt: input handling, and
/// permission prompts. Permissions arrive instead through `PermissionBroker`, because a
/// headless run has nowhere to ask and silently blocks tools it would otherwise prompt for.
///
/// It also speaks the CLI's **control channel** — the same line-delimited stdin the turns use,
/// carrying `control_request` objects the CLI answers with a `control_response`. Verified against
/// CLI 2.1.218: a control request works with no `initialize` handshake (Skalman never sends one),
/// `set_model` switches the model mid-conversation without a respawn — the next model round-trip
/// uses it, and the assistant message that follows reports the new model — and `apply_flag_settings`
/// carries the fast-mode flag. Codex's per-turn `exec` has no equivalent live channel, so the
/// capability protocols below are Claude-only and the UI offers the control only when the cast
/// succeeds.
final class ClaudeStreamSession:
    ConversationStreamSession,
    ModelSwitchableConversation,
    FastModeConversation,
    SubagentReportingConversation,
    SubagentHistoryConversation {

    // MARK: - Properties

    let sessionID: SessionID

    private let plan: () -> AgentLaunchPlan
    private let effort: String?
    private let subagentTranscriptPlan: () -> ClaudeSubagentTranscriptPlan?

    /// Fired on the main queue for every parsed event.
    var onEvent: ((StreamEvent) -> Void)?

    /// Fired on the main queue for child-agent events. Forwarded child output is deliberately
    /// absent from `onEvent`, because it belongs to the child's drill-in transcript.
    var onSubagentEvent: ((SubagentEvent) -> Void)?

    /// Fired when the process ends, for any reason.
    var onExit: ((Int32) -> Void)?

    var onSendAvailabilityChange: (() -> Void)?

    private(set) var isRunning = false

    private var process: Process?
    private var inputPipe: Pipe?

    /// Partial line carried between reads: a chunk boundary lands mid-JSON far more often
    /// than not, so lines are only parsed once their newline has arrived.
    private var buffer = Data()

    private var parseDiagnostics = StreamParseDiagnostics()
    var malformedLineCount: Int { parseDiagnostics.malformedLineCount }

    private var subagentAdapter = ClaudeSubagentEventAdapter()

    /// In-flight control requests, keyed by the id the response echoes back. Everything here runs
    /// on the main queue — reads, writes and the response routing all hop there — so the map needs
    /// no locking. A monotonic counter mints the ids rather than a UUID, so the wire is legible.
    private var controlRequestSequence = 0
    private var pendingControl: [String: (Result<Void, Error>) -> Void] = [:]

    /// Diagnostic fallback for a child that exits before stream-json can explain why.
    private var errorBuffer = Data()
    private var turnStartedAt: TimeInterval?
    private var isTurnInFlight = false

    // MARK: - Initialization

    init(
        sessionID: SessionID,
        effort: String? = nil,
        subagentTranscriptPlan: @escaping () -> ClaudeSubagentTranscriptPlan? = { nil },
        plan: @escaping () -> AgentLaunchPlan
    ) {
        self.sessionID = sessionID
        self.effort = effort
        self.subagentTranscriptPlan = subagentTranscriptPlan
        self.plan = plan
    }

    // MARK: - Public Methods

    /// Starts the CLI. Does nothing if it is already running.
    func start() {
        guard !isRunning else { return }

        let plan = plan()

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.environment = AgentEnvironment.launchEnvironment()
        process.standardInput = input
        process.standardOutput = output

        // Merged into the same pipe would corrupt the JSON stream, so diagnostics are read
        // separately and only surfaced when the process dies unexpectedly.
        process.standardError = error

        buffer.removeAll(keepingCapacity: true)
        errorBuffer.removeAll(keepingCapacity: true)
        parseDiagnostics.reset()
        subagentAdapter.reset()

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async {
                self?.received(chunk)
            }
        }

        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async {
                self?.receivedError(chunk)
            }
        }

        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.handleTermination(status: process.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            SkalmanLogger.agent.error("Stream session failed to start: \(error.localizedDescription)")
            output.fileHandleForReading.readabilityHandler = nil
            (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { [weak self] in
                self?.onExit?(-1)
            }
            return
        }

        self.process = process
        self.inputPipe = input
        self.isRunning = true
        onSendAvailabilityChange?()
    }

    /// Sends a user turn.
    ///
    /// The CLI accepts the same message envelope the API uses, one JSON object per line.
    var canSend: Bool { isRunning && inputPipe != nil && !isTurnInFlight }

    /// One process serves the whole conversation here, so this is stable across turns.
    var rootProcessIdentifier: pid_t? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard canSend, let inputPipe else { return false }

        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]]
        ]

        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        data.append(0x0A)

        // A write to a dead process raises SIGPIPE rather than returning an error, and the
        // process may have exited between the check above and here.
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
            turnStartedAt = startedAt
            isTurnInFlight = true
            onSendAvailabilityChange?()
            return true
        } catch {
            SkalmanLogger.agent.error("Stream session write failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Ends the conversation. Closing stdin is the graceful route — the CLI finishes its
    /// current turn and exits on end-of-input.
    func finish() {
        try? inputPipe?.fileHandleForWriting.close()
        inputPipe = nil
        onSendAvailabilityChange?()
    }

    func terminate() {
        guard isRunning else { return }
        finish()
        process?.terminate()
    }

    // MARK: - Child Transcript History

    func loadSubagentHistory(completion: @escaping ([SubagentEvent]) -> Void) {
        guard let plan = subagentTranscriptPlan() else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        ClaudeSubagentTranscriptReplay.loadIndex(plan: plan, completion: completion)
    }

    func loadSubagentTranscript(
        for descriptor: SubagentDescriptor,
        completion: @escaping ([StreamEvent], Bool) -> Void
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
        sendControl(subtype: ClaudeControlRequest.setModel, body: body, completion: completion)
    }

    /// Toggles Claude Code's fast mode for the rest of the conversation. Fast mode is off by
    /// default in this transport and only engages on an Opus 4.7/4.8 model, so a `.success` here
    /// means the flag was accepted — not that fast mode is actively drawing, which the account's
    /// subscription, usage credits and org policy still gate.
    func setFastMode(_ enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        let body: [String: Any] = ["settings": ["fastMode": enabled]]
        sendControl(subtype: ClaudeControlRequest.applyFlagSettings, body: body, completion: completion)
    }

    private func sendControl(
        subtype: String,
        body: [String: Any],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard isRunning, let inputPipe else {
            completion(.failure(ClaudeControlError.notRunning))
            return
        }

        controlRequestSequence += 1
        let requestID = "\(ClaudeControlRequest.requestIDPrefix)\(controlRequestSequence)"

        guard let data = ClaudeControlRequest.line(subtype: subtype, requestID: requestID, body: body) else {
            completion(.failure(ClaudeControlError.encodingFailed))
            return
        }

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            completion(.failure(ClaudeControlError.writeFailed(error.localizedDescription)))
            return
        }

        pendingControl[requestID] = completion

        // The channel answers in well under a second in practice; the timeout only guards a
        // response that never arrives — a child that died between the write and the reply — so the
        // completion cannot leak.
        DispatchQueue.main.asyncAfter(deadline: .now() + ClaudeStreamDefaults.controlResponseTimeout) { [weak self] in
            guard let pending = self?.pendingControl.removeValue(forKey: requestID) else { return }
            pending(.failure(ClaudeControlError.timedOut))
        }
    }

    private func routeControlResponse(_ response: ControlResponse) {
        guard let requestID = response.requestID,
              let completion = pendingControl.removeValue(forKey: requestID) else { return }
        if response.isError {
            completion(.failure(ClaudeControlError.rejected(response.error ?? "unknown error")))
        } else {
            completion(.success(()))
        }
    }

    private func failPendingControlRequests(with error: Error) {
        let pending = pendingControl
        pendingControl.removeAll()
        for completion in pending.values { completion(.failure(error)) }
    }

    // MARK: - Private Methods

    private func received(_ chunk: Data) {
        buffer.append(chunk)

        // Complete lines only; whatever follows the last newline waits for the next read.
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])

            guard let line = String(data: lineData, encoding: .utf8) else {
                parseDiagnostics.recordMalformedLine(provider: "Claude")
                continue
            }

            // The control channel's replies share this stream. Route them to their pending request
            // and keep them out of the conversation model — they are transport, not content.
            if let response = ControlResponse.parse(line) {
                routeControlResponse(response)
                continue
            }

            HookOutcomeLog.note(line: line, sessionID: sessionID)

            if let route = subagentAdapter.route(line) {
                for event in route.events { onSubagentEvent?(event) }
                guard route.belongsToParent else { continue }
            }

            switch StreamEvent.parse(line) {
            case .events(let events):
                for event in events { onEvent?(completingTurnMetrics(in: event)) }
            case .malformed:
                parseDiagnostics.recordMalformedLine(provider: "Claude")
            }
        }
    }

    private func receivedError(_ chunk: Data) {
        guard errorBuffer.count < ClaudeStreamDefaults.maximumErrorBytes else { return }
        let remaining = ClaudeStreamDefaults.maximumErrorBytes - errorBuffer.count
        errorBuffer.append(chunk.prefix(remaining))
    }

    private func handleTermination(status: Int32) {
        guard isRunning else { return }

        isRunning = false
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        inputPipe = nil
        onSendAvailabilityChange?()

        // A request whose reply will now never arrive fails rather than sitting on its timeout.
        failPendingControlRequests(with: ClaudeControlError.notRunning)

        for event in subagentAdapter.terminationEvents(status: status) {
            onSubagentEvent?(event)
        }

        if status != 0 {
            let diagnostics = String(decoding: errorBuffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !diagnostics.isEmpty {
                onEvent?(completingTurnMetrics(in: .turnFinished(
                    text: diagnostics,
                    isError: true,
                    metrics: .empty
                )))
            }
        }

        onExit?(status)
    }

    /// Claude supplies its own `duration_ms` on an ordinary result. The monotonic local clock
    /// fills failures and protects against a future result shape omitting it.
    private func completingTurnMetrics(in event: StreamEvent) -> StreamEvent {
        guard case .turnFinished(let text, let isError, let metrics) = event else {
            return event
        }

        let duration = turnStartedAt.map {
            max(0, ProcessInfo.processInfo.systemUptime - $0)
        }
        turnStartedAt = nil
        isTurnInFlight = false
        onSendAvailabilityChange?()

        return .turnFinished(
            text: text,
            isError: isError,
            metrics: metrics.filling(duration: duration, effort: effort)
        )
    }
}

enum ClaudeStreamDefaults {
    /// Stderr is diagnostic fallback only, so a broken child cannot grow memory without bound.
    static let maximumErrorBytes = 64 * 1024

    /// The control channel answers in milliseconds; this only bounds the wait on a reply that
    /// never comes, so a completion cannot be stranded.
    static let controlResponseTimeout: TimeInterval = 5
}

// MARK: - Capability Protocols

/// A conversation transport that can change its model mid-conversation without a respawn.
///
/// Claude's stream-json control channel supports this; Codex's per-turn `exec` does not (yet), so
/// it deliberately does not conform and the UI offers the control only when the cast succeeds —
/// the same shape as `AgentKind.supportsForking` and its kin.
protocol ModelSwitchableConversation: AnyObject {
    /// `nil` resets to the session default. The completion reports the CLI's own verdict, so a
    /// rejected model id surfaces rather than reading as success.
    func setModel(_ model: String?, completion: @escaping (Result<Void, Error>) -> Void)
}

/// A conversation transport that can toggle Claude Code's fast mode mid-conversation. Claude-only,
/// for the same reason as `ModelSwitchableConversation`.
protocol FastModeConversation: AnyObject {
    func setFastMode(_ enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void)
}

// MARK: - Wire Format

/// Builds the `control_request` line the CLI reads off stdin. Pure and separate from the session so
/// the exact wire shape is unit-testable without standing up a subprocess — the same reason the
/// conversation model is split from its drawing.
enum ClaudeControlRequest {
    static let requestIDPrefix = "skalman-ctrl-"
    static let setModel = "set_model"
    static let applyFlagSettings = "apply_flag_settings"

    /// `{"type":"control_request","request_id":"…","request":{"subtype":"…", …body}}` plus a
    /// trailing newline, matching the one-object-per-line envelope the turns use.
    static func line(subtype: String, requestID: String, body: [String: Any]) -> Data? {
        var request: [String: Any] = ["subtype": subtype]
        request.merge(body) { _, new in new }
        let envelope: [String: Any] = [
            "type": "control_request",
            "request_id": requestID,
            "request": request
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
        data.append(0x0A)
        return data
    }
}

/// The parsed half of a `control_response` line. `request_id` lives inside `response`, as measured
/// against CLI 2.1.218: `{"type":"control_response","response":{"subtype":"success","request_id":"…"}}`
/// and, on failure, `{"…","response":{"subtype":"error","request_id":"…","error":"…"}}`.
struct ControlResponse {
    let requestID: String?
    let isError: Bool
    let error: String?

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
            error: response["error"] as? String
        )
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
