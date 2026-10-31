import Foundation
import ThreadingController

// MARK: - Mac Mail Delivery

/// Turns stored mail into something a Mac session notices, per surface, without ever handing a
/// peer's words to the agent as context.
///
/// Sending is storing (`MacMailbox`); this is the separate, per-surface step on the recipient's
/// host that `docs/feature-drafts/agent-mail.md` calls delivery. What reaches an agent is always a
/// **notice** — one host-authored line naming counts, senders and hosts, built by the controller
/// (`mailNotice`) — and the agent reads the text itself with `mail_inbox`, inside the vouched
/// header. So a busy agent learns mail is waiting without the body ever arriving as harness
/// context, and contract item 5 holds on every surface.
///
/// | Surface | On arrival |
/// |---|---|
/// | Native chat, live | `interrupt`: steer the notice into the running turn where the transport can; otherwise, and for `normal`, the notice joins the visible queue. |
/// | Terminal, hooks can answer | Signal an armed idle-wake hook; ordinary hooks announce at tool/turn/prompt boundaries. |
/// | Terminal, hooks cannot answer | Mail stays available through `mail_inbox`; input is never changed. |
/// | Dormant | Nothing; its next launch's `SessionStart` hook (or, for a chat, its first live edge) announces it. |
///
/// An idle agent is not proof of an empty human draft. Terminal delivery belongs exclusively
/// to hooks, including when a native chat changes surface while a mailbox query is in flight.
@MainActor
final class MacMailDelivery {

    // MARK: - Types

    /// What arrival should do for a session, decided from facts alone.
    enum Plan: Equatable {
        case steerNotice
        case queueNotice
        /// A terminal whose own hooks announce mail without touching its input.
        case awaitHooks
        /// A terminal without answering hooks can explicitly read its inbox.
        case awaitInbox
        /// Not running; announced at its next launch.
        case awaitLaunch
    }

    /// The facts `plan` decides from, gathered by the live wrapper.
    struct Facts: Equatable {
        let surface: ControlSessionOverview.Surface
        let answersHooks: Bool
    }

    /// Resolves only the affected session; no terminal input capability belongs to mail delivery.
    @MainActor
    struct Runtime {
        let facts: @MainActor (SessionID) -> Facts
        let chat: @MainActor (SessionID) -> (any AppMessageReceiving)?

        static let live = Runtime(
            facts: { sessionID in
                Facts(
                    surface: SessionMessageDelivery.surface(for: sessionID),
                    answersHooks: ProjectStore.shared.session(withID: sessionID)?.kind.supports(.answeringMailHooks) ?? false
                )
            },
            chat: { AgentRuntime.shared.conversationRuntimeSurface(for: $0) }
        )
    }

    /// What became of a notice offered to a live chat.
    enum ChatNoticeOutcome: Equatable {
        case steered
        case queued
        case notTaken
    }

    // MARK: - Properties

    /// Where host-local session mailboxes are bound. Injected for tests.
    var mailboxes: RemoteSessionMailboxes = .shared

    static let shared = MacMailDelivery(mailbox: .shared)

    private let mailbox: MacMailbox
    private let runtime: Runtime
    private let observations = AppEventObservations()
    /// Sessions seen live in this run, so a session's first live edge can announce mail that
    /// arrived while it was not running. Bounded by the running-session count.
    private var liveSessions: Set<SessionID> = []
    /// Sessions with a notice lookup already in flight, so a burst of edges costs one query.
    private var pending: Set<SessionID> = []
    /// Sessions with a mail wake requested and not yet answered. At most one each.
    private var waking: Set<SessionID> = []
    private var started = false

    // MARK: - Initialization

    init(mailbox: MacMailbox, runtime: Runtime = .live) {
        self.mailbox = mailbox
        self.runtime = runtime
    }

    /// Observes activity edges so mail waiting for a boundary is announced at it.
    func start() {
        guard !started else { return }
        started = true
        observations.observe(SessionActivityDidChange.self) { [weak self] event in
            self?.activityChanged(event.sessionID)
        }
    }

    // MARK: - Rules

