import AppKit
import ThreadingRemoteKit
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

// MARK: - Attention Alert

/// What a notification about a session says.
///
/// Each case is separately switchable in Settings, so the raw value is a stored preference and
/// must not be renamed. They are listed here loudest first, which is also the order the
/// settings rows take: the one holding a turn up, the one that finished off screen, and the
/// chatty one.
enum AttentionAlert: String, Equatable, CaseIterable {
    /// A turn stopped dead on a question — `awaitingUser`.
    case blocked

    /// Finished or asked while nobody was looking — `needsAttention`.
    case unread

    /// A turn ended while the app was in the background. The case above never covers this:
    /// the visible session settles to `idle` precisely because in-app it needs no flag, and a
    /// native conversation reports `idle` off screen too — the transcript is its record.
    case finished

    /// The notification's second line, and the only description of each alert — the settings
    /// row that switches a kind off says the same sentence the banner would have said, so the
    /// toggle can be matched to the thing it silences.
    var body: String {
        switch self {
        case .blocked: return L10n.string("Waiting for your approval to continue")
        case .unread: return L10n.string("Finished and waiting for you")
        case .finished: return L10n.string("Finished its turn")
        }
    }

    /// What the settings row is called.
    var settingsTitle: String {
        switch self {
        case .blocked: return L10n.string("Blocked on an approval")
        case .unread: return L10n.string("Finished while you were elsewhere")
        case .finished: return L10n.string("Finished a turn in the background")
        }
    }

    /// Only the blocked state sounds: it is the one holding a turn up right now, which is the
    /// same ranking the sidebar's filled-versus-hollow marks already draw. Whether that sound
    /// actually plays is `AppSettings.playsAttentionAlertSound`.
    var sounds: Bool { self == .blocked }
}

// MARK: - Attention Alert Policy

/// Decides, from one activity edge, whether a notification is posted, withdrawn, or neither.
///
/// Pure so the matrix is testable without `UNUserNotificationCenter`: the center owns the
/// delivery, this owns the judgement.
enum AttentionAlertPolicy {

    enum Action: Equatable {
        case post(AttentionAlert)

        /// Withdraw whatever this session has delivered: the state it reported no longer
        /// holds, and a notification for an answered question is litter in Notification
        /// Center. Hygiene is half the feature.
        case clear

        case none
    }

    /// `reportsOwnTurns` gates `.finished`: a shell's working→idle is a quiet timer expiring
    /// after every burst of output, and notifying on each `ls` would bury the alerts that
    /// matter. Only a session whose agent declares its own turn boundaries — a hook-reporting
    /// terminal or a native conversation — has a working→idle edge that means a turn ended.
    static func action(
        from old: SessionActivity,
        to new: SessionActivity,
        appIsActive: Bool,
        reportsOwnTurns: Bool
    ) -> Action {
        guard old != new else { return .none }

        switch new {
        case .awaitingUser:
            return .post(.blocked)
        case .needsAttention:
            return .post(.unread)
        case .idle where old == .working && !appIsActive && reportsOwnTurns:
            return .post(.finished)
        case .idle, .working, .dormant, .limitReached:
            // Whatever this session had delivered described `old`; the edge makes it stale.
            // `idle` is in the list because a `.finished` alert leaves the session idle.
            //
            // A limit stop posts nothing of its own, deliberately. Every alert here is a
            // *change the user can act on* — answer this, read that — and there is no action
            // behind this one: the window resets when it resets. It clears a stale alert and
            // then says its piece on the row, where the user is already looking when they
            // wonder where a session went.
            let couldHaveAlert = old == .awaitingUser || old == .needsAttention || old == .idle
            return couldHaveAlert ? .clear : .none
        }
    }
}

// MARK: - Attention Alert Scope

/// Whether one session wants alerts at all, resolved across the same three scopes the app
/// already uses for themes: the session's own answer, then its project's, then the app.
///
/// The two scoped answers are *optional* so "inherit" is a state distinct from "not muted".
/// A plain `Bool` on each level could not express a session un-muted inside a muted project —
/// the menu would offer an Unmute that did nothing, which is worse than not offering it.
///
/// The app-wide switch is deliberately **not** the third fallback but an outer gate: it is
/// what people reach for meaning "silence, all of it", and a per-session exception outliving
/// it would be a surprise. See `AttentionAlertCenter.wants`.
enum AttentionAlertScope {

