import Foundation
import ThreadingDomain
import ThreadingPTYHostKit

// MARK: - Defaults

/// Numbers the reattach step owns.
enum PTYHostReattachDefaults {

    /// How long the daemon is given to answer `list`.
    ///
    /// The same number `PTYHostRegistrationDefaults.surveyTimeout` gives the upgrade check, and
    /// for the same reason: both are one connect and two frames on a unix socket, and a daemon
    /// that has not answered in this long is one whose answer this launch is better off without.
    static let surveyTimeout: TimeInterval = PTYHostRegistrationDefaults.surveyTimeout

    /// The queue the survey and the launch's own kills run on. Serial, because the relaunch waits
    /// on what is enqueued ahead of it.
    ///
    /// The deadline and the bounded replay a *stop* is given are not here: they live with the stop
    /// itself, in `PTYHostBackgroundSessionsDefaults`, because the Background Sessions list
    /// performs exactly the same one.
    static let queueLabel = "codes.threading.ptyhost.reattach"
}

// MARK: - Holdings

/// What `threading-ptyd` answered when a launch asked what it was still holding.
///
/// The socket path travels with the answer because every session in it is reached through that
/// exact rendezvous, and re-deriving it a second time would be a second chance to derive it
/// differently.
struct PTYHostHoldings: Sendable, Equatable {
    let socketPath: String
    let sessions: [PTYHostSessionSummary]
    /// What a `KeepAlive` restart could not account for. Reported after every `hello`, so a
    /// launch that connects at all learns it.
    let lost: [PTYHostSessionIdentity]

    init(
        socketPath: String,
        sessions: [PTYHostSessionSummary],
        lost: [PTYHostSessionIdentity] = []
    ) {
        self.socketPath = socketPath
        self.sessions = sessions
        self.lost = lost
    }
}

// MARK: - The round trip

/// The one step of the reattach that has to talk to another process.
///
/// Injectable and separate from everything else, in `PTYHostProbe`'s shape: the classification
/// below is a pure function over what came back, so a test forces "the daemon holds these three"
/// and "there is no daemon" without a socket, and the launch path it changes is asserted rather
/// than arranged.
struct PTYHostHoldingsSurvey: Sendable {

    private let answer: @Sendable (PTYHostDecision) -> PTYHostHoldings?

    init(_ answer: @escaping @Sendable (PTYHostDecision) -> PTYHostHoldings?) {
        self.answer = answer
    }

    func holdings(for decision: PTYHostDecision) -> PTYHostHoldings? {
        answer(decision)
    }

    /// Connect, `hello`, `list`, close. **Blocking**; never on the main actor.
    ///
    /// The connect *is* the availability probe rather than a second one beside it. That is not
    /// only thrift: `PTYHostAvailability.resolve` owns the order these questions are asked in —
    /// the setting first and for free, then the path bound, then the helper, and only then a
    /// socket — and a reattach that re-implemented the order would be a second place for it to
    /// drift. So the probe closure handed to `resolve` keeps the client it made, and the `list`
    /// goes out on the connection the gate has already admitted.
    static func connecting(eventLog: EventLog = .shared) -> PTYHostHoldingsSurvey {
        PTYHostHoldingsSurvey { decision in
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
                        closed: { _ in
                            // A link that ended before answering must not hold this launch for
                            // the whole deadline.
                            held.abandon()
                        }
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
                if let reason = availability.unavailability, reason != .disabled {
                    // `disabled` is the ordinary answer on every launch until the hidden key is
                    // set, and journalling nothing happening is how a journal stops being read.
                    eventLog.record(.session, "PTY host held no sessions to take back", [
                        "cause": reason.token
                    ])
                }
                return nil
            }

            do {
                try client.list()
            } catch {
                client.close()
                return nil
            }
            guard let sessions = held.wait(PTYHostReattachDefaults.surveyTimeout) else {
                client.close()
                return nil
            }
            let lost = client.reportedLoss?.ids ?? []
            client.close()
            return PTYHostHoldings(socketPath: socketPath, sessions: sessions, lost: lost)
        }
    }

    /// A survey that answers the same way every time, for a test forcing a branch.
    static func answering(_ holdings: PTYHostHoldings?) -> PTYHostHoldingsSurvey {
        PTYHostHoldingsSurvey { _ in holdings }
    }

}

