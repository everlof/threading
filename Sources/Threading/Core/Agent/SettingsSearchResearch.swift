import Foundation

/// Answers a settings search the term filter could not: one headless agent run reads the
/// settings catalogue over a scoped MCP endpoint and names the pages the query *meant*.
///
/// `CommitMessageComposer`'s pattern, applied to Settings: a read-only one-shot on the default
/// account, stdout and stderr merged into one pipe, the run's final message taken as the
/// answer. Like the other research runs it is manual only — a run spends the user's usage, so
/// the Ask AI button asks for it and nothing fires it automatically. One run at a time:
/// Settings is one surface, so re-entrancy is refused rather than queued.
///
/// Unlike the Codex-only research features this one picks its runtime: the first with
/// `.headlessResearch` and an enabled login answers, so a Claude-only user gets the search a
/// Codex-only user already had.
@MainActor
enum SettingsSearchResearch {

    /// One page the run pointed at, resolved against the catalogue so the UI can trust it.
    struct Match: Equatable {
        let pageID: String
        let title: String
        let symbol: String
        /// The run's own sentence saying why this page answers the query. May be empty.
        let reason: String
    }

    /// What the run replied, before the catalogue has vouched for it.
    struct RawMatch: Decodable, Equatable {
        let page: String
        let reason: String?
    }

    enum ResearchError: Error, Equatable {
        case alreadyRunning
        case unavailable
        case launchFailed
        case timedOut
        case exitedAbnormally(Int32)
        case noAnswer

        var message: String {
            switch self {
            case .alreadyRunning: return "A search is already running."
            case .unavailable: return "No agent with a login can answer this."
            case .launchFailed: return "The agent could not be launched."
            case .timedOut: return "The search timed out."
            case .exitedAbnormally(let status): return "The agent exited with status \(status)."
            case .noAnswer: return "The agent returned no readable answer."
            }
        }
    }

    // MARK: - Properties

    /// The runtime that will answer, or nil when nothing eligible is logged in — which is when
    /// the Ask AI affordance stays hidden. First claimant of `.headlessResearch` with an
    /// enabled login, in declaration order.
    static var provider: AgentKind? {
        AgentKind.allCases.first {
            $0.supports(.headlessResearch) && !AgentAccountDiscovery.accounts(for: $0).isEmpty
        }
    }

    /// Whether a run is in flight, so the button and a second click can refuse politely.
    private(set) static var isRunning = false

    // MARK: - Public Methods

    static func run(
        query: String,
        completion: @escaping @MainActor @Sendable (Result<[Match], ResearchError>) -> Void
    ) {
        guard !isRunning else {
            completion(.failure(.alreadyRunning))
            return
        }
        guard let kind = provider else {
            completion(.failure(.unavailable))
            return
        }

        let scopeSessionID = MCPSessionRegistry.beginAdHoc(
            allowedTools: [MCPBuiltInTool.listSettings.rawValue]
        )
        guard let plan = AgentLauncher.settingsResearchPlan(
            kind: kind,
            sessionID: scopeSessionID,
            prompt: prompt(query: query),
            in: FileManager.default.temporaryDirectory.path
        ) else {
            MCPSessionRegistry.endAdHoc(scopeSessionID)
            completion(.failure(.launchFailed))
            return
        }

        isRunning = true
        queue.async {
            let (output, failure) = execute(plan)
            let answer = output.flatMap { answerText(fromOutput: $0, kind: kind) }

            DispatchQueue.main.async {
                isRunning = false
                MCPSessionRegistry.endAdHoc(scopeSessionID)

                if let failure {
                    completion(.failure(failure))
                } else if let raw = answer.flatMap(rawMatches(fromAnswer:)) {
                    completion(.success(validated(raw)))
                } else {
                    ThreadingLogger.agent.error(
                    "Settings research returned no readable answer (\(output?.count ?? 0, privacy: .public) bytes)"
                    )
                    completion(.failure(.noAnswer))
                }
            }
        }
    }

    // MARK: - Prompt

    /// Internal for the tests: what the run is asked is a decision worth pinning.
    static func prompt(query: String) -> String {
        """
        You are the settings search of Threading, a macOS app hosting coding agents. The \
        user typed the following into the Settings search field, and the literal keyword \
        filter answered nothing useful:

        \(query)

        Call the list_settings tool once to read the catalogue of Threading's Settings \
        pages. Choose the pages — at most \(SettingsResearchDefaults.maximumMatches), most \
        likely first — where the user would actually find what they mean. Judge by intent \
        rather than wording: "stop it flashing when it finishes" is about notifications or \
        motion, whatever words those pages use.

        Reply with only this JSON — no code fences, no prose around it:
        {"matches":[{"page":"<page id>","reason":"<one short sentence, in the user's own \
        language, saying what on that page answers them>"}]}

        If nothing plausibly answers the query, reply {"matches":[]}.
        """
    }

    // MARK: - Answer Reading

