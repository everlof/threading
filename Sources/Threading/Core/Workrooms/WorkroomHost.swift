import Foundation
import ThreadingController
import ThreadingWorkroomPortal

// MARK: - Workroom Host

/// Runs the Linked Workrooms portal exactly while it has something to serve: Workrooms is on in
/// Settings **and** at least one room is open. Then it starts the loopback portal, starts the
/// chosen tunnel in front of it, and tells the portal the public origin the tunnel published.
/// Otherwise both are stopped and the portal refuses everything as unavailable.
///
/// Every transition is `refresh()`: at launch, when a Workrooms setting changes, after the owner
/// opens or closes a room, and every `WorkroomHostDefaults.recheckInterval` so a room's expiry
/// stops the tunnel without anyone touching the app.
@MainActor
final class WorkroomHost {

    enum Status: Equatable {
        /// Workrooms is switched off in Settings.
        case off
        /// On, with no open room: nothing is published.
        case idle
        case starting
        case published(URL)
        case unavailable(String)
    }

    static let shared = WorkroomHost()

    private(set) var status: Status = .off {
        didSet { if status != oldValue { NotificationCenter.default.post(WorkroomStatusDidChange()) } }
    }

    /// The public origin a person's link starts with, while the portal is published.
    var publishedOrigin: String? {
        guard case .published(let url) = status else { return nil }
        let text = url.absoluteString
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    private let portal: WorkroomPortal
    private var server: WorkroomPortalServer?
    private var tunnel: WorkroomTunnel?
    private var tunnelKey: String?
    private var recheck: Task<Void, Never>?
    private var refreshing: Task<Void, Never>?
    private var refreshAgain = false
    private let appEvents = AppEventObservations()

    init(portal: WorkroomPortal = WorkroomPortal(backend: WorkroomPortalBackend())) {
        self.portal = portal
    }

    /// Launch, background services only. Never in a hosted test (`StateManager.isHostedTest`):
    /// a test has no business publishing a port to the internet.
    func start() {
        guard !StateManager.isHostedTest, recheck == nil else { return }
        appEvents.observe(AppSettingsDidChange.self) { [weak self] change in
            guard change.affects(AppSettingIdentity.workroomsEnabled.rawValue,
                                 AppSettingIdentity.workroomTunnelProvider.rawValue,
                                 AppSettingIdentity.workroomNgrokDomain.rawValue) else { return }
            self?.refresh()
        }
        recheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(WorkroomHostDefaults.recheckInterval))
                self?.refresh()
            }
        }
        refresh()
    }

    /// Re-decides whether the portal should be published. Coalesced: a refresh requested while
    /// one is reading the store runs once more afterwards.
    func refresh() {
        guard refreshing == nil else { refreshAgain = true; return }
        refreshing = Task { [weak self] in
            guard let self else { return }
            let enabled = AppSettings.shared.workroomsEnabled
            let openRooms = enabled ? ((try? await MacMailbox.shared.controllerStore().openWorkroomCount()) ?? 0) : 0
            self.apply(enabled: enabled, openRooms: openRooms)
            self.refreshing = nil
            if self.refreshAgain { self.refreshAgain = false; self.refresh() }
        }
    }

    /// The owner's "Close All Workrooms": every room closed and the tunnel down, now.
    func closeEverything() async {
        _ = try? await MacMailbox.shared.controllerStore().closeAllWorkrooms()
        tearDown(to: AppSettings.shared.workroomsEnabled ? .idle : .off)
        refresh()
    }

    // MARK: - Private

    private func apply(enabled: Bool, openRooms: Int) {
        guard enabled else { return tearDown(to: .off) }
        guard openRooms > 0 else { return tearDown(to: .idle) }
        let provider = AppSettings.shared.workroomTunnelProvider
        let domain = AppSettings.shared.workroomNgrokDomain
        let key = "\(provider.rawValue)|\(domain ?? "")"
        if server != nil, tunnelKey == key { return }
        if server != nil { tearDown(to: .starting) }
        status = .starting
        let server = WorkroomPortalServer(portal: portal)
        self.server = server
        tunnelKey = key
        server.start { [weak self] port in
            guard let self, self.server === server else { return }
            guard let port else { return self.fail(L10n.string("The workroom portal could not listen on this Mac.")) }
            let recipe: WorkroomTunnelRecipe = provider == .ngrok ? .ngrok(domain: domain) : .cloudflare()
            let tunnel = WorkroomTunnel(recipe: recipe)
            self.tunnel = tunnel
            tunnel.start(port: port) { [weak self] state in
                guard let self, self.tunnel === tunnel else { return }
                self.tunnelChanged(state, port: port)
            }
        }
    }

    private func tunnelChanged(_ state: WorkroomTunnelState, port: UInt16) {
        switch state {
        case .stopped:
            break
        case .starting:
            status = .starting
        case .connected(let url):
            let origin = url.absoluteString.hasSuffix("/") ? String(url.absoluteString.dropLast()) : url.absoluteString
            guard let configuration = WorkroomPortalConfiguration(publicOrigin: origin, loopbackPort: port) else {
                return fail(L10n.string("The tunnel published an address the portal cannot use."))
            }
            Task { await portal.configure(configuration) }
            status = .published(URL(string: configuration.publicOrigin) ?? url)
            EventLog.shared.record(.mcp, "Workroom portal published", ["provider": tunnelKey ?? ""])
        case .unavailable(let message):
            Task { await portal.configure(nil) }
            status = .unavailable(message)
        }
    }

    private func fail(_ message: String) {
        tearDown(to: .unavailable(message))
    }

    private func tearDown(to status: Status) {
        tunnel?.stop()
        tunnel = nil
        server?.stop()
        server = nil
        tunnelKey = nil
        Task { await portal.configure(nil) }
        self.status = status
    }
}

