import Foundation
import ThreadingRemoteKit

enum PhoneMirrorDefaults {
    /// An agent writing five files, or a page settling through redirects, becomes one revision.
    static let revisionCoalescing: TimeInterval = 0.15
    /// How often a live mirror checks that its tab still exists and is still shared. The same
    /// cadence as the browser tunnel's authority monitor; it runs only while a mirror does.
    static let sourceCheckInterval: TimeInterval = 2
    /// One mirror per phone, and at most this many at once (`RemoteOwnerDeviceRegistry` allows
    /// 32 devices; nobody mirrors to more than a handful).
    static let maximumSessions = 4
    /// How long the chip keeps saying how a mirror ended, with **Mirror again** beside it.
    static let endedNoticeLifetime: TimeInterval = 600
    static let lastDeviceKey = "phoneMirror.lastDevice"
}

/// One owner phone, as Remote Access identifies it.
struct PhoneMirrorDevice: Hashable, Sendable {
    let shareID: String
    let deviceID: String
}

/// Where a mirror's frames go: the phone's authenticated events socket. Called from the frame
/// worker, never the main actor.
protocol PhoneMirrorChannel: AnyObject, Sendable {
    func sendPhoneMirrorFrame(_ text: String)
}

/// What the Mac's chip says about one mirror.
enum PhoneMirrorStatus: Equatable, Sendable {
    /// The phone has the state and has not answered yet.
    case connecting
    case showing
    /// The person's finger is on the stage.
    case interacting
    /// A phone that had joined left the app; the Mac keeps the mirror waiting.
    case away
    /// The invite went to a suspended phone.
    case notified
    /// The phone is in use, so the mirror waits as a quiet offer.
    case inUse
    /// The app opened after the fresh-start window; the mirror waits as a quiet offer.
    case waiting
    /// Nothing can reach the phone until Threading is opened on it.
    case openOnPhone
    /// The phone has Mirror switched off for this Mac.
    case disabledOnPhone
    case ended(RemoteMirrorEndReason)
}

/// The chip's whole input for one browser.
struct PhoneMirrorChipState: Equatable, Sendable {
    /// Nil once the mirror has ended and only its notice remains.
    let mirrorID: String?
    let source: PhoneMirrorSource
    let deviceName: String
    let status: PhoneMirrorStatus
    let mode: RemoteMirrorMode
    let revision: UInt64
    let otherDevices: [PhoneMirrorCandidate]
}

/// A phone the Mac could mirror to.
struct PhoneMirrorCandidate: Hashable, Sendable {
    let device: PhoneMirrorDevice
    let name: String
    /// Connected now, with Mirror on for this Mac.
    let isLive: Bool
}

enum PhoneMirrorStartOutcome: Equatable, Sendable {
    case started(mirrorID: String)
    case sourceUnavailable
    case noPhone
}

/// Something about mirroring changed; the chip and the command palette re-read.
struct PhoneMirrorDidChange: AppEvent {
    static let name = Notification.Name("phoneMirrorDidChange")
}

/// A cancellable piece of scheduled work.
@MainActor
protocol PhoneMirrorTimer: AnyObject {
    func cancel()
}

/// The Mac half of Mirror. It owns every mirror session; the phone renders what a session names
/// and reports whether it is showing it.
///
/// Starting asks nothing on either device: the click is the consent, because the phone is the
/// owner's own paired device. What protects a phone is on the phone — it never takes the stage
/// while in use — and here: owner devices only, one mirror per phone, every end reaches both
/// sides, and nothing an agent does can open a stage.
@MainActor
final class PhoneMirrorCoordinator {
    struct Environment {
        var now: @MainActor () -> Date
        var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> PhoneMirrorTimer
        var hostID: @MainActor () -> String
        var hostName: @MainActor () -> String
        var source: @MainActor (PhoneMirrorSource) -> PhoneMirrorSourceSnapshot?
        var inviteTargets: @MainActor () -> [RemoteMirrorInviteTarget]
        var sendInvite: @MainActor (
            RemoteNotificationEventDTO, RemoteMirrorInviteTarget,
            @escaping @MainActor (RemoteNotificationPushResult) -> Void
        ) -> Void
        var withdrawInvite: @MainActor (RemoteNotificationRetractionDTO, RemoteMirrorInviteTarget) -> Void
        var deviceName: @MainActor (PhoneMirrorDevice) -> String?
        var defaults: UserDefaults
        var didChange: @MainActor () -> Void
    }

