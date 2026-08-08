import Foundation

// MARK: - Scheduled Reset Policy

/// What a send aimed at a usage window's reset should do if, when the moment comes, the window
/// has not actually reset.
///
/// The question exists because `resetsAt` is a **reading**, not a fact: it is refreshed on an
/// interval, is sometimes served from a local cache, and moves — `Project.swift` records that it
/// stands still through a session and jumps by exactly five hours when a new window opens. So a
/// send scheduled against it can arrive to find the window still spent, and there is no single
/// right answer to that. All three ship; Settings ▸ Usage Windows chooses.
enum ScheduledResetPolicy: String, CaseIterable, Sendable {

    /// Fire at the stored moment whatever the reading now says. The most predictable — the time
    /// shown when it was scheduled is the time it sends — and the one that wastes a turn if the
    /// reading was stale.
    case sendAnyway

    /// Re-read at the moment; if the window is still spent and its reset has moved forward,
    /// stand aside once for the new moment, then deliver regardless.
    case waitOnce

    /// Keep standing aside until the window genuinely frees, bounded by
    /// `ScheduledMessageDefaults.maximumResetRearms` so a misreported window cannot turn one
    /// scheduled message into an unbounded chase.
    case waitUntilReset

    static let `default` = ScheduledResetPolicy.waitOnce

    /// What the user has chosen, read where the decision is made.
    @MainActor
    static var current: ScheduledResetPolicy { ScheduledResetSettings.policy }

    var title: String {
        switch self {
        case .sendAnyway: return L10n.string("Send it anyway")
        case .waitOnce: return L10n.string("Wait once for the new reset")
        case .waitUntilReset: return L10n.string("Wait until the window actually resets")
        }
    }

    var explanation: String {
        switch self {
        case .sendAnyway:
            return L10n.string(
                "Sends at the time you picked. If the reading was stale the agent meets the "
                + "limit immediately and the turn is spent for nothing."
            )
        case .waitOnce:
            return L10n.string(
                "Checks again when the moment arrives, stands aside once if the window has "
                + "moved, then sends."
            )
        case .waitUntilReset:
            return L10n.string(
                "Keeps waiting until the window frees. Most likely to land on a fresh window, "
                + "and can send noticeably later than the time you picked."
            )
        }
    }

    /// How many times this policy permits standing aside.
    var permittedRearms: Int {
        switch self {
        case .sendAnyway: return 0
        case .waitOnce: return 1
        case .waitUntilReset: return ScheduledMessageDefaults.maximumResetRearms
        }
    }

    /// Whether a send should stand aside for a window that has not reset, given how many times
    /// it already has.
    ///
    /// Pure, and stated here rather than inside the performer, so the matrix is one test rather
    /// than three code paths through a view controller.
    func shouldStandAside(alreadyRearmed count: Int, windowHasReset: Bool) -> Bool {
        guard !windowHasReset else { return false }
        return count < permittedRearms
    }
}

// MARK: - Storage

/// Where that choice is kept.
///
/// Through `PreferenceStore` rather than `UserDefaults.standard`, and on this page the
/// distinction is load-bearing rather than tidy: the test bundle is hosted in the app, so a test
/// that set this would set it for the developer's own copy — and the consequence would be their
/// scheduled sends behaving differently for reasons no one could see. `UsageWindowSettings` keeps
/// its schedule here for the same reason, one shelf along.
@MainActor
enum ScheduledResetSettings {

    private static let key = "scheduledResetPolicy"

    static var policy: ScheduledResetPolicy {
        get {
            PreferenceStore.shared.string(forKey: key)
                .flatMap(ScheduledResetPolicy.init(rawValue:))
                ?? .default
        }
        set {
            guard newValue != policy else { return }
            PreferenceStore.shared.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(AppSettingsDidChange())
        }
    }
}
