import Foundation
import ThreadingDomain
import ThreadingPTYHostKit

// MARK: - Defaults

/// The numbers the Background Sessions surface owns.
enum PTYHostBackgroundSessionsDefaults {

    /// How long the daemon is given to answer `list`. The reattach step's number, for its
    /// reason: one connect and two frames on a unix socket, and an answer that has not come in
    /// this long is one the page is better off not waiting for.
    static let surveyTimeout = PTYHostReattachDefaults.surveyTimeout

    /// How long a stopped child is given to die before the connection is dropped.
    static let stopTimeout: TimeInterval = 3

    /// The replay a stop-only attach asks for.
    ///
    /// Bound to the floor rather than to nothing: attaching is the only way to name a session on
    /// a `kill`, and a watcher that is about to end the child has no use for its history. The
    /// daemon clamps anything smaller up to this anyway.
    static let stopReplayBudget = PTYHostReplayDefaults.minimumBudgetBytes

    static let queueLabel = "codes.threading.ptyhost.inventory"
}

// MARK: - One held session

/// One row of the Background Sessions list: what the daemon is holding, described in the app's
/// own words.
///
/// A value, built away from any view, because the daemon's `list` answers in *its* vocabulary —
/// an identity, a pid, an executable path — and the person reading the page is looking for a
/// conversation. The join is the app's, and it is the only place that knows how.
struct PTYHostHeldSession: Equatable {

    /// What a `kill` has to name.
    let identity: PTYHostSessionIdentity

    /// The conversation, when this app still has one. `nil` is a child held for a session that
    /// has been deleted or archived — the reattach step ends those, so a row like this is a
    /// survey that raced a deletion rather than a steady state.
    let sessionID: SessionID?

    /// The conversation's name, or the executable's when there is no conversation left to name.
    let name: String

    /// The project it belongs to, when there is one.
    let project: String?

    /// Which runtime it is running.
    let agent: String?

    /// When the daemon spawned it. The row shows an elapsed time rather than a clock time,
    /// because "started 4 hours ago" is the question a wedged agent raises.
    let startedAt: Date

    let pid: Int32

    /// Whether the child has ended and the daemon is holding its status for a late observer.
    /// Such a row cannot be stopped — there is nothing left to stop.
    let hasExited: Bool

    // MARK: - Building

    /// Turns the daemon's answer into rows.
    ///
    /// `describe` is the join, injected, so the whole projection is testable without a store: it
    /// answers a conversation's name, project and runtime, or nil when the app no longer has it.
    static func rows(
        for summaries: [PTYHostSessionSummary],
        describe: (SessionID) -> (name: String, project: String?, agent: String)?
    ) -> [PTYHostHeldSession] {
        summaries.map { summary in
            let described = summary.sessionID.flatMap(describe)
            return PTYHostHeldSession(
                identity: summary.id,
                sessionID: summary.sessionID,
                // The executable is the fallback rather than a placeholder: a child whose
                // conversation is gone is still identifiable by what it is running, and that is
                // exactly the row somebody looking for a wedged agent needs to see.
                name: described?.name ?? (summary.executable as NSString).lastPathComponent,
                project: described?.project,
                agent: described?.agent,
                startedAt: summary.startedAt,
                pid: summary.pid,
                hasExited: summary.exit != nil
            )
        }
    }
}

// MARK: - Status

/// What the Background Sessions section says about the host itself.
///
/// Every unavailability degrades to the same behaviour — today's in-process PTY — but they are
/// separate reasons because only some of them have a fix, and only one of them has a fix the
/// user can press. A `Bool` here is how a feature that quietly stopped working becomes
/// unexplainable, which is the argument `PTYHostAvailability` already makes one layer down.
enum PTYHostBackgroundSessionsStatus: Equatable {

    /// Nothing has answered yet. The page draws immediately and gains the answer.
    case surveying

    /// The host answered, and this is how many sessions it holds.
    case holding(Int)

    /// It did not, for this reason.
    case unavailable(PTYHostUnavailability)

    /// The sentence the section leads with.
    var sentence: String {
        switch self {
        case .surveying:
            return L10n.string("Asking the background host what it is holding…")
        case .holding(let count):
            switch count {
            case 0:
                return L10n.string("The background host is running and holding no sessions.")
            case 1:
                return L10n.string("The background host is holding one session.")
            default:
                return L10n.format("The background host is holding %lld sessions.", Int64(count))
            }
        case .unavailable(let reason):
            return Self.sentence(for: reason)
        }
    }