    static let shared = PhoneMirrorCoordinator(environment: .system)

    @MainActor
    private final class Session {
        let id: String
        var device: PhoneMirrorDevice
        let source: PhoneMirrorSource
        var startedAt: Date
        var revision: UInt64 = 1
        var url: URL
        var title: String
        var mode: RemoteMirrorMode = .interactive
        var status: PhoneMirrorStatus = .connecting
        var hasJoined = false
        var invite: (eventID: String, target: RemoteMirrorInviteTarget)?
        var browser: ObjectIdentifier
        var observation: PhoneMirrorSourceObservation?
        var expiry: PhoneMirrorTimer?
        var inviteExpiry: PhoneMirrorTimer?
        var pendingRevision: PhoneMirrorTimer?
        var pendingDocument = false

        init(id: String, device: PhoneMirrorDevice, source: PhoneMirrorSource, startedAt: Date,
             snapshot: PhoneMirrorSourceSnapshot) {
            self.id = id
            self.device = device
            self.source = source
            self.startedAt = startedAt
            url = snapshot.url
            title = RemoteMirror.boundedTitle(snapshot.title)
            browser = ObjectIdentifier(snapshot.browser)
        }
    }

    private struct LiveDevice {
        weak var channel: PhoneMirrorChannel?
        let channelID: ObjectIdentifier
        var availability: RemoteMirrorAvailability
        var helloAt: Date
    }

    private struct EndedNotice {
        let source: PhoneMirrorSource
        let browser: ObjectIdentifier
        let device: PhoneMirrorDevice
        let reason: RemoteMirrorEndReason
        let endedAt: Date
    }

    private let environment: Environment
    private var sessions: [String: Session] = [:]
    private var live: [PhoneMirrorDevice: LiveDevice] = [:]
    private var endedNotices: [ObjectIdentifier: EndedNotice] = [:]
    private var sourceCheck: PhoneMirrorTimer?

    init(environment: Environment) {
        self.environment = environment
    }

    // MARK: - Reading

    var hasSessions: Bool { !sessions.isEmpty }

    /// The phones this Mac could mirror to, most recently active first.
    func candidates() -> [PhoneMirrorCandidate] {
        let liveDevices = live
            .filter { $0.value.availability == .enabled && $0.value.channel != nil }
            .sorted { $0.value.helloAt > $1.value.helloAt }
            .map(\.key)
        var ordered = liveDevices
        var others = environment.inviteTargets()
            .map { PhoneMirrorDevice(shareID: $0.identity.shareID, deviceID: $0.identity.deviceID) }
            .filter { device in !ordered.contains(device) && live[device]?.availability != .disabled }
        if let last = lastDevice, let index = others.firstIndex(of: last) {
            others.insert(others.remove(at: index), at: 0)
        }
        ordered.append(contentsOf: others)
        return ordered.map { device in
            PhoneMirrorCandidate(
                device: device,
                name: name(of: device),
                isLive: liveDevices.contains(device)
            )
        }
    }

    func chipState(forBrowser browser: ObjectIdentifier) -> PhoneMirrorChipState? {
        if let session = sessions.values.first(where: { $0.browser == browser }) {
            return PhoneMirrorChipState(
                mirrorID: session.id,
                source: session.source,
                deviceName: name(of: session.device),
                status: session.status,
                mode: session.mode,
                revision: session.revision,
                otherDevices: candidates().filter { $0.device != session.device }
            )
        }
        guard let notice = endedNotices[browser],
              environment.now().timeIntervalSince(notice.endedAt) < PhoneMirrorDefaults.endedNoticeLifetime
        else { return nil }
        return PhoneMirrorChipState(
            mirrorID: nil,
            source: notice.source,
            deviceName: name(of: notice.device),
            status: .ended(notice.reason),
            mode: .interactive,
            revision: 0,
            otherDevices: []
        )
    }

