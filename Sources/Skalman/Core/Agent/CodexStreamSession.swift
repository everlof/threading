import Foundation

/// Runs Codex headlessly and adapts its one-process-per-turn JSONL output to a persistent chat.
///
/// `codex exec --json` exits after every turn. Skalman keeps this wrapper alive, launching a
/// fresh process for the first turn and `codex exec resume` for later ones. A successful child
/// exit therefore means "ready for another message", not "the conversation ended".
final class CodexStreamSession: ConversationStreamSession {

    // MARK: - Properties

    let sessionID: UUID

    var onEvent: ((StreamEvent) -> Void)?
    var onExit: ((Int32) -> Void)?

    private(set) var isRunning = false
    var canSend: Bool { isRunning && process == nil }

    private let plan: () -> AgentLaunchPlan
    private var process: Process?
    private var buffer = Data()
    private var errorBuffer = Data()
    private var receivedTurnFinished = false
    private var isTerminating = false

    // MARK: - Initialization

    init(sessionID: UUID, plan: @escaping () -> AgentLaunchPlan) {
        self.sessionID = sessionID
        self.plan = plan
    }

    // MARK: - Public Methods

    /// Opens the logical conversation. The first child is deferred until there is a prompt,
    /// because `codex exec` consumes exactly one prompt and then exits.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        isTerminating = false
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard canSend else { return false }

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
            self?.received(chunk)
        }

        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.receivedError(chunk)
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
            onEvent?(.turnFinished(text: error.localizedDescription, isError: true))
            return false
        }

        self.process = process

        do {
            try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            try input.fileHandleForWriting.close()
            return true
        } catch {
            SkalmanLogger.agent.error("Codex prompt write failed: \(error.localizedDescription)")
            process.terminate()
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

            guard let line = String(data: lineData, encoding: .utf8) else { continue }

            for event in CodexStreamEvent.parse(line) {
                if case .turnFinished = event { receivedTurnFinished = true }
                DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
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

        if isTerminating {
            isTerminating = false
            onExit?(status)
            return
        }

        // A normal child exit completes one turn; the logical session stays open so the next
        // send can launch `exec resume`. If Codex died before emitting a terminal event, make
        // the failure visible instead of leaving the status stuck on Working.
        guard !receivedTurnFinished else { return }

        let diagnostics = String(data: errorBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = diagnostics?.isEmpty == false
            ? diagnostics
            : (status == 0 ? nil : "Codex exited with status \(status).")

        onEvent?(.turnFinished(text: message, isError: status != 0))
    }
}

enum CodexStreamDefaults {
    /// Stderr is diagnostic fallback only. Capping it prevents a failed child from becoming an
    /// unbounded in-memory log while stdout remains the authoritative event stream.
    static let maximumErrorBytes = 64 * 1024
}