    /// The arrival rule, as a pure function of the surface's facts.
    static func plan(for facts: Facts, priority: MailPriority) -> Plan {
        switch facts.surface {
        case .chat:
            return priority == .interrupt ? .steerNotice : .queueNotice
        case .terminal:
            return facts.answersHooks ? .awaitHooks : .awaitInbox
        case .dormant:
            return .awaitLaunch
        }
    }

    /// Offers a notice to a live chat: steered into the running turn when asked and possible,
    /// otherwise queued visibly. Never the body.
    static func offer(_ notice: String, to chat: AppMessageReceiving, steering: Bool) -> ChatNoticeOutcome {
        guard chat.isRunning else { return .notTaken }
        let prompt = ConversationPrompt(text: notice)
        if steering, chat.steerAppMessage(prompt) == .steered { return .steered }
        switch chat.acceptAppMessage(prompt) {
        case .handedToTurn, .queuedBehindTurn: return .queued
        case .refused: return .notTaken
        }
    }

    // MARK: - Arrival

    /// Mail was just stored for a Mac session. Decides and performs this surface's delivery.
    func arrived(for sessionID: SessionID, priority: MailPriority) {
        // A host-local mailbox is announced by its host's own hooks.
        guard !mailboxes.keepsMailOnHost(sessionID) else { return }
        MailIdleWake.shared.arrived(for: sessionID)
        let facts = runtime.facts(sessionID)
        switch Self.plan(for: facts, priority: priority) {
        case .steerNotice, .queueNotice:
            announce(sessionID, event: .postToolUse, steering: priority == .interrupt)
        case .awaitLaunch:
            considerWake(sessionID)
        case .awaitHooks, .awaitInbox:
            break
        }
    }

    // MARK: - Wake

    /// A dormant chat with open mail admitted under a `wake` grant is started in the background
    /// with the notice as its first prompt. Bounds: one wake in flight per session; only native
    /// chats (a terminal waits for its own `SessionStart` hook); the grant's chain token budget
    /// is checked by the store against the usage it has recorded for that chain — on this Mac
    /// none is attributed to chains yet, so a budget does not limit a Mac wake today.
    private func considerWake(_ sessionID: SessionID) {
        guard !waking.contains(sessionID),
              let session = ProjectStore.shared.session(withID: sessionID), !session.isArchived,
              Self.canWake(usesNativeUI: session.usesNativeUI, kind: session.kind) else { return }
        waking.insert(sessionID)
        let mailbox = mailbox
        Task { @MainActor in
            guard await mailbox.wakeCandidate(for: sessionID) != nil,
                  SessionMessageDelivery.surface(for: sessionID) == .dormant,
                  let notice = await mailbox.notice(for: sessionID, event: .sessionStart) else {
                self.waking.remove(sessionID)
                return
            }
            // The notice is spent on the wake; the first live edge must not repeat it.
            self.liveSessions.insert(sessionID)
            NotificationCenter.default.post(MailWakeRequested(sessionID: sessionID, notice: notice))
        }
    }

    static func canWake(usesNativeUI: Bool, kind: AgentKind) -> Bool {
        usesNativeUI && kind.supportsNativeUI
    }

    /// The window's answer. A failed start leaves the mail waiting for the next launch.
    func wakeFinished(_ sessionID: SessionID, launched: Bool) {
        waking.remove(sessionID)
        if !launched {
            liveSessions.remove(sessionID)
            EventLog.shared.record(.mcp, "Mail wake did not start the session", ["session": sessionID.uuidString])
        }
    }

