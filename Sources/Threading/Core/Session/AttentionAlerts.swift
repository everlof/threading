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

    /// A session went on starting turns after every interrupt its curfew had to give.
    ///
    /// The quietest of the four in frequency and the loudest in meaning: it is the only one that
    /// says Threading tried something and it did not work. Posted by
    /// `postCurfewGaveUp(sessionID:interrupts:stopped:)` rather than by an activity edge, because
    /// nothing about the session's *state* changed — what ran out was the ladder.
    case curfew

    /// The notification's second line, and the only description of each alert — the settings
    /// row that switches a kind off says the same sentence the banner would have said, so the
    /// toggle can be matched to the thing it silences.
    ///
    /// The curfew's real banner names how many interrupts were spent, which is a number this
    /// case cannot carry; the poster supplies that line. What is stated here is the same sentence
    /// with the shipped budget in it, so the settings row still quotes what the user would read
    /// rather than a paraphrase of it.
    var body: String {
        switch self {
        case .blocked: return L10n.string("Waiting for your approval to continue")
        case .unread: return L10n.string("Finished and waiting for you")
        case .finished: return L10n.string("Finished its turn")
        case .curfew:
            return CurfewReceiptWords.gaveUpAlertBody(count: CurfewDefaults.maximumInterrupts)
        }
    }

    /// What the settings row is called.
    var settingsTitle: String {
        switch self {
        case .blocked: return L10n.string("Blocked on an approval")
        case .unread: return L10n.string("Finished while you were elsewhere")
        case .finished: return L10n.string("Finished a turn in the background")
        case .curfew: return L10n.string("Kept working after its curfew")
        }
    }

}

// MARK: - Attention Alert Policy

/// Decides, from one activity edge, whether a notification is posted, withdrawn, or neither.
///
/// Pure so the matrix is testable without `UNUserNotificationCenter`: the center owns the
/// delivery, this owns the judgement.
enum AttentionAlertPolicy {

    /// How loudly a post arrives.
    ///
    /// Not a property of the alert — the same `unread` is worth interrupting somebody for once
    /// and worth almost nothing the fourth time in six seconds.
    enum Presentation: Equatable {

        /// A banner, and whatever sound the chain resolved. What every post used to be.
        case interrupt

        /// Delivered to Notification Center with no banner and no sound
        /// (`UNNotificationInterruptionLevel.passive`).
        ///
        /// **Quiet, never dropped.** The session still wants the user and the entry still says
        /// so; what is withheld is the second, third and fourth interruption for a fact they
        /// have already been handed. Suppressing the post outright was the obvious alternative
        /// and is wrong: the withdrawal on the way out took the previous banner with it, so
        /// "post nothing" would leave a session that wants the user with nothing anywhere
        /// saying so.
        case quiet
    }

    /// Whether this post is news.
    ///
    /// The rule is one sentence: **the user is interrupted once per session per episode, and
    /// the episode ends when they look at it.** `lastAnnounced` is what the session has already
    /// said and is cleared by viewing, so a state that leaves a flag and lands straight back on
    /// it re-posts quietly, while a genuinely different alert — `unread` escalating to
    /// `blocked` — interrupts like it should.
    ///
    /// Measured on 25 August 2026, which is why this exists. One terminal session with no
    /// lifecycle hooks produced `output → working`, `quiet → needsAttention`, `output →
    /// working`, `bell → needsAttention`, `output → working`, `quiet → needsAttention` inside
    /// six seconds: four identical banners for one burst of output, because the quiet timer is
    /// the turn boundary for a session that reports none of its own. A second session sitting
    /// at an idle prompt did the same thing fifteen times across one day, ~35 minutes apart,
    /// having produced no turn at all since the morning.
    ///
    /// `curfew` is exempt and stays loud. It is not derived from a state edge — it is posted
    /// once per curfew episode by a ladder that has already run out — and it is the only alert
    /// that reports Threading trying something and failing. A repeat of that one is news.
    ///
    /// **The episode also ends on its own.** The announcement is otherwise cleared by one thing
    /// — looking at the session — so a question answered on the phone, or one the agent moved
    /// past by itself, left the next alert on this Mac silent for as long as the user did not
    /// open that chat here. Two different events were sharing one rule: over 1–8 September 2026
    /// this Mac recorded 1,158 repeats whose median gap was one second and whose longest was an
    /// hour and 41 minutes. The first is the burst this rule exists for; the second is news.
    static let repeatWindow: TimeInterval = 30 * 60

