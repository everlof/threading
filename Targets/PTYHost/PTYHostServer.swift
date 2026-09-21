#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Dispatch
import Foundation
import ThreadingPTYHostKit

// MARK: - Server

/// The daemon: a listener, a set of connections, a set of sessions, and one serial queue that
/// owns all three.
///
/// **One queue.** Every accept, every decoded frame, every byte read off a master and every
/// timer lands on `queue`, so none of the state below needs a lock and the ordering questions
/// that matter — a replay before the live output that follows it, a ring append before the
/// fan-out that reads it — are answered by construction rather than by care. The only work that
/// happens elsewhere is the kernel I/O itself: each session's master has its own `DispatchIO`
/// channel on its own queue, and hands its bytes back here.
///
/// **Nothing here parses the byte stream.** It is copied into a ring and copied out to watchers.
/// The one syscall the daemon makes *about* a terminal is `tcgetpgrp`, which answers a question
/// with no bytes in it.
final class PTYHostServer: @unchecked Sendable {

    // MARK: - Properties

    private let socketPath: String
    private let stateDirectory: URL
    private let build: String

    private let queue = DispatchQueue(
        label: "codes.threading.ptyd",
        qos: PTYHostDefaults.eventQueueQoS
    )
    private let journal: PTYHostJournalFile
    private let state: PTYHostState

    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    private var connections: [UInt64: PTYHostConnection] = [:]
    private var sessions: [PTYHostSessionIdentity: PTYSession] = [:]
    /// A replacement waiting for the deliberately stopped incarnation of the same logical
    /// session to finish. The existing child remains the only child until its output and exit
    /// have been delivered; only then is the request allowed to spawn.
    private var pendingReplacements: [PTYHostSessionIdentity: (
        request: PTYHostSpawnRequest,
        connection: PTYHostConnection
    )] = [:]
    private var connectionCount: UInt64 = 0
    private var sessionCount: UInt64 = 0

    /// What the previous daemon could not account for. Reported after every `hello`, for this
    /// process's whole life.
    ///
    /// Reported repeatedly rather than once-and-acknowledged because an acknowledgement is a
    /// fourth state to get wrong for no gain: the app's answer to a `lost` set is idempotent —
    /// it offers to resume sessions that are resumable by their agent-assigned identifier — and a
    /// second Threading, or a support tool, is owed the same answer as the first.
    private var lostSessions: [PTYHostSessionIdentity] = []
    private var lostSince = Date()
    private var lossIncidentID: UUID?
    private var lossDetectedAt: Date?

    private var isRetiring = false

    /// The descriptor holding the state directory's exclusive lock. Never closed: the kernel
    /// releases the lock when this process ends, and not before.
    private var ownershipLock: Int32 = -1
    private var ringBudget = PTYHostDefaults.aggregateRingBytes

    /// A `.pipes` child's three parent-side descriptors, held between the spawn that made them
    /// and the read channels that adopt them. Removed the moment `startReading` has handed each
    /// one to a `DispatchIO`, which is then their only owner — a descriptor with two apparent
    /// owners is how one gets closed under a file the kernel has already recycled it for.
    private var pipeDescriptors: [PTYHostSessionIdentity: PTYSpawn.PipeChild] = [:]

    // MARK: - Initialization

    init(socketPath: String, stateDirectory: URL, build: String) {
        self.socketPath = socketPath
        self.stateDirectory = stateDirectory
        self.build = build
        journal = PTYHostJournalFile(directory: stateDirectory)
        state = PTYHostState(directory: stateDirectory)
    }

    // MARK: - Public Methods

    /// How `start()` ended. A held state directory is its own answer, because it is the one refusal
    /// that is not this process's failure and clears on its own when the owner exits.
    enum StartOutcome {
        case listening
        case stateDirectoryHeld
        case failed
    }

    /// Prepares and takes ownership of the state directory, reads what the previous daemon left,
    /// and binds the socket.
    ///
    /// Any outcome but `.listening` has already said why on standard error. There is no degraded
    /// mode: a daemon that cannot be reached is a daemon whose sessions nobody can attach to, and
    /// the app's availability decision keeps a selected background session stopped when the socket
    /// is not there.
    ///
    /// **One daemon per state directory.** A second one used to run the recovery below against the
    /// first one's live `sessions.jsonl`, take its running agents for a crashed predecessor's
    /// orphans, and `SIGKILL` their groups — measured in the remote-host spike, where a new
    /// generation was started beside a draining one. launchd never orders it that way, since
    /// `KeepAlive` restarts a job only after it exits, but an operator, a leftover unit or a
    /// half-finished upgrade can, so the daemon refuses rather than trusting every caller.
    func start() -> StartOutcome {
        guard prepareStateDirectory() else {
            FileHandle.standardError.write(
                Data("threading-ptyd: cannot prepare the state directory\n".utf8)
            )
            return .failed
        }

        // Before anything reads or writes the directory: a second daemon must not append to the
        // first one's journal or state file, and above all must not run the recovery below.
        switch PTYHostPOSIX.lockExclusively(
            stateDirectory.appendingPathComponent(PTYHostDefaults.ownershipLockFileName).path
        ) {
        case .held(let descriptor):
            ownershipLock = descriptor
        case .heldElsewhere:
            FileHandle.standardError.write(Data(
                "threading-ptyd: another daemon owns \(stateDirectory.path); not starting\n".utf8
            ))
            return .stateDirectoryHeld
        case .failed(let code):
            FileHandle.standardError.write(Data(
                "threading-ptyd: cannot lock \(stateDirectory.path): \(String(cString: strerror(code)))\n".utf8
            ))
            return .failed
        }

        journal.prune()
        applyRingBudgetOverride()
        journal.record(.started, [
            Field.pid: String(getpid()),
            Field.build: build
        ])

        recoverPreviousSessions()

        guard bindListener() else { return .failed }
        journal.record(.listening, [Field.socket: socketPath])
        return .listening
    }

    // MARK: - Private Methods — startup

    private enum Field {
        static let pid = "pid"
        static let build = "build"
        static let socket = "socket"
        static let session = "session"
        static let connection = "connection"
        static let reason = "reason"
        static let detail = "detail"
        static let status = "status"
        static let signalled = "signalled"
        static let bytes = "bytes"
        static let from = "from"
        static let to = "to"
        static let cols = "cols"
        static let rows = "rows"
        static let lines = "lines"
        static let executable = "executable"
        static let channel = "channel"
        static let stream = "stream"
    }