    @MainActor
    static func isMuted(sessionID: SessionID) -> Bool {
        resolve(
            session: ProjectStore.shared.session(withID: sessionID)?.notificationsMuted,
            project: ProjectStore.shared.project(forSessionID: sessionID)?.notificationsMuted
        )
    }

    /// The precedence itself, kept pure so it is testable without a store.
    static func resolve(session: Bool?, project: Bool?) -> Bool {
        session ?? project ?? false
    }
}

// MARK: - Attention Alert Icon

/// Puts the project's icon on the banner — as its attachment, on the trailing side.
///
/// The leading slot is not takeable. It always draws the posting app's icon, and the one
/// sanctioned replacement — a communication notification's sender avatar — needs
/// `com.apple.developer.usernotifications.communication`, which is a *restricted*
/// entitlement: AMFI kills a dev-signed build that requests it ("adhoc signed but contains
/// restricted entitlements"), Apple grants the capability to the iOS family only, and our
/// Developer ID pipeline has no profile to carry it. Measured (July 2026, macOS 26): an
/// unentitled `updating(from:)` posts without error and the system draws the generic icon
/// anyway. The attachment is the supported remainder, and needs none of that.
enum AttentionAlertIcon {

    /// An attachment holding a *copy* of the icon, never the stored file itself: scheduling
    /// an attachment **moves** the file into the system's attachment store, and the original
    /// belongs to `ProjectIconStore`. Nil — meaning the banner posts bare — when the copy
    /// cannot be written or the attachment is refused; the icon is decoration, not payload.
    static func attachment(iconPNGData: Data) -> UNNotificationAttachment? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ProjectIconDefaults.storedExtension)
        do {
            try iconPNGData.write(to: url)
            return try UNNotificationAttachment(
                identifier: "",
                url: url,
                options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier]
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }
}

// MARK: - Attention Alert Center

/// Posts macOS notifications when a session wants the user, and withdraws them when it no
/// longer does.
///
/// Listens on `SessionActivityDidChange` — the one channel both surfaces already report
/// through — and keeps its own last-seen map because the event carries only the session id.
/// Banners show only while the app is inactive: in the app, the sidebar mark and the
/// permission card are the cues, and a banner over them would say the same thing twice
/// (`willPresent` returns nothing).
@MainActor
final class AttentionAlertCenter: NSObject {

    static let shared = AttentionAlertCenter()

    private let observations = AppEventObservations()
    private var activationObserver: NSObjectProtocol?
    private var lastActivity: [SessionID: SessionActivity] = [:]

    /// What each session currently has on screen, so a preference switched off can withdraw
    /// the notification it describes. Without it, turning a kind off would leave that kind's
    /// banners sitting in Notification Center — the same litter the withdrawals elsewhere in
    /// this file exist to avoid.
    private var delivered: [SessionID: AttentionAlert] = [:]

    /// Set once `start()` runs. Everything reachable from other subsystems no-ops before it,
    /// which is what keeps `UNUserNotificationCenter` (and its permission prompt) out of the
    /// test host — tests never start the center.
    private var isStarted = false

    private override init() {}

    // MARK: - Public Methods

