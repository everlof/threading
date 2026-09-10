import Foundation
import ThreadingPTYHostKit

// MARK: - Launch Notice

/// What one launch has to say about the work that outlived the last one.
///
/// Two variants, and they are the two answers `PTYHostReattach` can come back with that a person
/// would want to know about: the daemon kept agents working while Threading was closed, or a
/// restarted daemon could not account for some and they are gone. Everything else the reattach
/// classifies — an ended child, a child held for a conversation that has been deleted — is either
/// an ordinary dormant row or a thing nobody can see, and neither earns a band.
///
/// Deliberately a value rather than a view. The presenter decides where the band lives; this
/// decides whether there is anything to say and what the sentence is, which is the half a test
/// can hold without a window.
enum PTYHostLaunchNotice: Equatable {

    /// `count` sessions the daemon kept running **and this launch got back**. `pending` is how
    /// many it could **not** take back — a terminal that could not be built, or a survey that
    /// came back after the pane had gone.
    ///
    /// The split is the whole point, and it is the bug this case shipped with: `count` used to be
    /// everything the daemon held, so a launch that recovered 31 of 32 said "32 sessions kept
    /// running" and put `Reattach` beside it — a sentence that overstated what came back next to
    /// a button for the one that did not, five minutes after the 31 were plainly live on screen.
    /// A band states what happened; only the part that did not happen earns an action.
    case keptRunning(count: Int, pending: Int)

    /// The daemon restarted and its children went with it (D12: `KeepAlive` restores the service,
    /// not the work). These are still resumable by their agent-assigned identifiers, which is
    /// what `Resume` does; only the turn in flight is lost, which is exactly today's cost.
    case lost([SessionID])

    /// The same loss with the daemon recovery event that owns it. Kept separate from the legacy
    /// case so tests and callers that construct a notice directly remain source-compatible.
    case lostIncident(ids: [SessionID], key: String, detectedAt: Date?)

    // MARK: - Deriving

    /// The band a launch owes, or nil when it owes none.
    ///
    /// **A loss outranks a survival**, and only one band fits: the kept-running sentence is good
    /// news that needs nothing done about it, while the lost one names work that is not coming
    /// back on its own. A launch that saw both says the second, and the journal has both counts.
    static func forLaunch(
        _ plan: PTYHostReattachPlan,
        pending: Int,
        loss: PTYHostLost? = nil
    ) -> PTYHostLaunchNotice? {
        if !plan.lost.isEmpty {
            guard let loss else { return .lost(plan.lost) }
            let key = loss.incidentID.map { "incident:\($0.uuidString)" }
                ?? "legacy:\(loss.since.timeIntervalSince1970):"
                    + plan.lost.map(\.uuidString).sorted().joined(separator: ",")
            return .lostIncident(ids: plan.lost, key: key, detectedAt: loss.detectedAt)
        }
        // A conversation the daemon kept working counts as recovered too. It is not being taken
        // back — its transport cannot be rejoined mid-stream — but it *did* keep running and this
        // launch resumes it from the transcript it wrote, so there is nothing left to press for
        // it. What `pending` names is the other set: terminals the daemon is still holding that
        // this launch did not attach.
        let held = max(0, pending)
        let recovered = max(0, plan.adopt.count - held) + plan.resume.count
        guard recovered > 0 || held > 0 else { return nil }
        return .keptRunning(count: recovered, pending: held)
    }

    // MARK: - Reading

    var count: Int {
        switch self {
        case .keptRunning(let count, _): return count
        case .lost(let sessionIDs), .lostIncident(let sessionIDs, _, _):
            return sessionIDs.count
        }
    }

