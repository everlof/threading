import Foundation

// MARK: - Permission Broker

/// Decides whether a headless session's tool call may proceed.
///
/// A headless Claude has nowhere to ask, so it blocks anything that would normally prompt.
/// A `PreToolUse` hook is pointed at Threading's own HTTP listener instead: the hook holds the
/// tool call open while the app asks the user, then carries the answer back. That restores
/// the terminal's behaviour rather than trading it for a blanket `bypassPermissions`.
@MainActor
enum PermissionBroker {

    // MARK: - Properties

    /// Asks the user. Set by the window controller, which owns the sheet.
    ///
    /// Nil means nothing can present, so requests are denied rather than hanging: a session
    /// whose window has gone away must not leave the CLI blocked forever.
    static var present: (
        (
            PermissionRequest,
            @escaping @MainActor @Sendable (PermissionDecision) -> Void
        ) -> Void
    )?

    /// Says what macOS is about to ask for and who caused it, before the call that raises the
    /// system prompt runs. Set alongside `present` by the same window controller.
    ///
    /// Nil is not a denial: an unexplained system prompt is what happens today, and losing the
    /// explanation must not also lose the tool call.
    static var explainSystemGrant: (
        (
            SystemPrivacyPermission,
            PermissionRequest,
            @escaping @MainActor @Sendable (Bool) -> Void
        ) -> Void
    )?

    /// Reads a grant without requesting it. Injected so a test states the machine's answer
    /// instead of inheriting whatever this Mac has approved in System Settings.
    static var systemGrantStatus: (SystemPrivacyPermission) -> SystemPrivacyStatus? = { permission in
        SystemPrivacyStatusReader().immediateStatus(of: permission)
    }

    /// Tools the user chose to stop being asked about, per session.
    private static var alwaysAllowed: [SessionID: Set<ToolIdentity>] = [:]

    /// Grants the user has already been briefed on and waved through.
    ///
    /// App-wide and for the life of the process, because the grant is app-wide: macOS asks
    /// Threading once, not once per session. The set only matters in one case — the user let
    /// the command run and then pressed Deny on the *system* prompt. macOS remembers that and
    /// never asks again, so without this the next `screencapture` would be briefed forever for
    /// a dialog that can no longer appear. Every other outcome is settled by the status read:
    /// an approved grant reads `.allowed` and forecasts nothing, and a briefing the user
    /// declined leaves the tool unrun, so there is nothing yet to have been asked about.
    private static var briefedGrants: Set<SystemPrivacyPermission> = []

    // MARK: - Public Methods

    /// Resolves one hook request, calling back with the decision.
    ///
    /// Runs on the main queue: it reaches the model layer and may put a sheet on screen.
    static func decide(
        _ request: PermissionRequest,
        completion: @escaping @MainActor @Sendable (PermissionDecision) -> Void
    ) {
        ExecutionAuditStore.shared.recordPermissionRequest(request)
        let auditedCompletion: @MainActor @Sendable (PermissionDecision) -> Void = { decision in
            ExecutionAuditStore.shared.recordPermissionDecision(decision, for: request)
            completion(decision)
        }

        // An unattended automation run has nobody to ask, so its approved revision answers every
        // call at once — including a call that would raise a macOS prompt, which it refuses rather
        // than briefing. Checked first: a card here would only stop the run until its curfew.
        if let registration = UnattendedRunPermissions.registration(for: request.sessionID) {
            auditedCompletion(UnattendedRunPermissions.decision(
                for: request,
                under: registration,
                mode: permissionMode(for: request.sessionID),
                workingDirectory: ProjectStore.shared.workingDirectory(forSessionID: request.sessionID),
                systemGrantStatus: systemGrantStatus
            ))
            return
        }

        // A terminal reaches this hook only because an unattended run owned it at launch
        // (`AgentLauncher.brokersTerminalRun`). Once that run has settled the process may live on
        // with the person at its prompt, and the CLI's own permission prompt is the one they can
        // see and answer there; a card would ask the same question a second time, elsewhere.
        if case .toolHook = request.origin,
           ProjectStore.shared.session(withID: request.sessionID)?.usesNativeUI == false {
            auditedCompletion(.deferToAgent(
                reason: "A terminal session answers its own permission prompts."
            ))
            return
        }

        // Ahead of every other rule, including the modes that promise not to interrupt. What
        // follows is not one of Threading's permission questions — it is the only warning the
        // user will get that *macOS* is about to put a dialog on their screen naming Threading
        // for something an agent did. No mode Threading offers can promise the system stays
        // quiet, so none of them is a reason to let that dialog arrive unexplained.
        if let grant = foreseenSystemGrant(for: request) {
            brief(grant, before: request, completion: auditedCompletion)
            return
        }

        decideIgnoringSystemGrant(request, completion: auditedCompletion)
    }

    // MARK: - System Grants

    /// The macOS grant this call is about to be stopped by, when there is one worth naming.
    ///
    /// Three conditions, and each removes a way of being annoying: the command has to be one
    /// that needs a grant, the grant has to be one Threading can *read* — so the system prompt
    /// is certain rather than guessed at — and it has to not have been raised already. A
    /// session that refuses everything is excluded too: its call is about to be denied, and
    /// explaining a dialog that will never appear is the interruption this exists to prevent.
    private static func foreseenSystemGrant(
        for request: PermissionRequest
    ) -> SystemPrivacyPermission? {
        guard let grant = SystemGrantForecast.grant(for: request),
              !briefedGrants.contains(grant),
              systemGrantStatus(grant) == .notAllowed,
              briefingApplies(in: permissionMode(for: request.sessionID)) else { return nil }
        return grant
    }

