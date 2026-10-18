import Foundation

/// Sends a subagent's final reply back to the chat that started it, as mail from the subagent.
///
/// A subagent's whole purpose is the answer it brings back, and asking its agent to remember to
/// report is how a parent ends up waiting on prose it never receives (the side chat's report-back
/// needed a one-line tool instruction for exactly that reason). So the host does it: when a turn
/// the subagent did not get from the user completes, its final reply — already captured at the
/// provider's own turn boundary in `CompletedTurnSnapshotStore` — is stored as mail **from the
/// subagent's mailbox** to the parent's. The words are the subagent's own, so the mail's vouched
/// header attributing them to that agent is true; the host authors nothing in the body but a
/// marked cut.
///
/// A turn the user typed into the subagent is the user talking to it, not work the parent asked
/// for, and is not mailed. Origin is read where each surface knows it: the native queue's hand-over
/// and the terminal's `UserPromptSubmit` report, through `MailHumanTurn.isAgentOriginated`. An
/// unknown origin reports, since the brief that opened the chat is the turn the parent is waiting
/// on. A turn that ends without a reply — a limit, an exit — mails nothing; `watch_session`
/// reports those edges.
@MainActor
final class SubagentReportBack {

    // MARK: - Types

    struct Dependencies {
        let session: (SessionID) -> AgentSession?
        /// The active tenure's supervisor, if any. Reports stop when the parent's tenure ends.
        let supervision: (SessionID) -> Supervision?
        /// The latest completed-turn capture. Compared across the turn, because a turn that ends
        /// without a capture leaves the previous turn's in place.
        let snapshot: (SessionID) -> CompletedTurnSnapshot?
        let mail: (_ text: String, _ parentID: SessionID, _ childID: SessionID) -> Void
        let recordReport: (Supervision) -> Void
    }

    // MARK: - Properties

    static let shared = SubagentReportBack(dependencies: Dependencies(
        session: { ProjectStore.shared.session(withID: $0) },
        supervision: { ControlGrantStore.shared.activeManager(of: $0) },
        snapshot: { sessionID in
            let store = CompletedTurnSnapshotStore.shared
            return store.snapshot(
                sessionID: sessionID,
                generation: store.currentGeneration(sessionID: sessionID)
            )
        },
        mail: { text, parentID, childID in
            MacMailDelivery.shared.storeUndeliverable(text, to: parentID, from: childID) { stored in
                guard !stored else { return }
                EventLog.shared.record(.session, "Subagent reply could not be mailed to its parent", [
                    "parent": parentID.uuidString,
                    "child": childID.uuidString,
                ])
            }
        },
        recordReport: { supervision in
            _ = ControlGrantStore.shared.appendEvent(.reportReceived, to: supervision)
        }
    ))

    /// Mail's own bound (`Limits.text` in the controller): UTF-8 bytes, not characters.
    static let maximumMailUTF8Bytes = 32_768
    static let cutNotice = "\n\n[Cut here by Threading at 32 KiB; the full reply is in the subagent's chat.]"

    private let dependencies: Dependencies
    private let observations: AppEventObservations
    private var isStarted = false
    /// Subagents whose turn in flight was typed by a person. Bounded by live subagents: an entry
    /// is replaced at every turn start and removed at the turn's end.
    private var userTurns: Set<SessionID> = []
    /// The capture each subagent's turn in flight began with, so its end mails only a reply
    /// captured during it — never the previous turn's again. Same bound as `userTurns`.
    private var capturesAtTurnStart: [SessionID: CompletedTurnSnapshot] = [:]

    // MARK: - Initialization

    init(center: NotificationCenter = .default, dependencies: Dependencies) {
        self.dependencies = dependencies
        observations = AppEventObservations(center: center)
    }

    // MARK: - Public Methods

    /// Started at launch, beside agent mail: a subagent resumed after a relaunch reports like one
    /// started this run.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        observations.observe(SessionRuntimeDidChange.self) { [weak self] event in
            self?.runtimeChanged(event)
        }
    }

    /// A turn began with `prompt`. Called by both surfaces at the point each knows its prompt;
    /// a no-op for anything that is not a subagent.
    func turnStarted(sessionID: SessionID, prompt: String?) {
        guard dependencies.session(sessionID)?.isSubagent == true else { return }
        if let prompt, !prompt.isEmpty, !MailHumanTurn.isAgentOriginated(prompt) {
            userTurns.insert(sessionID)
        } else {
            userTurns.remove(sessionID)
        }
    }

    /// The mail body for a captured reply: the reply itself, cut at mail's bound on a character
    /// boundary with a marked note. Nil when there is nothing to send.
    static func mailBody(for reply: String?) -> String? {
        guard let reply = reply?.replacingOccurrences(of: "\0", with: ""),
              !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard reply.utf8.count > maximumMailUTF8Bytes else { return reply }
        let budget = maximumMailUTF8Bytes - cutNotice.utf8.count
        var kept = ""
        var used = 0
        for character in reply {
            let size = String(character).utf8.count
            guard used + size <= budget else { break }
            kept.append(character)
            used += size
        }
        return kept + cutNotice
    }

    // MARK: - Private Methods

    private func runtimeChanged(_ event: SessionRuntimeDidChange) {
        let childID = event.sessionID
        if event.transition.beganPendingOutcome, dependencies.session(childID)?.isSubagent == true {
            capturesAtTurnStart[childID] = dependencies.snapshot(childID)
        }
        guard event.transition.completedPendingOutcome else { return }
        let typedByUser = userTurns.remove(childID) != nil
        let captureAtStart = capturesAtTurnStart.removeValue(forKey: childID)
        guard !typedByUser,
              let child = dependencies.session(childID),
              let parentID = child.subagentParentID,
              let supervision = dependencies.supervision(childID),
              supervision.managerID == parentID,
              let capture = dependencies.snapshot(childID),
              capture != captureAtStart,
              let body = Self.mailBody(for: capture.finalAssistantText) else { return }
        dependencies.mail(body, parentID, childID)
        dependencies.recordReport(supervision)
    }
}