    /// `send_to_session`'s fallback: a message the target's surface could not take now becomes
    /// mail in its mailbox. Already admitted by the control plane, so the store is told the owner
    /// decided (`ownerAdmitted`).
    func storeUndeliverable(
        _ text: String,
        to targetID: SessionID,
        from callerID: SessionID,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let senderName = Self.title(of: callerID)
        let targetName = Self.title(of: targetID)
        let mailbox = mailbox
        let mailboxes = mailboxes
        let callerHosted = mailboxes.binding(for: callerID)
        Task { @MainActor in
            // Asked before routing, not read from this run's bindings: after a relaunch a hosted
            // target has none until something provisions it, and its mail would otherwise land
            // in a Mac mailbox its agent never reads. A host that cannot be asked keeps the mail
            // here, and it moves there when the mailbox is bound.
            let hosted: MailAddress?
            if case .host(let binding) = await mailboxes.resolve(targetID) { hosted = binding.address } else { hosted = nil }
            do {
                // A target whose mailbox lives on its host is queued for that host; its
                // `<macHost>/*` grant stands for the admission the control plane already made.
                let recipient: MailAddress
                if let hosted { recipient = hosted } else { recipient = try await mailbox.register(targetID, name: targetName) }
                if let callerHosted {
                    // A caller whose mailbox lives on its host sends from there, so the reply
                    // reaches the mailbox it reads (the Mac answers no mail tools for it). The
                    // control plane already admitted this pair; a Mac recipient records that as
                    // a grant naming the caller's host address exactly (siblings created after
                    // the caller launched have none yet), so this Mac does not refuse it.
                    if hosted == nil {
                        guard try await mailbox.admitSibling(recipient: recipient, sender: callerHosted.address) else {
                            // The owner revoked this sender on the target: their decision stands.
                            throw ControllerError.forbidden
                        }
                    }
                    _ = try await mailboxes.send(as: callerHosted, to: recipient, text: text)
                    MacMailSync.shared.kick(host: callerHosted.address.host)
                } else {
                    _ = try await mailbox.send(
                        from: callerID, senderName: senderName, to: recipient, id: UUID(), text: text,
                        replyTo: nil, priority: .normal, ownerAdmitted: hosted == nil
                    )
                    if let hosted { MacMailSync.shared.kick(host: hosted.host) }
                }
                completion(true)
                if hosted == nil && callerHosted == nil { self.arrived(for: targetID, priority: .normal) }
            } catch {
                EventLog.shared.record(.mcp, "Undeliverable session message could not be stored as mail", [
                    "target": targetID.uuidString,
                    "reason": MacMailbox.describe(error)
                ])
                completion(false)
            }
        }
    }

    // MARK: - Activity

    func activityChanged(_ sessionID: SessionID) {
        guard runtime.facts(sessionID).surface == .chat else {
            liveSessions.remove(sessionID)
            return
        }
        let firstLiveEdge = liveSessions.insert(sessionID).inserted
        // A chat has no SessionStart hook: its first live edge in this run is where mail
        // that waited for it is announced, all of it, once.
        if firstLiveEdge { announce(sessionID, event: .sessionStart, steering: false) }
        else { announceIfUnannounced(sessionID) }
    }

    /// The boundary delivery: only mail no hook or adapter has announced yet.
    private func announceIfUnannounced(_ sessionID: SessionID) {
        guard !pending.contains(sessionID) else { return }
        pending.insert(sessionID)
        let mailbox = mailbox
        Task { @MainActor in
            let waiting = await mailbox.hasUnannouncedMail(for: sessionID)
            self.pending.remove(sessionID)
            if waiting { self.announce(sessionID, event: .postToolUse, steering: false) }
        }
    }

    private func announce(_ sessionID: SessionID, event: MailNoticeEvent, steering: Bool) {
        let mailbox = mailbox
        Task { @MainActor in
            // Capture the receiving chat before the actor hop. Never redirect a notice to a
            // terminal if this session changes surface while its mailbox is being read.
            guard self.runtime.facts(sessionID).surface == .chat,
                  let chat = self.runtime.chat(sessionID), chat.isRunning else { return }
            guard let notice = await mailbox.notice(for: sessionID, event: event) else { return }
            let outcome = Self.offer(notice, to: chat, steering: steering)
            if outcome == .notTaken {
                EventLog.shared.record(.mcp, "Mail notice not taken by chat", ["session": sessionID.uuidString])
            }
        }
    }

    static func title(of sessionID: SessionID) -> String {
        ProjectStore.shared.session(withID: sessionID)?.displayTitle ?? MacMailDefaults.unnamedSession
    }
}

/// Mail asks the window to start a dormant chat. The notice is its opening prompt.
struct MailWakeRequested: AppEvent {
    static let name = Notification.Name("mailWakeRequested")
    let sessionID: SessionID
    let notice: String
}
