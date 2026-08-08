import Foundation

// MARK: - Limit Recovery Policy

/// What Threading does when a live terminal session is refused over its account's usage limit —
/// the moment `ObservedUsageLimit` reports, decided by the user in advance.
///
/// The default is the quiet one. Recovery types into the user's session and spends their quota
/// with nobody watching, so it is opted into, never discovered: `flagOnly` still reads the
/// refusal (that is what un-strands the spinner — see `limit-recovery.md`) and then leaves the
/// decision where it is today, in front of the user.
enum LimitRecoveryPolicy: String, CaseIterable, Sendable {

    /// Detect and mark, touch nothing. The session flags as stopped on the user; the CLI's own
    /// chooser stays exactly as the CLI drew it.
    case flagOnly

    /// Answer the CLI's chooser with its stop-and-wait option, then schedule "continue" for the
    /// binding window's reset through the scheduled-messages machinery — the routine the user
    /// described doing by hand, automated whole and journaled at every step.
    case waitForReset

    static let `default` = LimitRecoveryPolicy.flagOnly

    /// What the user has chosen, read where the decision is made.
    @MainActor
    static var current: LimitRecoveryPolicy { LimitRecoverySettings.policy }

    var title: String {
        switch self {
        case .flagOnly:
            return L10n.string("Flag the session and wait for you")
        case .waitForReset:
            return L10n.string("Answer the chooser and continue at reset")
        }
    }

    var explanation: String {
        switch self {
        case .flagOnly:
            return L10n.string(
                "The refusal is read and the session is marked as stopped; nothing is typed and nothing is scheduled."
            )
        case .waitForReset:
            return L10n.string(
                "Threading chooses “Stop and wait”, schedules “continue” for the window's reset, and the session resumes on its own."
            )
        }
    }
}

// MARK: - Storage

/// Stored through `PreferenceStore` for the reason the Usage Windows page's own settings are:
/// a hosted test run must not flip what a background process does with the developer's real
/// sessions and quota.
@MainActor
enum LimitRecoverySettings {

    private static let key = "limitRecoveryPolicy"

    static var policy: LimitRecoveryPolicy {
        get {
            PreferenceStore.shared.string(forKey: key)
                .flatMap(LimitRecoveryPolicy.init(rawValue:))
                ?? .default
        }
        set {
            guard newValue != policy else { return }
            PreferenceStore.shared.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(AppSettingsDidChange())
        }
    }
}
