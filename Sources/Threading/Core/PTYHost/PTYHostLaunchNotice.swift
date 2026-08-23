import Foundation

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

    /// `threading-ptyd` kept `count` sessions running. `pending` is how many of them this launch
    /// has **not** taken back — a terminal that could not be built, or a survey that came back
    /// after the pane had gone. Zero is the ordinary case and the band then states a fact and
    /// offers no action: after the reattach they are ordinary running sessions, and the only
    /// thing left worth saying is that they never stopped.
    case keptRunning(count: Int, pending: Int)

    /// The daemon restarted and its children went with it (D12: `KeepAlive` restores the service,
    /// not the work). These are still resumable by their agent-assigned identifiers, which is
    /// what `Resume` does; only the turn in flight is lost, which is exactly today's cost.
    case lost([SessionID])

    // MARK: - Deriving

    /// The band a launch owes, or nil when it owes none.
    ///
    /// **A loss outranks a survival**, and only one band fits: the kept-running sentence is good
    /// news that needs nothing done about it, while the lost one names work that is not coming
    /// back on its own. A launch that saw both says the second, and the journal has both counts.
    static func forLaunch(_ plan: PTYHostReattachPlan, pending: Int) -> PTYHostLaunchNotice? {
        if !plan.lost.isEmpty { return .lost(plan.lost) }
        // A conversation the daemon kept working counts too. It is not being taken back — its
        // transport cannot be rejoined mid-stream — but it *did* keep running, which is the
        // sentence, and the work it did is in the transcript the resume reads.
        let kept = plan.adopt.count + plan.resume.count
        guard kept > 0 else { return nil }
        return .keptRunning(count: kept, pending: pending)
    }

    // MARK: - Reading

    var count: Int {
        switch self {
        case .keptRunning(let count, _): return count
        case .lost(let sessionIDs): return sessionIDs.count
        }
    }

    /// The sentence the band carries.
    var message: String {
        switch self {
        case .keptRunning(let count, _):
            return count == 1
                ? L10n.string("One session kept running while Threading was closed.")
                : L10n.format(
                    "%lld sessions kept running while Threading was closed.",
                    Int64(count)
                )
        case .lost(let sessionIDs):
            return sessionIDs.count == 1
                ? L10n.string(
                    "One session was lost while Threading was closed. Its conversation can be "
                        + "resumed."
                )
                : L10n.format(
                    "%lld sessions were lost while Threading was closed. Their conversations can "
                        + "be resumed.",
                    Int64(sessionIDs.count)
                )
        }
    }

    /// The band's one answer, or nil when there is nothing left to press.
    var actionTitle: String? {
        switch self {
        case .keptRunning(_, let pending):
            return pending > 0 ? L10n.string("Reattach") : nil
        case .lost:
            return L10n.string("Resume")
        }
    }

    /// Whether the band reads as a problem or as a fact. A loss is the only one of the two that
    /// went wrong, and the mark's shape says so as well as its ink.
    var isAttention: Bool {
        switch self {
        case .keptRunning: return false
        case .lost: return true
        }
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
/// Held in memory only. Nothing about it goes on disk: the fact it reports is the daemon's own
/// list, which the next launch asks for again.
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

    /// Whether this launch has already said its piece.
    private(set) var hasOffered = false

    // MARK: - Initialization

    init(actions: Actions) {
        self.actions = actions
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
        case .lost(let sessionIDs):
            actions.resume(sessionIDs)
        }
    }
}