    func mirrorID(forBrowser browser: ObjectIdentifier) -> String? {
        sessions.values.first { $0.browser == browser }?.id
    }

    /// Whether an invite, by its notification id, still applies: its mirror runs and the phone
    /// has not joined.
    func isInviteCurrent(eventID: String) -> Bool {
        sessions.values.contains { $0.invite?.eventID == eventID && !$0.hasJoined }
    }

    // MARK: - Starting and stopping

    /// Starts mirroring `source` to `device`, or to the most recently active phone.
    @discardableResult
    func start(_ source: PhoneMirrorSource, on device: PhoneMirrorDevice? = nil) -> PhoneMirrorStartOutcome {
        guard let snapshot = environment.source(source) else { return .sourceUnavailable }
        guard let target = device ?? candidates().first?.device else { return .noPhone }
        if let existing = sessions.values.first(where: { $0.source == source }) {
            if existing.device == target, existing.hasJoined {
                existing.revision += 1
                sendState(existing)
                changed()
                return .started(mirrorID: existing.id)
            }
            // Starting again is a fresh offer the phone weighs anew — a phone that has put the
            // keyboard away now takes it, one still in use still only shows the quiet offer.
            end(existing, reason: .replaced)
        }
        if let other = sessions.values.first(where: { $0.device == target }) {
            end(other, reason: .replaced)
        }
        if sessions.count >= PhoneMirrorDefaults.maximumSessions,
           let oldest = sessions.values.min(by: { $0.startedAt < $1.startedAt }) {
            end(oldest, reason: .replaced)
        }
        let session = Session(
            id: UUID().uuidString.lowercased(),
            device: target,
            source: source,
            startedAt: environment.now(),
            snapshot: snapshot
        )
        sessions[session.id] = session
        endedNotices[session.browser] = nil
        session.observation = snapshot.browser.observePhoneMirrorChanges { [weak self, sessionID = session.id] change in
            self?.sourceChanged(sessionID: sessionID, change: change)
        }
        lastDevice = target
        session.expiry = environment.schedule(RemoteMirror.offerLifetime) { [weak self, sessionID = session.id] in
            guard let self, let session = self.sessions[sessionID], !session.hasJoined else { return }
            self.end(session, reason: .expired)
        }
        deliver(session)
        startSourceCheckIfNeeded()
        changed()
        return .started(mirrorID: session.id)
    }

    func stop(mirrorID: String) {
        guard let session = sessions[mirrorID] else { return }
        end(session, reason: .stoppedOnMac)
    }

    /// Moves a running mirror to another phone, as if it had been started there.
    func move(mirrorID: String, to device: PhoneMirrorDevice) {
        guard let session = sessions[mirrorID], session.device != device else { return }
        let source = session.source
        end(session, reason: .replaced)
        start(source, on: device)
    }

    /// **Reload on iPhone**: a new revision of the same page.
    func reload(mirrorID: String) {
        guard let session = sessions[mirrorID] else { return }
        session.revision += 1
        sendState(session)
        changed()
    }

    func setMode(_ mode: RemoteMirrorMode, mirrorID: String) {
        guard let session = sessions[mirrorID], session.mode != mode else { return }
        session.mode = mode
        sendState(session)
        changed()
    }

    /// Clears the ended notice so the chip disappears.
    func dismissNotice(forBrowser browser: ObjectIdentifier) {
        guard endedNotices.removeValue(forKey: browser) != nil else { return }
        changed()
    }

    // MARK: - The phone's side

    /// A phone that understands Mirror said so on its events socket. `showing` is the mirror its
    /// stage still holds from before it went away; one this Mac no longer runs is ended there.
    func phoneSaidHello(
        _ device: PhoneMirrorDevice,
        availability: RemoteMirrorAvailability,
        showing: String? = nil,
        channel: PhoneMirrorChannel
    ) {
        live[device] = LiveDevice(
            channel: channel,
            channelID: ObjectIdentifier(channel),
            availability: availability,
            helloAt: environment.now()
        )
        if let showing, sessions[showing]?.device != device {
            send(RemoteMirrorEndedDTO(mirrorID: showing, reason: .expired), to: channel)
        }
        for session in sessions.values where session.device == device {
            if availability == .disabled {
                end(session, reason: .disabled)
            } else {
                deliver(session)
            }
        }
        changed()
    }

