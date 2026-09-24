#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Dispatch
import Foundation
import ThreadingPTYHostKit

// MARK: - Client

/// One connection to `threading-ptyd`, from the app.
///
/// **One connection, one session.** After a successful `spawn` or `attach` the connection is
/// bound, which is what lets output and input travel as bare bytes with no envelope and no id —
/// the hot path of a terminal must not pay for a header it can derive from the socket. The client
/// enforces the binding locally as well as trusting the daemon to: a second `attach` is a
/// programming error and answers with a typed refusal rather than a stream two sessions are
/// interleaved on.
///
/// **The client speaks first.** `hello` goes out before anything is read, carrying this build's
/// protocol pair, its generation string and its pid, and the daemon answers with its own `hello`
/// or with `helloRefused`. Speaking first is what makes a wrong-protocol daemon cheap to detect: the
/// app has committed to nothing at the point the answer arrives, so a refusal is a close rather
/// than an unwind.
///
/// **Nothing here touches the main actor.** The handshake blocks on the caller's thread — with
/// deadlines, so it is bounded — and every frame after it is decoded and delivered on the
/// client's own serial queue. The coalescing hop to main is the *caller's*, in
/// `installProcessOutputObserver`'s existing shape; a client that hopped per frame would put a
/// terminal's whole output rate on the main queue, which is the shape that makes a mirror slow
/// (`performance.md`'s scaling gate: the read loop must not touch main).
///
/// **A frame this build does not know is ignored, not fatal.** The protocol is additive, so a
/// well-framed control frame with an unrecognised `type` means the peer is newer in a way the
/// version gate admitted — the correct response is to log it and read on. Only a
/// `PTYHostFramingRefusal` closes the connection, because once a length or a `kind` is wrong
/// there is no way to find the next header.
final class PTYHostClient: @unchecked Sendable {

    // MARK: - Types

    /// Where decoded frames go. Every one of these is called on `queue` and never on main.
    ///
    /// Closures rather than a delegate protocol, matching `ExtensionHostDescriptorConnection`
    /// next door: under complete strict concurrency a weak delegate would have to be `Sendable`
    /// and would then be sendable to the main actor by accident, which is precisely the hop this
    /// type exists to avoid.
    struct Events: Sendable {

        /// A decoded control frame. `hello`, `helloRefused` and the handshake's own frames are
        /// **not** delivered here — the handshake consumes them — but everything the daemon says
        /// afterwards is, including `lost`, which is also recorded on the client.
        var frame: @Sendable (PTYHostFrame) -> Void

        /// Raw output (`kind` 1): replay bytes first, in order, then live output. A pty
        /// session's whole stream, and a pipes session's **standard output** only.
        var output: @Sendable (Data) -> Void

        /// A pipes session's standard error (`kind` 1 with
        /// `PTYHostFramingDefaults.standardErrorFlag`).
        ///
        /// A second closure rather than a flag on `output`, so a caller that has one stream —
        /// every pty session, which is every caller that existed before pipes — reads exactly
        /// what it read before and cannot accidentally feed diagnostics into an emulator. The
        /// default drops them, which is the right answer for a terminal: a pty child's stderr
        /// *is* the terminal, so a frame carrying this flag on a pty session is a frame that
        /// should not exist.
        var standardError: @Sendable (Data) -> Void

        /// The link ended. Delivered exactly once, and only for a client whose `connect()`
        /// returned — a `connect()` that throws *is* its own report. `nil` means `close()`.
        var closed: @Sendable (PTYHostClientError?) -> Void

        init(
            frame: @escaping @Sendable (PTYHostFrame) -> Void = { _ in },
            output: @escaping @Sendable (Data) -> Void = { _ in },
            standardError: @escaping @Sendable (Data) -> Void = { _ in },
            closed: @escaping @Sendable (PTYHostClientError?) -> Void = { _ in }
        ) {
            self.frame = frame
            self.output = output
            self.standardError = standardError
            self.closed = closed
        }

