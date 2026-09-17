#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import ThreadingPTYHostKit

// MARK: - Errors

/// Why a command-line invocation could not reach the daemon, or could not be believed once it
/// had.
///
/// Typed rather than a string thrown from wherever it happened, because two callers act on the
/// same failure differently: `status` reports "nothing is listening" as an ordinary finding and
/// prints the rest of what it knows, while `stop` reports it as a refusal and stops. A sentence
/// cannot be branched on.
///
/// Each case carries a one-sentence `sentence` for standard error. Sentences rather than tokens
/// here — unlike the wire and the journal, which carry tokens because they reach a support
/// report — because the reader is a person at a shell prompt.
enum PTYHostCLIError: Error, Equatable {

    /// The default rendezvous could not be derived, so there is nothing to connect to.
    case noDefaultLocation

    /// The rendezvous path does not fit `sockaddr_un.sun_path`.
    case socketPathTooLong(bytes: Int)

    /// No socket file at the path. Reported separately from a refused connect because they mean
    /// different things: nothing has ever bound this path, versus something left a file behind.
    case socketMissing(path: String)

    /// The kernel refused the connect, or nobody accepted inside the deadline.
    case connectFailed(path: String, code: Int32)

    /// The daemon accepted the connection and never answered the greeting.
    case handshakeTimedOut

    /// A daemon answered and the version gate refused it. The client never sends `retire` over
    /// this: retiring is the app's upgrade policy and ends somebody's working agents.
    case incompatible(PTYHostUpdateTarget)

    /// The daemon hung up while an answer was outstanding.
    case connectionClosed

    /// A frame that should have come back did not, inside its bound.
    case answerTimedOut(what: String)

    var sentence: String {
        switch self {
        case .noDefaultLocation:
            return "Cannot work out where the background host keeps its socket."
        case .socketPathTooLong(let bytes):
            return "The socket path is \(bytes) bytes, which is too long for a unix socket."
        case .socketMissing(let path):
            return "No socket at \(path), so no background host is listening."
        case .connectFailed(let path, let code):
            return "Cannot connect to \(path): \(String(cString: strerror(code)))."
        case .handshakeTimedOut:
            return "The background host accepted the connection and did not answer the greeting."
        case .incompatible(let target):
            switch target {
            case .app:
                return "The running background host speaks a newer protocol than this tool."
            case .daemon:
                return "The running background host speaks an older protocol than this tool."
            }
        case .connectionClosed:
            return "The background host hung up before answering."
        case .answerTimedOut(let what):
            return "The background host did not answer \(what) in time."
        }
    }
}

// MARK: - Client

/// One connection to `threading-ptyd`, for a person at a shell prompt.
///
/// **Blocking, on this thread, with one reader thread behind it.** A command-line invocation is a
/// straight line — connect, greet, ask, print, exit — so the client that serves it says "wait
/// until this frame arrives" directly rather than through a delivery queue. That is the shape
/// `PTYHostTestClient` already has, and for the same reason; the app's `PTYHostClient` is
/// asynchronous because a terminal's output rate has to stay off the main queue, and none of that
/// applies here.
///
/// Every wait is bounded. Nothing here retires a daemon, and nothing here spawns one: the CLI
/// observes and, at most, ends one child it was told to end.
final class PTYHostCLIClient: @unchecked Sendable {

    // MARK: - Properties

    private let descriptor: Int32
    private let build: String
    private let condition = NSCondition()
    private var decoder = PTYHostFrameDecoder()
    private var controls: [PTYHostFrame] = []
    private var closed = false

    private static let encoder = JSONEncoder()
    private static let jsonDecoder = JSONDecoder()

    /// What the daemon said about itself. Nil until the greeting has been answered.
    private(set) var peer: PTYHostHello?

    // MARK: - Initialization

    private init(descriptor: Int32, build: String) {
        self.descriptor = descriptor
        self.build = build
        Thread.detachNewThread { [self] in read() }
    }

    deinit {
        hangUp()
    }