// MARK: - The plan

/// What one launch does about each session the background host is holding.
///
/// Five answers rather than two, because "the daemon has it" is not one fact. A running terminal
/// is taken back; a running *conversation* kept working and is resumed from what it wrote, because
/// its transport cannot be rejoined mid-stream; a child that ended while nobody was attached is a
/// dormant row with an exit status, exactly as an in-process exit would have left it; a child held
/// for a conversation this app no longer has can never be shown by anything and is ended; and a
/// session a restarted daemon could not account for is not the daemon's any more at all, so it goes
/// to the ordinary relaunch path to be resumed by transcript.
struct PTYHostReattachPlan: Equatable {

    /// Still running, on a pseudo-terminal. This launch reconnects a terminal to it.
    let adopt: [PTYHostSessionSummary]

    /// Still running, on three pipes. **Ended here and resumed from its transcript.**
    ///
    /// A native conversation's CLI speaks a newline-delimited request/response protocol whose
    /// state — the handshake, the thread identity, the turn in flight, the composer capabilities
    /// — lives in the app rather than on the wire, so a fresh app cannot pick up a stream that is
    /// half-way through one. What the child *did* while Threading was closed is not lost, because
    /// it was written to the provider's own transcript as it happened; that is what the resume
    /// reads. `PTYHostSessionSummary.channel` is why this is a decision rather than a guess.
    let resume: [PTYHostSessionSummary]

    /// Ended while nobody was watching. The exit is recorded and the row stays dormant.
    let ended: [PTYHostSessionSummary]

    /// Held for a conversation that has been deleted or archived since. Killed.
    let orphans: [PTYHostSessionIdentity]

    /// Reported lost by a restarted daemon. Left to `relaunchSessionsFromLastQuit`.
    let lost: [SessionID]

    static let empty = PTYHostReattachPlan(
        adopt: [],
        resume: [],
        ended: [],
        orphans: [],
        lost: []
    )

    /// Every session the ordinary relaunch must leave alone.
    ///
    /// Both halves, and the second is the less obvious one: a session that kept working after the
    /// quit and then ended is *not* a session to relaunch. It ran, it finished, and starting a
    /// second agent on the conversation because the record from the last quit said it had been
    /// running would be relaunching something that already had its turn.
    /// A session on `resume` is deliberately **not** here: its child is being ended precisely so
    /// the ordinary relaunch can start a fresh one on the conversation it was writing.
    var heldSessionIDs: Set<SessionID> {
        Set((adopt + ended).compactMap(\.sessionID))
    }

    var isEmpty: Bool {
        adopt.isEmpty && resume.isEmpty && ended.isEmpty && orphans.isEmpty && lost.isEmpty
    }
}

extension PTYHostSessionSummary {

    /// The conversation this summary names, or nil for a surface version 1 does not host.
    var sessionID: SessionID? {
        guard case .agentSession(let sessionID) = id.identity else { return nil }
        return sessionID
    }
}

// MARK: - Reattach

/// Takes back the agents `threading-ptyd` kept running while Threading was closed.
///
/// **This runs ahead of `relaunchSessionsFromLastQuit`, and that order is the feature.** The
/// record written at the last quit is a hint about what *was* running; the daemon's own list is
/// what *is*. Relaunching a session the daemon is still holding would start a second agent on one
/// conversation while the first went on working where nothing could reach it, so the relaunch
/// plans only what the host does not hold.
///
/// Every way the host can be missing degrades to exactly today's behaviour, and the commonest way
/// — the hidden key being off — is answered on the calling turn without opening anything, so a
/// launch with the feature off is byte-for-byte the launch it was before this existed.
@MainActor
enum PTYHostReattach {

    // MARK: - Public Methods