    /// Starts observing. Called once from the real app startup, never under tests.
    func start() {
        isStarted = true
        UNUserNotificationCenter.current().delegate = self

        observations.observe(SessionActivityDidChange.self) { [weak self] event in
            Task { @MainActor in self?.activityChanged(for: event.sessionID) }
        }
        observations.observe(TerminalSessionDidEnd.self) { [weak self] event in
            Task { @MainActor in self?.forget(event.sessionID) }
        }
        observations.observe(AppSettingsDidChange.self) { [weak self] _ in
            Task { @MainActor in self?.settingsChanged() }
        }

        // Returning to the app is "looking" at the session on screen: whatever its
        // notification was saying, the user is now in front of it. Off-screen sessions keep
        // theirs — being in the app is not the same as having seen every session.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard let visible = AgentRuntime.shared.visibleSessionID else { return }
                AttentionAlertCenter.shared.sessionWasViewed(visible)
            }
        }
    }

    /// The session came on screen — selected in the sidebar, or the app came back to the
    /// front with it showing. Its notification, if any, has been seen.
    func sessionWasViewed(_ sessionID: SessionID) {
        guard isStarted else { return }
        withdraw(sessionID: sessionID)
    }

    /// Re-checks everything already delivered against the current preferences and withdraws
    /// whatever the user has just switched off.
    ///
    /// Two entrances, because muting is not one setting: the Settings page arrives through
    /// `AppSettingsDidChange`, and a row's Mute item calls this directly — it writes to the
    /// project store, which knows nothing about notifications and should not learn.
    func preferencesChanged() {
        guard isStarted else { return }
        for (sessionID, alert) in delivered where !wants(alert, for: sessionID) {
            withdraw(sessionID: sessionID)
        }
    }

    /// Posts one update the user explicitly asked an agent to send.
    ///
    /// Requested updates use unique request identifiers: step three must not replace step two.
    /// The destination is a closed Threading route encoded as scalar notification metadata, never
    /// an agent-authored URL or path.
    @discardableResult
    func postRequestedUpdate(
        eventID: String,
        sessionID: SessionID,
        title: String?,
        body: String,
        destination: RemoteNotificationDestinationDTO
    ) -> Bool {
        guard isStarted, destination.isValid,
              AppSettings.shared.notifiesOnAttention,
              !AttentionAlertScope.isMuted(sessionID: sessionID) else {
            return false
        }

        let content = UNMutableNotificationContent()
        let session = ProjectStore.shared.session(withID: sessionID)
        let project = ProjectStore.shared.project(forSessionID: sessionID)
        content.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? session?.displayTitle
            ?? "Threading session"
        if let project { content.subtitle = project.name }
        content.body = body
        content.sound = AppSettings.shared.playsAttentionAlertSound ? .default : nil
        content.userInfo = AttentionAlertDefaults.userInfo(
            sessionID: sessionID,
            destination: destination
        )
        if let project { content.threadIdentifier = project.id.uuidString }
        if let icon = project?.icon,
           let png = ProjectIconStore.pngData(for: icon),
           let attachment = AttentionAlertIcon.attachment(iconPNGData: png) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: "requested-\(eventID)",
            content: content,
            trigger: nil
        )
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    center.add(request)
                }
            case .denied:
                break
            default:
                center.add(request)
            }
        }
        return true
    }

    // MARK: - Private Methods

    private func activityChanged(for sessionID: SessionID) {
        let new = AgentRuntime.shared.activity(sessionID: sessionID)
        let old = lastActivity[sessionID] ?? .dormant
        lastActivity[sessionID] = new

        let action = AttentionAlertPolicy.action(
            from: old,
            to: new,
            appIsActive: NSApp.isActive,
            reportsOwnTurns: AgentRuntime.shared.reportsOwnTurns(sessionID: sessionID)
        )

        switch action {
        case .post(let alert) where wants(alert, for: sessionID):
            post(alert, for: sessionID)
        case .post, .clear:
            // Two ways to arrive at the same place: the edge made whatever was delivered
            // stale, or the state it moved to is one this session no longer alerts on. Either
            // way nothing that describes `old` should still be on screen.
            withdraw(sessionID: sessionID)
        case .none:
            break
        }
    }

    /// Whether this session posts this kind of alert: the app-wide switch as an outer gate,
    /// then the kind the user chose to keep, then the session's own scope.
    private func wants(_ alert: AttentionAlert, for sessionID: SessionID) -> Bool {
        AppSettings.shared.notifiesOnAttention
            && AppSettings.shared.notifies(on: alert)
            && !AttentionAlertScope.isMuted(sessionID: sessionID)
    }

    private func post(_ alert: AttentionAlert, for sessionID: SessionID) {
        let content = UNMutableNotificationContent()
        let session = ProjectStore.shared.session(withID: sessionID)
        let project = ProjectStore.shared.project(forSessionID: sessionID)

        content.title = session?.displayTitle ?? "Threading session"
        if let project { content.subtitle = project.name }
        content.body = alert.body
        // The ranking is the alert's (only `blocked` ever sounds); whether it is heard is the
        // user's, and the two are separate questions — a sound switched off should not have to
        // cost the banner that carries it.
        content.sound = alert.sounds && AppSettings.shared.playsAttentionAlertSound
            ? .default
            : nil
        content.userInfo = [AttentionAlertDefaults.sessionKey: sessionID.uuidString]
        if let project { content.threadIdentifier = project.id.uuidString }
        if let icon = project?.icon,
           let png = ProjectIconStore.pngData(for: icon),
           let attachment = AttentionAlertIcon.attachment(iconPNGData: png) {
            content.attachments = [attachment]
        }
        delivered[sessionID] = alert

        // The request id is the session id, so a session's newer state replaces its older
        // notification instead of stacking beneath it.
        let request = UNNotificationRequest(
            identifier: sessionID.uuidString,
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                // Asked on the first alert-worthy edge rather than at launch, so the
                // permission dialog appears beside a notification with a reason to exist.
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    center.add(request)
                }
            case .denied:
                break
            default:
                center.add(request)
            }
        }
    }

    private func withdraw(sessionID: SessionID) {
        delivered[sessionID] = nil
        let identifiers = [sessionID.uuidString]
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func forget(_ sessionID: SessionID) {
        lastActivity[sessionID] = nil
        withdraw(sessionID: sessionID)
    }

    /// Switching any of it off withdraws what it described: an off switch that leaves its
    /// traces behind is not off. The master switch is the loudest case and no longer the only
    /// one — a single kind, or one session's mute, has the same obligation.
    private func settingsChanged() {
        guard AppSettings.shared.notifiesOnAttention else {
            delivered.removeAll()
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            return
        }
        preferencesChanged()
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AttentionAlertCenter: UNUserNotificationCenterDelegate {

    /// Ordinary state alerts stay quiet while their session UI is already available. Explicit
    /// milestone notifications still present: the user asked for those even if Threading happens
    /// to be frontmost, and their inspection target may be in a different chat or pane.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if userInfo[AttentionAlertDefaults.destinationKindKey] != nil {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([])
        }
    }

    /// Clicking the notification opens the session it is about.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let raw = userInfo[AttentionAlertDefaults.sessionKey] as? String
        let destination = AttentionAlertDefaults.destination(from: userInfo) ?? .session
        completionHandler()
        Task { @MainActor in
            if let raw, let sessionID = SessionID(uuidString: raw) {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(
                    SessionNotificationOpened(
                        sessionID: sessionID,
                        destination: destination
                    )
                )
            }
        }
    }
}

