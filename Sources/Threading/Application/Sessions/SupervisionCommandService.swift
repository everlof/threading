import Foundation

@MainActor
protocol SupervisionToolProviding: AnyObject {
    var supervisionCommands: SupervisionCommandService { get }
}

@MainActor
extension SupervisionToolProviding {
    func listAccounts(_ arguments: ListAccountsArguments, for sessionID: SessionID) -> MCPToolResult {
        supervisionCommands.listAccounts(arguments, for: sessionID)
    }

    func sessionCost(_ arguments: SessionCostArguments, for sessionID: SessionID) -> MCPToolResult {
        supervisionCommands.sessionCost(arguments, for: sessionID)
    }

    func resumeSession(
        _ arguments: ResumeSessionArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        supervisionCommands.resumeSession(arguments, for: sessionID, completion: completion)
    }

    func spawnSession(
        _ arguments: SpawnSessionArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        supervisionCommands.spawnSession(arguments, for: sessionID, completion: completion)
    }

    func moveSessionToAccount(
        _ arguments: MoveSessionToAccountArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        supervisionCommands.moveSessionToAccount(arguments, for: sessionID, completion: completion)
    }

    func finishWorkspace(
        _ arguments: SessionReferenceArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        supervisionCommands.finishWorkspace(arguments, for: sessionID)
    }

    func adoptSession(_ arguments: AdoptSessionArguments, for sessionID: SessionID) -> MCPToolResult {
        supervisionCommands.adoptSession(arguments, for: sessionID)
    }

    func releaseSession(
        _ arguments: ReleaseSessionArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        supervisionCommands.releaseSession(arguments, for: sessionID)
    }

    func subscribeToChildren(
        _ arguments: SubscribeToChildrenArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        supervisionCommands.subscribeToChildren(arguments, for: sessionID)
    }
}

/// Agent-facing wording and application adapters for the supervision tool family.
/// Policy stays in `WorkspaceControlPlane`; lifecycle mutation stays in the window-owned
/// `SessionCoordinator` reached through `SupervisionActionRegistry`.
@MainActor
final class SupervisionCommandService {
    static let shared = SupervisionCommandService()

    private let projects: ProjectStore
    private let control: WorkspaceControlPlane
    private let grants: ControlGrantStore
    private let subscriptions: SupervisionSubscriptionCenter
    private let usage: AccountUsageService
    private let transcriptUsage: TranscriptUsageService
    private let actions: SupervisionActionRegistry

    init(
        projects: ProjectStore = .shared,
        control: WorkspaceControlPlane = .live,
        grants: ControlGrantStore = .shared,
        subscriptions: SupervisionSubscriptionCenter = .shared,
        usage: AccountUsageService = .shared,
        transcriptUsage: TranscriptUsageService = .shared,
        actions: SupervisionActionRegistry = .shared
    ) {
        self.projects = projects
        self.control = control
        self.grants = grants
        self.subscriptions = subscriptions
        self.usage = usage
        self.transcriptUsage = transcriptUsage
        self.actions = actions
    }