    /// Connects to a rendezvous, with a deadline.
    ///
    /// The socket is put in non-blocking mode for the connect so a listener that has stopped
    /// accepting costs this process a bounded wait rather than an indefinite one, and put back
    /// afterwards because everything above this is written as blocking reads and writes.
    ///
    /// `SO_NOSIGPIPE` before anything else: a write to a socket the daemon has already closed
    /// would otherwise raise `SIGPIPE` and kill the tool mid-sentence. The process-wide
    /// `SIG_IGN` in `main()` covers it too; both are here because either one alone is a line's
    /// edit away from being removed by somebody who saw only the other.
    static func connect(
        socketPath: String,
        build: String,
        timeout: TimeInterval = PTYHostCLIDefaults.connectTimeout
    ) throws -> PTYHostCLIClient {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw PTYHostCLIError.socketMissing(path: socketPath)
        }

        guard let address = PTYHostPOSIX.unixAddress(path: socketPath) else {
            throw PTYHostCLIError.socketPathTooLong(bytes: socketPath.utf8.count)
        }

        let handle = socket(AF_UNIX, PTYHostPOSIX.streamSocketType, 0)
        guard handle >= 0 else {
            throw PTYHostCLIError.connectFailed(path: socketPath, code: errno)
        }
        PTYHostPOSIX.suppressBrokenPipeSignal(on: handle)

        let flags = fcntl(handle, F_GETFL, 0)
        _ = fcntl(handle, F_SETFL, flags | O_NONBLOCK)

        let started = PTYHostPOSIX.connect(handle, address)
        if started != 0 {
            guard errno == EINPROGRESS else {
                let code = errno
                PTYHostPOSIX.close(handle)
                throw PTYHostCLIError.connectFailed(path: socketPath, code: code)
            }
            var poller = pollfd(fd: handle, events: Int16(POLLOUT), revents: 0)
            let milliseconds = Int32(max(timeout, 0) * 1000)
            guard poll(&poller, 1, milliseconds) > 0 else {
                PTYHostPOSIX.close(handle)
                throw PTYHostCLIError.connectFailed(path: socketPath, code: ETIMEDOUT)
            }
            var pending: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(handle, SOL_SOCKET, SO_ERROR, &pending, &size)
            guard pending == 0 else {
                PTYHostPOSIX.close(handle)
                throw PTYHostCLIError.connectFailed(path: socketPath, code: pending)
            }
        }
        _ = fcntl(handle, F_SETFL, flags)