/// The portal's view of the store, plus delivery: a person's write leaves mail for the session
/// that asked, and this tells that session's surface it has arrived (`MacMailDelivery`).
struct WorkroomPortalBackend: WorkroomParticipantBackend {
    private func backend() async throws -> StoreParticipantBackend {
        StoreParticipantBackend(store: try await MacMailbox.shared.controllerStore())
    }

    func redeem(invitation token: String, deviceLabel: String) async throws -> (WorkroomParticipant, String) {
        let result = try await backend().redeem(invitation: token, deviceLabel: deviceLabel)
        await MainActor.run { NotificationCenter.default.post(WorkroomStatusDidChange()) }
        return result
    }
    func participant(sessionToken: String) async throws -> WorkroomParticipant? {
        try await backend().participant(sessionToken: sessionToken)
    }
    func inbox(person: WorkroomPersonID, filter: WorkroomInboxFilter, cursor: Int64) async throws -> WorkroomInboxPage {
        try await backend().inbox(person: person, filter: filter, cursor: cursor)
    }
    func question(person: WorkroomPersonID, id: QuestionID) async throws -> WorkroomQuestionDetail {
        try await backend().question(person: person, id: id)
    }
    func answer(person: WorkroomPersonID, id: QuestionID, answers: [WorkroomFieldAnswer],
                comment: String) async throws -> WorkroomParticipantReceipt {
        await delivered(try await backend().answer(person: person, id: id, answers: answers, comment: comment))
    }
    func clarify(person: WorkroomPersonID, id: QuestionID, text: String) async throws -> WorkroomParticipantReceipt {
        await delivered(try await backend().clarify(person: person, id: id, text: text))
    }
    func decline(person: WorkroomPersonID, id: QuestionID, reason: String) async throws -> WorkroomParticipantReceipt {
        await delivered(try await backend().decline(person: person, id: id, reason: reason))
    }
    func setLanguage(person: WorkroomPersonID, language: String) async throws -> WorkroomPerson {
        try await backend().setLanguage(person: person, language: language)
    }

    private func delivered(_ receipt: WorkroomParticipantReceipt) async -> WorkroomParticipantReceipt {
        await MainActor.run {
            if receipt.notified.kind == .session {
                MacMailDelivery.shared.arrived(for: SessionID(receipt.notified.id), priority: .normal)
            }
            NotificationCenter.default.post(WorkroomStatusDidChange())
        }
        return receipt
    }
}

/// Something the Workrooms page shows changed: the portal's state, a room, or an answer.
struct WorkroomStatusDidChange: AppEvent {
    static let name = Notification.Name("workroomStatusDidChange")
}

enum WorkroomHostDefaults {
    /// How often an expired room is noticed when nothing else happens.
    static let recheckInterval: TimeInterval = 300
}
