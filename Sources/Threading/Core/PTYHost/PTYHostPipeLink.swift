import Darwin
import Dispatch
import Foundation
import ThreadingDomain
import ThreadingPTYHostKit

// MARK: - Defaults

/// Numbers the pipe half of the link owns.
///
/// Kept apart from `PTYHostSessionDefaults`, which is the *terminal* half: those numbers are
/// about a screen seed and a replay budget, and none of them means anything here.
enum PTYHostPipeDefaults {

    /// How long a launch waits for the daemon to say the child exists.
    ///
    /// `AgentChildProcess.launch` is synchronous by contract — "`posix_spawn` reports a missing
    /// executable synchronously, exactly as `Process.run()` did" — and the three transports set
    /// `isRunning` on the line after it returns. So the host-backed path has to answer the same
    /// question before it returns, and the only way to answer it is to wait for `spawned` or
    /// `spawnRefused`. The daemon sends one of them straight out of `posix_spawn`, so this is a
    /// millisecond in practice. Three seconds also covers the daemon's two-second escalation and
    /// half-second output drain when this is an atomic same-identity replacement; the bound still
    /// turns a daemon that stopped answering into a launch failure rather than a hang.
    static let spawnTimeout: TimeInterval = 3

    /// How long the quit path waits for one conversation's `detach` to leave.
    ///
    /// The same shape as `PTYHostSessionDefaults.detachDrainSeconds` and, in `AgentRuntime`, the
    /// same shared deadline: a `DispatchIO` write is reported complete later, and on this path
    /// the close that follows the frame is the process exiting.
    static let detachDrainSeconds: TimeInterval = PTYHostSessionDefaults.detachDrainSeconds

    /// Keeps a deliberately stopped link alive long enough for a compatible older daemon to
    /// observe the kill and report the exit. Without it, discarding a native controller closes
    /// the socket behind the queued kill and the old daemon retains that identity for 30 minutes.
    static let terminationRetentionSeconds: TimeInterval = 5

    /// What may be queued towards the transport's own end of a pipe before bytes are dropped.
    ///
    /// The daemon's bound, from the other side. A transport that has stopped reading its child's
    /// output is not helped by a larger buffer, and the link's read loop must never be the thing
    /// that waits — the alternative to dropping is holding the whole daemon connection open on
    /// one wedged reader.
    static let maximumPendingChildBytes = 4 * 1024 * 1024

    /// What a link reports when the connection to the daemon ended without an `exited` frame.
    ///
    /// `128 + SIGHUP`, which is what a shell reports for a process that lost the thing it was
    /// attached to — and that is precisely what happened: when the daemon goes, its children lose
    /// their descriptors and the CLIs end. It is deliberately not
    /// `AgentChildProcessDefaults.spawnFailureStatus`, which means "it never started" and would
    /// put a launch failure on a conversation that had been running for an hour.
    static let linkLostStatus = 128 + SIGHUP
}

// MARK: - The plan

/// Everything a native launch needs in order to run its CLI in `threading-ptyd` instead of in
/// this process.
///
/// A value rather than three arguments, so `AgentChildProcess.launch` takes one optional and
/// "there is no host" is one `nil` rather than a combination that can be half-supplied. Composed
/// at the surface that owns the conversation record — `ConversationViewController`, which is
/// where `PTYHostPolicy` is asked, exactly as `AgentSessionViewController` asks it for a terminal.
struct PTYHostChildPlan: Sendable {

    /// The conversation this child belongs to, as the daemon names sessions.
    let identity: PTYHostSessionIdentity

    /// How the link to the daemon is made. Injectable for the reason every other seam here is:
    /// a test drives the whole host-backed path with no daemon, no socket and no window.
    let factory: PTYHostTransportFactory

    /// The directory the child starts in.
    ///
    /// Stated rather than left to the daemon, and that is the whole point: the daemon inherits
    /// *launchd's* working directory, and a child that started somewhere else than it would have
    /// in-process is a difference nobody asked for. The in-process path passes no working
    /// directory at all, so the child inherits the app's; naming the app's here is what makes the
    /// two byte-identical rather than merely similar.
    let workingDirectory: String?

    init(
        identity: PTYHostSessionIdentity,
        factory: @escaping PTYHostTransportFactory,
        workingDirectory: String? = FileManager.default.currentDirectoryPath
    ) {
        self.identity = identity
        self.factory = factory
        self.workingDirectory = workingDirectory
    }
}