    /// Created `0700` and then set `0700` again, because the directory may already exist from a
    /// run that used the default mask — the same two steps the MCP bridge's directory takes, for
    /// the same reason. The `0700` is the authorization boundary for this protocol: there is no
    /// token in any frame, and this is why there does not need to be one.
    private func prepareStateDirectory() -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: stateDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: PTYHostDefaults.directoryPermissions]
            )
            try manager.setAttributes(
                [.posixPermissions: PTYHostDefaults.directoryPermissions],
                ofItemAtPath: stateDirectory.path
            )
            return true
        } catch {
            return false
        }
    }

    private func applyRingBudgetOverride() {
        guard let raw = ProcessInfo.processInfo.environment[
            PTYHostDefaults.ringBudgetEnvironmentKey
        ], let requested = Int(raw) else { return }
        ringBudget = min(
            max(requested, PTYHostDefaults.minimumRingBytes),
            PTYHostDefaults.aggregateRingBytes
        )
        journal.record(.ringBudgetOverridden, [Field.bytes: String(ringBudget)])
    }

    /// Reads `sessions.jsonl` and accounts for everything the previous daemon left open.
    ///
    /// **Neither outcome is "carry on".** A child of a dead daemon has no master anybody holds,
    /// so there is nothing to attach a watcher to and nothing to read: whether it is alive or not
    /// it is lost, and the honest design goal is to *say* what was lost rather than to pretend
    /// nothing was.
    ///
    /// Each is probed by pid **and** kernel start time, never by pid alone, because macOS hands
    /// the numbers out again. The probe matters because "they all died with the host" turns out
    /// to be false: measured on 2026-08-23, a `sleep` spawned by this daemon and orphaned by a
    /// `kill -9` of it went on running as `Ss+`, session leader of a terminal nothing holds,
    /// reparented to launchd. So a survivor's whole process **group** is killed here, which is
    /// the only place that can: the app's orphan sweep skips host-held children by design, so
    /// nothing else will ever clean this one up, and an agent still working in a session no
    /// surface can reach is worse than one that ended.
    private func recoverPreviousSessions() {
        let (unaccounted, skipped) = state.unaccountedSessions()
        if skipped > 0 {
            journal.record(.stateLineSkipped, [Field.lines: String(skipped)])
        }
        guard !unaccounted.isEmpty else { return }

        lossIncidentID = UUID()
        lossDetectedAt = Date()
        var earliest = Date()
        var recoveredIDs: Set<PTYHostSessionIdentity> = []
        for entry in unaccounted where recoveredIDs.insert(entry.id).inserted {
            let stillRunning = PTYSpawn.exists(entry.pid)
                && entry.startTime != nil
                && PTYSpawn.startTime(of: entry.pid) == entry.startTime
            if stillRunning { PTYSpawn.signalGroup(entry.pid, SIGKILL) }
            journal.record(stillRunning ? .lostSessionStillRunning : .lostSession, [
                Field.session: entry.id.description,
                Field.pid: String(entry.pid),
                Field.channel: entry.channel.rawValue,
                Field.detail: stillRunning ? "groupKilled" : "processGone"
            ])
            state.append(PTYHostStateRecord(edge: .lost, id: entry.id, pid: entry.pid))
            lostSessions.append(entry.id)
            earliest = min(earliest, entry.since)
        }
        lostSince = earliest
    }

    /// Binds the rendezvous.
    ///
    /// The daemon unlinks a stale socket, not the app: this is the only process that may be
    /// listening there, so it is the only one that can tell a leftover file from a live listener
    /// without a race.
    private func bindListener() -> Bool {
        guard let address = PTYHostPOSIX.unixAddress(path: socketPath) else {
            let message = "threading-ptyd: socket path is \(socketPath.utf8.count) bytes, over the "
                + "\(PTYHostPOSIX.unixPathCapacity - 1)-byte limit\n"
            FileHandle.standardError.write(Data(message.utf8))
            return false
        }

        unlink(socketPath)
        let descriptor = socket(AF_UNIX, PTYHostPOSIX.streamSocketType, 0)
        guard descriptor >= 0 else { return false }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        PTYHostPOSIX.suppressBrokenPipeSignal(on: descriptor)

        let bound = PTYHostPOSIX.bind(descriptor, address)
        guard bound == 0, listen(descriptor, PTYHostDefaults.socketBacklog) == 0 else {
            FileHandle.standardError.write(
                Data("threading-ptyd: cannot bind \(socketPath): \(String(cString: strerror(errno)))\n".utf8)
            )
            close(descriptor)
            return false
        }
        _ = chmod(socketPath, PTYHostDefaults.socketPermissions)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)

        listener = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPendingConnections() }
        acceptSource = source
        source.activate()
        return true
    }

    // MARK: - Private Methods — connections

    private func acceptPendingConnections() {
        while listener >= 0 {
            let descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else { return }
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

            connectionCount += 1
            let number = connectionCount
            let connection = PTYHostConnection(
                descriptor: descriptor,
                number: number,
                queue: queue
            )

            connections[number] = connection
            connection.onFrames = { [weak self, weak connection] frames in
                guard let self, let connection else { return }
                handle(frames, from: connection)
            }
            connection.onRefusal = { [weak self, weak connection] refusal in
                guard let self, let connection else { return }
                journal.record(.frameRefused, [
                    Field.connection: String(connection.number),
                    Field.reason: Self.token(for: refusal)
                ])
                connection.close()
            }
            connection.onOverload = { [weak self, weak connection] in
                guard let self, let connection else { return }
                journal.record(.backpressureClosed, [
                    Field.connection: String(connection.number),
                    Field.bytes: String(connection.pendingWriteBytes)
                ])
                connection.close(discardingQueuedWrites: true)
            }
            connection.onClosed = { [weak self, weak connection] in
                guard let self, let connection else { return }
                forget(connection)
            }
            journal.record(.connectionOpened, [Field.connection: String(number)])
            connection.start()
        }
    }

    /// A connection ended, however it ended.
    ///
    /// **A close is also a detach, and one without seeds.** The daemon cannot know how much of
    /// the ring that watcher had applied, so the next attach is answered with a cut and the app
    /// re-derives its own screen — an honest loss rather than a replay of a screen nobody handed
    /// over.
    private func forget(_ connection: PTYHostConnection) {
        connections.removeValue(forKey: connection.number)
        let cancelled = pendingReplacements.compactMap { id, pending in
            pending.connection === connection ? id : nil
        }
        for id in cancelled {
            pendingReplacements.removeValue(forKey: id)
            journal.record(.replacementCancelled, [
                Field.session: id.description,
                Field.reason: "connectionClosed"
            ])
        }
        if let id = connection.boundSession, let session = sessions[id] {
            unbind(connection, from: session, keepingSeed: false)
        }
        connection.boundSession = nil
        journal.record(.connectionClosed, [Field.connection: String(connection.number)])
    }

    private func unbind(
        _ connection: PTYHostConnection,
        from session: PTYSession,
        keepingSeed: Bool
    ) {
        session.watchers.removeAll { $0 === connection }
        connection.boundSession = nil
        if !keepingSeed { session.seed = nil }
        if !session.isAttached {
            session.detachedAt = Date()
            session.foregroundTimer?.cancel()
            session.foregroundTimer = nil
            session.lastForeground = nil
        }
    }

    // MARK: - Private Methods — frames

    private func handle(_ frames: [PTYHostWireFrame], from connection: PTYHostConnection) {
        for frame in frames where !connection.isClosed {
            switch frame.kind {
            case .control:
                guard let control = try? Self.decoder.decode(
                    PTYHostFrame.self,
                    from: frame.payload
                ) else {
                    journal.record(.frameRefused, [
                        Field.connection: String(connection.number),
                        Field.reason: "undecodableControl"
                    ])
                    connection.send(.error(PTYHostErrorFrame(code: .malformedFrame)))
                    connection.close()
                    continue
                }
                handle(control, from: connection)
            case .input:
                guard connection.hasGreeted else { refuseUngreeted(connection); continue }
                write(frame.payload, from: connection)
            case .output:
                // Output is the daemon's to send. A client sending one is speaking a dialect
                // this build does not have, and there is nothing to do with the bytes.
                refuse(connection, code: .malformedFrame, detail: "outputFromClient")
            }
        }
    }

    private func handle(_ frame: PTYHostFrame, from connection: PTYHostConnection) {
        guard connection.hasGreeted || Self.isHello(frame) else {
            refuseUngreeted(connection)
            return
        }

        switch frame {
        case .hello(let peer):
            greet(peer, on: connection)
        case .list:
            connection.send(.sessions(sessions.values
                .sorted { $0.startedAt < $1.startedAt }
                .map(\.summary)))
        case .spawn(let request):
            spawn(request, from: connection)
        case .attach(let request):
            attach(request, from: connection)
        case .resize(let request):
            guard let session = boundSession(named: request.id, on: connection) else { return }
            guard session.channel == .pty else {
                // A well-formed frame for the wrong channel, which is not the same failure as a
                // frame that cannot be believed: the stream is still readable and the session is
                // still working, so this is an `error` the connection survives rather than a
                // close. Closing here would end a conversation over a caller's slip.
                journal.record(.frameRefused, [
                    Field.session: session.id.description,
                    Field.connection: String(connection.number),
                    Field.reason: PTYHostError.unsupportedChannel.rawValue,
                    Field.detail: "resize"
                ])
                connection.send(.error(PTYHostErrorFrame(
                    code: .unsupportedChannel,
                    detail: "resize"
                )))
                return
            }
            resize(session, to: request.grid, from: connection)
        case .detach(let request):
            guard let session = boundSession(named: request.id, on: connection) else { return }
            // A pipes session stores nothing: it has no emulator anywhere, so its seeds are
            // empty by construction and an `.exact` rejoin off an empty screen would be a replay
            // of bytes with nothing to render them into. The frame is still the right one to
            // send — it is what makes the hand-over deliberate rather than a watcher that
            // vanished, and it is what the app's drain waits on before the process exits.
            if session.channel == .pty {
                session.seed = PTYSession.DetachSeed(
                    screen: request.screenSeed,
                    modes: request.modeSeed,
                    ringOffset: request.ringOffset
                )
            }
            unbind(connection, from: session, keepingSeed: session.channel == .pty)
            scheduleIdleExpiry(of: session, at: request.idleExpiresAt)
            journal.record(.detached, [
                Field.session: session.id.description,
                Field.connection: String(connection.number),
                Field.bytes: String(request.ringOffset)
            ])
        case .closeInput(let request):
            guard let session = boundSession(named: request.id, on: connection) else { return }
            closeInput(of: session, from: connection)
        case .kill(let request):
            guard let session = boundSession(named: request.id, on: connection) else { return }
            kill(session, escalate: request.escalate)
        case .retire:
            retire()
        case .journalTail(let request):
            connection.send(.journal(PTYHostJournal(
                lines: journal.tail(maxBytes: request.maxBytes)
            )))
        case .helloRefused, .sessions, .spawned, .spawnRefused, .attached, .resized,
             .exited, .foreground, .lost, .journal, .error:
            // Every one of these is the daemon's to send. Receiving one means the peer is
            // speaking the protocol backwards, which is not a state to keep serving.
            refuse(connection, code: .malformedFrame, detail: "daemonFrameFromClient")
        }
    }

    private static func isHello(_ frame: PTYHostFrame) -> Bool {
        if case .hello = frame { return true }
        return false
    }

    /// `hello` is the first frame on every connection, in both directions.
    ///
    /// The protocol pair is the admission gate. The generation is reported so the app can replace
    /// a compatible old process gracefully when the bundle on disk moved underneath it.
    private func greet(_ peer: PTYHostHello, on connection: PTYHostConnection) {
        guard !connection.hasGreeted else {
            refuse(connection, code: .malformedFrame, detail: "repeatedHello")
            return
        }

        let compatibility = PTYHostCompatibility.evaluate(peer: peer)
        guard compatibility == .compatible else {
            journal.record(.connectionRefused, [
                Field.connection: String(connection.number),
                Field.reason: compatibility.rawValue,
                Field.build: peer.build
            ])
            connection.send(.helloRefused(PTYHostHelloRefusal(
                compatibility: compatibility,
                update: compatibility.updateTarget(evaluatedBy: .daemon) ?? .app
            )))
            connection.close()
            return
        }

        connection.hasGreeted = true
        connection.send(.hello(PTYHostHello(build: build, pid: getpid())))
        if !lostSessions.isEmpty {
            connection.send(.lost(PTYHostLost(
                ids: lostSessions,
                since: lostSince,
                incidentID: lossIncidentID,
                detectedAt: lossDetectedAt
            )))
        }
    }

    private func refuseUngreeted(_ connection: PTYHostConnection) {
        journal.record(.connectionRefused, [
            Field.connection: String(connection.number),
            Field.reason: "beforeHello"
        ])
        connection.send(.error(PTYHostErrorFrame(code: .malformedFrame, detail: "beforeHello")))
        connection.close()
    }

    private func refuse(_ connection: PTYHostConnection, code: PTYHostError, detail: String?) {
        journal.record(.frameRefused, [
            Field.connection: String(connection.number),
            Field.reason: code.rawValue,
            Field.detail: detail ?? ""
        ])
        connection.send(.error(PTYHostErrorFrame(code: code, detail: detail)))
        connection.close()
    }

    /// The session a frame may name: the one this connection is bound to, and no other.
    ///
    /// A frame naming a different session is not a mistake to answer politely — the connection
    /// and the app disagree about what it is attached to, and every later `input` byte would go
    /// to whichever of them is wrong. So it is an `error` and a close.
    private func boundSession(
        named id: PTYHostSessionIdentity,
        on connection: PTYHostConnection
    ) -> PTYSession? {
        guard let bound = connection.boundSession else {
            refuse(connection, code: .notAttached, detail: "unbound")
            return nil
        }
        guard bound == id, let session = sessions[id] else {
            refuse(connection, code: .notAttached, detail: "sessionMismatch")
            return nil
        }
        return session
    }

    // MARK: - Private Methods — sessions

    private func spawn(_ request: PTYHostSpawnRequest, from connection: PTYHostConnection) {
        guard connection.boundSession == nil else {
            refuse(connection, code: .alreadyAttached, detail: "spawn")
            return
        }
        guard !isRetiring else {
            refuseSpawn(request.id, .retiring, on: connection)
            return
        }
        if let existing = sessions[request.id] {
            if pendingReplacements[request.id] != nil {
                refuseSpawn(request.id, .alreadyExists, on: connection)
                return
            } else if existing.exitDelivered {
                release(existing)
            } else if request.replaceExisting == true {
                pendingReplacements[request.id] = (request, connection)
                journal.record(.replacementQueued, [
                    Field.session: request.id.description,
                    Field.pid: String(existing.pid),
                    Field.connection: String(connection.number)
                ])
                // The replacement request is itself the authority to stop the old incarnation.
                // It may reach the serial daemon queue before the old connection's kill frame;
                // making the handoff depend on cross-socket arrival order recreates the race this
                // queue exists to remove.
                if !existing.wasKilled { kill(existing, escalate: true) }
                return
            } else {
                refuseSpawn(request.id, .alreadyExists, on: connection)
                return
            }
        }
        let session: PTYSession
        switch request.channel {
        case .pty(let grid):
            let outcome = PTYSpawn.spawn(
                executable: request.executable,
                arguments: request.arguments,
                execName: request.execName,
                environment: request.environment,
                workingDirectory: request.cwd,
                grid: grid
            )
            switch outcome {
            case .success(let child):
                session = PTYSession(
                    id: request.id,
                    child: child,
                    executable: request.executable,
                    grid: grid
                )
            case .failure(let failure):
                refuseSpawnFailure(failure, request.id, on: connection)
                return
            }
        case .pipes:
            let outcome = PTYSpawn.spawnPipes(
                executable: request.executable,
                arguments: request.arguments,
                execName: request.execName,
                environment: request.environment,
                workingDirectory: request.cwd
            )
            switch outcome {
            case .success(let child):
                session = PTYSession(
                    id: request.id,
                    child: child,
                    executable: request.executable
                )
                pipeDescriptors[request.id] = child
            case .failure(let failure):
                refuseSpawnFailure(failure, request.id, on: connection)
                return
            }
        }
        sessions[request.id] = session

        // Written before the reply, because the whole point of the file is to be the last thing
        // that happened before a crash: a child nobody recorded is a child a restart cannot even
        // say it lost.
        state.append(PTYHostStateRecord(
            edge: .spawned,
            id: session.id,
            pid: session.pid,
            startTime: session.startTime,
            executable: session.executable,
            channel: session.channel
        ))
        journal.record(.spawned, [
            Field.session: session.id.description,
            Field.pid: String(session.pid),
            Field.executable: (session.executable as NSString).lastPathComponent,
            Field.channel: session.channel.rawValue,
            Field.cols: String(session.grid.cols),
            Field.rows: String(session.grid.rows)
        ])

        startReading(session)
        watchForExit(session)

        connection.send(.spawned(PTYHostSpawned(
            id: session.id,
            pid: session.pid,
            startTime: session.startTime ?? PTYHostProcessStartTime(seconds: 0, microseconds: 0)
        )))
        bind(connection, to: session)
        enforceRingBudget()
    }

    /// The two ways a spawn can fail, answered the same way for both channels.
    ///
    /// A missing executable is the caller's fact and travels as a `spawnRefused` token; a `fork`
    /// or `posix_spawn` that failed is the machine's and travels as an `error`, because there is
    /// nothing the app can change about it and the errno belongs in the journal rather than on
    /// the wire.
    private func refuseSpawnFailure(
        _ failure: PTYSpawn.Failure,
        _ id: PTYHostSessionIdentity,
        on connection: PTYHostConnection
    ) {
        switch failure {
        case .executableUnavailable:
            refuseSpawn(id, .executableUnavailable, on: connection)
        case .forkFailed(let code):
            journal.record(.spawnFailed, [
                Field.session: id.description,
                Field.reason: String(cString: strerror(code))
            ])
            connection.send(.error(PTYHostErrorFrame(code: .spawnFailed)))
        }
    }

    private func refuseSpawn(
        _ id: PTYHostSessionIdentity,
        _ reason: PTYHostSpawnRefusal,
        on connection: PTYHostConnection
    ) {
        journal.record(.spawnRefused, [
            Field.session: id.description,
            Field.reason: reason.rawValue
        ])
        connection.send(.spawnRefused(PTYHostSpawnRefused(id: id, reason: reason)))
    }

    /// Attaching hands over the history first and the live stream afterwards, in that order,
    /// on this one connection.
    ///
    /// The ordering is the whole point of a rejoin, and it is guaranteed by two facts rather than
    /// by a barrier: every frame is queued from this one serial queue, and a channel performs its
    /// writes in the order they were submitted. So the `attached` frame, then the replay bytes,
    /// then whatever the child produces next, reach the watcher in that order — and nothing is
    /// sent twice, because the ring *is* the stream.
    ///
    /// **An attach never resizes.** The watcher is told the grid and adopts it.
    private func attach(_ request: PTYHostAttach, from connection: PTYHostConnection) {
        guard connection.boundSession == nil else {
            refuse(connection, code: .alreadyAttached, detail: "attach")
            return
        }
        guard let session = sessions[request.id] else {
            connection.send(.error(PTYHostErrorFrame(code: .unknownSession, detail: "attach")))
            return
        }

        let replay = session.replay(budget: request.normalizedReplayBudget)
        connection.send(.attached(PTYHostAttached(
            id: session.id,
            pid: session.pid,
            grid: session.grid,
            replay: replay.kind,
            totalBytesWritten: session.ring.totalBytesWritten,
            replayByteCount: replay.payloads.reduce(0) { $0 + $1.count }
        )))
        for payload in replay.payloads {
            for chunk in Self.chunks(of: payload) {
                connection.send(kind: .output, payload: chunk)
            }
        }

        journal.record(.attached, [
            Field.session: session.id.description,
            Field.connection: String(connection.number),
            Field.reason: Self.token(for: replay.kind)
        ])
        bind(connection, to: session)

        // A session that has already ended is still worth attaching to: the watcher is owed the
        // ending, and it is owed it after the history rather than instead of it.
        if let exit = session.exit {
            connection.send(.exited(PTYHostExited(
                id: session.id,
                status: exit.status,
                signalled: exit.signalled
            )))
            session.exitObserved = true
            scheduleRelease(of: session)
        }
    }

    private func bind(_ connection: PTYHostConnection, to session: PTYSession) {
        cancelIdleExpiry(of: session)
        connection.boundSession = session.id
        session.watchers.append(connection)
        session.detachedAt = nil
        pushForeground(of: session)
        startForegroundTimer(for: session)
    }

    /// Sets the durable grid, applies it to the terminal, and answers the connection that asked.
    ///
    /// The answer is the whole of what `resized` adds, and it carries the grid that reached
    /// `TIOCSWINSZ` rather than the one that was requested: those differ where the request is out
    /// of a `winsize`'s range, and an acknowledgement of a number the terminal does not hold
    /// would let the app believe a divergence had been closed.
    ///
    /// A terminal that would not take the size is **not** acknowledged and does not become the
    /// durable grid: a session with no master left is the only way this happens, and telling a
    /// later watcher it inherits a grid nothing was ever set to is worse than saying nothing. The
    /// app's own reconciliation retries at its next convergence point.
    private func resize(
        _ session: PTYSession,
        to grid: PTYHostGrid,
        from connection: PTYHostConnection
    ) {
        guard let applied = PTYSpawn.applyWindowSize(grid, to: session.master) else {
            journal.record(.resizeFailed, [
                Field.session: session.id.description,
                Field.connection: String(connection.number),
                Field.cols: String(grid.cols),
                Field.rows: String(grid.rows)
            ])
            return
        }
        session.grid = applied
        journal.record(.resized, [
            Field.session: session.id.description,
            Field.cols: String(applied.cols),
            Field.rows: String(applied.rows)
        ])
        connection.send(.resized(PTYHostResized(id: session.id, grid: applied)))
    }

    /// Closes a pipes child's standard input, which is how every native transport says goodbye.
    ///
    /// The channel is closed rather than the descriptor: `DispatchIO`'s cleanup handler is the
    /// descriptor's only owner, so closing it here and closing it there would be two closes of a
    /// number the kernel may already have handed to something else. `close(flags: [])` lets
    /// whatever is still queued reach the child first, which matters because the last thing
    /// written before a goodbye is usually the request the goodbye is about.
    private func closeInput(of session: PTYSession, from connection: PTYHostConnection) {
        guard session.channel == .pipes else {
            journal.record(.frameRefused, [
                Field.session: session.id.description,
                Field.connection: String(connection.number),
                Field.reason: PTYHostError.unsupportedChannel.rawValue,
                Field.detail: "closeInput"
            ])
            connection.send(.error(PTYHostErrorFrame(
                code: .unsupportedChannel,
                detail: "closeInput"
            )))
            return
        }
        guard let io = session.io else { return }
        session.io = nil
        io.close(flags: [])
        journal.record(.inputClosed, [Field.session: session.id.description])
    }

    /// `SIGTERM` to the group, then `SIGKILL` to the group after a grace when asked to escalate.
    ///
    /// The group rather than the process, because `forkpty` made the child a session leader and
    /// its own children are in that group; signalling the leader alone is how orphans are made.
    private func kill(_ session: PTYSession, escalate: Bool) {
        cancelIdleExpiry(of: session)
        session.wasKilled = true
        journal.record(.killRequested, [
            Field.session: session.id.description,
            Field.pid: String(session.pid)
        ])
        PTYSpawn.signalGroup(session.pid, SIGTERM)
        guard escalate else { return }

        let id = session.id
        let pid = session.pid
        queue.asyncAfter(deadline: .now() + PTYHostDefaults.killEscalationGrace) { [weak self] in
            guard let self, let current = sessions[id], current.pid == pid,
                  current.exit == nil else { return }
            journal.record(.killEscalated, [
                Field.session: id.description,
                Field.pid: String(pid)
            ])
            PTYSpawn.signalGroup(pid, SIGKILL)
        }
    }

    /// Stops a deliberately idle child once the absolute retention deadline passes.
    ///
    /// The app is the policy owner and supplies the date; the daemon only owns the timer and the
    /// process. A later attach cancels it before binding. Nil means protected work and removes any
    /// earlier deadline rather than inheriting policy from a previous watcher.
    private func scheduleIdleExpiry(of session: PTYSession, at expiration: Date?) {
        cancelIdleExpiry(of: session)
        guard let expiration, !session.isAttached, session.exit == nil else { return }

        let interval = max(0, expiration.timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + interval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self, weak session] in
            guard let self, let session,
                  sessions[session.id] === session,
                  !session.isAttached,
                  session.exit == nil,
                  session.idleExpiresAt == expiration else { return }
            session.idleExpiryTimer?.cancel()
            session.idleExpiryTimer = nil
            journal.record(.idleExpired, [
                Field.session: session.id.description,
                Field.pid: String(session.pid)
            ])
            kill(session, escalate: true)
        }
        session.idleExpiresAt = expiration
        session.idleExpiryTimer = timer
        timer.activate()
    }

    private func cancelIdleExpiry(of session: PTYSession) {
        session.idleExpiryTimer?.cancel()
        session.idleExpiryTimer = nil
        session.idleExpiresAt = nil
    }

    // MARK: - Private Methods — the byte stream

    /// Wires up whichever descriptors this session has.
    ///
    /// One `DispatchIO` per direction per stream, each on its own read queue and each handing its
    /// bytes back to the host queue. A pty has one channel that both reads and writes its master;
    /// a pipes child has three, and the asymmetry is the channel's whole difference here.
    private func startReading(_ session: PTYSession) {
        switch session.channel {
        case .pty:
            let master = session.master
            session.io = readChannel(master, of: session, stream: .standardOutput)
        case .pipes:
            guard let child = pipeDescriptors.removeValue(forKey: session.id) else { return }
            sessionCount += 1
            let input = child.input
            session.io = DispatchIO(
                type: .stream,
                fileDescriptor: input,
                queue: DispatchQueue(
                    label: "codes.threading.ptyd.stdin.\(sessionCount)",
                    qos: PTYHostDefaults.eventQueueQoS
                ),
                cleanupHandler: { _ in close(input) }
            )
            session.outputIO = readChannel(child.output, of: session, stream: .standardOutput)
            session.errorIO = readChannel(child.errors, of: session, stream: .standardError)
        }
    }

    /// One reader, on its own queue, delivering bursts to the host queue in order.
    private func readChannel(
        _ descriptor: Int32,
        of session: PTYSession,
        stream: OutputStreamKind
    ) -> DispatchIO {
        sessionCount += 1
        let io = DispatchIO(
            type: .stream,
            fileDescriptor: descriptor,
            queue: DispatchQueue(
                label: "codes.threading.ptyd.read.\(sessionCount)",
                qos: PTYHostDefaults.eventQueueQoS
            ),
            cleanupHandler: { _ in close(descriptor) }
        )
        io.setLimit(lowWater: 1)
        // One read is one frame, and a frame stays well inside the wire's 1 MiB bound: a repaint
        // crosses as several frames rather than one a slow watcher cannot use yet.
        io.setLimit(highWater: PTYHostDefaults.readChunkBytes)

        io.read(offset: 0, length: Int.max, queue: queue) { [weak self, weak session] done, data, error in
            guard let self, let session else { return }
            if let data, !data.isEmpty {
                var bytes = Data()
                bytes.reserveCapacity(data.count)
                data.enumerateBytes { buffer, _, _ in bytes.append(contentsOf: buffer) }
                deliver(bytes, of: session, stream: stream)
            }
            if done || error != 0 {
                session.noteReaderFinished()
                deliverExitIfReady(session)
            }
        }
        return io
    }

    /// Which of a child's two output streams a burst came from.
    ///
    /// Only a `.pipes` child has two. The three streams stay three all the way across the wire,
    /// because merging them would corrupt the newline-delimited JSON the app's transports parse —
    /// which is `AgentChildProcess`'s own rule, kept here rather than restated differently.
    private enum OutputStreamKind {
        case standardOutput
        case standardError

        var flags: UInt8 {
            switch self {
            case .standardOutput: return 0
            case .standardError: return PTYHostFramingDefaults.standardErrorFlag
            }
        }

        var token: String {
            switch self {
            case .standardOutput: return "stdout"
            case .standardError: return "stderr"
            }
        }
    }

    /// The ring first, then the watchers.
    ///
    /// A detached session costs exactly this: one append, one comparison, and no allocation per
    /// watcher, because there are none and the frame is never built.
    ///
    /// **Only standard output reaches the ring**, and only a pipes child has anything else. The
    /// ring is what a rejoin replays, and a rejoining watcher parses one stream; interleaving the
    /// other into it would corrupt exactly what the replay exists to hand over, and a second ring
    /// would be a second `totalBytesWritten` for one `ringOffset` to mean two things by.
    /// Diagnostics are live-only: the transports read them separately and surface them when a
    /// child dies unexpectedly, and a rejoin that replayed yesterday's stderr would be
    /// attributing an old observation to a new one.
    private func deliver(_ bytes: Data, of session: PTYSession, stream: OutputStreamKind) {
        if stream == .standardOutput { session.append(bytes) }
        if !session.watchers.isEmpty {
            for chunk in Self.chunks(of: bytes) {
                guard let framed = try? PTYHostFraming.encode(
                    kind: .output,
                    flags: stream.flags,
                    payload: chunk
                ) else { continue }
                for watcher in session.watchers { watcher.sendFramed(framed) }
            }
        }
        pushForeground(of: session)
    }

    private func write(_ bytes: Data, from connection: PTYHostConnection) {
        guard let id = connection.boundSession, let session = sessions[id] else {
            refuse(connection, code: .notAttached, detail: "input")
            return
        }
        guard session.exit == nil, let io = session.io else {
            // Either the child has ended or its standard input has already been closed. Both mean
            // the same thing to the writer — these bytes will never be read — and both are said
            // with a token rather than swallowed, because a transport that thinks it sent a turn
            // waits for an answer that is not coming.
            connection.send(.error(PTYHostErrorFrame(code: .sessionExited, detail: "input")))
            return
        }
        guard session.pendingInputBytes + bytes.count
            <= PTYHostDefaults.maximumPendingInputBytes else {
            // A child that has stopped reading is not helped by a larger buffer, and the PTY read
            // loop must never be the thing that waits.
            journal.record(.inputDropped, [
                Field.session: session.id.description,
                Field.bytes: String(bytes.count)
            ])
            return
        }

        let submitted = bytes.count
        session.pendingInputBytes += submitted
        let payload = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        io.write(offset: 0, data: payload, queue: queue) { [weak session] done, _, _ in
            guard done, let session else { return }
            session.pendingInputBytes = max(0, session.pendingInputBytes - submitted)
        }
    }

    // MARK: - Private Methods — foreground

    /// Checked after each burst and on a slow timer while somebody is attached, never while
    /// detached: a program can take the terminal without writing a byte, and a detached session
    /// has nobody to tell.
    private func pushForeground(of session: PTYSession) {
        // A pipes child has no controlling terminal, so there is no foreground process group to
        // read and nothing to say. Not a degradation: the app asks the question only of a
        // terminal, to decide whether a title belongs to the shell or to what it is running.
        guard session.channel == .pty else { return }
        guard session.isAttached, session.exit == nil else { return }
        guard let group = PTYSpawn.foregroundProcessGroup(of: session.master) else { return }
        guard group != session.lastForeground else { return }
        session.lastForeground = group
        for watcher in session.watchers {
            watcher.send(.foreground(PTYHostForeground(id: session.id, processGroup: group)))
        }
    }

    private func startForegroundTimer(for session: PTYSession) {
        guard session.channel == .pty else { return }
        guard session.foregroundTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + PTYHostDefaults.foregroundPollInterval,
            repeating: PTYHostDefaults.foregroundPollInterval
        )
        timer.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            pushForeground(of: session)
        }
        session.foregroundTimer = timer
        timer.activate()
    }

    // MARK: - Private Methods — endings

    private func watchForExit(_ session: PTYSession) {
        // The handler is installed before the source is activated: `NOTE_EXIT` is delivered at
        // most once, and a child that has already exited fires it during `activate()`. A Linux
        // pidfd is level-triggered instead — readable from the exit until it is closed — which
        // `reap` tolerates because it does nothing once the exit is recorded.
        guard let source = PTYHostPOSIX.makeExitSource(
            for: session.pid,
            queue: queue,
            handler: { [weak self, weak session] in
                guard let self, let session else { return }
                reap(session, attempt: 0)
            }
        ) else {
            pollForExit(session)
            return
        }
        session.processSource = source
        source.activate()
    }

    /// The fallback when no exit event could be armed — on Linux, a `pidfd_open` refused because
    /// the daemon is out of descriptors, or made on a kernel older than 5.3 that has no pidfds.
    ///
    /// A session whose ending nobody notices is a session that is never released and an app that
    /// waits forever, so the exit is polled instead. Each tick is one non-blocking `waitpid`,
    /// asked as the last reap attempt so a still-running child schedules no retries of its own.
    private func pollForExit(_ session: PTYSession) {
        journal.record(.exitPolled, [
            Field.session: session.id.description,
            Field.pid: String(session.pid)
        ])
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + PTYHostDefaults.exitPollInterval,
            repeating: PTYHostDefaults.exitPollInterval
        )
        timer.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            reap(session, attempt: PTYHostDefaults.reapAttempts)
        }
        session.processSource = timer
        timer.activate()
    }

    private func reap(_ session: PTYSession, attempt: Int) {
        guard session.exit == nil else { return }
        var status: Int32 = 0
        let reaped = waitpid(session.pid, &status, WNOHANG)
        if reaped == 0 {
            // The exit is known and the zombie is not collectable yet, which is rare and always
            // brief. Retried on the queue rather than waited for: blocking here would stop every
            // other session being served.
            guard attempt < PTYHostDefaults.reapAttempts else { return }
            queue.asyncAfter(deadline: .now() + PTYHostDefaults.reapRetryInterval) { [weak self, weak session] in
                guard let self, let session else { return }
                reap(session, attempt: attempt + 1)
            }
            return
        }

        let signalled = reaped > 0 && (status & 0x7F) != 0 && (status & 0x7F) != 0x7F
        let value: Int32 = reaped <= 0
            ? -1
            : (signalled ? (status & 0x7F) : ((status >> 8) & 0xFF))
        session.noteExit(status: value, signalled: signalled)
        cancelIdleExpiry(of: session)
        session.processSource?.cancel()
        session.processSource = nil

        state.append(PTYHostStateRecord(
            edge: .exited,
            id: session.id,
            pid: session.pid,
            status: value,
            signalled: signalled
        ))
        journal.record(.exited, [
            Field.session: session.id.description,
            Field.pid: String(session.pid),
            Field.status: String(value),
            Field.signalled: signalled ? "true" : "false",
            Field.detail: session.wasKilled ? "afterKill" : "onItsOwn"
        ])
        deliverExitIfReady(session)
    }

    /// An exit is reported after its output, not before it.
    ///
    /// The child's last write is usually still in the terminal buffer when the kernel reports the
    /// exit, and a watcher told "it ended" before it is shown the ending has lost exactly the
    /// bytes it most wanted. So the frame waits for the master to reach end of file — or for a
    /// bounded grace, because a surviving grandchild can hold the slave open indefinitely.
    private func deliverExitIfReady(_ session: PTYSession) {
        guard let exit = session.exit, !session.exitDelivered else { return }
        if !session.masterFinished {
            // Not yet drained. Wait for end of file, and no longer than the grace — a surviving
            // grandchild holding the slave open must delay the ending, never withhold it.
            let remaining = PTYHostDefaults.exitDrainGrace - Date().timeIntervalSince(exit.at)
            if remaining > 0 {
                queue.asyncAfter(deadline: .now() + remaining) { [weak self, weak session] in
                    guard let self, let session else { return }
                    deliverExitIfReady(session)
                }
                return
            }
        }

        session.exitDelivered = true
        session.foregroundTimer?.cancel()
        session.foregroundTimer = nil
        for watcher in session.watchers {
            watcher.send(.exited(PTYHostExited(
                id: session.id,
                status: exit.status,
                signalled: exit.signalled
            )))
        }
        if session.isAttached { session.exitObserved = true }
        if let pending = pendingReplacements.removeValue(forKey: session.id) {
            release(session)
            guard !pending.connection.isClosed, !isRetiring else {
                if !pending.connection.isClosed {
                    refuseSpawn(session.id, .retiring, on: pending.connection)
                }
                journal.record(.replacementCancelled, [
                    Field.session: session.id.description,
                    Field.reason: isRetiring ? "retiring" : "connectionClosed"
                ])
                return
            }
            journal.record(.replacementStarted, [
                Field.session: session.id.description,
                Field.connection: String(pending.connection.number)
            ])
            spawn(pending.request, from: pending.connection)
            return
        }
        scheduleRelease(of: session)
    }

    /// When an ended session stops existing.
    ///
    /// Three answers, and each is a different question about who still needs it. A retiring
    /// daemon releases at once — it is being replaced and the app has already been told. A
    /// session whose ending somebody saw is held briefly, so a watcher that reconnects a moment
    /// later still learns how it ended rather than being told the id is unknown. A session that
    /// ended with nobody watching is held far longer, because the app may be closed, and then
    /// released anyway: the record is the last thing anybody wants and the ring behind it is half
    /// a mebibyte.
    private func scheduleRelease(of session: PTYSession) {
        guard session.exit != nil else { return }
        if isRetiring {
            release(session)
            return
        }
        let delay = session.exitObserved
            ? PTYHostDefaults.exitedRetention
            : PTYHostDefaults.unobservedExitRetention
        let id = session.id
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let current = sessions[id], current === session else { return }
            release(current)
        }
    }

    private func release(_ session: PTYSession) {
        guard sessions[session.id] === session else { return }
        sessions.removeValue(forKey: session.id)
        session.foregroundTimer?.cancel()
        session.foregroundTimer = nil
        cancelIdleExpiry(of: session)
        session.processSource?.cancel()
        session.processSource = nil
        session.io?.close(flags: .stop)
        session.io = nil
        session.outputIO?.close(flags: .stop)
        session.outputIO = nil
        session.errorIO?.close(flags: .stop)
        session.errorIO = nil
        // Only reached when a spawn was answered and the descriptors were never adopted, which
        // cannot happen today — but a descriptor left in this map is a leak for the life of the
        // process, so the release is the one place that can promise it is empty.
        pipeDescriptors.removeValue(forKey: session.id)
        for watcher in session.watchers { watcher.boundSession = nil }
        session.watchers.removeAll()
        journal.record(.released, [Field.session: session.id.description])
        finishRetirementIfDrained()
    }

    // MARK: - Private Methods — retirement

    /// Stop accepting, unlink **now**, keep serving what is already attached, exit when the last
    /// session ends.
    ///
    /// The unlink is immediate because that is what the frame is for: a replacement binary has to
    /// be able to bind the path while this process is still finishing its work. A daemon that has
    /// not been asked to retire never exits on its own, however idle it is — launchd binds the
    /// registration to the path rather than to the code, so an exit is an upgrade only when
    /// somebody asked for one.
    private func retire() {
        guard !isRetiring else { return }
        isRetiring = true
        acceptSource?.cancel()
        acceptSource = nil
        if listener >= 0 {
            close(listener)
            listener = -1
        }
        unlink(socketPath)
        journal.record(.retiring, [Field.session: String(sessions.count)])

        let replacements = pendingReplacements
        pendingReplacements.removeAll()
        for (id, pending) in replacements {
            refuseSpawn(id, .retiring, on: pending.connection)
            journal.record(.replacementCancelled, [
                Field.session: id.description,
                Field.reason: "retiring"
            ])
        }

        // Sessions that have already ended are the ones nothing is waiting for.
        for session in Array(sessions.values) where session.exitDelivered { release(session) }
        finishRetirementIfDrained()
    }

    private func finishRetirementIfDrained() {
        guard isRetiring, sessions.isEmpty else { return }
        journal.record(.retired)
        // Writes are asynchronous, so exiting the instant the last session is released can
        // truncate the frame that said so.
        queue.asyncAfter(deadline: .now() + PTYHostDefaults.retireFlushDelay) {
            exit(PTYHostDefaults.successExitCode)
        }
    }

    // MARK: - Private Methods — the aggregate ring bound

    /// A per-session cap is not an aggregate one.
    ///
    /// Sixty-four detached sessions at half a mebibyte each is 32 MiB of resident ring in a
    /// process the user can see in Activity Monitor, so the daemon holds a total and gives memory
    /// back when it is exceeded — oldest **detached** session first, halving towards a floor, and
    /// every shrink journalled, because history quietly thrown away is the failure this exists to
    /// avoid.
    ///
    /// An attached session is never shrunk: somebody is watching it, and the cost of shrinking it
    /// is a rejoin they can see. If every session is attached the budget is exceeded and said so
    /// in the journal, which is the honest answer — the alternative is degrading the one session
    /// a person is looking at.
    private func enforceRingBudget() {
        var total = sessions.values.reduce(0) { $0 + $1.ringCapacity }
        guard total > ringBudget else { return }

        let candidates = sessions.values
            .filter { !$0.isAttached && $0.ringCapacity > PTYHostDefaults.minimumRingBytes }
            .sorted { ($0.detachedAt ?? $0.startedAt) < ($1.detachedAt ?? $1.startedAt) }
        guard !candidates.isEmpty else {
            journal.record(.ringShrunk, [
                Field.reason: "noDetachedSession",
                Field.bytes: String(total)
            ])
            return
        }

        for session in candidates {
            let before = session.ringCapacity
            var capacity = before
            while total > ringBudget, capacity > PTYHostDefaults.minimumRingBytes {
                let next = max(PTYHostDefaults.minimumRingBytes, capacity / 2)
                total -= capacity - next
                capacity = next
            }
            guard capacity < before else { continue }
            session.shrinkRing(to: capacity)
            journal.record(.ringShrunk, [
                Field.session: session.id.description,
                Field.from: String(before),
                Field.to: String(capacity)
            ])
            if total <= ringBudget { return }
        }
    }

    // MARK: - Private Methods — helpers

    private static let decoder = JSONDecoder()

    /// Splits a payload into wire-sized frames. The seeds an app hands over are bounded but not
    /// small, and one frame per repaint would sit right against the protocol's own limit.
    private static func chunks(of data: Data) -> [Data] {
        guard data.count > PTYHostDefaults.readChunkBytes else { return [data] }
        var chunks: [Data] = []
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: PTYHostDefaults.readChunkBytes, limitedBy: data.endIndex)
                ?? data.endIndex
            chunks.append(Data(data[index..<end]))
            index = end
        }
        return chunks
    }

    private static func token(for refusal: PTYHostFramingRefusal) -> String {
        switch refusal {
        case .oversizePayload: return "oversizePayload"
        case .unknownKind: return "unknownKind"
        }
    }

    private static func token(for replay: PTYHostReplay) -> String {
        switch replay {
        case .exact: return "exact"
        case .cut: return "cut"
        case .none: return "none"
        }
    }
}