// MARK: - Attention Alert Defaults

enum AttentionAlertDefaults {
    /// The `userInfo` key carrying the session a notification is about.
    static let sessionKey = "sessionID"
    static let destinationKindKey = "destinationKind"
    static let attachmentIDKey = "attachmentID"
    static let browserTabIDKey = "browserTabID"
    static let extensionIdentifierKey = "extensionIdentifier"
    static let extensionPanelIDKey = "extensionPanelID"

    static func userInfo(
        sessionID: SessionID,
        destination: RemoteNotificationDestinationDTO
    ) -> [String: String] {
        var result = [
            sessionKey: sessionID.uuidString,
            destinationKindKey: destination.kind.rawValue,
        ]
        result[attachmentIDKey] = destination.attachmentID
        result[browserTabIDKey] = destination.browserTabID
        result[extensionIdentifierKey] = destination.extensionIdentifier
        result[extensionPanelIDKey] = destination.extensionPanelID
        return result
    }

    static func destination(
        from userInfo: [AnyHashable: Any]
    ) -> RemoteNotificationDestinationDTO? {
        guard let rawKind = userInfo[destinationKindKey] as? String,
              let kind = RemoteNotificationDestinationDTO.Kind(rawValue: rawKind) else {
            return nil
        }
        let destination = RemoteNotificationDestinationDTO(
            kind: kind,
            attachmentID: userInfo[attachmentIDKey] as? String,
            browserTabID: userInfo[browserTabIDKey] as? String,
            extensionIdentifier: userInfo[extensionIdentifierKey] as? String,
            extensionPanelID: userInfo[extensionPanelIDKey] as? String
        )
        return destination.isValid ? destination : nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
