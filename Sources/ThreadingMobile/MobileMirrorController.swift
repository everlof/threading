import Foundation
import ThreadingGlanceKit
import ThreadingRemoteKit
import UIKit
import UserNotifications

/// The phone half of Mirror.
///
/// The Mac owns each mirror; this decides what the phone does with one. Turning Mirror on at the
/// Mac asks nothing: an idle phone takes the stage, a phone in use shows only the quiet
/// *Mirror ready · Show* offer, and a phone where Threading is not in front gets a notification
/// that opens straight into the stage. Every exit returns to the screen beneath, untouched.
@MainActor
final class MobileMirrorController: ObservableObject {
    /// A mirror the phone holds without showing it.
    struct Offer: Equatable {
        let pairingID: String
        let macName: String
        let state: RemoteMirrorStateDTO
    }

    @Published private(set) var offer: Offer?
    @Published private(set) var isStageShown = false

    private weak var model: RemoteAppModel?
    private let preferences: MobileMirrorPreferences
    private let guide: MobileMirrorGuideStore
    private let interaction: MobileInteractionMonitor
    private var stage: MobileMirrorStagePresenter?
    private var current: (pairingID: String, state: RemoteMirrorStateDTO)?
    private var awaiting: (pairingID: String, mirrorID: String, task: Task<Void, Never>)?
    private let activity = MobileMirrorLiveActivity()
    private var offerView: MobileMirrorOfferPresenter?

    init(
        preferences: MobileMirrorPreferences = .shared,
        guide: MobileMirrorGuideStore = .shared,
        interaction: MobileInteractionMonitor = .shared
    ) {
        self.preferences = preferences
        self.guide = guide
        self.interaction = interaction
    }