    /// Whether a session's mode leaves anything for a briefing to be about.
    ///
    /// Only `dontAsk` is excluded, and the reason is not politeness. Approving a briefing *is*
    /// the tool's approval, so briefing a `dontAsk` session would turn the one mode that
    /// promises to refuse rather than interrupt into an allow — the mode inverted by the
    /// feature meant to warn about a dialog its call was never going to reach. Every other mode
    /// is briefed, including `bypassPermissions`: no mode Threading offers can promise macOS
    /// stays quiet, so none of them is a reason to let a system dialog arrive unexplained.
    ///
    /// Pure, so the matrix is testable without a store or a sheet.
    static func briefingApplies(in mode: AgentPermissionMode?) -> Bool {
        mode != .dontAsk
    }

    /// Explains the coming system prompt, then lets the call through or refuses it.
    ///
    /// Approving here *is* the tool's approval — the card already showed the command, the
    /// session and the agent, which is strictly more than the ordinary permission card shows.
    /// A second sheet immediately behind the first would be the app asking twice about one
    /// decision, which is how people learn to click through both.
    ///
    /// It is not a standing approval: `allowAlways` is a choice the user makes in words, and
    /// nothing here offers it.
    private static func brief(
        _ grant: SystemPrivacyPermission,
        before request: PermissionRequest,
        completion: @escaping @MainActor @Sendable (PermissionDecision) -> Void
    ) {
        guard let explainSystemGrant else {
            // Nothing to explain with. The prompt arrives unexplained, as it does today — which
            // is worse than the sheet and far better than the call vanishing.
            decideIgnoringSystemGrant(request, completion: completion)
            return
        }

        // The reasons are the model's, not the user's, and stay in English alongside the rest
        // of this file's — they are read by an agent deciding what to do next, not shown in the
        // interface. Naming the grant is what lets it stop retrying and say why.
        explainSystemGrant(grant, request) { proceed in
            guard proceed else {
                completion(.deny(reason:
                    "The user declined to let this raise the macOS "
                        + "\(grant.englishName) permission prompt."))
                return
            }
            briefedGrants.insert(grant)
            completion(.allow(reason:
                "Approved in Threading, which told the user macOS will ask for "
                    + "\(grant.englishName) next."))
        }
    }

    /// The ordinary decision, with the forecast already spent. Split out so `decide` cannot
    /// re-enter its own first branch and brief the same call forever.
    private static func decideIgnoringSystemGrant(
        _ request: PermissionRequest,
        completion: @escaping @MainActor @Sendable (PermissionDecision) -> Void
    ) {
        if let decision = automaticDecision(for: request) {
            completion(decision)
            return
        }

        guard let present else {
            completion(.deny(reason: "Threading has no window available to ask for permission."))
            return
        }

        present(request, completion)
    }

    /// The ordinary policy that can change while a request waits behind another approval.
    /// Kept separate from system-grant briefing so the UI queue can safely re-check it without
    /// forecasting or presenting the macOS dialog twice.
    static func automaticDecision(for request: PermissionRequest) -> PermissionDecision? {
        let session = ProjectStore.shared.session(withID: request.sessionID)
        return PermissionPolicy.automaticDecision(
            for: request,
            allowedForSession: alwaysAllowed[request.sessionID] ?? [],
            mode: session.flatMap(AgentLauncher.permissionMode(for:)),
            kind: session?.kind,
            builtInMCPTool: MCPDefaults.isBuiltInAllowedToolName
        )
    }

    /// Forgets which grants have been briefed. For tests, which must not inherit a set left
    /// standing by whichever test ran before them.
    static func discardSystemGrantBriefings() {
        briefedGrants.removeAll()
    }

    // MARK: - Private Methods

    /// The mode this session is running under, resolved the same way its launch resolved it.
    ///
    /// Read from the store rather than remembered at launch, so a mode changed mid-session
    /// applies to the next tool call. That is a deliberate difference from the *flags*, which
    /// only a relaunch can restate: this layer is Threading's own and has no such excuse.
    static func permissionMode(for sessionID: SessionID) -> AgentPermissionMode? {
        guard let session = ProjectStore.shared.session(withID: sessionID) else { return nil }
        return AgentLauncher.permissionMode(for: session)
    }

    /// Records that a tool should stop prompting for the rest of a session.
    static func allowAlways(toolName: String, for sessionID: SessionID) {
        alwaysAllowed[sessionID, default: []].insert(ToolIdentity(toolName))
    }

    /// Forgets a session's standing approvals, so a resumed conversation starts asking again.
    static func discard(sessionID: SessionID) {
        alwaysAllowed.removeValue(forKey: sessionID)
    }
}

// MARK: - Permission Policy

extension PermissionPolicy {

    static func isAutoAllowed(_ toolName: String) -> Bool {
        isAutoAllowed(ToolIdentity(toolName))
    }

    /// Threading's own MCP display tools are the Mac host's to name, so the portable rule is
    /// answered here with this host's built-in inventory.

    static func isAutoAllowed(_ tool: ToolIdentity) -> Bool {
        isAutoAllowed(tool, builtInMCPTool: MCPDefaults.isBuiltInAllowedToolName)
    }
}
