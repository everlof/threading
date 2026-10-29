import Foundation

/// The selected-session choice is shared by both desktop hosts. Keep the key and its
/// first-launch value with the restore policy so a host shim cannot silently drift.
enum SelectedSessionRestorePreference {
    static let key = "restoresLastSession"
    static let defaultValue = true

    static func read(from defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    static func write(_ restores: Bool, to defaults: UserDefaults) {
        defaults.set(restores, forKey: key)
    }
}

// MARK: - Session Restore Policy

/// Which sessions a launch brings back live.
///
/// The two answers differ in what they are bounded by, which is the whole of the choice.
/// `.runningAtLastQuit` reads the post-retention live set the quit recorded. It depends on that
/// one record, though, and a reboot, a force quit, or an app that opened and closed again without
/// restoring anything leaves that record saying nothing. `.recentlyUsed` survives all of those
/// because it reads the conversations themselves, and is bounded by the age and count settings.
enum SessionRestorePolicy: String, CaseIterable, Sendable {

    /// Bring nothing back. Every row starts dormant and resumes when it is opened.
    case nothing

    /// What had a live agent at the last quit after settled idle processes were retired.
    case runningAtLastQuit

    /// What was used inside the window, most recent first, up to the limit.
    case recentlyUsed

    /// The settings pop-up's wording, read as the end of its row's title: "Bring back at launch ▸
    /// Running at last quit". Terse because the control is one pop-up wide and a title that
    /// truncates says less than a short one.
    var settingsTitle: String {
        switch self {
        case .nothing: L10n.string("Nothing")
        case .runningAtLastQuit: L10n.string("Running at last quit")
        case .recentlyUsed: L10n.string("Recently used")
        }
    }

    /// The policy a store holds, given what is stored and the toggle this setting replaced.
    ///
    /// Kept apart from `UserDefaults` so the migration is a fact about values rather than about a
    /// hosted test's preferences: this bundle runs inside the app, and a test that wrote a real
    /// policy key would decide what the developer's own next launch does.
    static func resolved(
        stored: String?,
        legacyRestoresRunningSessions: Bool
    ) -> SessionRestorePolicy {
        if let stored, let value = SessionRestorePolicy(rawValue: stored) { return value }
        return legacyRestoresRunningSessions ? .runningAtLastQuit : .nothing
    }
}

// MARK: - Session Restore Defaults

enum SessionRestoreDefaults {

    /// The policy's persisted names belong beside the value it stores, so desktop host
    /// adapters cannot migrate or clamp the same choice under different keys.
    static let policyKey = "sessionRestorePolicy"
    static let legacyRunningSessionsKey = "restoresRunningSessions"
    static let windowDaysKey = "sessionRestoreWindowDays"
    static let limitKey = "sessionRestoreLimit"

    /// An elapsed window, not calendar days: 25 hours ago is outside a one-day window even
    /// across a daylight-saving transition.
    static let secondsPerDay: TimeInterval = 24 * 60 * 60

    /// One day, which on a working store is close to what was running anyway, and reaches the
    /// conversation somebody left open overnight without reaching last week's.
    static let windowDays = 1

    /// Four settled agents kept warm. Each is a real CLI process and can own its own descendants;
    /// a small default keeps quick switching useful without turning the sidebar into a process
    /// inventory. Unfinished or otherwise unsafe-to-retire work does not count against this cap.
    static let limit = 4

    /// Offered in the settings pop-ups. Bounds rather than a free field: both values decide how
    /// many processes a launch spawns, so the range is the product's, not a text field's.
    static let windowDayChoices = [1, 2, 3, 7, 14, 30]
    static let limitChoices = [4, 8, 12, 16, 24, 32]

    static func windowTitle(days: Int) -> String {
        #if os(Linux)
        // swift-corelibs-foundation has no DateComponentsFormatter. The Linux host currently
        // ships English copy; keep the offered values and grammar in this shared policy.
        return days == 1 ? "1 day" : "\(days) days"
        #else
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day]
        formatter.unitsStyle = .full
        let seconds = Double(days) * secondsPerDay
        return formatter.string(from: seconds) ?? "\(days)"
        #endif
    }

    static func limitTitle(_ limit: Int) -> String {
        L10n.format("At most %d", limit)
    }

    static func clampWindowDays(_ value: Int) -> Int {
        guard let first = windowDayChoices.first, let last = windowDayChoices.last else {
            return windowDays
        }
        return value <= 0 ? windowDays : min(max(value, first), last)
    }

    static func clampLimit(_ value: Int) -> Int {
        guard let first = limitChoices.first, let last = limitChoices.last else { return limit }
        return value <= 0 ? limit : min(max(value, first), last)
    }
}