    /// The sentence the band carries.
    ///
    /// Two clauses rather than one when a launch both recovered work and left some behind,
    /// because they are two different facts and only the second has anything to do.
    var message: String {
        switch self {
        case .keptRunning(let count, let pending):
            let recovered = count == 1
                ? L10n.string("One session kept running while Threading was closed.")
                : L10n.format(
                    "%lld sessions kept running while Threading was closed.",
                    Int64(count)
                )
            guard pending > 0 else { return recovered }
            // A whole sentence rather than a clause, because a launch that recovered nothing
            // shows this one on its own.
            let held = pending == 1
                ? L10n.string("One session could not be taken back.")
                : L10n.format("%lld sessions could not be taken back.", Int64(pending))
            return count > 0 ? "\(recovered) \(held)" : held
        case .lost(let sessionIDs), .lostIncident(let sessionIDs, _, _):
            return sessionIDs.count == 1
                ? L10n.string(
                    "One session was lost when the background session host restarted. Its "
                        + "conversation can be resumed."
                )
                : L10n.format(
                    "%lld sessions were lost when the background session host restarted. Their "
                        + "conversations can be resumed.",
                    Int64(sessionIDs.count)
                )
        }
    }

    /// The band's one answer, or nil when there is nothing left to press.
    var actionTitle: String? {
        switch self {
        case .keptRunning(_, let pending):
            return pending > 0 ? L10n.string("Reattach") : nil
        case .lost, .lostIncident:
            return L10n.string("Resume")
        }
    }

    /// Whether the band reads as a problem or as a fact. A loss is the only one of the two that
    /// went wrong, and the mark's shape says so as well as its ink.
    var isAttention: Bool {
        switch self {
        case .keptRunning: return false
        case .lost, .lostIncident: return true
        }
    }

    var persistentIncidentKey: String? {
        guard case .lostIncident(_, let key, _) = self else { return nil }
        return key
    }
}

// MARK: - The one-shot offer

/// Puts the launch band up, once, and never again in this launch.
///
/// `LaunchRestoration`'s shape and for its reason: the decision is separate from the presenter so
/// it can be tested without a window, and the offer is one-shot because a band about *this
/// launch's* survey has nothing to add the second time — a later survey, run because the user
/// pressed Reattach, is answering a question they just asked rather than announcing one.
///
/// The per-launch offer stays in memory. A loss incident's identity is also remembered in
/// preferences, because a surviving daemon reports the same recovery fact on every connection
/// and reopening Threading must not turn one daemon restart into a fresh warning each time.
@MainActor
final class PTYHostLaunchNoticeCenter {

    // MARK: - Types

    struct Actions {

        /// Puts the band on screen. The closure it is handed performs the band's one answer; the
        /// presenter decides where the band lives and when it goes away.
        var present: (PTYHostLaunchNotice, _ answer: @escaping () -> Void) -> Void

        /// Asks the host again and takes back whatever it is still holding.
        var reattach: () -> Void

        /// Puts the lost conversations back through the ordinary relaunch path.
        var resume: ([SessionID]) -> Void
    }

    // MARK: - Properties

    private let actions: Actions
    private let defaults: UserDefaults

    private static let presentedIncidentKey = "PTYHostLastPresentedLossIncident"

    /// Whether this launch has already said its piece.
    private(set) var hasOffered = false

    // MARK: - Initialization

    init(actions: Actions, defaults: UserDefaults = .standard) {
        self.actions = actions
        self.defaults = defaults
    }

    // MARK: - Public Methods

    /// Offers the band, if there is one to offer and this launch has not already offered one.
    ///
    /// Returns whether it went up, so a caller can journal the difference between "nothing to
    /// say" and "already said".
    @discardableResult
    func offer(_ notice: PTYHostLaunchNotice?) -> Bool {
        guard let notice, !hasOffered else { return false }
        hasOffered = true
        if let key = notice.persistentIncidentKey {
            guard defaults.string(forKey: Self.presentedIncidentKey) != key else { return false }
            defaults.set(key, forKey: Self.presentedIncidentKey)
        }
        actions.present(notice) { [weak self] in
            self?.perform(notice)
        }
        return true
    }

    // MARK: - Private Methods

    private func perform(_ notice: PTYHostLaunchNotice) {
        switch notice {
        case .keptRunning:
            actions.reattach()
        case .lost(let sessionIDs), .lostIncident(let sessionIDs, _, _):
            actions.resume(sessionIDs)
        }
    }
}