    /// The run's final text, dug out of a merged stdout/stderr capture.
    ///
    /// Internal for the tests: each runtime wraps its answer differently, and the wrapper is
    /// the part a CLI release would break.
    static func answerText(fromOutput output: String, kind: AgentKind) -> String? {
        switch kind {
        case .claude:
            return claudeResultEnvelope(fromOutput: output)
        case .codex:
            return CommitMessageComposer.finalAgentMessage(fromJSONL: output)
        case .grok, .openCode, .cursor:
            return nil
        }
    }

    /// The JSON the answer carries, however the model dressed it.
    ///
    /// Direct decode first; failing that, the slice from the first `{` to the last `}` —
    /// which is how a fenced or prefaced reply still yields its object. Internal for the
    /// tests: models fence and preface even when told not to.
    static func rawMatches(fromAnswer answer: String) -> [RawMatch]? {
        struct RawAnswer: Decodable {
            let matches: [RawMatch]
        }

        func decoded(_ text: Substring) -> [RawMatch]? {
            (try? JSONDecoder().decode(RawAnswer.self, from: Data(text.utf8)))?.matches
        }

        if let direct = decoded(answer[...]) { return direct }

        guard let first = answer.firstIndex(of: "{"),
              let last = answer.lastIndex(of: "}"), first < last else { return nil }
        return decoded(answer[first...last])
    }

    /// Keeps only matches the catalogue vouches for, deduplicated and capped.
    ///
    /// A page id is the identity, but a model that read the catalogue sometimes answers with
    /// the title it showed the user — so an unknown id gets one more chance as a title before
    /// it is dropped.
    static func validated(_ raw: [RawMatch]) -> [Match] {
        var seen = Set<String>()
        let matches: [Match] = raw.compactMap { candidate in
            let identifier = candidate.page.trimmingCharacters(in: .whitespacesAndNewlines)
            let page = SettingsPages.page(id: identifier)
                ?? SettingsPages.id(ofTitle: identifier).flatMap { SettingsPages.page(id: $0) }
            guard let page, seen.insert(page.id).inserted else { return nil }

            return Match(
                pageID: page.id,
                title: page.title,
                symbol: page.symbol,
                reason: candidate.reason?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
        return Array(matches.prefix(SettingsResearchDefaults.maximumMatches))
    }

    // MARK: - Private Methods

    private static let queue = DispatchQueue(
        label: "codes.threading.settings-search",
        qos: .userInitiated
    )

    /// Claude's `--output-format json` envelope: the last line that decodes to an object
    /// carrying a `result` string. Line-wise on purpose — the capture merges stderr, so the
    /// envelope cannot be assumed to be the whole output.
    private static func claudeResultEnvelope(fromOutput output: String) -> String? {
        var answer: String?
        for line in output.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                  let result = object[SettingsResearchDefaults.claudeResultKey] as? String,
                  !result.isEmpty else { continue }
            answer = result
        }
        if answer == nil,
           let first = output.firstIndex(of: "{"),
           let last = output.lastIndex(of: "}"), first < last,
           let object = try? JSONSerialization.jsonObject(
               with: Data(output[first...last].utf8)
           ) as? [String: Any],
           let result = object[SettingsResearchDefaults.claudeResultKey] as? String,
           !result.isEmpty {
            // A future CLI pretty-printing the envelope across lines still answers.
            answer = result
        }
        return answer
    }

    /// The process-group runner bounds provider output and records whether its own timeout fired,
    /// rather than guessing from a signal that may have been the child's crash.
    private static func execute(
        _ plan: AgentLaunchPlan
    ) -> (output: String?, failure: ResearchError?) {
        let result: BoundedChildResult
        do {
            result = try BoundedChildProcess.run(
                executable: plan.executable,
                arguments: plan.arguments,
                environment: AgentEnvironment.launchEnvironment(),
                timeout: SettingsResearchDefaults.timeout,
                maximumOutputBytes: SettingsResearchDefaults.maximumOutputBytes
            )
        } catch {
            ThreadingLogger.agent.error(
                "Settings research launch failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return (nil, .launchFailed)
        }

        let output = String(decoding: result.output, as: UTF8.self)
        ThreadingLogger.agent.info(
            "Settings research child finished: \(String(describing: result.termination), privacy: .public), \(result.output.count, privacy: .public) retained output bytes, truncated=\(result.outputWasTruncated, privacy: .public)"
        )

        switch result.termination {
        case .timedOut:
            return (output, .timedOut)
        case .exited(let status) where status != 0:
            return (output, .exitedAbnormally(status))
        case .exited:
            return (output, nil)
        }
    }
}

// MARK: - Research Defaults

enum SettingsResearchDefaults {
    /// More than this stops being an answer and becomes the list the user already had.
    static let maximumMatches = 4

    /// Shorter than the other research runs: a person is watching a spinner in Settings, not
    /// a background task. A fast model answers well inside this; a wedged one should not hold
    /// the pane for a minute and a half.
    static let timeout: TimeInterval = 60
    static let maximumOutputBytes = 8 * 1024 * 1024

    /// The key carrying the reply in Claude's `--print --output-format json` envelope.
    static let claudeResultKey = "result"
}
