import Foundation

/// Runs Codex headlessly and adapts its one-process-per-turn JSONL output to a persistent chat.
///
/// `codex exec --json` exits after every turn. Skalman keeps this wrapper alive, launching a
/// fresh process for the first turn and `codex exec resume` for later ones. A successful child
/// exit therefore means "ready for another message", not "the conversation ended".
final class CodexStreamSession: ConversationStreamSession {

    // MARK: - Properties

    let sessionID: SessionID

    var onEvent: ((StreamEvent) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onSendAvailabilityChange: (() -> Void)?

    private(set) var isRunning = false
    var canSend: Bool { isRunning && process == nil }

    /// Nil between turns: `codex exec` is one child per turn, so an idle conversation has a
    /// logical session but no process. Saying so is more honest than naming a dead pid.
    var rootProcessIdentifier: pid_t? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    private let plan: () -> AgentLaunchPlan
    private let effort: String?
    private var process: Process?
    private var buffer = Data()
    private var errorBuffer = Data()
    private var parseDiagnostics = StreamParseDiagnostics()
    var malformedLineCount: Int { parseDiagnostics.malformedLineCount }
    private var receivedTurnFinished = false
    private var isTerminating = false
    private var turnStartedAt: TimeInterval?

    // MARK: - Initialization

    init(
        sessionID: SessionID,
        effort: String? = nil,
        plan: @escaping () -> AgentLaunchPlan
    ) {
        self.sessionID = sessionID
        self.effort = effort
        self.plan = plan
    }

    // MARK: - Public Methods

    /// Opens the logical conversation. The first child is deferred until there is a prompt,
    /// because `codex exec` consumes exactly one prompt and then exits.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        isTerminating = false
        parseDiagnostics.reset()
        onSendAvailabilityChange?()
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard canSend else { return false }

        turnStartedAt = ProcessInfo.processInfo.systemUptime
        let launchPlan = plan()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = URL(fileURLWithPath: launchPlan.executable)
        process.arguments = launchPlan.arguments
        process.environment = AgentEnvironment.launchEnvironment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        buffer.removeAll(keepingCapacity: true)
        errorBuffer.removeAll(keepingCapacity: true)
        receivedTurnFinished = false

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

        process.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                self?.handleTermination(status: child.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            SkalmanLogger.agent.error("Codex stream failed to start: \(error.localizedDescription)")
            onEvent?(completingTurnMetrics(in: .turnFinished(
                text: error.localizedDescription,
                isError: true,
                metrics: .empty
            )))
            return false
        }

        self.process = process
        onSendAvailabilityChange?()

        do {
            try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            try input.fileHandleForWriting.close()
            return true
        } catch {
            SkalmanLogger.agent.error("Codex prompt write failed: \(error.localizedDescription)")
            // `handleTermination` must treat this as deliberate teardown. Otherwise it also
            // synthesizes a failed turn for the child exit after send() has already failed.
            isTerminating = true
            isRunning = false
            process.terminate()
            onSendAvailabilityChange?()
            return false
        }
    }

    /// A Codex turn has no reusable stdin to close; finishing the logical conversation is the
    /// same operation as terminating it.
    func finish() {
        terminate()
    }

    func terminate() {
        guard isRunning else { return }

        isTerminating = true
        isRunning = false
        onSendAvailabilityChange?()

        if let process {
            process.terminate()
        } else {
            onExit?(0)
        }
    }

    // MARK: - Event Stream

    private func received(_ chunk: Data) {
        buffer.append(chunk)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])

            guard let line = String(data: lineData, encoding: .utf8) else {
                parseDiagnostics.recordMalformedLine(provider: "Codex")
                continue
            }

            switch CodexStreamEvent.parse(line) {
            case .events(let events):
                for event in events {
                    let completed = completingTurnMetrics(in: event)
                    if case .turnFinished = completed { receivedTurnFinished = true }
                    onEvent?(completed)
                }
            case .malformed:
                parseDiagnostics.recordMalformedLine(provider: "Codex")
            }
        }
    }

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
        onSendAvailabilityChange?()

        if isTerminating {
            isTerminating = false
            onExit?(status)
            return
        }

        // A normal child exit completes one turn; the logical session stays open so the next
        // send can launch `exec resume`. If Codex died before emitting a terminal event, make
        // the failure visible instead of leaving the status stuck on Working.
        guard !receivedTurnFinished else { return }

        let diagnostics = String(decoding: errorBuffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = !diagnostics.isEmpty
            ? diagnostics
            : (status == 0 ? nil : "Codex exited with status \(status).")

        onEvent?(completingTurnMetrics(in: .turnFinished(
            text: message,
            isError: status != 0,
            metrics: .empty
        )))
    }

    /// Codex reports exact output usage but no wall duration in `turn.completed`, so the
    /// process wrapper adds the submit-to-terminal-event round trip from a monotonic clock.
    private func completingTurnMetrics(in event: StreamEvent) -> StreamEvent {
        guard case .turnFinished(let text, let isError, let metrics) = event else {
            return event
        }

        let duration = turnStartedAt.map {
            max(0, ProcessInfo.processInfo.systemUptime - $0)
        }
        turnStartedAt = nil

        return .turnFinished(
            text: text,
            isError: isError,
            metrics: metrics.filling(duration: duration, effort: effort)
        )
    }
}

enum CodexStreamDefaults {
    /// Stderr is diagnostic fallback only. Capping it prevents a failed child from becoming an
    /// unbounded in-memory log while stdout remains the authoritative event stream.
    static let maximumErrorBytes = 64 * 1024
}