    /// Whether the status line carries the one affordance any of these reasons has: the Login
    /// Items row in System Settings, which is the only fix the app cannot perform itself.
    var offersLoginItems: Bool {
        self == .unavailable(.requiresApproval)
    }

    /// Whether anything is being held. A host holding nothing can be turned off outright.
    var heldSessionCount: Int? {
        switch self {
        case .holding(let count): return count
        case .surveying, .unavailable: return nil
        }
    }

    private static func sentence(for reason: PTYHostUnavailability) -> String {
        switch reason {
        case .disabled:
            return L10n.string(
                "The background host is off. Every session runs its terminal inside Threading and "
                    + "ends when Threading quits."
            )
        case .requiresApproval:
            return L10n.string(
                "The background host is waiting for your approval in System Settings ▸ General ▸ "
                    + "Login Items."
            )
        case .notRegistered:
            return L10n.string(
                "macOS knows the background host but it is switched off. Turning the setting off "
                    + "and on again registers it."
            )
        case .notFound:
            return L10n.string("The background host has not been registered with macOS yet.")
        case .notRunning:
            return L10n.string(
                "The background host is registered but nothing is listening. It starts again on "
                    + "its own."
            )
        case .registrationRefreshing:
            return L10n.string(
                "The background host is being updated. New sessions run inside Threading until "
                    + "it is ready."
            )
        case .protocolMismatch:
            return L10n.string(
                "A background host from a different version of Threading is running. It stands "
                    + "down once the sessions it holds have ended."
            )
        case .helperMissing:
            return L10n.string("This copy of Threading does not include the background host.")
        case .socketPathTooLong:
            return L10n.string(
                "The background host cannot open its socket: the path inside your home folder is "
                    + "too long."
            )
        }
    }
}

// MARK: - The section's whole state

/// Everything the Background Sessions section draws, as one value.
///
/// One value rather than three properties because the three move together — a survey answers the
/// status, the rows and the rendezvous at once — and a view that reads them separately is a view
/// that can draw two of them from one survey and the third from the last.
struct PTYHostBackgroundSessionsState: Equatable {

    var status: PTYHostBackgroundSessionsStatus = .surveying

    /// What the daemon holds, in the order it reported.
    var sessions: [PTYHostHeldSession] = []

    /// The rendezvous every one of those sessions is reached through. Carried with the answer
    /// so a Stop cannot re-derive the path a different way than the survey did.
    var socketPath: String?

    /// The build a stop's own short-lived client introduces itself with.
    var build: String = ""

    static let surveying = PTYHostBackgroundSessionsState()

    /// The empty state's sentence, which is the status line's — the reason the list is empty is
    /// the same fact either way, and two sentences for it would be two things to keep in step.
    var emptyMessage: String { status.sentence }
}

// MARK: - Stopping one session

/// Ends one child the daemon is holding.
///
/// **Attach, then kill, on a connection of its own.** `kill` names a session, and the daemon
/// only accepts a frame naming the session the connection is *bound* to — one connection is one
/// session, which is what lets terminal bytes travel with no envelope. So a watcher that wants
/// to end a child it is not watching has to become its watcher first, for as long as it takes to
/// say so. The replay that costs is bounded to the floor. Nothing about the daemon changes for
/// this; the asymmetry is the protocol's and is documented in `pty-host.md`.
///
/// **Blocking**; never on the main actor.
enum PTYHostSessionStop {

    @discardableResult
    static func run(
        _ identity: PTYHostSessionIdentity,
        socketPath: String,
        build: String,
        eventLog: EventLog = .shared
    ) -> Bool {
        let exited = PTYHostLatch<Void>()
        let client = PTYHostClient(
            socketPath: socketPath,
            build: build,
            events: PTYHostClient.Events(
                frame: { frame in
                    guard case .exited(let ending) = frame, ending.id == identity else { return }
                    exited.complete(())
                },
                closed: { _ in exited.abandon() }
            ),
            eventLog: eventLog
        )
        defer { client.close() }

        guard (try? client.connect()) != nil else { return false }
        do {
            try client.attach(PTYHostAttach(
                id: identity,
                replayBudget: PTYHostBackgroundSessionsDefaults.stopReplayBudget
            ))
            try client.kill(PTYHostKill(id: identity, escalate: true))
        } catch {
            return false
        }
        let didExit = exited.wait(PTYHostBackgroundSessionsDefaults.stopTimeout) != nil
        if didExit { NotificationCenter.default.post(PTYHostMayHaveDrained()) }
        return didExit
    }
}