    /// Classifies what the daemon is holding against what this app still has.
    ///
    /// A pure function so the launch decision can be asserted without a daemon, a store or a
    /// window. `isKnown` answers whether a conversation exists and can still be shown — an
    /// archived or deleted one cannot, and a child running for it is a child nothing will ever
    /// display again.
    static func plan(
        holdings: PTYHostHoldings,
        isKnown: (SessionID) -> Bool
    ) -> PTYHostReattachPlan {
        var adopt: [PTYHostSessionSummary] = []
        var resume: [PTYHostSessionSummary] = []
        var ended: [PTYHostSessionSummary] = []
        var orphans: [PTYHostSessionIdentity] = []

        for summary in holdings.sessions {
            guard let sessionID = summary.sessionID, isKnown(sessionID) else {
                orphans.append(summary.id)
                continue
            }
            guard summary.exit == nil else {
                // An ending is an ending on either channel: the status is recorded and the row
                // is dormant, whichever transport wrote the bytes before it.
                ended.append(summary)
                continue
            }
            switch summary.resolvedChannel {
            case .pty: adopt.append(summary)
            case .pipes: resume.append(summary)
            }
        }

        return PTYHostReattachPlan(
            adopt: adopt,
            resume: resume,
            ended: ended,
            orphans: orphans,
            // A lost session is one the daemon *cannot* hand back, so it is deliberately not
            // held: the ordinary relaunch resumes it by its agent-assigned identifier, which is
            // the same cost this has always had — the turn in flight, and nothing else.
            lost: holdings.lost.compactMap { identity in
                guard case .agentSession(let sessionID) = identity.identity else { return nil }
                return sessionID
            }
        )
    }

