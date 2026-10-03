import Foundation

/// The permission authority of an unattended automation run, keyed by the session it runs in.
///
/// A permission card in a session nobody is watching does not protect anything: it stops the run
/// until its curfew. So while a run is active, `PermissionBroker` asks this instead of anyone,
/// and every answer is immediate — allowed when the approved revision's policy allows it, denied
/// with a reason the agent can read otherwise. The authority is the revision the person approved
/// on the host sheet; nothing in the project folder can widen it.
///
/// Registered when `TriggerStore.claimDispatch` reserves the run's session — before anything is
/// launched in it — and again when a fix stage is recovered after a relaunch. Kept main-actor and
/// synchronous, because the broker answers a hook that is holding a tool call open. It is cleared
/// as soon as the store reports the run is no longer active, so a person who later opens that
/// chat and keeps working gets the ordinary cards again.
@MainActor
enum UnattendedRunPermissions {

    struct Registration: Equatable {
        let policy: AutomationPermissionPolicy
        /// Named in every reason, so the audit says which approved revision decided.
        let revisionSequence: Int
    }

    private static var registrations: [SessionID: Registration] = [:]
    private static var observer: NSObjectProtocol?

    /// Run states in which the run still owns its session.
    static let activeRunStates: Set<TriggerRunState> = [
        .received, .assessing, .fixQueued, .fixing, .running, .finishing
    ]

    static func register(_ revision: TriggerRevision, for sessionID: SessionID) {
        register(Registration(policy: revision.effectivePermissions, revisionSequence: revision.sequence),
                 for: sessionID)
    }

