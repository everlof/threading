import Foundation

/// Drafts a commit message from the staged diff, with one headless agent run.
///
/// `ProjectIconResearch`'s pattern, applied to Git Review's composer: a read-only sandboxed
/// `codex exec` one-shot on the default account, stdout and stderr merged into one pipe, the
/// last `agent_message` in the JSONL taken as the answer. Like icon research it is manual
/// only — the run spends the user's usage, so a button asks for it and nothing fires it
/// automatically — and re-entrancy is refused per repository rather than queued.
///
/// The recent subjects travel in the prompt so the draft matches the repository's own voice
/// rather than a generic convention — a `feat:` prefix in a repo of plain sentences is a
/// wrong answer even when it is a good message.
enum CommitMessageComposer {

    enum ComposeError: Error {
        case alreadyRunning
        case launchFailed
        case timedOut
        case exitedAbnormally(Int32)
        case noAnswer

        var message: String {
            switch self {
            case .alreadyRunning: return "A draft is already being written."
            case .launchFailed: return "Codex could not be launched."
            case .timedOut: return "Drafting the message timed out."
            case .exitedAbnormally(let status): return "Codex exited with status \(status)."
            case .noAnswer: return "Codex returned no message."
            }
        }
    }

    /// Repositories with a run in flight, so a second click refuses rather than stacking.
    /// Main-thread only, like the stores.
    @MainActor private static var runningRoots: Set<String> = []

    // MARK: - Public Methods

    @MainActor
    static func run(
        stagedDiff: String,
        recentSubjects: [String],
        in root: URL,
        completion: @escaping @MainActor @Sendable (Result<String, ComposeError>) -> Void
    ) {
        guard !runningRoots.contains(root.path) else {
            completion(.failure(.alreadyRunning))
            return
        }
        runningRoots.insert(root.path)

        let plan = AgentLauncher.codexResearchPlan(
            in: root.path,
            prompt: prompt(stagedDiff: stagedDiff, recentSubjects: recentSubjects)
        )

        queue.async {
            let (output, failure) = execute(plan)
            let answer = output.flatMap(finalAgentMessage(fromJSONL:)).map(cleaned)

            DispatchQueue.main.async {
                runningRoots.remove(root.path)
                if let failure {
                    completion(.failure(failure))
                } else if let answer, !answer.isEmpty {
                    completion(.success(answer))
                } else {
                    completion(.failure(.noAnswer))
                }
            }
        }
    }

    // MARK: - Prompt

    /// Internal for the tests: what the agent is asked is a decision worth pinning.
    static func prompt(stagedDiff: String, recentSubjects: [String]) -> String {
        var sections = [
            "Write a commit message for the staged changes below.",
            "Reply with the commit message only — a single imperative subject line, "
                + "no quotes, no code fences, no explanation."
        ]

        if !recentSubjects.isEmpty {
            sections.append(
                "Match the voice of this repository's recent commit subjects:\n"
                    + recentSubjects.map { "- \($0)" }.joined(separator: "\n")
            )
        }

        let diff = stagedDiff.count > CommitDraftDefaults.diffCharacterCap
            ? String(stagedDiff.prefix(CommitDraftDefaults.diffCharacterCap)) + "\n… (truncated)"
            : stagedDiff
        sections.append("Staged diff:\n" + diff)

        return sections.joined(separator: "\n\n")
    }

    /// Internal for the tests: models still fence, quote, and preface even when told not to.
    /// The first non-empty line survives, stripped of the wrappers.
    static func cleaned(_ message: String) -> String {
        let line = message
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") } ?? ""
        return line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
    }

    // MARK: - Private Methods

    private static let queue = DispatchQueue(
        label: "codes.threading.commit-message",
        qos: .userInitiated
    )

    /// `ProjectIconResearch.execute`'s shape: one merged pipe, a terminate-on-timeout work
    /// item, and the uncaught-signal check that tells our timeout from the child's failure.
    private static func execute(
        _ plan: AgentLaunchPlan
    ) -> (output: String?, failure: ComposeError?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.environment = AgentEnvironment.launchEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            ThreadingLogger.agent.error(
                "Commit draft launch failed: \(error.localizedDescription, privacy: .public)"
            )
            return (nil, .launchFailed)
        }

        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + CommitDraftDefaults.timeout,
            execute: timeout
        )

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()

        let output = String(data: data, encoding: .utf8)
        ThreadingLogger.agent.info(
            "Commit draft child exited: status \(process.terminationStatus), \(data.count) output bytes"
        )

        if process.terminationReason == .uncaughtSignal {
            return (output, .timedOut)
        }
        guard process.terminationStatus == 0 else {
            return (output, .exitedAbnormally(process.terminationStatus))
        }

        return (output, nil)
    }

    /// The last completed `agent_message` in the run's JSONL — the model's final say.
    /// Internal for the tests, unlike its `ProjectIconResearch` twin, because the parsing is
    /// the part a Codex release would break.
    static func finalAgentMessage(fromJSONL output: String) -> String? {
        var message: String?

        for line in output.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                  object["type"] as? String == CommitDraftDefaults.completedEventType,
                  let item = object["item"] as? [String: Any],
                  item["type"] as? String == CommitDraftDefaults.agentMessageItemType,
                  let text = item["text"] as? String, !text.isEmpty else { continue }
            message = text
        }

        return message
    }
}

// MARK: - Composer Defaults

enum CommitDraftDefaults {
    /// Diff beyond this is cut before it travels: a message describes the change, and the
    /// change's shape survives truncation better than the run survives a megabyte of prompt.
    static let diffCharacterCap = 30_000

    /// How many recent subjects ride along as the voice sample.
    static let subjectSampleCount = 10

    static let timeout: TimeInterval = 90

    static let completedEventType = "item.completed"
    static let agentMessageItemType = "agent_message"
}
