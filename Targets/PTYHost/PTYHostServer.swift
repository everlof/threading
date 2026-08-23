import Darwin
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

    private let queue = DispatchQueue(label: "codes.threading.ptyd")
    private let journal: PTYHostJournalFile
    private let state: PTYHostState

    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    private var connections: [UInt64: PTYHostConnection] = [:]
    private var sessions: [PTYHostSessionIdentity: PTYSession] = [:]
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

    private var isRetiring = false
    private var ringBudget = PTYHostDefaults.aggregateRingBytes

    // MARK: - Initialization

    init(socketPath: String, stateDirectory: URL, build: String) {
        self.socketPath = socketPath
        self.stateDirectory = stateDirectory
        self.build = build
        journal = PTYHostJournalFile(directory: stateDirectory)
        state = PTYHostState(directory: stateDirectory)
    }

    // MARK: - Public Methods

    /// Prepares the state directory, reads what the previous daemon left, and binds the socket.
    ///
    /// Answers false having said why. There is no degraded mode: a daemon that cannot be reached
    /// is a daemon whose sessions nobody can attach to, and the app's whole availability decision
    /// is built to fall back to in-process PTYs when the socket is not there.
    func start() -> Bool {
        guard prepareStateDirectory() else {
            FileHandle.standardError.write(
                Data("threading-ptyd: cannot prepare the state directory\n".utf8)
            )
            return false
        }

        journal.prune()
        applyRingBudgetOverride()
        journal.record(.started, [
            Field.pid: String(getpid()),
            Field.build: build
        ])

        recoverPreviousSessions()

        guard bindListener() else { return false }
        journal.record(.listening, [Field.socket: socketPath])
        return true
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

        var earliest = Date()
        for entry in unaccounted {
            let stillRunning = PTYSpawn.exists(entry.pid)
                && entry.startTime != nil
                && PTYSpawn.startTime(of: entry.pid) == entry.startTime
            if stillRunning { PTYSpawn.signalGroup(entry.pid, SIGKILL) }
            journal.record(stillRunning ? .lostSessionStillRunning : .lostSession, [
                Field.session: entry.id.description,
                Field.pid: String(entry.pid),
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
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            let message = "threading-ptyd: socket path is \(pathBytes.count) bytes, over the "
                + "\(capacity - 1)-byte limit\n"
            FileHandle.standardError.write(Data(message.utf8))
            return false
        }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[pathBytes.count] = 0
            }
        }

        unlink(socketPath)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        var suppress: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &suppress,
            socklen_t(MemoryLayout<Int32>.size)
        )

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
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
            resize(session, to: request.grid)
        case .detach(let request):
            guard let session = boundSession(named: request.id, on: connection) else { return }
            session.seed = PTYSession.DetachSeed(
                screen: request.screenSeed,
                modes: request.modeSeed,
                ringOffset: request.ringOffset
            )
            unbind(connection, from: session, keepingSeed: true)
            journal.record(.detached, [
                Field.session: session.id.description,
                Field.connection: String(connection.number),
                Field.bytes: String(request.ringOffset)
            ])
        case .kill(let request):
            guard let session = boundSession(named: request.id, on: connection) else { return }
            kill(session, escalate: request.escalate)
        case .retire:
            retire()
        case .journalTail(let request):
            connection.send(.journal(PTYHostJournal(
                lines: journal.tail(maxBytes: request.maxBytes)
            )))
        case .helloRefused, .sessions, .spawned, .spawnRefused, .attached,
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
    /// The version pair is the gate and the build is only reported: a commit on master replaces
    /// the app bundle several times a day, and a build-gated daemon would be drained and
    /// restarted for changes that touch no frame.
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
            connection.send(.lost(PTYHostLost(ids: lostSessions, since: lostSince)))
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
        guard sessions[request.id] == nil else {
            refuseSpawn(request.id, .alreadyExists, on: connection)
            return
        }
        guard case .pty(let grid) = request.channel else {
            refuseSpawn(request.id, .unsupportedChannel, on: connection)
            return
        }

        let outcome = PTYSpawn.spawn(
            executable: request.executable,
            arguments: request.arguments,
            execName: request.execName,
            environment: request.environment,
            workingDirectory: request.cwd,
            grid: grid
        )
        let child: PTYSpawn.Child
        switch outcome {
        case .success(let spawned):
            child = spawned
        case .failure(.executableUnavailable):
            refuseSpawn(request.id, .executableUnavailable, on: connection)
            return
        case .failure(.forkFailed(let code)):
            journal.record(.spawnFailed, [
                Field.session: request.id.description,
                Field.reason: String(cString: strerror(code))
            ])
            connection.send(.error(PTYHostErrorFrame(code: .spawnFailed)))
            return
        }

        let session = PTYSession(
            id: request.id,
            child: child,
            executable: request.executable,
            grid: grid
        )
        sessions[request.id] = session

        // Written before the reply, because the whole point of the file is to be the last thing
        // that happened before a crash: a child nobody recorded is a child a restart cannot even
        // say it lost.
        state.append(PTYHostStateRecord(
            edge: .spawned,
            id: session.id,
            pid: session.pid,
            startTime: session.startTime,
            executable: session.executable
        ))
        journal.record(.spawned, [
            Field.session: session.id.description,
            Field.pid: String(session.pid),
            Field.executable: (session.executable as NSString).lastPathComponent,
            Field.cols: String(grid.cols),
            Field.rows: String(grid.rows)
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
            totalBytesWritten: session.ring.totalBytesWritten
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
        connection.boundSession = session.id
        session.watchers.append(connection)
        session.detachedAt = nil
        pushForeground(of: session)
        startForegroundTimer(for: session)
    }

    private func resize(_ session: PTYSession, to grid: PTYHostGrid) {
        session.grid = grid
        PTYSpawn.applyWindowSize(grid, to: session.master)
        journal.record(.resized, [
            Field.session: session.id.description,
            Field.cols: String(grid.cols),
            Field.rows: String(grid.rows)
        ])
    }

    /// `SIGTERM` to the group, then `SIGKILL` to the group after a grace when asked to escalate.
    ///
    /// The group rather than the process, because `forkpty` made the child a session leader and
    /// its own children are in that group; signalling the leader alone is how orphans are made.
    private func kill(_ session: PTYSession, escalate: Bool) {
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

    // MARK: - Private Methods — the byte stream

    /// Reads the master on its own channel and hands each burst back to the host queue.
    private func startReading(_ session: PTYSession) {
        sessionCount += 1
        let master = session.master
        let readQueue = DispatchQueue(label: "codes.threading.ptyd.pty.\(sessionCount)")
        let io = DispatchIO(
            type: .stream,
            fileDescriptor: master,
            queue: readQueue,
            cleanupHandler: { _ in close(master) }
        )
        io.setLimit(lowWater: 1)
        // One read is one frame, and a frame stays well inside the wire's 1 MiB bound: a repaint
        // crosses as several frames rather than one a slow watcher cannot use yet.
        io.setLimit(highWater: PTYHostDefaults.readChunkBytes)
        session.io = io

        io.read(offset: 0, length: Int.max, queue: queue) { [weak self, weak session] done, data, error in
            guard let self, let session else { return }
            if let data, !data.isEmpty {
                var bytes = Data()
                bytes.reserveCapacity(data.count)
                data.enumerateBytes { buffer, _, _ in bytes.append(contentsOf: buffer) }
                deliver(bytes, of: session)
            }
            if done || error != 0 {
                session.masterFinished = true
                deliverExitIfReady(session)
            }
        }
    }

    /// The ring first, then the watchers.
    ///
    /// A detached session costs exactly this: one append, one comparison, and no allocation per
    /// watcher, because there are none and the frame is never built.
    private func deliver(_ bytes: Data, of session: PTYSession) {
        session.append(bytes)
        if !session.watchers.isEmpty {
            for chunk in Self.chunks(of: bytes) {
                guard let framed = try? PTYHostFraming.encode(kind: .output, payload: chunk) else {
                    continue
                }
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
        guard session.isAttached, session.exit == nil else { return }
        guard let group = PTYSpawn.foregroundProcessGroup(of: session.master) else { return }
        guard group != session.lastForeground else { return }
        session.lastForeground = group
        for watcher in session.watchers {
            watcher.send(.foreground(PTYHostForeground(id: session.id, processGroup: group)))
        }
    }

    private func startForegroundTimer(for session: PTYSession) {
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
        let source = DispatchSource.makeProcessSource(
            identifier: session.pid,
            eventMask: .exit,
            queue: queue
        )
        // The handler is installed before the source is activated: `NOTE_EXIT` is delivered at
        // most once, and a child that has already exited fires it during `activate()`.
        source.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            reap(session, attempt: 0)
        }
        session.processSource = source
        source.activate()
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
        session.processSource?.cancel()
        session.processSource = nil
        session.io?.close(flags: .stop)
        session.io = nil
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