    /// Surveys the host, applies the plan, and answers which sessions the relaunch must skip.
    ///
    /// `completion` runs on the main actor exactly once. With the feature off it runs **on this
    /// turn**, synchronously, so the degraded launch keeps today's ordering as well as today's
    /// behaviour; otherwise it runs after one bounded round trip on a background queue.
    static func run(
        decision: PTYHostDecision,
        survey: PTYHostHoldingsSurvey = .connecting(),
        queue: DispatchQueue = DispatchQueue(
            label: PTYHostReattachDefaults.queueLabel,
            qos: .userInitiated
        ),
        store: ProjectStore = .shared,
        eventLog: EventLog = .shared,
        adopt: @escaping @MainActor (PTYHostSessionSummary, String) -> Bool,
        notice: @escaping @MainActor (PTYHostLaunchNotice) -> Void = { _ in },
        completion: @escaping @MainActor (Set<SessionID>) -> Void
    ) {
        // Answered here rather than inside the survey so it costs no hop at all: this is every
        // launch until the hidden key is set, and the launch it must not change is this one.
        guard decision.isEnabled else {
            completion([])
            return
        }

        queue.async {
            let holdings = survey.holdings(for: decision)
            let build = decision.build
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let holdings else {
                        completion([])
                        return
                    }
                    let plan = plan(holdings: holdings) { sessionID in
                        guard let session = store.session(withID: sessionID) else { return false }
                        return !session.isArchived
                    }
                    let outcome = apply(
                        plan,
                        socketPath: holdings.socketPath,
                        store: store,
                        eventLog: eventLog,
                        adopt: adopt
                    )
                    // The band before the relaunch: the relaunch is what `completion` starts, and
                    // a notice about what survived belongs in front of it rather than behind.
                    if let announcement = PTYHostLaunchNotice.forLaunch(
                        plan,
                        pending: outcome.pending
                    ) {
                        notice(announcement)
                    }

                    // **The relaunch waits for the conversations, and only for those.** Each of
                    // them is being ended so this launch can start a fresh CLI on the same
                    // conversation, and two CLIs writing one provider transcript is the race that
                    // would make. The orphans are enqueued *behind* the completion hop on the
                    // same serial queue rather than ahead of it: nothing waits on a child held for
                    // a conversation that no longer exists, and putting them first would make
                    // every relaunch pay their deadlines.
                    let socketPath = holdings.socketPath
                    let ending = plan.resume.map(\.id)
                    let orphans = plan.orphans
                    guard !ending.isEmpty || !orphans.isEmpty else {
                        completion(outcome.taken)
                        return
                    }
                    queue.async {
                        for identity in ending {
                            endHandedBack(
                                identity,
                                socketPath: socketPath,
                                build: build,
                                eventLog: eventLog
                            )
                        }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { completion(outcome.taken) }
                        }
                        for identity in orphans {
                            end(identity, socketPath: socketPath, build: build, eventLog: eventLog)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Private Methods

    /// Performs the plan and answers the sessions the relaunch must leave alone.
    ///
    /// A session whose terminal could not be built is **not** in the answer: it is not being
    /// taken back, so the ordinary relaunch is exactly right to relaunch it. It *is* counted as
    /// pending, which is what puts a `Reattach` on the launch band.
    ///
    /// Everything here is main-actor work on values the survey already has. The two kinds of
    /// child that have to be *ended* are the caller's, because their deadlines decide when the
    /// relaunch may start.
    private static func apply(
        _ plan: PTYHostReattachPlan,
        socketPath: String,
        store: ProjectStore,
        eventLog: EventLog,
        adopt: @MainActor (PTYHostSessionSummary, String) -> Bool
    ) -> (taken: Set<SessionID>, pending: Int) {
        var taken: Set<SessionID> = []
        // Running sessions this launch did **not** take back. Normally zero — and it is the
        // difference between a band that states a fact and a band with `Reattach` on it.
        var pending = 0
        for summary in plan.adopt {
            guard let sessionID = summary.sessionID else { continue }
            guard adopt(summary, socketPath) else {
                pending += 1
                continue
            }
            taken.insert(sessionID)
        }

        for summary in plan.ended {
            guard let sessionID = summary.sessionID else { continue }
            // The dormant-with-an-exit-status an in-process ending produces, arrived at from the
            // other direction: nobody was here to be told, so the status is read off the daemon
            // instead. `lastActiveAt` is deliberately untouched — the session was last active at
            // a moment nobody recorded, and stamping it now would reorder the sidebar around a
            // time that is not one.
            store.update(sessionID: sessionID) { stored in
                stored.lastExitCode = summary.exit
            }
            taken.insert(sessionID)
        }

        journal(plan, eventLog: eventLog)
        return (taken, pending)
    }

    private static func journal(_ plan: PTYHostReattachPlan, eventLog: EventLog) {
        guard !plan.isEmpty else { return }
        eventLog.record(.session, "PTY host reattach", [
            "adopted": String(plan.adopt.count),
            "resumed": String(plan.resume.count),
            "ended": String(plan.ended.count),
            "orphaned": String(plan.orphans.count),
            "lost": String(plan.lost.count)
        ])
        if !plan.lost.isEmpty {
            ThreadingLogger.ptyHost.warning(
                """
                The PTY host could not account for \(plan.lost.count, privacy: .public) \
                session(s); they are relaunched from their transcripts
                """
            )
        }
    }

    /// Ends a child the host is holding for a conversation nothing can show.
    ///
    /// The attach-then-kill is `PTYHostSessionStop`'s, shared with the Background Sessions list's
    /// Stop: `kill` names a session and a connection may only name the one it is bound to, so a
    /// watcher that wants to end a child it is not watching has to become its watcher first.
    ///
    /// **Blocking**; never on the main actor.
    private static func end(
        _ identity: PTYHostSessionIdentity,
        socketPath: String,
        build: String,
        eventLog: EventLog
    ) {
        _ = PTYHostSessionStop.run(
            identity,
            socketPath: socketPath,
            build: build,
            eventLog: eventLog
        )
        eventLog.record(.session, "PTY host held a session nothing can show", [
            "session": identity.description
        ])
    }

    /// Ends a conversation's CLI that kept working while Threading was closed.
    ///
    /// The same attach-then-kill, said differently in the journal because it is a different fact:
    /// this child was not stranded, it was *working*, and what it produced is in the provider's
    /// transcript waiting for the resume that follows.
    ///
    /// **Blocking**; never on the main actor.
    private static func endHandedBack(
        _ identity: PTYHostSessionIdentity,
        socketPath: String,
        build: String,
        eventLog: EventLog
    ) {
        let stopped = PTYHostSessionStop.run(
            identity,
            socketPath: socketPath,
            build: build,
            eventLog: eventLog
        )
        eventLog.record(.session, "PTY host kept a conversation working", [
            "session": identity.description,
            // A stop that outran its deadline is not a stop that failed — the kill has been sent
            // to the group either way — but the relaunch that follows is the thing that would
            // notice, so the difference is written down.
            "ended": stopped ? "confirmed" : "unconfirmed"
        ])
    }
}