// MARK: - The inventory

/// Surveys the background host for the Advanced page, and acts on what it finds.
///
/// Separate from the view for the reason every other survey here is: the round trip blocks, so
/// it happens on this type's own queue, and the view is handed a value on the main actor. The
/// three collaborators are injected rather than reached for, so the page's three interesting
/// states — off, waiting for approval, holding three sessions — are all reachable in a test with
/// no daemon anywhere.
@MainActor
final class PTYHostBackgroundSessionsInventory {

    // MARK: - Types

    /// The one blocking step, behind a seam. Answers the status **and** the rows, because they
    /// come from one round trip and splitting them would be two chances to disagree.
    struct Survey: Sendable {

        private let answer: @Sendable (PTYHostDecision) -> PTYHostBackgroundSessionsSurveyResult

        init(_ answer: @escaping @Sendable (PTYHostDecision) -> PTYHostBackgroundSessionsSurveyResult) {
            self.answer = answer
        }

        func result(for decision: PTYHostDecision) -> PTYHostBackgroundSessionsSurveyResult {
            answer(decision)
        }

        /// Connect, `hello`, `list`, close — after asking launchd, whose three answers the socket
        /// probe cannot produce.
        ///
        /// The order is `PTYHostAvailability.resolve`'s and is not re-litigated here: the setting
        /// first and for free, then the path bound, then the helper, and only then a socket. The
        /// registration status is asked *between* the cheap refusals and the connect, because
        /// "launchd has never seen the label" explains a silence the probe would report only as
        /// `notRunning`.
        static func connecting(
            registration: PTYHostRegistration = PTYHostRegistration(),
            eventLog: EventLog = .shared
        ) -> Survey {
            Survey { decision in
                guard decision.isEnabled else { return .init(status: .unavailable(.disabled)) }
                // A hosted test bundle *is* the shipping app, so reading `SMAppService.status`
                // from one would be asking launchd about the developer's own Threading — the
                // same refusal `PTYHostRegistrationCoordinator` makes before it so much as reads
                // the status, for the same reason.
                if !StateManager.isHostedTest, let reason = registration.unavailability {
                    return .init(status: .unavailable(reason))
                }

                let held = PTYHostLatch<[PTYHostSessionSummary]>()
                let box = PTYHostClientHolder()
                let probe = PTYHostProbe { request in
                    let client = PTYHostClient(
                        socketPath: request.socketPath,
                        build: request.build,
                        events: PTYHostClient.Events(
                            frame: { frame in
                                guard case .sessions(let summaries) = frame else { return }
                                held.complete(summaries)
                            },
                            closed: { _ in held.abandon() }
                        ),
                        eventLog: eventLog
                    )
                    do {
                        _ = try client.connect()
                    } catch PTYHostClientError.incompatible(let compatibility) {
                        return .mismatched(compatibility)
                    } catch {
                        return .notRunning
                    }
                    box.adopt(client)
                    return .ready
                }

                let availability = PTYHostAvailability.resolve(decision, probing: probe)
                guard case .available(let socketPath) = availability, let client = box.client else {
                    box.client?.close()
                    return .init(status: .unavailable(availability.unavailability ?? .notRunning))
                }
                defer { client.close() }

                guard (try? client.list()) != nil,
                      let summaries = held.wait(
                          PTYHostBackgroundSessionsDefaults.surveyTimeout
                      ) else {
                    return .init(status: .unavailable(.notRunning))
                }
                return .init(
                    status: .holding(summaries.count),
                    summaries: summaries,
                    socketPath: socketPath
                )
            }
        }

        /// A survey that answers the same way every time, for a test forcing a state.
        static func answering(_ result: PTYHostBackgroundSessionsSurveyResult) -> Survey {
            Survey { _ in result }
        }
    }