    static func presentation(
        of alert: AttentionAlert,
        lastAnnounced: AttentionAlertAnnouncement?,
        now: Date = Date()
    ) -> Presentation {
        guard alert != .curfew else { return .interrupt }
        guard let lastAnnounced, lastAnnounced.alert == alert else { return .interrupt }
        // A clock correction that puts the last announcement in the future is not evidence of
        // anything, and the error direction here is the same one the bell seam takes: the worst
        // case is one interruption too many, never a session that wanted the user in silence.
        let gap = now.timeIntervalSince(lastAnnounced.at)
        return (0..<repeatWindow).contains(gap) ? .quiet : .interrupt
    }

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
        reportsOwnTurns: Bool,
        isSnoozed: Bool = false
    ) -> Action {
        guard old != new else { return .none }
        // Snooze suppresses ordinary attention. Important edges clear the overlay before this
        // policy runs, so they still receive the notification they would have received unsnoozed.
        if isSnoozed { return .clear }

        switch new {
        case .awaitingUser:
            return .post(.blocked)
        case .needsAttention:
            return .post(.unread)
        case .idle where old == .working && !appIsActive && reportsOwnTurns:
            return .post(.finished)
        case .idle, .working, .readyWithBackgroundWork, .dormant, .limitReached:
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

// MARK: - Attention Alert Journal

/// Why a banner left the screen.
///
/// A type rather than nothing at all, because the four callers of `withdraw` mean four
/// different things and only one of them — `viewed` — is the user having actually dealt with
/// the session. The distinction is what separates "you looked at it" from "it went stale
/// again", which is the difference between a run of banners being expected and being a bug.
enum AttentionAlertWithdrawal: String {

    /// The session came on screen. The only reason that counts as the user having seen it.
    case viewed

    /// The activity edge made the delivered alert describe a state that no longer holds.
    case stateMoved

    /// The terminal ended, so there is no session left to alert about.
    case sessionEnded

    /// A preference was switched off — this kind, this session's mute, or the master switch.
    case preferenceOff
}

/// Which gate refused an alert, when one did.
///
/// `wants(_:for:)` asks four questions and returned one `Bool`, so a session that stopped
/// alerting could not say which switch stopped it. Named separately from the switches
/// themselves so the journal reads as a reason rather than as a settings dump.
enum AttentionAlertGate: String {
    case masterSwitch
    case alertKind
    case muted
    case snoozed

    /// macOS itself refused: the user answered No to the permission prompt, so nothing this
    /// app does will put a banner on screen. Its own case because it is the one gate the app's
    /// own Settings cannot show and cannot fix.
    case systemDenied
}

/// What a session was last told, kept **across** a withdrawal.
///
/// `delivered` answers "what is on screen right now" and is cleared the moment a banner is
/// taken back. That is the wrong memory for the question a run of identical banners raises,
/// which is "has this session already said this". Keeping the announcement separately is what
/// lets a re-post record `repeat=yes` and the gap since the last one, so fifteen identical
/// alerts in a day read as fifteen identical alerts rather than as fifteen unrelated events.
///
/// Cleared only by `viewed`: the user having looked at the session is what makes the next
/// alert news again.
struct AttentionAlertAnnouncement {
    let alert: AttentionAlert
    let at: Date
}

/// The center's own bookkeeping, kept apart from `UNUserNotificationCenter` so the ordering
/// rules can be checked without delivering anything.
///
/// **A post cannot commit synchronously.** The system's authorization answer arrives on its own
/// queue, and until it does there is no alert — so a post claims a token here first and spends
/// it when the answer comes back. Every withdrawal invalidates the tokens standing against that
/// session, which is the half that was missing: two edges a few milliseconds apart, a question
/// asked and then answered, could remove the banner and *then* add it, leaving one on screen
/// describing a state that had already gone. The same claim also stops an alert the system
/// refused from being counted as delivered, which used to leave `delivered` naming a banner
/// nobody could see and `announced` quieting the next real one.
struct AttentionAlertDeliveryLedger {

    /// A claim on one session's next delivery. Spent once, and invalidated by any withdrawal.
    struct Token: Equatable {
        fileprivate let sessionID: SessionID
        fileprivate let count: Int
    }

    /// What each session currently has on screen, so a preference switched off can withdraw
    /// the notification it describes. Without it, turning a kind off would leave that kind's
    /// banners sitting in Notification Center — the same litter the withdrawals elsewhere in
    /// this file exist to avoid.
    private(set) var deliveredAlerts: [SessionID: AttentionAlert] = [:]

    /// What each session has already been told, surviving the withdrawals `deliveredAlerts`
    /// does not. See `AttentionAlertAnnouncement` — this is what makes a repeat legible as one.
    private var announcements: [SessionID: AttentionAlertAnnouncement] = [:]

    /// One counter per session that has ever posted, bounded by the project store's own session
    /// count. It is deliberately never pruned: dropping an entry would restart it at zero and
    /// make a stale token in flight look current again, which is the exact race this closes.
    private var claims: [SessionID: Int] = [:]

    func delivered(for sessionID: SessionID) -> AttentionAlert? {
        deliveredAlerts[sessionID]
    }

    func announcement(for sessionID: SessionID) -> AttentionAlertAnnouncement? {
        announcements[sessionID]
    }

    mutating func beginPost(for sessionID: SessionID) -> Token {
        let count = claims[sessionID] ?? 0
        claims[sessionID] = count
        return Token(sessionID: sessionID, count: count)
    }

    func isCurrent(_ token: Token) -> Bool {
        claims[token.sessionID] == token.count
    }

    mutating func recordDelivery(
        of alert: AttentionAlert,
        for sessionID: SessionID,
        at date: Date
    ) {
        deliveredAlerts[sessionID] = alert
        announcements[sessionID] = AttentionAlertAnnouncement(alert: alert, at: date)
        pruneAnnouncements(before: date)
    }

    /// Returns what the session had on screen, if anything.
    @discardableResult
    mutating func withdraw(
        _ sessionID: SessionID,
        reason: AttentionAlertWithdrawal
    ) -> AttentionAlert? {
        claims[sessionID] = (claims[sessionID] ?? 0) + 1
        if reason == .viewed || reason == .sessionEnded { announcements[sessionID] = nil }
        return deliveredAlerts.removeValue(forKey: sessionID)
    }

    /// The master switch going off: nothing this center posted is on screen any more.
    mutating func withdrawAll() {
        for sessionID in claims.keys { claims[sessionID]? += 1 }
        deliveredAlerts.removeAll()
    }

    /// An announcement past twice the repeat window can no longer quiet anything, so keeping it
    /// only grows the map for sessions that have gone quiet.
    private mutating func pruneAnnouncements(before date: Date) {
        let cutoff = date.addingTimeInterval(-2 * AttentionAlertPolicy.repeatWindow)
        announcements = announcements.filter { $0.value.at >= cutoff }
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
/// Listens on `SessionRuntimeDidChange`, which carries the actual operational transition.
/// Read-receipt projection and restoration cannot turn an old unread result into a new alert.
/// Banners show only while the app is inactive: in the app, the sidebar mark and the
/// permission card are the cues, and a banner over them would say the same thing twice
/// (`willPresent` returns nothing).
@MainActor
final class AttentionAlertCenter: NSObject {

    static let shared = AttentionAlertCenter()

    private let observations = AppEventObservations()
    private var activationObserver: NSObjectProtocol?
    private var runtimeObserver: AttentionAlertRuntimeObserver?

    /// What is on screen, what each session has already been told, and the claim each in-flight
    /// post holds. See `AttentionAlertDeliveryLedger`.
    private var ledger = AttentionAlertDeliveryLedger()

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

        runtimeObserver = AttentionAlertRuntimeObserver(
            appIsActive: { NSApp.isActive },
            isSnoozed: { SessionSnoozeCenter.shared.isSnoozed($0) }
        ) { [weak self] event, action in
            self?.runtimeChanged(event, action: action)
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
        withdraw(sessionID: sessionID, reason: .viewed)
    }

    /// Re-checks everything already delivered against the current preferences and withdraws
    /// whatever the user has just switched off.
    ///
    /// Two entrances, because muting is not one setting: the Settings page arrives through
    /// `AppSettingsDidChange`, and a row's Mute item calls this directly — it writes to the
    /// project store, which knows nothing about notifications and should not learn.
    func preferencesChanged() {
        guard isStarted else { return }
        for (sessionID, alert) in ledger.deliveredAlerts where !wants(alert, for: sessionID) {
            withdraw(sessionID: sessionID, reason: .preferenceOff)
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
        guard isStarted else { return false }
        guard destination.isValid else {
            journal("Requested update refused", sessionID: sessionID, alert: nil, extra: [
                "event": eventID,
                "reason": "invalidDestination",
                "destination": destination.kind.rawValue,
            ])
            return false
        }

        // A requested update is an explicit promise to notify, so its arrival outranks a
        // visibility snooze just like an approval request or a fresh failure.
        SessionSnoozeCenter.shared.record(.requestedUpdate, for: sessionID)
        if !AppSettings.shared.notifiesOnAttention || AttentionAlertScope.isMuted(sessionID: sessionID) {
            let gate: AttentionAlertGate =
                AppSettings.shared.notifiesOnAttention ? .muted : .masterSwitch
            journal("Requested update refused", sessionID: sessionID, alert: nil, extra: [
                "event": eventID,
                "reason": gate.rawValue,
            ])
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
        content.sound = Self.requestedUpdateSound(for: sessionID)
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

    /// Tells the user a curfew tried everything it had and the session is still working.
    ///
    /// Its own entrance rather than an activity edge, because nothing about the session's state
    /// moved: what ran out was the ladder. Gated exactly like `post(_:for:)` — the master switch,
    /// this kind's own toggle, the session's mute and its snooze — so the one alert that fires at
    /// four in the morning obeys every switch the other three do.
    ///
    /// The body carries the count, which is the difference between a loop that shrugged off one
    /// interrupt and one that shrugged off three, and says plainly whether the agent was stopped.
    /// Clicking it opens the session, where the strip offers Lift.
    func postCurfewGaveUp(sessionID: SessionID, interrupts: Int, stopped: Bool) {
        guard isStarted else { return }
        // Journalled rather than dropped, and this is the alert where that matters most: it is
        // the only one that reports Threading trying something and failing, so a mute swallowing
        // it leaves a session working past its curfew with nothing anywhere having said so.
        if let gate = refusal(of: .curfew, for: sessionID) {
            journal("Attention alert suppressed", sessionID: sessionID, alert: .curfew, extra: [
                "gate": gate.rawValue,
                "interrupts": String(interrupts),
                "stopped": stopped ? "yes" : "no",
            ])
            return
        }

        let body = stopped
            ? L10n.format("Stopped after %lld interrupts", Int64(interrupts))
            : CurfewReceiptWords.gaveUpAlertBody(count: interrupts)
        post(.curfew, for: sessionID, body: body)
    }

    /// Takes the give-up notification back when the curfew that produced it is lifted.
    ///
    /// Narrowed to that alert on purpose: a session may have picked up an ordinary blocked or
    /// unread banner since, and lifting a curfew says nothing about those.
    func withdrawCurfewAlert(sessionID: SessionID) {
        guard isStarted, ledger.delivered(for: sessionID) == .curfew else { return }
        withdraw(sessionID: sessionID, reason: .stateMoved)
    }

    // MARK: - Which Sound An Alert Carries

    /// The sound one event carries on one session, or nil for a silent banner.
    ///
    /// One place, because the two posting paths had drifted into asking the same question
    /// twice. It used to be two questions — a switch for whether a sound played and a picker
    /// for which one — and it is one now: `silent` is a value the picker offers, so the switch
    /// that used to express it has nothing left to say.
    ///
    /// Which alerts sound is no longer a property of the alert. It is the bottom of the
    /// resolution chain — a per-event table holding today's answers — so an event that has
    /// never sounded can be given a sound without a second switch, and the two that sound can
    /// be quieted without losing their banners.
    ///
    /// The global silence gate answers here too, inside `SoundResolution`'s app-facing seam: a
    /// gated alert posts with no sound at all and is otherwise untouched. Both posting paths go
    /// through this one method, which is what keeps the gate from being something either of them
    /// could forget.
    private static func chosenSound(
        for event: SoundEvent,
        sessionID: SessionID
    ) -> UNNotificationSound? {
        SoundResolution.sound(for: event, sessionID: sessionID).notificationSound()
    }

    /// The sound a **state** alert carries: the chain's answer, unless a bell has just made this
    /// session's noise for it.
    ///
    /// The double this removes is one edge with two answers. A `BEL` in a background session
    /// settles `awaitingUser`, which is the `.blocked` alert below, and with Threading behind
    /// another app that banner used to present with its own sound on top of the bell — two
    /// unrelated sounds, ~0 ms apart, for one event.
    ///
    /// It is answered *here*, and in this direction, because of when each half decides. The ring
    /// is synchronous inside `TerminalSession.onBell`; this runs a main-actor turn later, since
    /// the center observes the activity edge through a `Task` and `post` reads the project icon
    /// off disk — work that may not sit on the PTY's byte path. So by the time this is asked,
    /// the bell either happened or it did not, and the question stops being the prediction that
    /// kept this open: not *will* the alert be heard, but *was* the bell.
    ///
    /// **Only the sound goes.** The banner posts, the icon and the thread are unchanged, the
    /// sidebar keeps its hand up and Notification Center keeps its entry. Silenced is not
    /// unnoticed.
    ///
    /// **The error direction is one-way.** Every uncertainty leaves this alert sounding — no
    /// note, an expired note, a bell the gate held, one the limiter rejected, one resolved to
    /// `silent`, one from a standalone terminal. Nothing in this seam can quiet a *bell*, so a
    /// bell cannot go missing for a reason the user cannot see, and the worst case is one sound
    /// too many.
    static func stateAlertSound(
        for alert: AttentionAlert,
        sessionID: SessionID,
        bells: AudibleBellRegister = .shared,
        now: Date = Date()
    ) -> UNNotificationSound? {
        guard !bells.heardBell(for: sessionID, at: now) else { return nil }
        return chosenSound(for: SoundEvent(alert), sessionID: sessionID)
    }

    /// The sound a requested update carries, which asks the register nothing.
    ///
    /// An update the user told an agent to send is not an echo of a bell — no `BEL` produced it
    /// and no state edge did either — so one arriving inside a bell's window is a coincidence,
    /// and quieting it would drop the sound from the one notification the user asked for by
    /// name. Named rather than inlined so that staying out of the seam is a decision with a
    /// test behind it.
    static func requestedUpdateSound(for sessionID: SessionID) -> UNNotificationSound? {
        chosenSound(for: .alertRequestedUpdate, sessionID: sessionID)
    }

    // MARK: - Private Methods

    private func runtimeChanged(_ event: SessionRuntimeDidChange, action: AttentionAlertPolicy.Action) {
        let sessionID = event.sessionID
        let new = event.transition.current.activity

        switch action {
        case .post(let alert):
            // Two ways to arrive at the same place: the edge made whatever was delivered
            // stale, or the state it moved to is one this session no longer alerts on. Either
            // way nothing that describes `old` should still be on screen — but they are not
            // the same *answer*, and only one of them is a switch the user can find and undo.
            if let gate = refusal(of: alert, for: sessionID) {
                journal(
                    "Attention alert suppressed",
                    sessionID: sessionID,
                    alert: alert,
                    extra: ["gate": gate.rawValue, "activity": new.logName]
                )
                withdraw(sessionID: sessionID, reason: .stateMoved)
            } else {
                post(alert, for: sessionID)
            }
        case .clear:
            withdraw(sessionID: sessionID, reason: .stateMoved)
        case .none:
            break
        }
    }

    /// Whether this session posts this kind of alert: the app-wide switch as an outer gate,
    /// then the kind the user chose to keep, then the session's own scope.
    private func wants(_ alert: AttentionAlert, for sessionID: SessionID) -> Bool {
        refusal(of: alert, for: sessionID) == nil
    }

    /// The first gate that refuses this alert, or `nil` where every one of them lets it through.
    ///
    /// The same four questions `wants` used to ask inline, answered by *name* rather than by a
    /// `Bool`, because "no alert appeared" is asked as often as its opposite and a boolean cannot
    /// say which switch was the one. Ordered loudest-first — the master switch is the answer to
    /// give when it is off, whatever else is also off underneath it.
    private func refusal(of alert: AttentionAlert, for sessionID: SessionID) -> AttentionAlertGate? {
        if !AppSettings.shared.notifiesOnAttention { return .masterSwitch }
        if !AppSettings.shared.notifies(on: alert) { return .alertKind }
        if AttentionAlertScope.isMuted(sessionID: sessionID) { return .muted }
        if SessionSnoozeCenter.shared.isSnoozed(sessionID) { return .snoozed }
        return nil
    }

    /// `body` overrides the alert's own sentence for the one case that cannot carry its detail —
    /// see `postCurfewGaveUp(sessionID:interrupts:stopped:)`. Every other caller omits it and
    /// gets what the settings row promised.
    // MARK: - The Journal

    /// Writes what this center just decided into the durable journal.
    ///
    /// **`EventLog`, not `ThreadingLogger`**, and the reason is measured rather than stylistic.
    /// The activity trail one layer down deliberately chose `os_log` at `info` so it could be
    /// read in the past tense — but `info` is not retained either: macOS keeps `.debug` and
    /// `.info` in a memory ring buffer and only `.error`/`.fault` reach disk, which is the
    /// finding `EventLog`'s own header records. Checked on 25 August 2026, asked why a banner
    /// had appeared 90 seconds earlier: `log show --info --predicate 'subsystem ==
    /// "codes.threading" AND category == "session"'` returned **nothing** from the running app
    /// for that minute, while a test host's lines from the same subsystem — written seconds
    /// before the query — came back fine. The ring had already evicted the answer.
    ///
    /// So the one user-visible thing this app does without asking — put a banner on someone's
    /// screen — had no durable record of having happened, and the only honest answer to "why
    /// did I get that" was a list of candidates.
    ///
    /// Nothing user-authored goes on a line: enum tokens, booleans, counts and an opaque
    /// session id. A session's *name* is on the banner and deliberately not here — the journal
    /// is copied into support reports.
    ///
    /// Safe under tests without a guard of its own: every entrance checks `isStarted`, which
    /// the app sets and a test never does.
    private func journal(
        _ message: String,
        sessionID: SessionID,
        alert: AttentionAlert?,
        extra: [String: String] = [:]
    ) {
        var detail = ["session": sessionID.uuidString]
        detail["alert"] = alert?.rawValue
        detail.merge(extra) { _, new in new }
        EventLog.shared.record(.session, message, detail)
    }

    /// How long the same session has been saying the same thing, in whole seconds, or `nil`
    /// where this alert is genuinely new. Rounded because the question is "again?", not "when".
    private func repeatGap(of alert: AttentionAlert, for sessionID: SessionID, now: Date) -> Int? {
        guard let previous = ledger.announcement(for: sessionID),
              previous.alert == alert else { return nil }
        return Int(now.timeIntervalSince(previous.at).rounded())
    }

    /// Asks the system whether an alert may be posted at all, then hands the answer back to
    /// `deliver` on the main actor.
    ///
    /// The order is the point. Everything that records this alert — the banner content, what
    /// the session was told, the journal line — happens *after* the authorization round trip,
    /// so a refusal leaves no trace claiming a banner exists and an edge that arrives during
    /// the round trip is still able to take the alert back before it lands.
    private func post(_ alert: AttentionAlert, for sessionID: SessionID, body: String? = nil) {
        let token = ledger.beginPost(for: sessionID)
        // Captured as tokens rather than reaching back through `self`: this callback is not on
        // the main actor, and the journal must not need a hop it could be dropped in.
        // `EventLog.record` is already serialized behind its own queue.
        let sessionToken = sessionID.uuidString
        let alertToken = alert.rawValue

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                // Asked on the first alert-worthy edge rather than at launch, so the
                // permission dialog appears beside a notification with a reason to exist.
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else {
                        // The one refusal the app's own Settings cannot show and cannot undo.
                        // Silent before this line: every alert afterwards was built, counted as
                        // delivered, and dropped by the system with nothing anywhere saying so.
                        EventLog.shared.record(.session, "Attention alert not delivered", [
                            "session": sessionToken,
                            "alert": alertToken,
                            "gate": AttentionAlertGate.systemDenied.rawValue,
                            "answered": "just now",
                        ])
                        return
                    }
                    Task { @MainActor in
                        AttentionAlertCenter.shared
                            .deliver(alert, for: sessionID, body: body, token: token)
                    }
                }
            case .denied:
                EventLog.shared.record(.session, "Attention alert not delivered", [
                    "session": sessionToken,
                    "alert": alertToken,
                    "gate": AttentionAlertGate.systemDenied.rawValue,
                    "answered": "earlier",
                ])
            default:
                Task { @MainActor in
                    AttentionAlertCenter.shared
                        .deliver(alert, for: sessionID, body: body, token: token)
                }
            }
        }
    }

    /// Builds one alert and hands it to the system, once the system has said it may.
    ///
    /// Both guards exist because this runs a round trip later than the edge that asked for it:
    /// the state may have moved and taken the alert back, and a preference may have been
    /// switched off. An alert landing after either is the litter every withdrawal here avoids.
    private func deliver(
        _ alert: AttentionAlert,
        for sessionID: SessionID,
        body: String?,
        token: AttentionAlertDeliveryLedger.Token
    ) {
        guard isStarted, ledger.isCurrent(token) else { return }
        if let gate = refusal(of: alert, for: sessionID) {
            journal("Attention alert suppressed", sessionID: sessionID, alert: alert, extra: [
                "gate": gate.rawValue,
                "when": "afterAuthorization",
            ])
            return
        }

        let content = UNMutableNotificationContent()
        let session = ProjectStore.shared.session(withID: sessionID)
        let project = ProjectStore.shared.project(forSessionID: sessionID)

        content.title = session?.displayTitle ?? "Threading session"
        if let project { content.subtitle = project.name }
        content.body = body ?? alert.body
        // Whether this kind sounds and which sound it is are one question now, asked of the
        // chain: the built-in answers say `blocked` sounds and the other two do not, which is
        // the ranking the sidebar's filled-versus-hollow marks already draw. Nothing visual
        // turns on it — a silent alert still posts its banner.
        content.sound = Self.stateAlertSound(for: alert, sessionID: sessionID)
        // Once per episode, not once per edge. See `AttentionAlertPolicy.presentation`.
        let now = Date()
        let presentation = AttentionAlertPolicy.presentation(
            of: alert,
            lastAnnounced: ledger.announcement(for: sessionID),
            now: now
        )
        if presentation == .quiet {
            content.interruptionLevel = .passive
            content.sound = nil
        }
        content.userInfo = [AttentionAlertDefaults.sessionKey: sessionID.uuidString]
        if let project { content.threadIdentifier = project.id.uuidString }
        if let icon = project?.icon,
           let png = ProjectIconStore.pngData(for: icon),
           let attachment = AttentionAlertIcon.attachment(iconPNGData: png) {
            content.attachments = [attachment]
        }
        let gap = repeatGap(of: alert, for: sessionID, now: now)
        ledger.recordDelivery(of: alert, for: sessionID, at: now)

        // `repeat` is the field this whole record exists for. A session that keeps re-deriving
        // the same alert — the row leaves the flag and lands straight back on it — produces a
        // banner every time, and from outside those are indistinguishable from a session that
        // genuinely wanted the user fifteen times. `sinceLast` is what tells them apart.
        var reported = [
            "cause": AgentRuntime.shared.activityCause(sessionID: sessionID)?.rawValue ?? "unknown",
            "appActive": NSApp.isActive ? "yes" : "no",
            "sounds": content.sound == nil ? "no" : "yes",
            "repeat": gap == nil ? "no" : "yes",
            "presented": presentation == .quiet ? "quiet" : "interrupt",
        ]
        reported["sinceLast"] = gap.map(String.init)
        journal("Attention alert posted", sessionID: sessionID, alert: alert, extra: reported)

        // The request id is the session id, so a session's newer state replaces its older
        // notification instead of stacking beneath it.
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: sessionID.uuidString,
            content: content,
            trigger: nil
        ))
    }

    /// Takes this session's banner back, and says why.
    ///
    /// The reason is not decoration. `viewed` is the only one that means the user dealt with
    /// the session, and it is the only one that forgets what the session was last told — so a
    /// banner the user actually saw makes the next one news again, while a banner that merely
    /// went stale leaves the announcement standing and the re-post records itself as a repeat.
    private func withdraw(sessionID: SessionID, reason: AttentionAlertWithdrawal) {
        // Also invalidates any post still waiting on the system's authorization answer, so an
        // alert cannot land after the edge that took it back. See `AttentionAlertDeliveryLedger`.
        let had = ledger.withdraw(sessionID, reason: reason)
        if had != nil {
            journal(
                "Attention alert withdrawn",
                sessionID: sessionID,
                alert: had,
                extra: ["reason": reason.rawValue]
            )
        }
        let identifiers = [sessionID.uuidString]
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func forget(_ sessionID: SessionID) {
        withdraw(sessionID: sessionID, reason: .sessionEnded)
    }

    /// Switching any of it off withdraws what it described: an off switch that leaves its
    /// traces behind is not off. The master switch is the loudest case and no longer the only
    /// one — a single kind, or one session's mute, has the same obligation.
    private func settingsChanged() {
        guard AppSettings.shared.notifiesOnAttention else {
            ledger.withdrawAll()
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
    /// What an install that has never chosen hears: macOS's own notification tone, which is
    /// what every alert carried before the sound was a setting.
    static let sound: SoundChoice = .system

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