        /// For a caller that only wants the handshake — the availability probe.
        static let ignored = Events()
    }

    private enum State {
        case idle
        case handshaking
        case ready
        case closed
    }

    /// A decoded frame that shared a socket read with the peer's `hello`.
    ///
    /// The handshake must finish draining that already-decoded batch before handing the
    /// descriptor to `DispatchIO`. Keeping output and control in one sequence preserves wire
    /// order, including the standard-error bit that a pair of payload-only arrays would lose.
    private typealias PendingDelivery = PTYHostHandshake.Delivery

    // MARK: - Properties

    /// The queue every event is delivered on. Serial, so frames arrive in wire order.
    let queue: DispatchQueue

    private let socketPath: String
    private let build: String
    private let events: Events
    typealias Journal = @Sendable (String, [String: String]) -> Void
    private let journal: Journal
    private let connectTimeout: TimeInterval
    private let helloTimeout: TimeInterval
    private let maximumQueuedWriteBytes: Int

    /// Guards everything below. Never held across a call out of this type: a `DispatchIO`
    /// teardown runs its cleanup handler on `queue`, and re-entering under the lock would
    /// deadlock the pump against its own close.
    private let lock = NSLock()

    private var state: State = .idle
    private var descriptor: Int32 = -1
    private var channel: DispatchIO?
    #if os(Linux)
    private var writer: PTYHostSocketWriter?
    #endif
    private var decoder = PTYHostFrameDecoder()
    private var queuedWriteBytes = 0
    private var binding = PTYHostConnectionBinding()
    private var peerHelloStorage: PTYHostHello?
    private var reportedLossStorage: PTYHostLost?
    private var didReportClosed = false
    /// Callers blocked in `drainWrites(until:)`. Signalled when the queue empties, and again
    /// when the connection closes — a waiter must not be held for its whole deadline by a link
    /// that has already ended.
    private var drainWaiters: [DispatchSemaphore] = []

    // MARK: - Initialization

    init(
        socketPath: String,
        build: String,
        events: Events,
        journal: @escaping Journal,
        queue: DispatchQueue? = nil,
        connectTimeout: TimeInterval = PTYHostClientDefaults.connectTimeout,
        helloTimeout: TimeInterval = PTYHostClientDefaults.helloTimeout,
        maximumQueuedWriteBytes: Int = PTYHostClientDefaults.maximumQueuedWriteBytes
    ) {
        self.socketPath = socketPath
        self.build = build
        self.events = events
        self.journal = journal
        self.queue = queue ?? DispatchQueue(
            label: PTYHostClientDefaults.clientQueueLabel,
            qos: PTYHostClientDefaults.clientQueueQoS
        )
        self.connectTimeout = connectTimeout
        self.helloTimeout = helloTimeout
        self.maximumQueuedWriteBytes = maximumQueuedWriteBytes
    }

    deinit {
        // Only the descriptor, and only if nothing ever adopted it. A live pump owns its own
        // teardown through the channel's cleanup handler.
        lock.lock()
        let orphan = channel == nil ? descriptor : -1
        descriptor = -1
        lock.unlock()
        if orphan >= 0 { PTYHostSocket.close(orphan) }
    }

    // MARK: - Public Properties

    /// The daemon's `hello`, once the gate admitted it. Its `build` is what a journal reports and
    /// what the retirement policy compares; it is never compared for admission.
    var peerHello: PTYHostHello? {
        lock.lock()
        defer { lock.unlock() }
        return peerHelloStorage
    }

    /// The most recent `lost` frame the daemon sent — the sessions a `KeepAlive` restart could
    /// not account for.
    ///
    /// Recorded here as well as delivered through `Events.frame` because it arrives immediately
    /// after `hello`, before any caller has had a chance to install a handler for it, and it is
    /// the one thing this connection knows that nothing else can reconstruct.
    var reportedLoss: PTYHostLost? {
        lock.lock()
        defer { lock.unlock() }
        return reportedLossStorage
    }