    func attach(_ model: RemoteAppModel) {
        self.model = model
        MirrorEndIntent.handler = { [weak self] mirrorID, hostID in
            await self?.endFromLiveActivity(mirrorID: mirrorID, hostID: hostID)
        }
        #if DEBUG
        if let id = ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey],
           let fixture = MobileDemoFixture(rawValue: id) {
            Task { [weak self] in
                // After the scene has connected and the demo dashboard is up.
                try? await Task.sleep(for: .seconds(1.5))
                self?.startDemo(fixture)
            }
        }
        #endif
    }

    #if DEBUG
    /// The Mirror demo fixtures: the stage over a local prototype page, with no Mac.
    private func startDemo(_ fixture: MobileDemoFixture) {
        let macName = "MacBook Pro"
        switch fixture {
        case .mirrorGuide, .mirrorControls:
            guide.resetGuide()
        case .mirrorLive:
            guide.completeGuide()
        case .mirrorOffer:
            let state = RemoteMirrorStateDTO(
                mirrorID: "demo-mirror", mirrorRevision: 1, sourceTitle: "festina-prototype",
                render: .init(sessionID: "demo", browserTabID: "demo", url: "https://festina.example/"),
                mode: .interactive, offerAgeMilliseconds: 0, rejoin: false
            )
            offer = Offer(pairingID: model?.activeHostID ?? "demo", macName: macName, state: state)
            presentOffer()
            return
        default:
            return
        }
        let presenter = presentStage(macName: macName)
        presenter.showDemo(title: "festina-prototype", step: fixture == .mirrorControls ? .controls : nil)
    }
    #endif

    // MARK: - The events socket

    /// The events socket for `pairingID` came up: say that this phone understands Mirror, whether
    /// it takes mirrors from this Mac, and which mirror it is still showing, if any.
    func eventsConnected(pairingID: String) {
        guard let host = host(pairingID), host.isOwnerDevice else { return }
        let availability: RemoteMirrorAvailability = preferences.isEnabled(hostID: Self.macID(host))
            ? .enabled : .disabled
        send(RemoteClientMessage(
            type: RemoteMirrorSignal.hello.rawValue,
            id: current?.pairingID == pairingID ? current?.state.mirrorID : nil,
            state: availability.rawValue
        ))
    }

    func receive(_ state: RemoteMirrorStateDTO, pairingID: String) {
        guard let host = host(pairingID), host.isOwnerDevice else { return }
        let isShowing = isStageShown && current?.state.mirrorID == state.mirrorID
        let isAwaiting = awaiting?.pairingID == pairingID && awaiting?.mirrorID == state.mirrorID
        let arrival = MobileMirrorArrivalPolicy.decide(MobileMirrorArrivalContext(
            isEnabled: preferences.isEnabled(hostID: Self.macID(host)),
            isAppActive: UIApplication.shared.applicationState == .active,
            isShowingThisMirror: isShowing,
            isAwaitingThisMirror: isAwaiting,
            isOfferingThisMirror: offer?.state.mirrorID == state.mirrorID,
            offerAge: TimeInterval(state.offerAgeMilliseconds) / 1_000,
            rejoin: state.rejoin,
            isInUse: interaction.state.isInUse(at: Date())
        ))
        switch arrival {
        case .stage:
            show(state, pairingID: pairingID, macName: host.name)
        case let .quietOffer(reason):
            offer = Offer(pairingID: pairingID, macName: host.name, state: state)
            presentOffer()
            send(RemoteClientMessage(type: RemoteMirrorSignal.hold.rawValue, id: state.mirrorID, state: reason.rawValue))
        case .notify:
            offer = Offer(pairingID: pairingID, macName: host.name, state: state)
            presentOffer()
            postLocalInvite(state, host: host)
            send(RemoteClientMessage(
                type: RemoteMirrorSignal.hold.rawValue,
                id: state.mirrorID,
                state: RemoteMirrorHoldReason.waiting.rawValue
            ))
        case .refuse:
            send(RemoteClientMessage(
                type: RemoteMirrorSignal.hold.rawValue,
                id: state.mirrorID,
                state: RemoteMirrorHoldReason.disabled.rawValue
            ))
        }
    }

    func receive(_ ended: RemoteMirrorEndedDTO, pairingID: String) {
        if offer?.state.mirrorID == ended.mirrorID {
            offer = nil
            dismissOffer()
        }
        removeLocalInvite(mirrorID: ended.mirrorID)
        if awaiting?.mirrorID == ended.mirrorID {
            awaiting?.task.cancel()
            awaiting = nil
            stage?.showEnded(MobileL10n.string("Mirroring ended on the Mac."))
        }
        guard current?.state.mirrorID == ended.mirrorID else { return }
        closeStage(sendsLeave: false, endedMessage: Self.endedMessage(ended.reason))
    }

    // MARK: - Opening

    /// The person tapped the quiet offer.
    func showOffer() {
        guard let offer, let host = host(offer.pairingID) else { return }
        show(offer.state, pairingID: offer.pairingID, macName: host.name)
    }

    /// The person tapped the invite notification: open the stage at once, connecting, and let
    /// the content arrive behind it.
    func openFromNotification(_ event: RemoteNotificationEventDTO) -> Bool {
        guard let model,
              let host = model.hosts.first(where: { ($0.hostID ?? $0.id) == event.hostID && $0.isOwnerDevice })
        else { return false }
        awaitMirror(event.sessionID, host: host, sourceTitle: nil)
        return true
    }

    /// **Return** in the Live Activity.
    func openFromLiveActivity(_ route: MirrorReturnRoute) -> Bool {
        guard let model,
              let host = model.hosts.first(where: { ($0.hostID ?? $0.id) == route.hostID && $0.isOwnerDevice })
        else { return false }
        if isStageShown, current?.state.mirrorID == route.mirrorID { return true }
        awaitMirror(route.mirrorID, host: host, sourceTitle: current?.state.sourceTitle)
        return true
    }

    private func awaitMirror(_ mirrorID: String, host: PairedRemoteHost, sourceTitle: String?) {
        removeLocalInvite(mirrorID: mirrorID)
        if let offer, offer.state.mirrorID == mirrorID {
            show(offer.state, pairingID: offer.pairingID, macName: host.name)
            return
        }
        awaiting?.task.cancel()
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MobileMirrorDefaults.notificationJoinTimeout))
            guard !Task.isCancelled, let self, self.awaiting?.mirrorID == mirrorID else { return }
            self.awaiting = nil
            self.stage?.showEnded(MobileL10n.string("This mirror is no longer on the Mac."))
        }
        awaiting = (host.id, mirrorID, timeout)
        presentStage(macName: host.name).showConnecting(sourceTitle: sourceTitle)
        if model?.activeHostID != host.id { model?.selectHost(host.id) }
    }

    // MARK: - The stage

    private func show(_ state: RemoteMirrorStateDTO, pairingID: String, macName: String) {
        awaiting?.task.cancel()
        awaiting = nil
        if offer?.state.mirrorID == state.mirrorID {
            offer = nil
            dismissOffer()
        }
        removeLocalInvite(mirrorID: state.mirrorID)
        let isNewMirror = current?.state.mirrorID != state.mirrorID
        if !isNewMirror, let previous = current?.state, previous.mirrorRevision > state.mirrorRevision {
            return
        }
        // A reconnect re-sends the revision already on screen: keep the page, take the mode.
        let reloads = isNewMirror || current?.state.mirrorRevision != state.mirrorRevision || !isStageShown
        current = (pairingID, state)
        let presenter = presentStage(macName: macName)
        presenter.apply(state, client: model?.client, isNewMirror: isNewMirror, reloads: reloads)
        send(RemoteClientMessage(type: RemoteMirrorSignal.join.rawValue, id: state.mirrorID))
        if let host = host(pairingID) {
            activity.show(macName: macName, hostID: Self.macID(host), mirrorID: state.mirrorID, title: state.sourceTitle)
        }
    }

    private func presentStage(macName: String) -> MobileMirrorStagePresenter {
        if let stage {
            stage.macName = macName
            return stage
        }
        let presenter = MobileMirrorStagePresenter(macName: macName, guide: guide)
        presenter.onEnd = { [weak self] in self?.endFromPhone() }
        presenter.onTouching = { [weak self] touching in
            guard let self, let mirrorID = self.current?.state.mirrorID else { return }
            self.send(RemoteClientMessage(
                type: RemoteMirrorSignal.presence.rawValue,
                id: mirrorID,
                state: (touching ? RemoteMirrorPresence.touching : .idle).rawValue
            ))
        }
        presenter.onDismissed = { [weak self] in
            guard let self else { return }
            self.stage = nil
            self.isStageShown = false
        }
        stage = presenter
        isStageShown = true
        // The keyboard would otherwise stay up behind the stage. The draft stays where it is.
        interaction.dismissKeyboardBeneath()
        presenter.present()
        return presenter
    }

    /// **End Mirror** on the phone.
    func endFromPhone() {
        awaiting?.task.cancel()
        awaiting = nil
        closeStage(sendsLeave: true, endedMessage: nil)
    }

    /// **End** in the Live Activity. It may run in an app the system launched in the background
    /// for it, with the events socket closed, so it ends the mirror over REST.
    func endFromLiveActivity(mirrorID: String, hostID: String) async {
        let client = model?.activeHost.map(Self.macID) == hostID ? model?.client : nil
        if current?.state.mirrorID == mirrorID {
            closeStage(sendsLeave: true, endedMessage: nil)
        }
        await MobileMirrorLiveActivity.endAll(mirrorID: mirrorID)
        try? await client?.endMirror(mirrorID: mirrorID)
    }

    private func closeStage(sendsLeave: Bool, endedMessage: String?) {
        if sendsLeave, let mirrorID = current?.state.mirrorID {
            send(RemoteClientMessage(type: RemoteMirrorSignal.leave.rawValue, id: mirrorID))
        }
        current = nil
        activity.end()
        if let endedMessage, let stage {
            stage.showEnded(endedMessage)
        } else {
            stage?.dismiss()
        }
    }

    // MARK: - The quiet offer

    private func presentOffer() {
        guard let offer else { return }
        if offerView == nil {
            let presenter = MobileMirrorOfferPresenter()
            presenter.onShow = { [weak self] in self?.showOffer() }
            offerView = presenter
        }
        offerView?.present(macName: offer.macName, theme: model.map { RemoteThemePalette($0.appTheme) })
    }

    private func dismissOffer() {
        offerView?.dismiss()
    }

    // MARK: - Away from the app

    private func postLocalInvite(_ state: RemoteMirrorStateDTO, host: PairedRemoteHost) {
        let event = RemoteNotificationEventDTO(
            id: Self.localInviteID(state.mirrorID),
            kind: .mirrorInvite,
            hostID: host.hostID ?? host.id,
            sessionID: state.mirrorID,
            title: MobileL10n.string("Mirror from %@", host.name),
            body: MobileL10n.string("%@ — tap to show", state.sourceTitle)
        )
        // The payload is the same event APNs would carry, so a tap takes the same path. Encoded
        // on a worker: the main actor only decides that an invite is due.
        Task.detached(priority: .userInitiated) {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.threadIdentifier = RemoteMirror.inviteThread
            content.interruptionLevel = .timeSensitive
            if let data = try? JSONEncoder().encode(event),
               let object = try? JSONSerialization.jsonObject(with: data) {
                content.userInfo = ["event": object]
            }
            let request = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func removeLocalInvite(mirrorID: String) {
        let id = Self.localInviteID(mirrorID)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    private static func localInviteID(_ mirrorID: String) -> String { "mirror-\(mirrorID)" }

    // MARK: - Helpers

    private func host(_ pairingID: String) -> PairedRemoteHost? {
        model?.hosts.first { $0.id == pairingID }
    }

    private func send(_ message: RemoteClientMessage) {
        model?.sendEventsMessage(message)
    }

    /// Mirror preferences follow the Mac, not one pairing of it.
    static func macID(_ host: PairedRemoteHost) -> String { host.hostID ?? host.id }

    static func endedMessage(_ reason: RemoteMirrorEndReason) -> String? {
        switch reason {
        case .stoppedOnMac: return MobileL10n.string("Mirroring stopped on the Mac.")
        case .sourceClosed: return MobileL10n.string("The page closed on the Mac.")
        case .expired: return MobileL10n.string("This mirror expired.")
        case .revoked: return MobileL10n.string("This iPhone was disconnected from the Mac.")
        case .replaced, .endedOnPhone, .disabled, .unknown: return nil
        }
    }
}

/// Whether the person is using the phone, fed by the app's own window and the keyboard.
@MainActor
final class MobileInteractionMonitor {
    static let shared = MobileInteractionMonitor()

    private(set) var state = MobileInteractionState()
    /// The app's own window: where the quiet offer sits and focus returns after the stage.
    private(set) weak var appWindow: UIWindow?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    MobileInteractionMonitor.shared.state.isKeyboardVisible = true
                    MobileInteractionMonitor.shared.state.keyboardShownAt = Date()
                }
            },
            center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    MobileInteractionMonitor.shared.state.isKeyboardVisible = false
                }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    MobileInteractionMonitor.shared.state.activatedAt = Date()
                }
            },
        ]
    }

    func track(_ window: UIWindow) {
        appWindow = window
    }

    func record(_ event: UIEvent) {
        guard event.type == .touches, let touches = event.allTouches else { return }
        let active = touches.filter { $0.phase != .ended && $0.phase != .cancelled }.count
        if active == 0, state.activeTouches > 0 { state.lastTouchEndedAt = Date() }
        state.activeTouches = active
    }

    func dismissKeyboardBeneath() {
        appWindow?.endEditing(true)
    }
}

/// The app's one window, so a touch anywhere in Threading tells Mirror the phone is in use.
final class MobileInteractionWindow: UIWindow {
    override func sendEvent(_ event: UIEvent) {
        super.sendEvent(event)
        MainActor.assumeIsolated {
            MobileInteractionMonitor.shared.record(event)
        }
    }
}
