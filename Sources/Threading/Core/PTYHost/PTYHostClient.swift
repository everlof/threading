import Darwin
import Dispatch
import Foundation
import ThreadingPTYHostKit

// MARK: - Errors

/// Why a link to the background PTY host could not be made, or could not be kept.
///
/// Structural tokens rather than sentences, and typed rather than a `Bool` or an `NSError`,
/// because every one of them has a different consequence: three mean "run this session's PTY
/// in-process", two mean "the caller has a bug", and the rest mean "the daemon is not the daemon
/// we can talk to". A caller that cannot tell them apart cannot degrade correctly.
enum PTYHostClientError: Error, Equatable, Sendable {

    /// The rendezvous path does not fit `sockaddr_un.sun_path`.
    case pathTooLong(bytes: Int)
    case socketUnavailable(errno: Int32)
    case connectFailed(errno: Int32)
    case connectTimedOut
    /// The daemon did not say `hello` inside `PTYHostDefaults.helloTimeout`.
    case handshakeTimedOut
    /// The peer closed before the handshake finished.
    case closedEarly
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)

    /// The version gate refused, from **this app's** perspective — `selfTooOld` means the app is
    /// behind, whichever side did the evaluating. See `PTYHostClient.connect()`.
    case incompatible(PTYHostCompatibility)

    /// The stream stopped being a conversation. Terminal: there is no resynchronisation point in
    /// a length-prefixed stream.
    case framing(PTYHostFramingRefusal)

    /// A frame this build would have sent is larger than the wire allows.
    case oversizeFrame

    /// The daemon stopped reading and the unwritten bytes reached
    /// `PTYHostDefaults.maximumQueuedWriteBytes`. The connection is closed rather than grown.
    case writeQueueOverflow(queuedBytes: Int)

    /// A send before `connect()` returned, or after the link closed.
    case notReady

    /// A second `spawn` or `attach` on a connection that is already bound to a session.
    case alreadyBound(PTYHostSessionIdentity)

    /// Raw input on a connection that has not been bound to a session. Input carries no id, so
    /// there is nothing else to say who it is for.
    case notBound

    /// A frame naming a session this connection is not bound to.
    case sessionMismatch(bound: PTYHostSessionIdentity, frame: PTYHostSessionIdentity)

    /// The journal token. A cause, never a path.
    var token: String {
        switch self {
        case .pathTooLong: return "pathTooLong"
        case .socketUnavailable: return "socketUnavailable"
        case .connectFailed: return "connectFailed"
        case .connectTimedOut: return "connectTimedOut"
        case .handshakeTimedOut: return "handshakeTimedOut"
        case .closedEarly: return "closedEarly"
        case .readFailed: return "readFailed"
        case .writeFailed: return "writeFailed"
        case .incompatible(let compatibility): return "incompatible.\(compatibility.rawValue)"
        case .framing(let refusal):
            switch refusal {
            case .oversizePayload: return "framing.oversizePayload"
            case .unknownKind: return "framing.unknownKind"
            }
        case .oversizeFrame: return "oversizeFrame"
        case .writeQueueOverflow: return "writeQueueOverflow"
        case .notReady: return "notReady"
        case .alreadyBound: return "alreadyBound"
        case .notBound: return "notBound"
        case .sessionMismatch: return "sessionMismatch"
        }
    }
}

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
/// protocol pair, its build string and its pid, and the daemon answers with its own `hello` or
/// with `helloRefused`. Speaking first is what makes a wrong-version daemon cheap to detect: the
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

        /// Raw PTY output (`kind` 1): replay bytes first, in order, then live output.
        var output: @Sendable (Data) -> Void

        /// The link ended. Delivered exactly once, and only for a client whose `connect()`
        /// returned — a `connect()` that throws *is* its own report. `nil` means `close()`.
        var closed: @Sendable (PTYHostClientError?) -> Void

        init(
            frame: @escaping @Sendable (PTYHostFrame) -> Void = { _ in },
            output: @escaping @Sendable (Data) -> Void = { _ in },
            closed: @escaping @Sendable (PTYHostClientError?) -> Void = { _ in }
        ) {
            self.frame = frame
            self.output = output
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

    // MARK: - Properties

    /// The queue every event is delivered on. Serial, so frames arrive in wire order.
    let queue: DispatchQueue

    private let socketPath: String
    private let build: String
    private let events: Events
    private let eventLog: EventLog
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
    private var decoder = PTYHostFrameDecoder()
    private var queuedWriteBytes = 0
    private var boundSessionStorage: PTYHostSessionIdentity?
    private var peerHelloStorage: PTYHostHello?
    private var reportedLossStorage: PTYHostLost?
    private var didReportClosed = false

    // MARK: - Initialization

    init(
        socketPath: String,
        build: String,
        events: Events,
        eventLog: EventLog = .shared,
        queue: DispatchQueue? = nil,
        connectTimeout: TimeInterval = PTYHostDefaults.connectTimeout,
        helloTimeout: TimeInterval = PTYHostDefaults.helloTimeout,
        maximumQueuedWriteBytes: Int = PTYHostDefaults.maximumQueuedWriteBytes
    ) {
        self.socketPath = socketPath
        self.build = build
        self.events = events
        self.eventLog = eventLog
        self.queue = queue ?? DispatchQueue(label: PTYHostDefaults.clientQueueLabel)
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
        if orphan >= 0 { Darwin.close(orphan) }
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
        return boundSessionStorage
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .ready
    }

    // MARK: - Public Methods

    /// Connects, says `hello`, waits for the daemon's, and runs the version gate.
    ///
    /// Blocking, bounded by `connectTimeout + helloTimeout`, and therefore **never on the main
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
            let hello = try performHandshake()
            startPump()
            return hello
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
        switch frame {
        case .spawn(let request):
            try bind(to: request.id)
        case .attach(let request):
            try bind(to: request.id)
        case .resize(let request):
            try requireBinding(matches: request.id)
        case .detach(let request):
            try requireBinding(matches: request.id)
        case .kill(let request):
            try requireBinding(matches: request.id)
        default:
            break
        }

        do {
            try enqueue(PTYHostFraming.framed(kind: .control, payload: try encode(frame)))
        } catch {
            unbindIfNeeded(after: frame)
            throw error
        }
    }

    func list() throws { try send(.list) }

    func spawn(_ request: PTYHostSpawnRequest) throws { try send(.spawn(request)) }

    func attach(_ request: PTYHostAttach) throws { try send(.attach(request)) }

    func resize(_ request: PTYHostResize) throws { try send(.resize(request)) }

    func detach(_ request: PTYHostDetach) throws { try send(.detach(request)) }

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
        lock.lock()
        let bound = boundSessionStorage
        lock.unlock()
        guard bound != nil else { throw PTYHostClientError.notBound }
        try enqueue(PTYHostFraming.framed(kind: .input, payload: bytes))
    }

    /// Ends the link. Idempotent; `Events.closed` fires at most once.
    func close() {
        close(with: nil)
    }

    // MARK: - Probing

    /// One connect-`hello`-close round trip, for `PTYHostAvailability`.
    ///
    /// The full client rather than a simplified dialect on purpose: a probe that spoke less than
    /// the link does could admit a daemon the link then refuses, and the degrade would happen at
    /// launch time instead of at decision time.
    static func probe(
        socketPath: String,
        build: String,
        eventLog: EventLog = .shared
    ) -> PTYHostProbeOutcome {
        let client = PTYHostClient(
            socketPath: socketPath,
            build: build,
            events: .ignored,
            eventLog: eventLog
        )
        do {
            _ = try client.connect()
            client.close()
            return .ready
        } catch PTYHostClientError.incompatible(let compatibility) {
            return .mismatched(compatibility)
        } catch {
            let cause = (error as? PTYHostClientError)?.token ?? "unknown"
            ThreadingLogger.ptyHost.info(
                "PTY host probe found no usable daemon: \(cause, privacy: .public)"
            )
            return .notRunning
        }
    }

    // MARK: - Private Methods — Handshake

    private func beginHandshake() throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .idle else { throw PTYHostClientError.notReady }
        state = .handshaking
    }

    private func performHandshake() throws -> PTYHostHello {
        let connected = try Self.connectedDescriptor(
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
        try Self.writeAll(descriptor: connected, try encode(.hello(mine)))

        let deadline = Date().addingTimeInterval(helloTimeout)
        var pending: [PTYHostFrame] = []
        var pendingOutput: [Data] = []

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

            for frame in wire {
                switch frame.kind {
                case .output:
                    pendingOutput.append(frame.payload)
                    continue
                case .input:
                    // The daemon never sends input. Ignore it rather than close: the framing is
                    // still in step, and a peer saying something meaningless is not a peer whose
                    // stream cannot be read.
                    ThreadingLogger.ptyHost.error("PTY host sent an input frame; ignored")
                    continue
                case .control:
                    break
                }

                guard let control = decodeControl(frame.payload) else { continue }
                switch control {
                case .hello(let peer):
                    let compatibility = PTYHostCompatibility.evaluate(peer: peer)
                    try admit(peer, compatibility: compatibility, descriptor: connected)
                    deliver(pending: pending, output: pendingOutput)
                    return peer
                case .helloRefused(let refusal):
                    // The daemon evaluated us. Its answer names *us* as the peer, so it is the
                    // mirror of ours.
                    throw PTYHostClientError.incompatible(Self.flipped(refusal.compatibility))
                default:
                    pending.append(control)
                }
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
            eventLog.record(
                .session,
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
            if let retirement = try? encode(.retire) {
                try? Self.writeAll(descriptor: descriptor, retirement)
            }
            _ = Darwin.shutdown(descriptor, SHUT_WR)
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
        eventLog.record(
            .session,
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
    private func deliver(pending: [PTYHostFrame], output: [Data]) {
        guard !pending.isEmpty || !output.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for frame in pending { self.handle(control: frame) }
            for bytes in output { self.events.output(bytes) }
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
            _ = Darwin.shutdown(orphan, SHUT_RDWR)
            Darwin.close(orphan)
        }
        if case .framing(let refusal) = error {
            eventLog.record(.session, "PTY host framing refused", ["cause": error.token])
            ThreadingLogger.ptyHost.error(
                "PTY host framing refused during handshake: \(String(describing: refusal), privacy: .public)"
            )
        }
    }

    /// The daemon's compatibility answer, restated from this app's side.
    ///
    /// `peerTooOld` from the daemon means *the app* is too old, which from here is `selfTooOld`.
    /// A fixed mapping would be right on one side and exactly backwards on the other, which is
    /// the same trap `PTYHostCompatibility.updateTarget(evaluatedBy:)` exists to avoid.
    private static func flipped(_ compatibility: PTYHostCompatibility) -> PTYHostCompatibility {
        switch compatibility {
        case .compatible: return .compatible
        case .peerTooOld: return .selfTooOld
        case .selfTooOld: return .peerTooOld
        }
    }

    // MARK: - Private Methods — The pump

    private func startPump() {
        lock.lock()
        let connected = descriptor
        lock.unlock()
        guard connected >= 0 else { return }

        let channel = DispatchIO(
            type: .stream,
            fileDescriptor: connected,
            queue: queue
        ) { _ in
            Darwin.close(connected)
        }
        channel.setLimit(lowWater: 1)

        lock.lock()
        self.channel = channel
        lock.unlock()

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
                eventLog.record(.session, "PTY host framing refused", ["cause": "framing"])
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
            events.output(frame.payload)
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
            eventLog.record(
                .session,
                "PTY host reported lost sessions",
                ["count": String(lost.ids.count)]
            )
            ThreadingLogger.ptyHost.warning(
                "PTY host lost \(lost.ids.count, privacy: .public) session(s) across a restart"
            )
        case .spawnRefused(let refused):
            // The binding was taken optimistically when the request went out. A refusal releases
            // it, so the caller may try another session on this connection rather than having to
            // build a second one.
            lock.lock()
            if boundSessionStorage == refused.id { boundSessionStorage = nil }
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

    private func bind(to session: PTYHostSessionIdentity) throws {
        lock.lock()
        defer { lock.unlock() }
        if let bound = boundSessionStorage {
            throw PTYHostClientError.alreadyBound(bound)
        }
        boundSessionStorage = session
    }

    private func requireBinding(matches session: PTYHostSessionIdentity) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let bound = boundSessionStorage else { throw PTYHostClientError.notBound }
        guard bound == session else {
            throw PTYHostClientError.sessionMismatch(bound: bound, frame: session)
        }
    }

    /// A `spawn` or `attach` whose bytes never left releases the binding it took.
    private func unbindIfNeeded(after frame: PTYHostFrame) {
        switch frame {
        case .spawn, .attach:
            lock.lock()
            boundSessionStorage = nil
            lock.unlock()
        default:
            break
        }
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
        let bound = maximumQueuedWriteBytes
        let queued = queuedWriteBytes + framed.count
        guard queued <= bound else {
            lock.unlock()
            let overflow = PTYHostClientError.writeQueueOverflow(queuedBytes: queued)
            eventLog.record(
                .session,
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
        let payload = framed.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: payload, queue: queue) { [weak self] done, _, error in
            guard done else { return }
            self?.finishedWrite(count, error: error)
        }
    }

    private func finishedWrite(_ count: Int, error: Int32) {
        lock.lock()
        queuedWriteBytes = max(0, queuedWriteBytes - count)
        lock.unlock()
        guard error != 0 else { return }
        close(with: .writeFailed(errno: error))
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
        let openDescriptor = descriptor
        let shouldReport = !didReportClosed
        didReportClosed = true
        channel = nil
        descriptor = -1
        boundSessionStorage = nil
        lock.unlock()

        if openDescriptor >= 0 { _ = Darwin.shutdown(openDescriptor, SHUT_RDWR) }
        if let openChannel {
            // The channel's cleanup handler owns the descriptor once the pump started.
            openChannel.close(flags: .stop)
        } else if openDescriptor >= 0 {
            Darwin.close(openDescriptor)
        }

        if shouldReport {
            if let cause = error?.token {
                eventLog.record(.session, "PTY host link closed", ["cause": cause])
            }
            queue.async { [events] in events.closed(error) }
        }
    }

    // MARK: - Private Methods — POSIX

    private static func connectedDescriptor(
        to path: String,
        timeout: TimeInterval
    ) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw PTYHostClientError.pathTooLong(bytes: pathBytes.count)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[pathBytes.count] = 0
            }
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw PTYHostClientError.socketUnavailable(errno: errno)
        }

        // Writing to a socket the daemon has already closed must be an error, not a signal.
        // Without this the app dies of SIGPIPE when a daemon exits mid-write — which is exactly
        // the moment the feature is supposed to be degrading gracefully.
        var suppressSignal: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &suppressSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )

        do {
            try connect(descriptor: descriptor, to: &address, timeout: timeout)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    /// Connects with a deadline, by asking for a non-blocking connect and polling it.
    ///
    /// `SO_SNDTIMEO` does not bound a blocking `connect`, so the deadline has to be expressed
    /// this way — the same shape `Targets/MCPBridge/UnixHTTPClient.swift` uses. The descriptor
    /// goes back into blocking mode afterwards, because the handshake reads with its own `poll`
    /// deadline and the pump sets whatever it needs.
    private static func connect(
        descriptor: Int32,
        to address: inout sockaddr_un,
        timeout: TimeInterval
    ) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw PTYHostClientError.connectFailed(errno: errno)
        }

        let started = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if started != 0 {
            guard errno == EINPROGRESS else {
                throw PTYHostClientError.connectFailed(errno: errno)
            }
            try waitForConnect(descriptor: descriptor, timeout: timeout)
        }

        guard fcntl(descriptor, F_SETFL, flags) >= 0 else {
            throw PTYHostClientError.connectFailed(errno: errno)
        }
    }

    private static func waitForConnect(descriptor: Int32, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw PTYHostClientError.connectTimedOut }

            var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&event, 1, Int32((remaining * 1000).rounded(.up)))
            if ready < 0 {
                if errno == EINTR { continue }
                throw PTYHostClientError.connectFailed(errno: errno)
            }
            guard ready > 0 else { throw PTYHostClientError.connectTimedOut }

            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 else {
                throw PTYHostClientError.connectFailed(errno: errno)
            }
            guard failure == 0 else { throw PTYHostClientError.connectFailed(errno: failure) }
            return
        }
    }

    private static func writeAll(descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                throw PTYHostClientError.writeFailed(errno: errno)
            }
        }
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
                count: PTYHostDefaults.handshakeReadChunkBytes
            )
            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
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