/// Why a host-backed launch did not happen, as a token for the journal and launch failure.
///
/// They are told apart so the refusal can be explained from a support report. None is permission
/// to change ownership and run the child in-process; only a policy decision that did not select
/// hosting takes that path.
enum PTYHostChildRefusal: Error, Equatable, Sendable {
    /// The link could not be made or the daemon refused the version gate.
    case linkUnavailable(String)
    /// The daemon answered `spawnRefused`.
    case refused(PTYHostSpawnRefusal)
    /// Neither `spawned` nor `spawnRefused` arrived inside `PTYHostPipeDefaults.spawnTimeout`.
    case timedOut
    /// A local descriptor could not be prepared.
    case descriptorsUnavailable(Int32)

    var token: String {
        switch self {
        case .linkUnavailable(let cause): return "link.\(cause)"
        case .refused(let reason): return "refused.\(reason.rawValue)"
        case .timedOut: return "timedOut"
        case .descriptorsUnavailable: return "descriptorsUnavailable"
        }
    }
}

// MARK: - Link

/// One native conversation's half of the link to `threading-ptyd`.
///
/// **It turns a socket back into three descriptors.** The three transports read their CLI through
/// `FileHandle.readabilityHandler` and write its standard input through `FileHandle.write`, and
/// none of that changes for a hosted child: `AgentChildProcess` makes the same three pipes it
/// always made and hands the transport the same three ends, while this link owns the *other*
/// three and pumps them across the wire. So the adapters see the same bytes, in the same order,
/// through the same API, and the framing, handshake deadlines, malformed-line counters and
/// exactly-once exit callbacks they each own are untouched — which is the half of this feature
/// the design named as the risky one.
///
/// **Nothing here runs on main except the ending.** Frames arrive on the client's own serial
/// queue and are written into the local pipes from there; the kernel then wakes the transport's
/// own readability handler, which hops to the main actor exactly as it did for a local child.
///
/// **Only an explicit stop kills the child.** `terminate()` sends `kill`; a quit sends `detach`;
/// and a link that is simply released lets go — the daemon reads the close as a watcher that
/// vanished and keeps the child.
final class PTYHostPipeLink: @unchecked Sendable {

    // MARK: - Types

    /// Where the link's one edge goes. Invoked **on the main queue**, exactly once.
    struct Delivery: Sendable {

        /// The child ended, with the status a shell would report. Never delivered inline from
        /// `spawn` or from anything `AgentChildProcess.launch` calls, so a transport's `start()`
        /// still owns its launch state when it returns.
        var ended: @Sendable (Int32) -> Void = { _ in }
    }

    // MARK: - Properties

    let identity: PTYHostSessionIdentity

    private let lock = NSLock()
    private var transportStorage: (any PTYHostSessionTransport)?
    private var deliveryStorage = Delivery()

    /// The daemon-facing ends of the three local pipes, once adopted. Each is owned by its
    /// channel's cleanup handler from that moment, and by nothing else.
    private var inputChannel: DispatchIO?
    private var outputChannel: DispatchIO?
    private var errorChannel: DispatchIO?
    private var pendingChildBytes = 0

    /// A native surface switch releases its controller immediately after asking the child to
    /// stop. Retain the link itself until the exit arrives (or a bounded backstop expires), so
    /// the kill frame and ending cannot be discarded with that controller.
    private var terminationRetainer: PTYHostPipeLink?

    /// The spawn answer, and the latch a synchronous launch waits on.
    private let spawnLatch = PTYHostLatch<Result<PTYHostSpawned, PTYHostChildRefusal>>()

    private var hasEnded = false
    private var hasExited = false

    // MARK: - Initialization

    init(identity: PTYHostSessionIdentity) {
        self.identity = identity
    }

    deinit {
        lock.lock()
        let transport = transportStorage
        transportStorage = nil
        let channels = [inputChannel, outputChannel, errorChannel]
        inputChannel = nil
        outputChannel = nil
        errorChannel = nil
        lock.unlock()

        // Letting go, never killing. The child is the daemon's and outlives this process, so a
        // link that stopped watching is a close — which the daemon keeps the child for.
        for channel in channels { channel?.close(flags: .stop) }
        transport?.close()
    }

    // MARK: - Public Methods

