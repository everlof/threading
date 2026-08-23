import Darwin
import Dispatch
import Foundation
import ThreadingPTYHostKit

// MARK: - Connection

/// One client of the daemon: a socket, a decoder, and at most one session it is bound to.
///
/// **Binding is the whole of the addressing.** The 8-byte header carries no session id, so a
/// connection is either *unbound* — it may say `hello`, `list`, `spawn`, `attach`, `retire` and
/// `journalTail` — or bound to exactly one session by a successful `spawn` or `attach`, after
/// which raw `output` and `input` frames on it belong to that session and `resize`, `detach` and
/// `kill` must name the bound id. Naming a different one is an `error` and a close: a frame
/// addressed to the wrong session is not a frame to guess about.
///
/// A session may have several bound connections — the app, a test, later the phone's mirror —
/// and output fans out to all of them.
///
/// Confined to the host queue. Every handler is delivered there, so the decoder, the counters and
/// the binding need no lock.
final class PTYHostConnection: @unchecked Sendable {

    // MARK: - Properties

    /// A number for the journal. The descriptor would be reused the moment this one closes, and a
    /// log where two different clients share a name is a log that cannot be read afterwards.
    let number: UInt64

    /// The session this connection speaks for, or nil while it is unbound.
    var boundSession: PTYHostSessionIdentity?

    /// True once `hello` has been exchanged. Anything before it closes the connection: the
    /// version gate is the first thing that happens, so nothing else can happen before it.
    var hasGreeted = false

    /// Bytes handed to the kernel that have not been written yet. The one number backpressure is
    /// decided on.
    private(set) var pendingWriteBytes = 0

    private(set) var isClosed = false

    /// Complete frames, in arrival order.
    var onFrames: (([PTYHostWireFrame]) -> Void)?
    /// The stream stopped being a conversation. The caller closes; nothing else is affected.
    var onRefusal: ((PTYHostFramingRefusal) -> Void)?
    /// The watcher fell far enough behind that keeping it would mean stalling a child.
    var onOverload: (() -> Void)?
    /// The socket ended, however it ended. Delivered exactly once.
    var onClosed: (() -> Void)?

    private let queue: DispatchQueue
    private let descriptor: Int32
    private let io: DispatchIO
    private var decoder = PTYHostFrameDecoder()
    private var isDrainingClose = false

    // MARK: - Initialization

    init(descriptor: Int32, number: UInt64, queue: DispatchQueue) {
        self.number = number
        self.queue = queue
        self.descriptor = descriptor

        // Without this a write to a socket the client has already closed raises `SIGPIPE`. The
        // process-wide ignore covers it too; both are here because either one alone is a
        // one-line change away from being removed by somebody who saw only the other.
        var suppress: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &suppress,
            socklen_t(MemoryLayout<Int32>.size)
        )

        io = DispatchIO(
            type: .stream,
            fileDescriptor: descriptor,
            queue: queue,
            cleanupHandler: { _ in Darwin.close(descriptor) }
        )
        // Deliver whatever has arrived rather than waiting for a buffer to fill: a control frame
        // is a few dozen bytes and the answer to it is what the client is waiting for.
        io.setLimit(lowWater: 1)
    }

    // MARK: - Public Methods

    func start() {
        io.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var bytes = Data()
                bytes.reserveCapacity(data.count)
                data.enumerateBytes { buffer, _, _ in bytes.append(contentsOf: buffer) }
                switch decoder.accept(bytes) {
                case .frames(let frames):
                    if !frames.isEmpty { onFrames?(frames) }
                case .refused(let refusal):
                    onRefusal?(refusal)
                    return
                }
            }
            if done || error != 0 { finish() }
        }
    }

    /// Encodes and queues one control frame.
    func send(_ frame: PTYHostFrame) {
        guard let payload = try? PTYHostConnection.encoder.encode(frame) else { return }
        send(kind: .control, payload: payload)
    }

    /// Queues one raw frame. Output and replay bytes both come through here.
    func send(kind: PTYHostFrameKind, payload: Data) {
        guard !isClosed else { return }
        guard let framed = try? PTYHostFraming.encode(kind: kind, payload: payload) else { return }
        enqueue(framed)
    }

    /// Bytes that are already a frame.
    ///
    /// Output is encoded once and queued to every watcher of a session, so a burst costs one
    /// framing rather than one per watcher — which is what makes fan-out O(watchers) in copies
    /// rather than in encodings.
    func sendFramed(_ framed: Data) {
        guard !isClosed else { return }
        enqueue(framed)
    }

    /// Ends the connection. Idempotent; `onClosed` fires once.
    ///
    /// **A close flushes what is already queued.** Almost every close here follows an `error`
    /// frame explaining it, and a close that discarded the queue would deliver the disconnection
    /// without the reason — which is exactly the state the structural error tokens exist to
    /// avoid. The channel performs its operations in order, so closing after the write means the
    /// write happens first.
    ///
    /// `discardingQueuedWrites` is the one exception, and it is the backpressure path: a watcher
    /// being dropped for being 4 MiB behind is by definition not draining, so waiting for its
    /// queue would be waiting forever.
    func close(discardingQueuedWrites: Bool = false) {
        guard !isClosed else { return }
        isClosed = true
        if discardingQueuedWrites {
            io.close(flags: .stop)
            _ = shutdown(descriptor, SHUT_RDWR)
        } else {
            io.close(flags: [])
            // Ends *our* reading, not the peer's: the channel closes only once its outstanding
            // operations finish, and this connection always has one outstanding read of
            // unbounded length. Without this the daemon would wait for the client to close and
            // the client would wait for the daemon, the descriptor would never be released, and
            // the frame explaining the close would be the last thing the client never learned
            // it had received. The write side stays open, so what is queued still goes out
            // before the channel's cleanup releases the descriptor.
            _ = shutdown(descriptor, SHUT_RD)
            endWhenDrained()
        }
        onClosed?()
    }

    // MARK: - Private Methods

    private static let encoder = JSONEncoder()

    private func enqueue(_ data: Data) {
        pendingWriteBytes += data.count
        if pendingWriteBytes > PTYHostDefaults.maximumPendingWriteBytes {
            onOverload?()
            return
        }

        let submitted = data.count
        let payload = data.withUnsafeBytes { DispatchData(bytes: $0) }
        io.write(offset: 0, data: payload, queue: queue) { [weak self] done, _, _ in
            guard done, let self else { return }
            pendingWriteBytes = max(0, pendingWriteBytes - submitted)
            if isClosed, pendingWriteBytes == 0 { _ = shutdown(descriptor, SHUT_RDWR) }
        }
    }

    /// The bound on waiting for a queued frame to reach the kernel.
    ///
    /// A peer that has stopped reading must not be able to hold a descriptor open by never
    /// draining the last frame it will ever be sent, so the wait ends either way.
    private func endWhenDrained() {
        if pendingWriteBytes <= 0 {
            _ = shutdown(descriptor, SHUT_RDWR)
            return
        }
        guard !isDrainingClose else { return }
        isDrainingClose = true
        queue.asyncAfter(deadline: .now() + PTYHostDefaults.closeFlushTimeout) { [weak self] in
            guard let self else { return }
            _ = shutdown(descriptor, SHUT_RDWR)
        }
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        io.close(flags: [])
        onClosed?()
    }
}