    func listAccounts(
        _ arguments: ListAccountsArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        let actor = ControlActor.agentSession(sessionID)
        if let refusal = control.authorize(actor, operation: .readAccounts) {
            return .failure(refusal.toolWords)
        }
        guard let caller = projects.session(withID: sessionID) else {
            return .failure(ControlRefusal.callerUnknown.toolWords)
        }
        let accounts = AgentAccountDiscovery.accounts(for: caller.kind)
        guard !accounts.isEmpty else {
            return .success("No enabled \(caller.kind.displayName) accounts are available.")
        }
        let candidates = accounts.map {
            LimitEscapeRanking.Candidate(
                accountID: $0.id,
                usage: usage.usage(for: $0),
                limits: CustomLimitSettings.shared.rules(for: $0.id)
            )
        }
        let ranks = Dictionary(uniqueKeysWithValues: LimitEscapeRanking
            .rank(candidates, metering: arguments.model ?? caller.model)
            .enumerated().map { ($0.element.accountID, $0.offset + 1) })
        let exclusions = Dictionary(uniqueKeysWithValues: LimitEscapeRanking
            .exclusions(candidates).map { ($0.accountID, CustomLimitReceipt.holdReason($0.hold)) })

        let rows = accounts.map { account in
            var parts = [
                "- \(account.displayName) — id \(account.id.rawValue)",
                account.handle == caller.accountHandle ? "caller's account" : "other login",
            ]
            switch usage.reading(for: account) {
            case .notFetched:
                parts.append("usage unknown (not fetched)")
            case .failed(let error):
                parts.append("usage unknown (\(error.message))")
            case .current(let value), .stale(let value, _):
                let windows = value.allWindows.map { window -> String in
                    let fraction = window.fraction.map { "\(Int(($0 * 100).rounded()))%" }
                        ?? "unknown"
                    let reset = window.resetsAt.map(Self.iso.string(from:)) ?? "unknown reset"
                    let bound = CustomLimitBounds.effectiveBound(
                        on: window.id,
                        in: CustomLimitSettings.shared.rules(for: account.id),
                        window: window
                    )
                    return "\(window.compactName) \(fraction), resets \(reset), your line \(Int((bound * 100).rounded()))%"
                }
                parts.append(windows.isEmpty ? "usage unknown (no windows)" : windows.joined(separator: "; "))
                if case .stale(_, let error) = usage.reading(for: account) {
                    parts.append("stale: \(error.message)")
                }
            }
            if let rank = ranks[account.id] { parts.append("best rank \(rank)") }
            if let exclusion = exclusions[account.id] {
                parts.append("excluded by your limit: \(exclusion)")
            }
            return parts.joined(separator: " · ")
        }
        return .success(rows.joined(separator: "\n"))
    }

    func sessionCost(
        _ arguments: SessionCostArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        let actor = ControlActor.agentSession(sessionID)
        let targetID: SessionID?
        if arguments.project == true {
            targetID = nil
        } else if let raw = arguments.sessionID {
            guard let parsed = parseSessionID(raw) else { return invalidSessionID() }
            targetID = parsed
        } else {
            targetID = sessionID
        }
        if let refusal = control.authorize(actor, operation: .readUsage, target: targetID) {
            return .failure(refusal.toolWords)
        }
        guard let callerProject = projects.project(forSessionID: sessionID) else {
            return .failure(ControlRefusal.callerUnknown.toolWords)
        }
        guard let report = transcriptUsage.report else {
            transcriptUsage.refresh()
            return .failure("The transcript usage index is not ready. Threading started a refresh; try again when it completes.")
        }

        let cells: [TranscriptUsageReport.Cell]
        let subject: String
        if arguments.project == true {
            let roots = Set(callerProject.sessions.flatMap { session -> [String] in
                [callerProject.folderPath, session.managedWorkspace?.executionPath].compactMap { $0 }
            })
            cells = report.cells.filter { cell in
                roots.contains { cell.checkoutPath == $0 || cell.checkoutPath.hasPrefix($0 + "/") }
            }
            subject = "Project “\(WorkspaceControlPlane.safeHeaderTitle(callerProject.name))”"
        } else {
            guard let targetID, let target = projects.session(withID: targetID) else {
                return .failure(ControlRefusal.targetUnknown.toolWords)
            }
            guard let transcriptID = target.resumeState.transcriptID?.rawValue else {
                return .success("“\(WorkspaceControlPlane.safeHeaderTitle(target.displayTitle))” has no transcript usage identity yet.")
            }
            cells = report.cells.filter { $0.sessionID == transcriptID }
            subject = "“\(WorkspaceControlPlane.safeHeaderTitle(target.displayTitle))”"
        }

        let selection = UsageReportSelection(
            cells: cells,
            range: UsageReportDefaults.maximumDayRange,
            now: Date(),
            calendar: .autoupdatingCurrent
        )
        return .success("""
            \(subject): \(UsageFormat.tokens(selection.tokens.processed)) processed tokens across \
            \(selection.records) priced responses; \(UsageFormat.currency(selection.cost.totalUSD)) \
            priced cost; \(UsageFormat.tokens(selection.cost.unpricedTokens)) unpriced. \
            Range \(Self.iso.string(from: selection.start)) through \(Self.iso.string(from: selection.end)).
            """)
    }