    static func register(_ registration: Registration, for sessionID: SessionID) {
        registrations[sessionID] = registration
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .triggersDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { reconcile() }
        }
    }

    static func registration(for sessionID: SessionID) -> Registration? {
        registrations[sessionID]
    }

    static func unregister(_ sessionID: SessionID) {
        registrations.removeValue(forKey: sessionID)
    }

    /// Drops registrations whose run has settled. Asynchronous because the store is an actor;
    /// a registration only ever *narrows* to cards, so a late removal is never a widening.
    static func reconcile(store: TriggerStore = .shared) {
        let sessions = Array(registrations.keys)
        guard !sessions.isEmpty else { return }
        Task { @MainActor in
            for sessionID in sessions {
                let run = try? await store.run(sessionID: sessionID)
                if let run, activeRunStates.contains(run.state) { continue }
                registrations.removeValue(forKey: sessionID)
            }
        }
    }

    // MARK: Decisions

    /// The answer for one call of a registered run. Pure apart from its arguments, so the whole
    /// matrix is testable without a session, a store or a window.
    ///
    /// `mode` is the stage's provider mode and `workingDirectory` the folder the run executes in,
    /// both read by the broker when the call arrives. A stage that may not edit (an assessment, a
    /// read-only task) gets read-only answers whatever the policy says: the policy widens what an
    /// editing stage may do without asking, never what a read-only stage may do at all.
    static func decision(
        for request: PermissionRequest,
        under registration: Registration,
        mode: AgentPermissionMode?,
        workingDirectory: String?,
        systemGrantStatus: (SystemPrivacyPermission) -> SystemPrivacyStatus?
    ) -> PermissionDecision {
        let revision = registration.revisionSequence
        let editing = mode == .acceptEdits || mode == .bypassPermissions

        // A macOS dialog would sit on a screen nobody is watching and name Threading for it, so
        // even full permission does not let a call raise one.
        if let grant = SystemGrantForecast.grant(for: request), systemGrantStatus(grant) == .notAllowed {
            return .deny(reason:
                "This would raise the macOS \(grant.englishName) permission prompt, and nobody is "
                    + "there to answer it during an unattended automation run (revision \(revision)).")
        }

        if registration.policy.isFull, editing {
            return .allow(reason: "Full permission, approved in automation revision \(revision).")
        }

        if PermissionPolicy.isAutoAllowed(request.tool) {
            return .allow(reason: "Read-only tool, allowed automatically by Threading.")
        }

        let rules = registration.policy.rules
        switch request.tool {
        case .bash:
            return shellDecision(request.shellCommand, rules: rules, revision: revision)

        case .write, .edit, .multiEdit, .notebookEdit:
            return fileDecision(request, rules: rules, revision: revision,
                                editing: editing, workingDirectory: workingDirectory)

        case .webFetch:
            let host = request.input["url"]?.stringValue.flatMap { URL(string: $0)?.host?.lowercased() }
            if let host, let rule = rules.first(where: { $0 == .webFetch(domain: host) }) {
                return allowed(by: rule, revision: revision)
            }
            return refused("fetching \(host ?? "this address")", revision: revision)

        case .mcp(let name):
            if let rule = rules.first(where: { $0 == .mcpTool(name) }) {
                return allowed(by: rule, revision: revision)
            }
            return refused("the tool \(name)", revision: revision)

        default:
            return refused("the tool \(request.toolName)", revision: revision)
        }
    }

    private static func shellDecision(
        _ command: String?, rules: [AutomationPermissionRule], revision: Int
    ) -> PermissionDecision {
        guard let command, let segments = ShellCommandPolicy.segments(ofVettable: command) else {
            return .deny(reason:
                "Unattended automation runs only run simple commands: no redirection (> <), "
                    + "substitution ($ or backticks), backgrounding or newlines "
                    + "(automation revision \(revision)).")
        }
        var used: [AutomationPermissionRule] = []
        for segment in segments {
            if ShellCommandPolicy.isReadOnlySegment(segment) { continue }
            let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let rule = rules.first(where: { rule in
                if case .shell(let pattern) = rule { return pattern.matches(words: words) }
                return false
            }) else {
                return refused("“\(segment)”", revision: revision)
            }
            used.append(rule)
        }
        guard !used.isEmpty else {
            return .allow(reason: "Read-only command, allowed automatically by Threading.")
        }
        return .allow(reason: "Allowed by automation revision \(revision): "
            + used.map(\.text).joined(separator: ", ") + ".")
    }

    private static func fileDecision(
        _ request: PermissionRequest, rules: [AutomationPermissionRule], revision: Int,
        editing: Bool, workingDirectory: String?
    ) -> PermissionDecision {
        // A rule never turns a read-only stage into one that writes: in those modes the CLI is
        // meant to refuse edits, and an allow from this hook would override it.
        guard editing else {
            return .deny(reason: "This stage of the automation run is read-only (revision \(revision)).")
        }
        guard let path = normalized(request.filePath, relativeTo: workingDirectory) else {
            return refused("changing a file it cannot name", revision: revision)
        }
        if let folder = workingDirectory.flatMap({ normalized($0, relativeTo: nil) }),
           path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") {
            return .allow(reason: "Local edit inside the automation's project folder (revision \(revision)).")
        }
        if let rule = rules.first(where: { rule in
            if case .fileWrite(let pattern) = rule { return pattern.matches(path) }
            return false
        }) {
            return allowed(by: rule, revision: revision)
        }
        return refused("changing \(path)", revision: revision)
    }

    /// An absolute path with `.` and `..` resolved by name alone. No filesystem access: this
    /// runs on the main actor while a hook holds the tool call open.
    static func normalized(_ path: String?, relativeTo folder: String?) -> String? {
        guard var path, !path.isEmpty else { return nil }
        if !path.hasPrefix("/") {
            guard let folder, folder.hasPrefix("/") else { return nil }
            path = folder + "/" + path
        }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func allowed(by rule: AutomationPermissionRule, revision: Int) -> PermissionDecision {
        .allow(reason: "Allowed by automation revision \(revision): \(rule.text).")
    }

    private static func refused(_ what: String, revision: Int) -> PermissionDecision {
        .deny(reason:
            "Not in this automation's allow-list (revision \(revision)): \(what). Unattended runs "
                + "cannot ask a person; continue without it, or report needsHuman if the task needs it.")
    }
}