    var delivery: Delivery {
        get {
            lock.lock()
            defer { lock.unlock() }
            return deliveryStorage
        }
        set {
            lock.lock()
            deliveryStorage = newValue
            lock.unlock()
        }
    }

    /// Whether the child is still believed to be running.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !hasExited && !hasEnded
    }

    /// The handlers a transport is built with. Every one of them runs on the transport's queue.
    func events() -> PTYHostClient.Events {
        PTYHostClient.Events(
            frame: { [weak self] frame in self?.received(frame) },
            output: { [weak self] bytes in self?.forward(bytes, to: .standardOutput) },
            standardError: { [weak self] bytes in self?.forward(bytes, to: .standardError) },
            closed: { [weak self] error in self?.linkClosed(error) }
        )
    }

    func adopt(_ transport: any PTYHostSessionTransport) {
        lock.lock()
        transportStorage = transport
        lock.unlock()
    }

    /// Takes the daemon-facing ends of the three local pipes and starts pumping standard input.
    ///
    /// Called **before** the spawn, so no output frame can arrive with nowhere to go. Each
    /// descriptor becomes its channel's alone: a second apparent owner is how a number the kernel
    /// has already recycled gets closed under an unrelated file.
    ///
    /// `F_SETNOSIGPIPE` on both write ends for `AgentChildProcess`'s reason, from the other
    /// direction: the transport may close its read end at any moment — a `finish()`, a released
    /// controller — and a write into a pipe nobody is reading raises `SIGPIPE`, which would take
    /// Threading down rather than report an error.
    func adoptDescriptors(input: Int32, output: Int32, error: Int32) {
        _ = fcntl(output, F_SETNOSIGPIPE, 1)
        _ = fcntl(error, F_SETNOSIGPIPE, 1)

        let queue = DispatchQueue(label: PTYHostPipeDefaults.channelQueueLabel)
        let outputChannel = DispatchIO(
            type: .stream,
            fileDescriptor: output,
            queue: queue,
            cleanupHandler: { _ in Darwin.close(output) }
        )
        let errorChannel = DispatchIO(
            type: .stream,
            fileDescriptor: error,
            queue: queue,
            cleanupHandler: { _ in Darwin.close(error) }
        )
        let inputChannel = DispatchIO(
            type: .stream,
            fileDescriptor: input,
            queue: queue,
            cleanupHandler: { _ in Darwin.close(input) }
        )
        inputChannel.setLimit(lowWater: 1)

        lock.lock()
        self.outputChannel = outputChannel
        self.errorChannel = errorChannel
        self.inputChannel = inputChannel
        lock.unlock()

        inputChannel.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, _ in
            guard let self else { return }
            if let data, !data.isEmpty {
                var bytes = Data()
                bytes.reserveCapacity(data.count)
                data.enumerateBytes { buffer, _, _ in bytes.append(contentsOf: buffer) }
                send(input: bytes)
            }
            // End of file on the transport's own end of standard input is the graceful shutdown
            // every one of these transports performs in `finish()`. It is a descriptor event with
            // no byte to carry it, which is why the wire has a frame for it.
            if done { closeChildInput() }
        }
    }

    /// Asks the daemon to start the child. Throwing means nothing was sent.
    func spawn(_ request: PTYHostSpawnRequest) throws {
        guard let transport = currentTransport() else { throw PTYHostClientError.notReady }
        try transport.spawn(request)
    }

    /// Blocks until the daemon has said whether the child exists.
    ///
    /// **Blocking, and bounded.** `AgentChildProcess.launch` is synchronous, so this answer has
    /// to be in hand before it returns; a refusal or silence becomes a launch failure without
    /// changing process ownership.
    func awaitSpawn(
        timeout: TimeInterval = PTYHostPipeDefaults.spawnTimeout
    ) -> Result<PTYHostSpawned, PTYHostChildRefusal> {
        spawnLatch.wait(timeout) ?? .failure(.timedOut)
    }

    /// Hands the child back to the daemon instead of ending it, and lets go of the link.
    ///
    /// **The seeds are empty, and that is structural rather than lazy.** A screen seed is a
    /// repaint derived from a live emulator; a pipes session has no emulator anywhere, so there
    /// is nothing to compute and nothing to hand over. The daemon stores nothing for a pipes
    /// session and answers the next attach with a line-boundary cut, which is the honest answer.
    ///
    /// The frame is still sent rather than the socket simply closed, for two reasons: it is what
    /// tells the daemon's journal that this was a deliberate hand-over rather than a watcher that
    /// vanished, and it is what `drainWrites` has to wait on before the process exits.
    ///
    /// **Blocking, bounded by `deadline`.** Answers whether the frame was sent.
    @discardableResult
    func detach(by deadline: Date, idleExpiresAt: Date? = nil) -> Bool {
        lock.lock()
        guard !hasEnded, let transport = transportStorage else {
            lock.unlock()
            return false
        }
        hasEnded = true
        transportStorage = nil
        lock.unlock()

        do {
            try transport.detach(PTYHostDetach(
                id: identity,
                screenSeed: Data(),
                modeSeed: Data(),
                ringOffset: 0,
                idleExpiresAt: idleExpiresAt
            ))
        } catch {
            let cause = (error as? PTYHostClientError)?.token ?? "unknown"
            ThreadingLogger.ptyHost.error(
                "PTY host conversation detach could not be sent: \(cause, privacy: .public)"
            )
            transport.close()
            return false
        }

        _ = transport.drainWrites(until: deadline)
        transport.close()
        return true
    }

    /// Ends the child and everything it started. The link stays open so the daemon's `exited`
    /// still arrives — a watcher is owed the ending, and the ending is what the transport's own
    /// teardown runs on.
    func terminate() {
        lock.lock()
        guard !hasEnded, let transport = transportStorage else {
            lock.unlock()
            return
        }
        terminationRetainer = self
        lock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + PTYHostPipeDefaults.terminationRetentionSeconds
        ) { [weak self] in
            self?.releaseTerminationRetention()
        }
        do {
            try transport.kill(PTYHostKill(id: identity, escalate: true))
        } catch {
            fail(with: error)
        }
    }

    /// Drops the link without ending the child.
    func close() {
        lock.lock()
        let transport = transportStorage
        transportStorage = nil
        lock.unlock()
        transport?.close()
    }

    // MARK: - Private Methods — Frames

    private func currentTransport() -> (any PTYHostSessionTransport)? {
        lock.lock()
        defer { lock.unlock() }
        return transportStorage
    }

    private func received(_ frame: PTYHostFrame) {
        switch frame {
        case .spawned(let spawned) where spawned.id == identity:
            spawnLatch.complete(.success(spawned))

        case .spawnRefused(let refusal) where refusal.id == identity:
            spawnLatch.complete(.failure(.refused(refusal.reason)))

        case .exited(let exited) where exited.id == identity:
            // The shell's own convention, so a hosted child and a local one report the same
            // number for the same outcome — `SpawnedChildProcess.reap` computes it the same way,
            // and the transports compare against it.
            let status = exited.signalled
                ? ChildProcessSpawnDefaults.signalledExitBase + exited.status
                : exited.status
            end(status: status)

        case .error(let failure):
            let qualifier = failure.detail ?? "-"
            ThreadingLogger.ptyHost.error(
                """
                PTY host reported \(failure.code.rawValue, privacy: .public) for a conversation: \
                \(qualifier, privacy: .public)
                """
            )
            // A spawn that will never be answered must not hold a launch for its whole deadline.
            if failure.code == .spawnFailed {
                spawnLatch.complete(.failure(.linkUnavailable(failure.code.rawValue)))
            }

        default:
            break
        }
    }

    /// Writes one burst into the transport's end of a pipe.
    ///
    /// Dropped rather than queued without bound when the transport has stopped reading, which is
    /// the daemon's own rule seen from this side: growing a buffer for a reader that is not
    /// reading moves the failure rather than fixing it, and the alternative is holding the whole
    /// connection — every other session's frames included — on one wedged handler.
    private func forward(_ bytes: Data, to stream: Stream) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        let candidate = stream == .standardOutput ? outputChannel : errorChannel
        guard let target = candidate else {
            lock.unlock()
            return
        }
        guard pendingChildBytes + bytes.count <= PTYHostPipeDefaults.maximumPendingChildBytes else {
            lock.unlock()
            ThreadingLogger.ptyHost.error(
                "PTY host output dropped: the conversation transport stopped reading"
            )
            return
        }
        let submitted = bytes.count
        pendingChildBytes += submitted
        lock.unlock()

        let payload = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        target.write(
            offset: 0,
            data: payload,
            queue: PTYHostPipeDefaults.completionQueue
        ) { [weak self] done, _, _ in
            guard done, let self else { return }
            lock.lock()
            pendingChildBytes = max(0, pendingChildBytes - submitted)
            lock.unlock()
        }
    }

    private func send(input bytes: Data) {
        guard let transport = currentTransport() else { return }
        do {
            try transport.sendInput(bytes)
        } catch {
            // A child that has ended is the ordinary case here, not a failure of the link: the
            // transport wrote into a descriptor whose reader is gone. Swallowed for the same
            // reason `F_SETNOSIGPIPE` exists on the local path — an unread write must be an error
            // this link absorbs, never something that ends Threading.
            let cause = (error as? PTYHostClientError)?.token ?? "unknown"
            ThreadingLogger.ptyHost.debug(
                "PTY host conversation input was not delivered: \(cause, privacy: .public)"
            )
        }
    }

    private func closeChildInput() {
        guard let transport = currentTransport() else { return }
        try? transport.closeInput(PTYHostCloseInput(id: identity))
    }

    // MARK: - Private Methods — Endings

    /// The connection ended without an `exited` frame.
    ///
    /// Not an exit anybody observed, and it is reported as an ending anyway, because from the
    /// transport's side the difference is invisible and the alternative is a conversation that
    /// looks live and answers nothing. The cause is journalled; the status says the child lost
    /// what it was attached to, which is exactly what happened.
    private func linkClosed(_ error: PTYHostClientError?) {
        if let error {
            ThreadingLogger.ptyHost.warning(
                "PTY host conversation link ended: \(error.token, privacy: .public)"
            )
        }
        end(status: PTYHostPipeDefaults.linkLostStatus)
    }

    private func fail(with error: Error) {
        let cause = (error as? PTYHostClientError)?.token ?? "unknown"
        ThreadingLogger.ptyHost.error(
            "PTY host conversation link failed: \(cause, privacy: .public)"
        )
        end(status: PTYHostPipeDefaults.linkLostStatus)
    }

    /// Reports the ending exactly once, after the transport has seen end of file.
    ///
    /// The two closes are the whole ordering contract, and they are why this is not simply a
    /// callback: a transport learns a child is gone by reading end-of-file on its output, and one
    /// told "it exited" while its pipe was still open would tear itself down with the last of the
    /// child's output still unread. The channels are closed here — after every byte the daemon
    /// sent has been submitted to them, on this same serial queue — and only then is the status
    /// delivered, on the main queue, which a synchronous `launch()` cannot be inside.
    private func end(status: Int32) {
        lock.lock()
        guard !hasEnded else {
            lock.unlock()
            return
        }
        hasEnded = true
        hasExited = true
        let output = outputChannel
        let errors = errorChannel
        let input = inputChannel
        outputChannel = nil
        errorChannel = nil
        inputChannel = nil
        terminationRetainer = nil
        let delivery = deliveryStorage
        lock.unlock()

        // `[]` rather than `.stop`: queued writes reach the transport before the descriptor is
        // released, so the last of the child's output is read before the end of file that follows
        // it. The input channel is stopped instead — there is nobody left to send to.
        output?.close(flags: [])
        errors?.close(flags: [])
        input?.close(flags: .stop)

        // A spawn nobody answered, whose child then ended: release the launch rather than let it
        // wait out its deadline.
        spawnLatch.complete(.failure(.linkUnavailable("closed")))

        DispatchQueue.main.async { delivery.ended(status) }
    }

    private func releaseTerminationRetention() {
        lock.lock()
        terminationRetainer = nil
        lock.unlock()
    }
}

// MARK: - Streams

extension PTYHostPipeLink {

    /// Which of the child's two output streams a burst belongs to.
    fileprivate enum Stream {
        case standardOutput
        case standardError
    }
}

extension PTYHostPipeDefaults {

    /// The label every one of a link's three channels shares. One queue per link rather than per
    /// descriptor: the three are ordered with respect to each other only through the client's
    /// serial queue, and giving them one queue keeps a burst on standard error from overtaking
    /// the standard output written just before it.
    static let channelQueueLabel = "codes.threading.ptyhost.conversation"

    /// Where a write's completion lands. Shared, because the handler does one subtraction.
    static let completionQueue = DispatchQueue(
        label: "codes.threading.ptyhost.conversation.writes"
    )
}