    func resumeSession(
        _ arguments: ResumeSessionArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let targetID = parseSessionID(arguments.sessionID) else {
            return completion(invalidSessionID())
        }
        let actor = ControlActor.agentSession(sessionID)
        if let refusal = control.admitResume(targetID, from: actor) {
            return completion(.failure(refusal.toolWords))
        }
        guard let target = projects.session(withID: targetID), let action = actions.current() else {
            return completion(.failure("The workspace window cannot resume that session."))
        }

        let launch: @MainActor (AgentAccount?) -> Void = { [weak self] destination in
            guard let self else { return completion(.failure("The manager command ended before launch.")) }
            if let destination, destination.handle != target.accountHandle {
                if let refusal = self.control.admitMove(targetID, from: actor) {
                    return completion(.failure(refusal.toolWords))
                }
                switch action.move(targetID, destination, sessionID) {
                case .success: break
                case .failure(let failure): return completion(.failure(failure.words))
                }
            }
            guard action.resume(targetID) else {
                return completion(.failure("“\(target.displayTitle)” could not be resumed in the background."))
            }
            let account = destination ?? AgentAccountDiscovery.account(
                for: target.kind,
                handle: target.accountHandle
            )
            let statement = "Resumed “\(target.displayTitle)” as \(account?.displayName ?? target.accountHandle.name), model \(target.model ?? "default")."
            let brief = (arguments.brief ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !brief.isEmpty else { return completion(.success(statement)) }
            self.control.send(brief, to: targetID, from: actor) { outcome in
                completion(.success(statement + " " + self.sendWords(outcome)))
            }
        }

        guard let requested = arguments.account, !requested.isEmpty else { return launch(nil) }
        resolveAccount(
            requested,
            provider: target.kind,
            model: target.model,
            excluding: target.accountHandle
        ) { result in
            switch result {
            case .success(let resolved): launch(resolved.account)
            case .failure(let failure): completion(.failure(failure.words))
            }
        }
    }

    func spawnSession(
        _ arguments: SpawnSessionArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let brief = (arguments.brief ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { return completion(.failure("Provide a brief for the child session.")) }
        guard let manager = projects.session(withID: sessionID),
              let project = projects.project(forSessionID: sessionID),
              let action = actions.current() else {
            return completion(.failure(ControlRefusal.callerUnknown.toolWords))
        }
        let requested = arguments.plan?.account
        let build: @MainActor (AgentAccount) -> Void = { [weak self] account in
            guard let self else { return completion(.failure("The manager command ended before launch.")) }
            let plan = ScheduledSessionPlan(
                projectID: project.id,
                kind: arguments.plan?.kind ?? manager.kind,
                accountHandle: account.handle,
                model: arguments.plan?.model ?? manager.model,
                reasoningEffort: arguments.plan?.reasoningEffort ?? manager.reasoningEffort,
                fastMode: arguments.plan?.fastMode ?? manager.fastMode,
                branch: arguments.plan?.branch,
                usesNativeUI: arguments.plan?.usesNativeUI ?? true,
                permissionMode: arguments.plan?.permissionMode ?? manager.permissionMode,
                managedWorkspacePlan: arguments.plan?.managedWorkspacePlan
            )
            if let refusal = self.control.admitSpawn(plan, from: .agentSession(sessionID)) {
                return completion(.failure(refusal.toolWords))
            }
            let parentID: SessionID?
            if let raw = arguments.asSideChatOf {
                guard let parsed = self.parseSessionID(raw) else { return completion(self.invalidSessionID()) }
                if let refusal = self.control.authorize(
                    .agentSession(sessionID), operation: .spawnSession, target: parsed
                ) { return completion(.failure(refusal.toolWords)) }
                parentID = parsed
            } else {
                parentID = nil
            }
            switch action.spawn(plan, brief, parentID, sessionID) {
            case .success(let child):
                completion(.success("Started “\(child.displayTitle)” (\(child.id.uuidString.lowercased())) as \(account.displayName), model \(child.model ?? "default"), and recorded it as your child."))
            case .failure(let failure):
                completion(.failure(failure.words))
            }
        }
        resolveAccount(
            requested ?? manager.accountHandle.name,
            provider: arguments.plan?.kind ?? manager.kind,
            model: arguments.plan?.model ?? manager.model,
            excluding: nil
        ) { result in
            switch result {
            case .success(let resolved): build(resolved.account)
            case .failure(let failure): completion(.failure(failure.words))
            }
        }
    }

    func moveSessionToAccount(
        _ arguments: MoveSessionToAccountArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let targetID = parseSessionID(arguments.sessionID) else {
            return completion(invalidSessionID())
        }
        let actor = ControlActor.agentSession(sessionID)
        if let refusal = control.admitMove(targetID, from: actor) {
            return completion(.failure(refusal.toolWords))
        }
        guard let target = projects.session(withID: targetID),
              let accountID = arguments.accountID,
              !accountID.isEmpty,
              let action = actions.current() else {
            return completion(.failure("Provide account_id from list_accounts."))
        }
        resolveAccount(
            accountID,
            provider: target.kind,
            model: target.model,
            excluding: target.accountHandle
        ) { result in
            switch result {
            case .failure(let failure): completion(.failure(failure.words))
            case .success(let resolved):
                switch action.move(targetID, resolved.account, sessionID) {
                case .failure(let failure): completion(.failure(failure.words))
                case .success(let source):
                    let reason = resolved.ranking.map {
                        " Best chose its \($0.decidingWindowName) window."
                    } ?? ""
                    completion(.success("Moved “\(target.displayTitle)” from \(source) to \(resolved.account.displayName); it remains dormant.\(reason)"))
                }
            }
        }
    }

    func finishWorkspace(
        _ arguments: SessionReferenceArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        guard let targetID = parseSessionID(arguments.sessionID) else { return invalidSessionID() }
        if let refusal = control.admitFinish(targetID, from: .agentSession(sessionID)) {
            return .failure(refusal.toolWords)
        }
        guard actions.current()?.finish(targetID, sessionID) == true,
              let target = projects.session(withID: targetID) else {
            return .failure("The managed workspace could not begin its finish handshake.")
        }
        return .success("“\(target.displayTitle)” began the same managed-workspace finish handshake its own agent uses.")
    }

    func adoptSession(_ arguments: AdoptSessionArguments, for sessionID: SessionID) -> MCPToolResult {
        guard let targetID = parseSessionID(arguments.sessionID) else { return invalidSessionID() }
        let brief = (arguments.brief ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { return .failure("Provide the brief this manager owns for the chat.") }
        switch control.adopt(targetID, brief: brief, from: .agentSession(sessionID)) {
        case .adopted(let supervision):
            return .success("Adopted \(supervision.childID.uuidString.lowercased()) with a durable supervision record.")
        case .alreadyManaged:
            return .success("That chat is already managed by this session; its existing brief is unchanged.")
        case .released:
            return .failure("The supervision changed before it could be recorded.")
        case .refused(let refusal):
            return .failure(refusal.toolWords)
        }
    }

    func releaseSession(_ arguments: ReleaseSessionArguments, for sessionID: SessionID) -> MCPToolResult {
        guard let targetID = parseSessionID(arguments.sessionID) else { return invalidSessionID() }
        switch control.release(targetID, outcome: arguments.outcome, from: .agentSession(sessionID)) {
        case .released:
            return .success("Released that child. Its chat and any managed workspace remain available to the user.")
        case .adopted, .alreadyManaged:
            return .failure("The supervision changed before it could be released.")
        case .refused(let refusal):
            return .failure(refusal.toolWords)
        }
    }

    func subscribeToChildren(
        _ arguments: SubscribeToChildrenArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        let actor = ControlActor.agentSession(sessionID)
        if let raw = arguments.sessionID {
            guard let childID = parseSessionID(raw) else { return invalidSessionID() }
            if let refusal = control.authorize(actor, operation: .subscribeToChildren, target: childID) {
                return .failure(refusal.toolWords)
            }
            guard subscriptions.subscribe(managerID: sessionID, childID: childID) else {
                return .failure("That chat is not an active child of this manager.")
            }
            return .success("Subscribed to that child's settle, exit, attention, limit, finish and archive events for this app run.")
        }
        if let refusal = control.authorize(actor, operation: .subscribeToChildren) {
            return .failure(refusal.toolWords)
        }
        let children = grants.activeChildren(of: sessionID)
        let count = children.filter {
            subscriptions.subscribe(managerID: sessionID, childID: $0.childID)
        }.count
        return .success("Subscribed to \(count) active child chat\(count == 1 ? "" : "s") for this app run.")
    }

    private struct ResolvedAccount {
        let account: AgentAccount
        let ranking: LimitEscapeRanking.Ranked?
    }

    private func resolveAccount(
        _ raw: String,
        provider: AgentKind,
        model: String?,
        excluding handle: AccountHandle?,
        completion: @escaping @MainActor (
            Result<ResolvedAccount, SupervisionActionFailure>
        ) -> Void
    ) {
        let accounts = AgentAccountDiscovery.accounts(for: provider).filter { $0.handle != handle }
        guard !accounts.isEmpty else {
            return completion(.failure(.init(
                "No other enabled \(provider.displayName) account is available."
            )))
        }
        let requested = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [AgentAccount]
        if requested.caseInsensitiveCompare("best") == .orderedSame {
            candidates = accounts
        } else {
            guard let match = accounts.first(where: {
                $0.id.rawValue.caseInsensitiveCompare(requested) == .orderedSame
                    || $0.handle.name.caseInsensitiveCompare(requested) == .orderedSame
                    || $0.displayName.caseInsensitiveCompare(requested) == .orderedSame
            }) else {
                return completion(.failure(.init(ControlRefusal.accountUnknown.toolWords)))
            }
            candidates = [match]
        }

        var remaining = candidates.count
        for account in candidates {
            usage.refresh(account, force: true) { [weak self] in
                guard let self else { return }
                remaining -= 1
                guard remaining == 0 else { return }
                let values = candidates.map {
                    LimitEscapeRanking.Candidate(
                        accountID: $0.id,
                        usage: self.usage.usage(for: $0),
                        limits: CustomLimitSettings.shared.rules(for: $0.id)
                    )
                }
                if requested.caseInsensitiveCompare("best") == .orderedSame {
                    guard let ranked = LimitEscapeRanking.best(among: values, metering: model),
                          let account = candidates.first(where: { $0.id == ranked.accountID }) else {
                        let exclusions = LimitEscapeRanking.exclusions(values)
                        let words = exclusions.map {
                            "\($0.accountID.rawValue) excluded by your limit: \(CustomLimitReceipt.holdReason($0.hold))"
                        }.joined(separator: "; ")
                        return completion(.failure(.init(words.isEmpty
                            ? "No enabled account has a fresh reading with headroom. Unknown and stale readings are not treated as capacity."
                            : words)))
                    }
                    return completion(.success(.init(account: account, ranking: ranked)))
                }
                guard let account = candidates.first,
                      case .current = self.usage.reading(for: account) else {
                    return completion(.failure(.init(
                        "Usage for that account is stale or unknown after refresh, so Threading did not move work onto it."
                    )))
                }
                let candidate = values[0]
                guard LimitEscapeRanking.hasHeadroom(candidate, metering: model) else {
                    let exclusion = LimitEscapeRanking.exclusions(values).first
                    return completion(.failure(.init(exclusion.map {
                        "That account is excluded by your limit: \(CustomLimitReceipt.holdReason($0.hold))"
                    } ?? "That account has no fresh metering window with headroom.")))
                }
                completion(.success(.init(account: account, ranking: nil)))
            }
        }
    }

    private func parseSessionID(_ raw: String?) -> SessionID? {
        raw.flatMap { SessionID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func invalidSessionID() -> MCPToolResult {
        .failure("session_id must be a Threading UUID from list_sessions.")
    }

    private func sendWords(_ outcome: ControlSendOutcome) -> String {
        switch outcome {
        case .sent: return "The brief was delivered as its next turn."
        case .queued: return "The brief is visible behind its current turn."
        case .typedUnconfirmed: return "The brief was typed, but the terminal did not confirm a turn."
        case .steered: return "The brief joined its current turn."
        case .refused(let refusal): return "The session launched, but the brief was refused: \(refusal.toolWords)"
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