    func phoneJoined(_ device: PhoneMirrorDevice, mirrorID: String) {
        guard let session = sessions[mirrorID], session.device == device else { return }
        session.hasJoined = true
        session.status = .showing
        session.expiry?.cancel()
        session.expiry = nil
        withdrawInvite(session)
        changed()
    }

    func phoneHeld(_ device: PhoneMirrorDevice, mirrorID: String, reason: RemoteMirrorHoldReason) {
        guard let session = sessions[mirrorID], session.device == device else { return }
        switch reason {
        case .inUse: session.status = .inUse
        case .waiting: session.status = .waiting
        case .disabled:
            end(session, reason: .disabled)
            return
        }
        changed()
    }

    func phonePresence(_ device: PhoneMirrorDevice, mirrorID: String, presence: RemoteMirrorPresence) {
        guard let session = sessions[mirrorID], session.device == device, session.hasJoined else { return }
        let status: PhoneMirrorStatus = presence == .touching ? .interacting : .showing
        guard session.status != status else { return }
        session.status = status
        changed()
    }

    func phoneLeft(_ device: PhoneMirrorDevice, mirrorID: String) {
        guard let session = sessions[mirrorID], session.device == device else { return }
        end(session, reason: .endedOnPhone, tellsPhone: false)
    }

    /// The phone's events socket closed: it left the app, locked, or lost the network.
    func channelClosed(_ channel: PhoneMirrorChannel) {
        let id = ObjectIdentifier(channel)
        guard let device = live.first(where: { $0.value.channelID == id })?.key else { return }
        live[device] = nil
        for session in sessions.values where session.device == device {
            if session.hasJoined {
                session.status = .away
                session.expiry?.cancel()
                session.expiry = environment.schedule(RemoteMirror.awayLifetime) { [weak self, sessionID = session.id] in
                    guard let self, let session = self.sessions[sessionID], session.status == .away else { return }
                    self.end(session, reason: .expired)
                }
            } else if session.status == .connecting || session.status == .inUse || session.status == .waiting {
                // It saw the offer and did not take it; it waits for the app to come back.
                session.status = .openOnPhone
            }
        }
        changed()
    }

    /// Remote Access stopped or a device was revoked.
    func endAll(reason: RemoteMirrorEndReason, shareID: String? = nil) {
        for session in sessions.values where shareID == nil || session.device.shareID == shareID {
            end(session, reason: reason)
        }
        if let shareID {
            live = live.filter { $0.key.shareID != shareID }
        } else {
            live.removeAll()
        }
        changed()
    }

    // MARK: - Delivery

    private func deliver(_ session: Session) {
        if let device = live[session.device], device.channel != nil {
            switch device.availability {
            case .enabled:
                if !session.hasJoined || session.status == .away {
                    session.status = session.hasJoined ? .showing : .connecting
                }
                sendState(session)
            case .disabled:
                end(session, reason: .disabled)
            }
            return
        }
        if session.hasJoined {
            session.status = .away
            return
        }
        guard let target = environment.inviteTargets().first(where: {
            $0.identity.shareID == session.device.shareID && $0.identity.deviceID == session.device.deviceID
        }), target.canPush else {
            session.status = .openOnPhone
            return
        }
        sendInvite(session, to: target)
    }

    private func sendState(_ session: Session) {
        guard let device = live[session.device], device.availability == .enabled,
              let channel = device.channel else { return }
        let age = max(0, environment.now().timeIntervalSince(session.startedAt))
        let state = RemoteMirrorStateDTO(
            mirrorID: session.id,
            mirrorRevision: session.revision,
            sourceTitle: session.title,
            render: RemoteMirrorRenderDTO(
                sessionID: session.source.sessionID.uuidString,
                browserTabID: session.source.tabID.uuidString,
                url: session.url.absoluteString
            ),
            mode: session.mode,
            offerAgeMilliseconds: Int64(age * 1_000),
            rejoin: session.hasJoined
        )
        send(state, to: channel)
    }

