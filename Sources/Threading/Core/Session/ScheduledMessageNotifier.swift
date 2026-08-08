import AppKit
@preconcurrency import UserNotifications

// MARK: - Scheduled Message Notifier

/// Tells the user about a scheduled send they were not there to watch.
///
/// Separate from `AttentionAlertCenter` rather than a fourth `AttentionAlert` case: those three
/// are states derived from one activity edge by a pure policy, and none of them describes "the
/// app did something on your behalf". Their raw values are stored preferences, so the enum is
/// also the wrong place to grow.
///
/// **It reports two things and stays quiet about the rest.** An agent started working unattended
/// is worth interrupting for — it is spending usage and touching a checkout with nobody looking.
/// So is a send that could not be made. A message delivered into a conversation already on screen
/// is not: the row leaving the strip is its receipt, and a banner for it would be noise.
@MainActor
final class ScheduledMessageNotifier {

    // MARK: - Singleton

    static let shared = ScheduledMessageNotifier()

    // MARK: - Report

    enum Report {
        case delivered(ScheduledMessage, sessionID: SessionID)
        case failed(ScheduledMessage, reason: String)
    }

    // MARK: - Properties

    private var isStarted = false
    private let center: UNUserNotificationCenter?

    // MARK: - Initialization

    /// The centre is resolved once and withheld under a test bundle, which is
    /// `AttentionAlertCenter`'s own discipline: `UNUserNotificationCenter.current()` asks the
    /// system for authorization, and a hosted test that touched it would put a permission
    /// dialog in front of whoever ran the suite.
    init(center: UNUserNotificationCenter? = ScheduledMessageNotifier.systemCenter()) {
        self.center = center
    }

    private static func systemCenter() -> UNUserNotificationCenter? {
        guard NSClassFromString("XCTestCase") == nil, Bundle.main.bundleIdentifier != nil else {
            return nil
        }
        return .current()
    }

    // MARK: - Public Methods

    func start() {
        guard !isStarted, center != nil else { return }
        isStarted = true
    }

    func report(_ report: Report) {
        guard isStarted, let center else { return }

        switch report {
        case .delivered(let message, let sessionID):
            // Only when the agent was woken *and* nobody is watching. A delivery into a
            // conversation the user has open announces itself by happening.
            guard !NSApp.isActive, message.target.projectID != nil || wasDormant(sessionID) else {
                return
            }
            post(
                center,
                title: L10n.string("A scheduled message was sent"),
                body: message.summary,
                sessionID: sessionID
            )

        case .failed(let message, let reason):
            post(
                center,
                title: L10n.string("A scheduled message could not be sent"),
                body: "\(message.summary) — \(reason)",
                sessionID: message.target.sessionID
            )
        }
    }

    // MARK: - Private Methods

    /// Whether the delivery had to start the agent, which is the part worth saying out loud.
    private func wasDormant(_ sessionID: SessionID) -> Bool {
        AgentRuntime.shared.activity(sessionID: sessionID) == .dormant
    }

    private func post(
        _ center: UNUserNotificationCenter,
        title: String,
        body: String,
        sessionID: SessionID?
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let sessionID {
            content.userInfo = [ScheduledNotifierDefaults.sessionKey: sessionID.uuidString]
        }

        center.add(
            UNNotificationRequest(
                identifier: "\(ScheduledNotifierDefaults.identifierPrefix)\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        )
    }
}

// MARK: - Defaults

enum ScheduledNotifierDefaults {
    static let identifierPrefix = "scheduled-message."
    static let sessionKey = "sessionID"
}