        return PTYHostCLIClient(descriptor: handle, build: build)
    }

    // MARK: - Public Methods

    /// Speaks first, and refuses a daemon the version gate will not admit.
    ///
    /// `hello` is the first frame on every connection in both directions, so nothing else may be
    /// asked before this returns. A refusal is reported and never repaired: this tool does not
    /// send `retire`, because retiring a daemon is the app's upgrade policy and the sessions it
    /// is holding are somebody's working agents.
    @discardableResult
    func greet() throws -> PTYHostHello {
        try send(.hello(PTYHostHello(build: build, pid: getpid())))
        let frame = try waitForControl(
            timeout: PTYHostCLIDefaults.helloTimeout,
            what: "the greeting"
        ) {
            if case .hello = $0 { return true }
            if case .helloRefused = $0 { return true }
            return false
        }
        switch frame {
        case .hello(let hello):
            let compatibility = PTYHostCompatibility.evaluate(peer: hello)
            guard compatibility == .compatible else {
                throw PTYHostCLIError.incompatible(
                    compatibility.updateTarget(evaluatedBy: .app) ?? .app
                )
            }
            peer = hello
            return hello
        case .helloRefused(let refusal):
            throw PTYHostCLIError.incompatible(refusal.update)
        default:
            throw PTYHostCLIError.handshakeTimedOut
        }
    }

    /// What the daemon is holding.
    func list() throws -> [PTYHostSessionSummary] {
        try send(.list)
        let frame = try waitForControl(
            timeout: PTYHostCLIDefaults.answerTimeout,
            what: "the session list"
        ) {
            if case .sessions = $0 { return true }
            return false
        }
        guard case .sessions(let summaries) = frame else {
            throw PTYHostCLIError.answerTimedOut(what: "the session list")
        }
        return summaries
    }

    /// A bounded tail of the daemon's own journal. The daemon caps the answer again on its side.
    func journalTail(maxBytes: Int) throws -> [String] {
        try send(.journalTail(PTYHostJournalTail(maxBytes: maxBytes)))
        let frame = try waitForControl(
            timeout: PTYHostCLIDefaults.answerTimeout,
            what: "the journal tail"
        ) {
            if case .journal = $0 { return true }
            return false
        }
        guard case .journal(let journal) = frame else {
            throw PTYHostCLIError.answerTimedOut(what: "the journal tail")
        }
        return journal.lines
    }

    /// Ends one child, the way the app's Background Sessions list ends one.
    ///
    /// **Attach, then kill.** `kill` names a session and the daemon only accepts a frame naming
    /// the session this connection is *bound* to, so a watcher that wants to end a child it is
    /// not watching has to become its watcher first. The replay that costs is bound to the floor:
    /// something about to end a child has no use for its history, and the daemon clamps anything
    /// smaller up to that anyway.
    ///
    /// Answers true when the ending arrived inside the bound. False is "it did not say so",
    /// which is not the same as "it is still running" — that is why the caller reports the
    /// difference rather than asserting the child is alive.
    func stop(_ identity: PTYHostSessionIdentity) throws -> PTYHostExited? {
        try send(.attach(PTYHostAttach(
            id: identity,
            replayBudget: PTYHostReplayDefaults.minimumBudgetBytes
        )))
        let answer = try waitForControl(
            timeout: PTYHostCLIDefaults.answerTimeout,
            what: "the attach"
        ) {
            switch $0 {
            case .attached, .exited, .error: return true
            default: return false
            }
        }
        if case .exited(let ending) = answer { return ending }
        if case .error = answer { return nil }

        try send(.kill(PTYHostKill(id: identity, escalate: true)))
        let ending = try waitForControl(
            timeout: PTYHostCLIDefaults.stopTimeout,
            what: "the ending"
        ) {
            if case .exited = $0 { return true }
            return false
        }
        guard case .exited(let body) = ending else { return nil }
        return body
    }

    /// The `lost` set the daemon pushes after every `hello`, or nil when it pushed none.
    ///
    /// Read after a later answer rather than waited for: the frame is queued immediately behind
    /// the greeting and stream delivery is ordered, so anything that came back after it has
    /// already proved whether it was sent.
    func reportedLoss() -> PTYHostLost? {
        condition.lock()
        defer { condition.unlock() }
        for frame in controls {
            if case .lost(let lost) = frame { return lost }
        }
        return nil
    }

    func hangUp() {
        condition.lock()
        let alreadyClosed = closed
        closed = true
        condition.broadcast()
        condition.unlock()
        guard !alreadyClosed else { return }
        PTYHostPOSIX.shutdown(descriptor, .readWrite)
    }

    // MARK: - Private Methods

    private func send(_ frame: PTYHostFrame) throws {
        guard let payload = try? Self.encoder.encode(frame),
              let framed = try? PTYHostFraming.encode(kind: .control, payload: payload) else {
            throw PTYHostCLIError.connectionClosed
        }
        write(framed)
    }

    private func waitForControl(
        timeout: TimeInterval,
        what: String,
        matching: (PTYHostFrame) -> Bool
    ) throws -> PTYHostFrame {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let index = controls.firstIndex(where: matching) {
                return controls.remove(at: index)
            }
            if closed { throw PTYHostCLIError.connectionClosed }
            guard condition.wait(until: deadline) else {
                throw PTYHostCLIError.answerTimedOut(what: what)
            }
        }
    }

    /// The reader thread. Raw `output` frames are decoded and dropped: the only thing that
    /// streams bytes at this tool is the replay a stop-only attach asks for, and nothing here
    /// renders a terminal.
    private func read() {
        var buffer = [UInt8](repeating: 0, count: PTYHostCLIDefaults.readBufferBytes)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                PTYHostPOSIX.read(descriptor, $0.baseAddress, $0.count)
            }
            guard count > 0 else {
                condition.lock()
                closed = true
                condition.broadcast()
                condition.unlock()
                PTYHostPOSIX.close(descriptor)
                return
            }
            let incoming = Data(buffer[0..<count])
            condition.lock()
            switch decoder.accept(incoming) {
            case .frames(let frames):
                for frame in frames where frame.kind == .control {
                    if let control = try? Self.jsonDecoder.decode(
                        PTYHostFrame.self,
                        from: frame.payload
                    ) {
                        controls.append(control)
                    }
                }
            case .refused:
                closed = true
            }
            condition.broadcast()
            condition.unlock()
        }
    }

    private func write(_ data: Data) {
        PTYHostPOSIX.writeAll(descriptor, data)
    }
}