    private func sendInvite(_ session: Session, to target: RemoteMirrorInviteTarget) {
        withdrawInvite(session)
        let macName = environment.hostName()
        let body = target.includesPreviews ? "\(session.title) — tap to show" : "Tap to show"
        let event = RemoteNotificationEventDTO(
            kind: .mirrorInvite,
            hostID: environment.hostID(),
            sessionID: session.id,
            title: "Mirror from \(macName)",
            body: body,
            titleLocalization: .init(key: "Mirror from %@", arguments: [macName]),
            bodyLocalization: target.includesPreviews
                ? .init(key: "%@ — tap to show", arguments: [session.title])
                : .init(key: "Tap to show"),
            createdAt: environment.now().timeIntervalSince1970
        )
        session.invite = (event.id, target)
        session.status = .notified
        environment.sendInvite(event, target) { [weak self, sessionID = session.id] result in
            guard let self, let session = self.sessions[sessionID], !session.hasJoined,
                  session.invite?.eventID == event.id, !result.accepted else { return }
            // A push that never left this Mac, or that APNs refused, cannot be waited on.
            session.invite = nil
            session.status = .openOnPhone
            self.changed()
        }
        session.inviteExpiry?.cancel()
        session.inviteExpiry = environment.schedule(TimeInterval(RemoteMirror.inviteLifetime)) {
            [weak self, sessionID = session.id] in
            guard let self, let session = self.sessions[sessionID], !session.hasJoined else { return }
            self.withdrawInvite(session)
            if session.status == .notified { session.status = .openOnPhone }
            self.changed()
        }
    }

    private func withdrawInvite(_ session: Session) {
        session.inviteExpiry?.cancel()
        session.inviteExpiry = nil
        guard let invite = session.invite else { return }
        session.invite = nil
        guard invite.target.canRetract else { return }
        environment.withdrawInvite(
            RemoteNotificationRetractionDTO(
                hostID: environment.hostID(),
                sessionID: session.id,
                eventID: invite.eventID,
                kind: .mirrorInvite
            ),
            invite.target
        )
    }

    // MARK: - The source

    private func sourceChanged(sessionID: String, change: PhoneMirrorSourceChange) {
        guard let session = sessions[sessionID] else { return }
        if change != .title { session.pendingDocument = true }
        guard session.pendingRevision == nil else { return }
        session.pendingRevision = environment.schedule(PhoneMirrorDefaults.revisionCoalescing) {
            [weak self, sessionID] in
            guard let self, let session = self.sessions[sessionID] else { return }
            session.pendingRevision = nil
            self.refreshSource(session)
        }
    }

    private func refreshSource(_ session: Session) {
        guard let snapshot = environment.source(session.source),
              ObjectIdentifier(snapshot.browser) == session.browser else {
            end(session, reason: .sourceClosed)
            return
        }
        let title = RemoteMirror.boundedTitle(snapshot.title)
        let moved = session.pendingDocument || snapshot.url != session.url
        session.pendingDocument = false
        guard moved || title != session.title else { return }
        session.url = snapshot.url
        session.title = title
        if moved { session.revision += 1 }
        sendState(session)
        changed()
    }

    private func startSourceCheckIfNeeded() {
        guard sourceCheck == nil, !sessions.isEmpty else { return }
        sourceCheck = environment.schedule(PhoneMirrorDefaults.sourceCheckInterval) { [weak self] in
            guard let self else { return }
            self.sourceCheck = nil
            for session in self.sessions.values {
                guard let snapshot = self.environment.source(session.source),
                      ObjectIdentifier(snapshot.browser) == session.browser else {
                    self.end(session, reason: .sourceClosed)
                    continue
                }
            }
            self.startSourceCheckIfNeeded()
        }
    }

    // MARK: - Ending

    private func end(_ session: Session, reason: RemoteMirrorEndReason, tellsPhone: Bool = true) {
        guard sessions.removeValue(forKey: session.id) != nil else { return }
        if tellsPhone, let channel = live[session.device]?.channel {
            send(RemoteMirrorEndedDTO(mirrorID: session.id, reason: reason), to: channel)
        }
        withdrawInvite(session)
        session.observation?.invalidate()
        session.expiry?.cancel()
        session.pendingRevision?.cancel()
        // Stopping on this Mac, or starting elsewhere, needs no notice; anything the person did not
        // do here says what happened, with **Mirror again** beside it.
        if reason != .replaced, reason != .stoppedOnMac {
            endedNotices[session.browser] = EndedNotice(
                source: session.source,
                browser: session.browser,
                device: session.device,
                reason: reason,
                endedAt: environment.now()
            )
        }
        if sessions.isEmpty {
            sourceCheck?.cancel()
            sourceCheck = nil
        }
        changed()
    }

