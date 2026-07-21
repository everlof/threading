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
final class ClaudeStreamSession: ConversationStreamSession {

    // MARK: - Properties

    let sessionID: UUID

    private let plan: () -> AgentLaunchPlan

    /// Fired on the main queue for every parsed event.
    var onEvent: ((StreamEvent) -> Void)?

    /// Fired when the process ends, for any reason.
    var onExit: ((Int32) -> Void)?

    private(set) var isRunning = false

    private var process: Process?
    private var inputPipe: Pipe?

    /// Partial line carried between reads: a chunk boundary lands mid-JSON far more often
    /// than not, so lines are only parsed once their newline has arrived.
    private var buffer = Data()

    // MARK: - Initialization

    init(sessionID: UUID, plan: @escaping () -> AgentLaunchPlan) {
        self.sessionID = sessionID
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

        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.environment = AgentEnvironment.launchEnvironment()
        process.standardInput = input
        process.standardOutput = output

        // Merged into the same pipe would corrupt the JSON stream, so diagnostics are read
        // separately and only surfaced when the process dies unexpectedly.
        process.standardError = Pipe()

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.received(chunk)
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
            onExit?(-1)
            return
        }

        self.process = process
        self.inputPipe = input
        self.isRunning = true
    }

    /// Sends a user turn.
    ///
    /// The CLI accepts the same message envelope the API uses, one JSON object per line.
    var canSend: Bool { isRunning && inputPipe != nil }

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
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
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
    }

    func terminate() {
        guard isRunning else { return }
        finish()
        process?.terminate()
    }

    // MARK: - Private Methods

    private func received(_ chunk: Data) {
        buffer.append(chunk)

        // Complete lines only; whatever follows the last newline waits for the next read.
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])

            guard let line = String(data: lineData, encoding: .utf8),
                  let event = StreamEvent.parse(line) else { continue }

            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(event)
            }
        }
    }

    private func handleTermination(status: Int32) {
        guard isRunning else { return }

        isRunning = false
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        inputPipe = nil

        onExit?(status)
    }
}