    /// What one stop did, on this type's queue.
    typealias Stopper = @Sendable (PTYHostSessionIdentity, String, String) -> Bool

    // MARK: - Properties

    private let survey: Survey
    private let stopper: Stopper
    private let queue: DispatchQueue
    private let store: ProjectStore
    private let eventLog: EventLog
    private let settings: AppSettings

    /// What the section draws, right now.
    private(set) var state = PTYHostBackgroundSessionsState.surveying

    /// Fired on the main actor whenever `state` moved.
    var onChange: (() -> Void)?

    // MARK: - Initialization

    init(
        survey: Survey = .connecting(),
        stopper: @escaping Stopper = { identity, socketPath, build in
            PTYHostSessionStop.run(identity, socketPath: socketPath, build: build)
        },
        queue: DispatchQueue = DispatchQueue(
            label: PTYHostBackgroundSessionsDefaults.queueLabel,
            qos: .userInitiated
        ),
        store: ProjectStore = .shared,
        settings: AppSettings = .shared,
        eventLog: EventLog = .shared
    ) {
        self.survey = survey
        self.stopper = stopper
        self.queue = queue
        self.store = store
        self.settings = settings
        self.eventLog = eventLog
    }

    // MARK: - Public Methods

    /// Asks the host what it is holding, and answers on the main actor.
    ///
    /// With the key off this still runs, and it still costs nothing: `decision.isEnabled` is the
    /// first thing the survey looks at, and the page needs the `.disabled` sentence to be able to
    /// say the host is off.
    func refresh() {
        let decision = PTYHostDecision.live(settings: settings, bundle: .main)
        let survey = self.survey
        queue.async { [weak self] in
            let result = survey.result(for: decision)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.adopt(result, build: decision.build) }
            }
        }
    }

    /// Ends one held session, and re-surveys so the list says what the host now holds.
    ///
    /// Answers on the main actor with whether the daemon reported the ending inside the deadline.
    /// A false is not "it is still running" — a stop that outran its deadline may still land —
    /// which is why the refresh follows either way and the list is what the user reads.
    func stop(
        _ session: PTYHostHeldSession,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        guard let socketPath = state.socketPath else {
            completion(false)
            return
        }
        let identity = session.identity
        let build = state.build
        let stopper = self.stopper
        eventLog.record(.session, "Stopping a background host session", [
            "session": identity.description
        ])
        queue.async { [weak self] in
            let stopped = stopper(identity, socketPath, build)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(stopped)
                    self?.refresh()
                }
            }
        }
    }

    // MARK: - Private Methods

    private func adopt(_ result: PTYHostBackgroundSessionsSurveyResult, build: String) {
        let sessions = PTYHostHeldSession.rows(for: result.summaries) { [store] sessionID in
            guard let session = store.session(withID: sessionID) else { return nil }
            return (
                name: session.displayTitle,
                project: store.project(forSessionID: sessionID)?.name,
                agent: session.kind.displayName
            )
        }
        let updated = PTYHostBackgroundSessionsState(
            status: result.status,
            sessions: sessions,
            socketPath: result.socketPath,
            build: build
        )
        guard updated != state else { return }
        state = updated
        onChange?()
    }
}

// MARK: - Survey result

/// What one survey came back with, before the app has joined it to its own conversations.
struct PTYHostBackgroundSessionsSurveyResult: Sendable, Equatable {
    let status: PTYHostBackgroundSessionsStatus
    let summaries: [PTYHostSessionSummary]
    let socketPath: String?

    init(
        status: PTYHostBackgroundSessionsStatus,
        summaries: [PTYHostSessionSummary] = [],
        socketPath: String? = nil
    ) {
        self.status = status
        self.summaries = summaries
        self.socketPath = socketPath
    }
}

// MARK: - Client holder

/// Holds a client across the `@Sendable` boundary a probe closure is.
///
/// The same box `PTYHostHoldingsSurvey` keeps, named once: the probe is handed to
/// `PTYHostAvailability.resolve`, which owns the order the questions are asked in, and the client
/// it made has to survive being handed back out.
final class PTYHostClientHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: PTYHostClient?

    var client: PTYHostClient? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func adopt(_ client: PTYHostClient) {
        lock.lock()
        storage = client
        lock.unlock()
    }
}