    /// The session this connection is bound to, or nil before `spawn`/`attach`.
    var boundSession: PTYHostSessionIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return binding.session
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .ready
    }

    // MARK: - Public Methods

    /// Connects, says `hello`, waits for the daemon's, and runs the version gate.
    ///
    /// Blocking, bounded by the connect, hello and frame-write deadlines, and therefore **never on the main
    /// actor**. On success the read pump is running and every later frame arrives on `queue`.
    ///
    /// The gate's three answers, per D2:
    ///
    /// - `compatible` — ready.
    /// - `peerTooOld` — the daemon is behind. It is sent `retire`, which unlinks the socket
    ///   immediately so a new binary can bind it, drains its existing sessions and exits; launchd
    ///   then starts the current binary. Then the connection closes and this throws.
    /// - `selfTooOld` — this app is behind. **Nothing further is sent**: retiring a daemon that
    ///   is newer than us would take working agents down to install an older host.
    ///
    /// A `helloRefused` from the daemon carries the daemon's own evaluation, which is the mirror
    /// image of ours — its `peerTooOld` is our `selfTooOld`. It is flipped here so that a caller
    /// reading `.incompatible(_)` never has to know which side did the arithmetic.
    @discardableResult
    func connect() throws -> PTYHostHello {
        try beginHandshake()
        do {
            let completion = try performHandshake()
            try startPump(pending: completion.pending)
            return completion.peer
        } catch {
            let refusal = (error as? PTYHostClientError) ?? .connectFailed(errno: 0)
            abandonHandshake(refusal)
            throw refusal
        }
    }

    /// Sends one control frame.
    ///
    /// The binding rules are enforced here rather than at each convenience method, so there is
    /// one place that decides what this connection is allowed to say.
    func send(_ frame: PTYHostFrame) throws {
        let reservation = try prepareToSend(frame)

        do {
            try enqueue(PTYHostFraming.framed(kind: .control, payload: try encode(frame)))
        } catch {
            unbindIfNeeded(reservation)
            throw error
        }
    }

    func list() throws { try send(.list) }

    func spawn(_ request: PTYHostSpawnRequest) throws { try send(.spawn(request)) }

    func attach(_ request: PTYHostAttach) throws { try send(.attach(request)) }

    func resize(_ request: PTYHostResize) throws { try send(.resize(request)) }

    func detach(_ request: PTYHostDetach) throws { try send(.detach(request)) }

    func closeInput(_ request: PTYHostCloseInput) throws { try send(.closeInput(request)) }

    func kill(_ request: PTYHostKill) throws { try send(.kill(request)) }

    func retire() throws { try send(.retire) }

    func journalTail(maxBytes: Int) throws {
        try send(.journalTail(PTYHostJournalTail(maxBytes: maxBytes)))
    }

    /// Raw keystrokes, as `kind` 2 with no envelope.
    ///
    /// Refused before a binding exists: input carries no session id, so a connection that has not
    /// bound has nothing to say who it is for, and guessing would type into somebody else's
    /// agent.
    func sendInput(_ bytes: Data) throws {
        try requireInputBinding()
        try enqueue(PTYHostFraming.framed(kind: .input, payload: bytes))
    }

    /// Blocks until nothing this client has queued is still unwritten, or `deadline` passes.
    ///
    /// `DispatchIO` accepts a write and reports it complete later, so "it has been sent" is not
    /// something the caller learns by returning from `send`. That matters in exactly one place:
    /// the quit path, where the close that follows the last frame is the process exiting, and a
    /// `detach` still in the queue is a seed the next launch never gets.
    ///
    /// **Blocking.** Bounded by the caller's deadline, which is the whole reason the deadline is
    /// the caller's: a quit with forty host-backed sessions must cost one wait, not forty.
    @discardableResult
    func drainWrites(until deadline: Date) -> Bool {
        lock.lock()
        guard queuedWriteBytes > 0, state == .ready else {
            let drained = queuedWriteBytes == 0
            lock.unlock()
            return drained
        }
        let semaphore = DispatchSemaphore(value: 0)
        drainWaiters.append(semaphore)
        lock.unlock()

        _ = semaphore.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow))
        lock.lock()
        defer { lock.unlock() }
        return queuedWriteBytes == 0
    }

    /// Ends the link. Idempotent; `Events.closed` fires at most once.
    func close() {
        close(with: nil)
    }

    // MARK: - Private Methods — Handshake

    private func beginHandshake() throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .idle else { throw PTYHostClientError.notReady }
        state = .handshaking
    }

    private func performHandshake() throws -> PTYHostHandshake.Completion {
        let connected = try PTYHostSocket.connect(
            to: socketPath,
            timeout: connectTimeout
        )
        lock.lock()
        descriptor = connected
        lock.unlock()

        let mine = PTYHostHello(
            protocolVersion: PTYHostProtocol.current,
            minimumSupported: PTYHostProtocol.minimumSupported,
            build: build,
            pid: getpid()
        )
        try Self.writeAll(
            descriptor: connected,
            try PTYHostFraming.framed(kind: .control, payload: try encode(.hello(mine)))
        )

        let deadline = Date().addingTimeInterval(helloTimeout)
        var handshake = PTYHostHandshake()

        while true {
            let bytes = try Self.read(descriptor: connected, until: deadline)
            let wire: [PTYHostWireFrame]
            lock.lock()
            let outcome = decoder.accept(bytes)
            lock.unlock()
            switch outcome {
            case .refused(let refusal):
                throw PTYHostClientError.framing(refusal)
            case .frames(let frames):
                wire = frames
            }

            if let completion = try handshake.accept(
                wire,
                decodeControl: decodeControl,
                admit: { try admit($0, compatibility: $1, descriptor: connected) },
                unexpectedInput: { ThreadingLogger.ptyHost.error("PTY host sent an input frame; ignored") }
            ) {
                return completion
            }
        }
    }

    /// Applies the gate and, on a refusal, does the one thing D2 says to do about it.
    private func admit(
        _ peer: PTYHostHello,
        compatibility: PTYHostCompatibility,
        descriptor: Int32
    ) throws {
        switch compatibility {
        case .compatible:
            lock.lock()
            peerHelloStorage = peer
            state = .ready
            lock.unlock()
            journal(
                "PTY host connected",
                ["build": peer.build, "protocol": String(peer.protocolVersion)]
            )
            ThreadingLogger.ptyHost.info(
                "PTY host connected, protocol \(peer.protocolVersion, privacy: .public)"
            )

        case .peerTooOld:
            // The daemon is behind. Ask it to retire: it unlinks the socket immediately so the
            // new binary can bind, keeps serving what is already attached, and exits when its
            // last session ends. Killing it instead would be killing working agents.
            if let retirement = try? PTYHostFraming.framed(
                kind: .control,
                payload: try encode(.retire)
            ) {
                try? Self.writeAll(descriptor: descriptor, retirement)
            }
            _ = PTYHostSocket.shutdown(descriptor, Int32(SHUT_WR))
            journalMismatch(peer, compatibility: compatibility, retired: true)
            throw PTYHostClientError.incompatible(compatibility)

        case .selfTooOld:
            // We are behind. Say nothing further — retiring a newer daemon would take working
            // agents down in order to install an older host.
            journalMismatch(peer, compatibility: compatibility, retired: false)
            throw PTYHostClientError.incompatible(compatibility)
        }
    }

    private func journalMismatch(
        _ peer: PTYHostHello,
        compatibility: PTYHostCompatibility,
        retired: Bool
    ) {
        let update = compatibility.updateTarget(evaluatedBy: .app)?.rawValue ?? "none"
        journal(
            "PTY host protocol mismatch",
            [
                "compatibility": compatibility.rawValue,
                "update": update,
                "build": peer.build,
                "protocol": String(peer.protocolVersion),
                "retired": retired ? "true" : "false"
            ]
        )
        ThreadingLogger.ptyHost.warning(
            """
            PTY host protocol mismatch: \(compatibility.rawValue, privacy: .public), \
            update \(update, privacy: .public)
            """
        )
    }

    /// Frames that arrived in the same read as `hello` — the daemon's `lost` set is the one that
    /// matters — are replayed once the pump owns the connection, in wire order.
    private func deliver(_ pending: [PendingDelivery]) {
        guard !pending.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for delivery in pending {
                switch delivery {
                case .control(let frame):
                    self.handle(control: frame)
                case .output(let bytes, let standardError):
                    if standardError {
                        self.events.standardError(bytes)
                    } else {
                        self.events.output(bytes)
                    }
                }
            }
        }
    }

    private func abandonHandshake(_ error: PTYHostClientError) {
        lock.lock()
        let orphan = descriptor
        descriptor = -1
        state = .closed
        // A `connect()` that throws is its own report; nothing has been handed to the caller yet,
        // so a `closed` event would be a second ending for a link that never began.
        didReportClosed = true
        lock.unlock()
        if orphan >= 0 {
            _ = PTYHostSocket.shutdown(orphan, Int32(SHUT_RDWR))
            PTYHostSocket.close(orphan)
        }
        if case .framing(let refusal) = error {
            journal("PTY host framing refused", ["cause": error.token])
            ThreadingLogger.ptyHost.error(
                "PTY host framing refused during handshake: \(String(describing: refusal), privacy: .public)"
            )
        }
    }

    // MARK: - Private Methods — The pump

    private func startPump(pending: [PendingDelivery]) throws {
        lock.lock()
        let connected = descriptor
        lock.unlock()
        guard connected >= 0 else { return }

        #if os(Linux)
        let writer = try PTYHostSocketWriter(descriptor: connected)
        #endif

        let channel = DispatchIO(
            type: .stream,
            fileDescriptor: connected,
            queue: queue
        ) { _ in
            PTYHostSocket.close(connected)
        }
        channel.setLimit(lowWater: 1)

        lock.lock()
        self.channel = channel
        #if os(Linux)
        self.writer = writer
        #endif
        lock.unlock()

        // Queue retained handshake deliveries before starting live reads, after every descriptor
        // owner has been allocated successfully. A failed writer allocation delivers nothing.
        deliver(pending)
        channel.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            self?.received(data, done: done, error: error)
        }
    }

    private func received(_ data: DispatchData?, done: Bool, error: Int32) {
        if let data, !data.isEmpty {
            var bytes = Data()
            bytes.append(contentsOf: data)
            lock.lock()
            let outcome = decoder.accept(bytes)
            lock.unlock()

            switch outcome {
            case .refused(let refusal):
                journal("PTY host framing refused", ["cause": "framing"])
                ThreadingLogger.ptyHost.error(
                    "PTY host framing refused: \(String(describing: refusal), privacy: .public)"
                )
                close(with: .framing(refusal))
                return
            case .frames(let frames):
                for frame in frames { dispatch(frame) }
            }
        }

        if error != 0 {
            close(with: .readFailed(errno: error))
            return
        }
        // `done` with no error is end-of-stream: the daemon closed, or exited.
        if done { close(with: nil) }
    }

    private func dispatch(_ frame: PTYHostWireFrame) {
        switch frame.kind {
        case .output:
            if frame.flags & PTYHostFramingDefaults.standardErrorFlag != 0 {
                events.standardError(frame.payload)
            } else {
                events.output(frame.payload)
            }
        case .input:
            ThreadingLogger.ptyHost.error("PTY host sent an input frame; ignored")
        case .control:
            guard let control = decodeControl(frame.payload) else { return }
            handle(control: control)
        }
    }

    private func handle(control frame: PTYHostFrame) {
        switch frame {
        case .lost(let lost):
            lock.lock()
            reportedLossStorage = lost
            lock.unlock()
            journal(
                "PTY host reported lost sessions",
                ["count": String(lost.ids.count)]
            )
            ThreadingLogger.ptyHost.warning(
                "PTY host lost \(lost.ids.count, privacy: .public) session(s) across a restart"
            )
        case .spawnRefused:
            // The binding was taken optimistically when the request went out. A refusal releases
            // it, so the caller may try another session on this connection rather than having to
            // build a second one.
            lock.lock()
            binding.received(frame)
            lock.unlock()
        default:
            break
        }
        events.frame(frame)
    }

    /// A control payload, or nil having said why.
    ///
    /// Nil is never fatal here. An unknown `type` is the additive case the version gate already
    /// admitted, and a body this build cannot read is still a frame whose *length* was right, so
    /// the stream is in step either way and the only correct move is to read on.
    private func decodeControl(_ payload: Data) -> PTYHostFrame? {
        do {
            return try JSONDecoder().decode(PTYHostFrame.self, from: payload)
        } catch PTYHostFrameRefusal.unknownFrameType(let type) {
            ThreadingLogger.ptyHost.info(
                "PTY host sent an unknown frame type; ignored: \(type, privacy: .public)"
            )
            return nil
        } catch {
            ThreadingLogger.ptyHost.error(
                """
                PTY host sent a control frame this build could not read; ignored: \
                \(String(describing: error), privacy: .private(mask: .hash))
                """
            )
            return nil
        }
    }

    // MARK: - Private Methods — Binding

    private func prepareToSend(_ frame: PTYHostFrame) throws -> PTYHostConnectionBinding.Reservation? {
        lock.lock()
        defer { lock.unlock() }
        return try binding.prepare(frame)
    }

    private func requireInputBinding() throws {
        lock.lock()
        defer { lock.unlock() }
        try binding.requireInputBinding()
    }

    /// A failed send releases only its own binding, even if a newer one was admitted meanwhile.
    private func unbindIfNeeded(_ reservation: PTYHostConnectionBinding.Reservation?) {
        lock.lock()
        defer { lock.unlock() }
        binding.sendingFailed(reservation)
    }

    // MARK: - Private Methods — Writing

    private func encode(_ frame: PTYHostFrame) throws -> Data {
        do {
            return try JSONEncoder().encode(frame)
        } catch {
            throw PTYHostClientError.oversizeFrame
        }
    }

    /// Hands framed bytes to the channel, refusing to grow past the write bound.
    ///
    /// The accounting is ours because `DispatchIO` has none to offer: it accepts whatever it is
    /// given and reports completion later, so "how much is unwritten" is a number only the caller
    /// can keep. A daemon that has stopped reading is the case this exists for — without the
    /// bound, an unresponsive peer would drive an unbounded allocation in the app.
    private func enqueue(_ framed: Data) throws {
        lock.lock()
        guard state == .ready, let channel else {
            lock.unlock()
            throw PTYHostClientError.notReady
        }
        #if os(Linux)
        guard let writer = self.writer else {
            lock.unlock()
            throw PTYHostClientError.notReady
        }
        #endif
        let bound = maximumQueuedWriteBytes
        let queued = queuedWriteBytes + framed.count
        guard queued <= bound else {
            lock.unlock()
            let overflow = PTYHostClientError.writeQueueOverflow(queuedBytes: queued)
            journal(
                "PTY host write queue overflowed",
                ["queuedBytes": String(queued)]
            )
            ThreadingLogger.ptyHost.error(
                """
                PTY host stopped reading; \(queued, privacy: .public) bytes queued, \
                over the \(bound, privacy: .public)-byte bound; closing
                """
            )
            close(with: overflow)
            throw overflow
        }
        queuedWriteBytes = queued
        lock.unlock()

        let count = framed.count
        #if os(Linux)
        writer.write(framed) { [weak self] error in self?.finishedWrite(count, error: error) }
        #else
        let payload = framed.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: payload, queue: queue) { [weak self] done, _, error in
            guard done else { return }
            self?.finishedWrite(count, error: error)
        }
        #endif
    }

    private func finishedWrite(_ count: Int, error: Int32) {
        lock.lock()
        queuedWriteBytes = max(0, queuedWriteBytes - count)
        // Taken under the lock and signalled outside it: the lock is never held across a call
        // out of this type.
        let waiters = queuedWriteBytes == 0 ? takeDrainWaitersLocked() : []
        lock.unlock()
        for waiter in waiters { waiter.signal() }
        guard error != 0 else { return }
        close(with: .writeFailed(errno: error))
    }

    /// The waiters, cleared. **The lock must be held.**
    private func takeDrainWaitersLocked() -> [DispatchSemaphore] {
        let waiters = drainWaiters
        drainWaiters.removeAll()
        return waiters
    }

    // MARK: - Private Methods — Closing

    private func close(with error: PTYHostClientError?) {
        lock.lock()
        guard state != .closed else {
            lock.unlock()
            return
        }
        state = .closed
        let openChannel = channel
        #if os(Linux)
        let openWriter = writer
        writer = nil
        #endif
        let openDescriptor = descriptor
        let shouldReport = !didReportClosed
        didReportClosed = true
        channel = nil
        descriptor = -1
        binding.reset()
        let waiters = takeDrainWaitersLocked()
        lock.unlock()
        for waiter in waiters { waiter.signal() }

        if openDescriptor >= 0 { _ = PTYHostSocket.shutdown(openDescriptor, Int32(SHUT_RDWR)) }
        #if os(Linux)
        openWriter?.close()
        #endif
        if let openChannel {
            // The channel's cleanup handler owns the descriptor once the pump started.
            openChannel.close(flags: .stop)
        } else if openDescriptor >= 0 {
            PTYHostSocket.close(openDescriptor)
        }

        if shouldReport {
            if let cause = error?.token {
                journal("PTY host link closed", ["cause": cause])
            }
            queue.async { [events] in events.closed(error) }
        }
    }

    // MARK: - Private Methods — POSIX

    private static func writeAll(descriptor: Int32, _ data: Data) throws {
        try PTYHostSocket.writeAll(descriptor: descriptor, data: data,
                                   timeout: PTYHostClientDefaults.helloTimeout)
    }

    private static func read(descriptor: Int32, until deadline: Date) throws -> Data {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw PTYHostClientError.handshakeTimedOut }

            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, Int32((remaining * 1000).rounded(.up)))
            if ready < 0 {
                if errno == EINTR { continue }
                throw PTYHostClientError.readFailed(errno: errno)
            }
            guard ready > 0 else { throw PTYHostClientError.handshakeTimedOut }

            var chunk = [UInt8](
                repeating: 0,
                count: PTYHostClientDefaults.handshakeReadChunkBytes
            )
            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                PTYHostSocket.read(descriptor, raw.baseAddress, raw.count)
            }
            if count > 0 { return Data(chunk[0..<count]) }
            if count == 0 { throw PTYHostClientError.closedEarly }
            if errno == EINTR { continue }
            throw PTYHostClientError.readFailed(errno: errno)
        }
    }
}

// MARK: - Framing helper

private extension PTYHostFraming {

    /// Framing an oversize payload is a refusal, not a trap, and the client's own error type is
    /// what its callers catch. Deliberately not an overload of the package's `encode` — a name
    /// that differed only by a defaulted argument would be resolved by arity rather than by
    /// intent.
    static func framed(kind: PTYHostFrameKind, payload: Data) throws -> Data {
        do {
            return try encode(kind: kind, flags: 0, payload: payload)
        } catch {
            throw PTYHostClientError.oversizeFrame
        }
    }
}
