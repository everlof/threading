import Foundation

struct ChangeRequestDraftText: Equatable, Sendable, Codable {
    var title: String
    var body: String
}

/// Writes title/body copy for the pull-request editor with a read-only Codex run.
///
/// Its output is only text. The type has no provider client and no publish method, which makes
/// "AI drafts; a person publishes" an architectural boundary rather than a promise in copy.
enum ChangeRequestTextComposer {
    enum ComposeError: Error {
        case alreadyRunning
        case launchFailed
        case timedOut
        case exitedAbnormally(Int32)
        case noAnswer

        var message: String {
            switch self {
            case .alreadyRunning: return L10n.string("A pull request draft is already being written.")
            case .launchFailed: return L10n.string("Codex could not be launched.")
            case .timedOut: return L10n.string("Drafting the pull request timed out.")
            case .exitedAbnormally(let status):
                return L10n.format("Codex exited with status %lld.", Int64(status))
            case .noAnswer: return L10n.string("Codex returned no pull request draft.")
            }
        }

        var diagnosticCode: String {
            switch self {
            case .alreadyRunning: return "already_running"
            case .launchFailed: return "launch_failed"
            case .timedOut: return "timed_out"
            case .exitedAbnormally: return "exited_abnormally"
            case .noAnswer: return "no_answer"
            }
        }
    }

    @MainActor private static var runningRoots: Set<String> = []
    private static let queue = DispatchQueue(
        label: "codes.threading.change-request-draft",
        qos: .userInitiated
    )

    @MainActor
    static func run(
        seed: ChangeRequestProposalSeed,
        in root: URL,
        completion: @escaping @MainActor @Sendable (
            Result<ChangeRequestDraftText, ComposeError>
        ) -> Void
    ) {
        guard !runningRoots.contains(root.path) else {
            ThreadingLogger.github.notice(
                "Change-request draft composition already running repository=\(root.path, privacy: .private(mask: .hash))"
            )
            completion(.failure(.alreadyRunning))
            return
        }
        let started = DispatchTime.now().uptimeNanoseconds
        ThreadingLogger.github.info(
            "Change-request draft composition started commits=\(seed.commitSubjects.count, privacy: .public) template=\(seed.template != nil, privacy: .public) diff_characters=\(seed.diff.count, privacy: .public) repository=\(root.path, privacy: .private(mask: .hash))"
        )
        runningRoots.insert(root.path)
        let plan = AgentLauncher.codexResearchPlan(
            in: root.path,
            prompt: prompt(seed: seed)
        )

        queue.async {
            let (output, failure) = execute(plan)
            let answer = output
                .flatMap(CommitMessageComposer.finalAgentMessage(fromJSONL:))
                .flatMap(draft(from:))
            DispatchQueue.main.async {
                runningRoots.remove(root.path)
                let elapsedMilliseconds = (
                    DispatchTime.now().uptimeNanoseconds - started
                ) / 1_000_000
                if let failure {
                    ThreadingLogger.github.warning(
                        "Change-request draft composition failed result=\(failure.diagnosticCode, privacy: .public) duration_ms=\(elapsedMilliseconds, privacy: .public) repository=\(root.path, privacy: .private(mask: .hash))"
                    )
                    completion(.failure(failure))
                } else if let answer {
                    ThreadingLogger.github.info(
                        "Change-request draft composition completed duration_ms=\(elapsedMilliseconds, privacy: .public) repository=\(root.path, privacy: .private(mask: .hash))"
                    )
                    completion(.success(answer))
                } else {
                    ThreadingLogger.github.warning(
                        "Change-request draft composition failed result=no_answer duration_ms=\(elapsedMilliseconds, privacy: .public) repository=\(root.path, privacy: .private(mask: .hash))"
                    )
                    completion(.failure(.noAnswer))
                }
            }
        }
    }

    static func prompt(seed: ChangeRequestProposalSeed) -> String {
        var sections = [
            "Draft a pull request title and body for the committed branch diff below.",
            "Return JSON only in this exact shape: {\"title\":\"...\",\"body\":\"...\"}. "
                + "Do not publish anything. Keep the title concise and make the body useful to a reviewer."
        ]
        if !seed.commitSubjects.isEmpty {
            sections.append(
                "Commits:\n" + seed.commitSubjects.map { "- \($0)" }.joined(separator: "\n")
            )
        }
        if let template = seed.template {
            sections.append("Preserve and complete this repository template:\n" + template)
        }
        let boundedDiff = seed.diff.count > ChangeRequestTextDefaults.diffCharacterLimit
            ? String(seed.diff.prefix(ChangeRequestTextDefaults.diffCharacterLimit))
                + "\n… (truncated)"
            : seed.diff
        sections.append("Committed diff:\n" + boundedDiff)
        return sections.joined(separator: "\n\n")
    }

    static func draft(from message: String) -> ChangeRequestDraftText? {
        let unfenced = message
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let start = unfenced.firstIndex(of: "{"),
              let end = unfenced.lastIndex(of: "}"),
              start <= end else { return nil }
        let data = Data(unfenced[start...end].utf8)
        guard var draft = try? JSONDecoder().decode(ChangeRequestDraftText.self, from: data) else {
            return nil
        }
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.title.isEmpty else { return nil }
        draft.title = String(draft.title.prefix(GitHubPullRequestDefaults.titleLimit))
        draft.body = String(draft.body.prefix(GitHubPullRequestDefaults.bodyLimit))
        return draft
    }

    private static func execute(
        _ plan: AgentLaunchPlan
    ) -> (output: String?, failure: ComposeError?) {
        let result: BoundedChildResult
        do {
            result = try BoundedChildProcess.run(
                executable: plan.executable,
                arguments: plan.arguments,
                environment: AgentEnvironment.launchEnvironment(),
                timeout: ChangeRequestTextDefaults.timeout,
                maximumOutputBytes: ChangeRequestTextDefaults.maximumOutputBytes
            )
        } catch {
            ThreadingLogger.github.error(
                "Change-request draft process launch failed executable=\(plan.executable, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return (nil, .launchFailed)
        }

        let output = String(decoding: result.output, as: UTF8.self)
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

enum ChangeRequestTextDefaults {
    static let diffCharacterLimit = 40_000
    static let timeout: TimeInterval = 90
    static let maximumOutputBytes = 8 * 1024 * 1024
}