    // MARK: - Helpers

    private func changed() {
        environment.didChange()
    }

    private func name(of device: PhoneMirrorDevice) -> String {
        environment.deviceName(device) ?? "iPhone"
    }

    private var lastDevice: PhoneMirrorDevice? {
        get {
            guard let pair = environment.defaults.stringArray(forKey: PhoneMirrorDefaults.lastDeviceKey),
                  pair.count == 2 else { return nil }
            return PhoneMirrorDevice(shareID: pair[0], deviceID: pair[1])
        }
        set {
            if let newValue {
                environment.defaults.set([newValue.shareID, newValue.deviceID], forKey: PhoneMirrorDefaults.lastDeviceKey)
            } else {
                environment.defaults.removeObject(forKey: PhoneMirrorDefaults.lastDeviceKey)
            }
        }
    }

    /// Frames are encoded on one serial worker, so they stay in order and the main actor only
    /// decides what to send.
    static let frameQueue = DispatchQueue(label: "codes.threading.phone-mirror.frames", qos: .userInitiated)

    private func send<Frame: Encodable & Sendable>(_ frame: Frame, to channel: PhoneMirrorChannel) {
        Self.frameQueue.async {
            guard let data = try? JSONEncoder().encode(frame) else { return }
            channel.sendPhoneMirrorFrame(String(decoding: data, as: UTF8.self))
        }
    }
}

// MARK: - Production environment

private final class PhoneMirrorTaskTimer: PhoneMirrorTimer {
    private var task: Task<Void, Never>?

    init(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            work()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

extension PhoneMirrorCoordinator.Environment {
    /// The process's own Remote Access, notification service and clock.
    static var system: Self {
        Self(
            now: { Date() },
            schedule: { seconds, work in PhoneMirrorTaskTimer(after: seconds, work) },
            hostID: { RemoteHostIdentity.current.id },
            hostName: { RemoteHostIdentity.current.name },
            source: { source in RemoteWorkspaceBridge.mirrorSource(for: source.sessionID, tabID: source.tabID) },
            inviteTargets: { RemoteNotificationService.shared.mirrorInviteTargets() },
            sendInvite: { event, target, completion in
                RemoteNotificationService.shared.sendMirrorInvite(event, to: target, completion: completion)
            },
            withdrawInvite: { retraction, target in
                RemoteNotificationService.shared.withdrawMirrorInvite(retraction, from: target)
            },
            deviceName: { device in
                RemoteAccessCoordinator.shared.pairedOwnerDevices
                    .first { $0.id == device.shareID }?.displayName
            },
            defaults: .standard,
            didChange: { NotificationCenter.default.post(PhoneMirrorDidChange()) }
        )
    }
}

/// What the Remote Access server may ask of Mirror: only the phone's own signals.
@MainActor
protocol RemotePhoneMirrorSignalling: AnyObject {
    func phoneSaidHello(
        _ device: PhoneMirrorDevice,
        availability: RemoteMirrorAvailability,
        showing: String?,
        channel: PhoneMirrorChannel
    )
    func phoneJoined(_ device: PhoneMirrorDevice, mirrorID: String)
    func phoneHeld(_ device: PhoneMirrorDevice, mirrorID: String, reason: RemoteMirrorHoldReason)
    func phonePresence(_ device: PhoneMirrorDevice, mirrorID: String, presence: RemoteMirrorPresence)
    func phoneLeft(_ device: PhoneMirrorDevice, mirrorID: String)
}

extension PhoneMirrorCoordinator: RemotePhoneMirrorSignalling {}

extension RemoteConnection: PhoneMirrorChannel {
    func sendPhoneMirrorFrame(_ text: String) {
        sendText(text)
    }
}
