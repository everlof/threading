import Foundation
import ThreadingRemoteKit

/// How long after a finger leaves the screen the phone still counts as in use.
enum MobileMirrorDefaults {
    static let recentTouchWindow: TimeInterval = 5
    /// A keyboard the system restores this soon after the app becomes active is not new input.
    static let restoredKeyboardWindow: TimeInterval = 2
    /// The arrival pill names the Mac and the source for this long.
    static let pillDwell: TimeInterval = 1.2
    /// The controls hide themselves after this long without a touch on them.
    static let controlsDwell: TimeInterval = 4
    /// The arrival pill reminds of the gesture this many times after the guide.
    static let gestureReminders = 3
    /// The two-finger hold that brings up the controls.
    static let controlsHoldDuration: TimeInterval = 0.5
    static let controlsHoldMovement: CGFloat = 12
    /// After this long with no revision and no touch the stage dims to standby.
    static let standbyAfter: TimeInterval = 15 * 60
    /// A notification tap that finds no mirror on the Mac within this long says so and returns.
    static let notificationJoinTimeout: TimeInterval = 12
    /// A loopback grant is renewed this long before it expires.
    static let tunnelRenewalMargin: TimeInterval = 120
    static let swapFade: TimeInterval = 0.15
    /// Where the quiet offer floats: below a standard navigation bar.
    static let offerTopInset: CGFloat = 52
}

/// What the phone does with a mirror the Mac sent it.
enum MobileMirrorArrival: Equatable {
    /// Take the screen (or keep it, for a newer revision of the mirror already showing).
    case stage
    /// Wait as the quiet *Mirror ready · Show* offer and tell the Mac why.
    case quietOffer(RemoteMirrorHoldReason)
    /// The app is not in front: post the invite as a local notification instead.
    case notify
    /// Mirror is switched off for this Mac.
    case refuse
}

/// The facts the arrival decision reads, gathered at the moment a mirror state arrives.
struct MobileMirrorArrivalContext: Equatable {
    var isEnabled: Bool
    var isAppActive: Bool
    /// The stage already shows this mirror, so this is a newer revision of it.
    var isShowingThisMirror: Bool
    /// The person tapped this mirror's notification or Live Activity and is waiting for it.
    var isAwaitingThisMirror: Bool
    /// This mirror already waits as the quiet offer; a newer revision of it keeps waiting.
    var isOfferingThisMirror = false
    var offerAge: TimeInterval
    var rejoin: Bool
    var isInUse: Bool
}

enum MobileMirrorArrivalPolicy {
    /// Starting on the Mac is the consent, so nothing here asks. What it protects is a phone
    /// being used: one with the keyboard up or a finger on the screen never loses its screen.
    static func decide(_ context: MobileMirrorArrivalContext) -> MobileMirrorArrival {
        guard context.isEnabled else { return .refuse }
        if context.isShowingThisMirror || context.isAwaitingThisMirror { return .stage }
        guard context.isAppActive else { return .notify }
        if context.isInUse { return .quietOffer(.inUse) }
        // The offer never promotes itself: a revision of a mirror already offered stays an offer.
        if context.isOfferingThisMirror { return .quietOffer(.waiting) }
        // The stage was the screen the person left, so a return takes them back to it.
        if context.rejoin { return .stage }
        // A late arrival may be the person coming to prompt: the offer waits and never promotes
        // itself into a takeover.
        guard context.offerAge < RemoteMirror.freshStartWindow else { return .quietOffer(.waiting) }
        return .stage
    }
}

/// Whether the person is using the phone right now.
///
/// Only the present counts: the keyboard is up, or a finger is on the screen or left it within
/// `recentTouchWindow`. Having used the phone a minute ago does not — the click on the Mac is the
/// newer evidence of where the person is.
struct MobileInteractionState: Equatable {
    var isKeyboardVisible = false
    var keyboardShownAt: Date?
    var activeTouches = 0
    var lastTouchEndedAt: Date?
    var activatedAt: Date?

    func isInUse(at now: Date) -> Bool {
        if activeTouches > 0 { return true }
        if let ended = lastTouchEndedAt, now.timeIntervalSince(ended) < MobileMirrorDefaults.recentTouchWindow {
            return true
        }
        guard isKeyboardVisible else { return false }
        // A keyboard the system put back on activation was not raised by the person.
        if let activatedAt, let shownAt = keyboardShownAt,
           shownAt >= activatedAt,
           shownAt.timeIntervalSince(activatedAt) < MobileMirrorDefaults.restoredKeyboardWindow {
            return false
        }
        return true
    }
}

/// The per-Mac Mirror switch, on by default. It is a setting, never a prompt.
@MainActor
final class MobileMirrorPreferences {
    static let shared = MobileMirrorPreferences(defaults: .standard)

    private static let disabledHostsKey = "threading.mobile.mirror.disabled-hosts.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func isEnabled(hostID: String) -> Bool {
        !disabledHosts.contains(hostID)
    }

    func setEnabled(_ enabled: Bool, hostID: String) {
        var hosts = disabledHosts
        if enabled { hosts.remove(hostID) } else { hosts.insert(hostID) }
        defaults.set(hosts.sorted(), forKey: Self.disabledHostsKey)
    }

    private var disabledHosts: Set<String> {
        Set(defaults.stringArray(forKey: Self.disabledHostsKey) ?? [])
    }
}

/// Whether the controls guide has run on this phone, and how many arrivals still remind of the
/// gesture. Per phone, not per Mac: a second Mac does not teach it again.
@MainActor
final class MobileMirrorGuideStore {
    static let shared = MobileMirrorGuideStore(defaults: .standard)

    private static let completedKey = "threading.mobile.mirror.guide-completed.v1"
    private static let remindersKey = "threading.mobile.mirror.gesture-reminders.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var hasCompletedGuide: Bool {
        defaults.bool(forKey: Self.completedKey)
    }

    /// Settings ▸ Mirror ▸ **Show the Controls Guide Again**: the next mirror teaches it again.
    func resetGuide() {
        defaults.set(false, forKey: Self.completedKey)
    }

    func completeGuide() {
        defaults.set(true, forKey: Self.completedKey)
        defaults.set(MobileMirrorDefaults.gestureReminders, forKey: Self.remindersKey)
    }

    /// Whether this arrival's pill reminds of the gesture; spends one reminder when it does.
    func takeGestureReminder() -> Bool {
        guard hasCompletedGuide else { return false }
        let left = defaults.integer(forKey: Self.remindersKey)
        guard left > 0 else { return false }
        defaults.set(left - 1, forKey: Self.remindersKey)
        return true
    }
}
