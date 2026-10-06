#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import ThreadingPTYHostKit
import ThreadingPTYClient

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

    case refused(String)

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
        case .refused(let message): return message
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

/// Shell-facing request/answer adapter over the same transport the Mac uses. The library owns
/// connect, hello, binding, framing and bounded writes. This adapter owns command deadlines and
/// a bounded mailbox; its callbacks never block the transport's serial queue on terminal IO.
final class PTYHostCLIClient {
    enum Event {
        case control(PTYHostFrame)
        case output(Data)
    }

    private let transport: PTYHostClient
    private let mailbox: PTYHostCLIMailbox
    private let socketPath: String
    private(set) var peer: PTYHostHello?

    private init(socketPath: String, build: String, timeout: TimeInterval) {
        self.socketPath = socketPath
        let mailbox = PTYHostCLIMailbox()
        self.mailbox = mailbox
        transport = PTYHostClient(
            socketPath: socketPath, build: build,
            events: .init(
                frame: { mailbox.append(.control($0)) },
                output: { mailbox.append(.output($0)) },
                standardError: { mailbox.append(.output($0)) },
                closed: { mailbox.finish($0) }
            ),
            journal: { _, _ in },
            connectTimeout: timeout,
            helloTimeout: PTYHostCLIDefaults.helloTimeout,
            retiresOlderDaemon: false
        )
    }

    deinit { hangUp() }

    static func connect(
        socketPath: String, build: String,
        timeout: TimeInterval = PTYHostCLIDefaults.connectTimeout
    ) throws -> PTYHostCLIClient {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw PTYHostCLIError.socketMissing(path: socketPath)
        }
        return PTYHostCLIClient(socketPath: socketPath, build: build, timeout: timeout)
    }

    @discardableResult
    func greet() throws -> PTYHostHello {
        if let peer { return peer }
        do {
            let hello = try transport.connect()
            peer = hello
            return hello
        } catch { throw mapped(error) }
    }

    func list() throws -> [PTYHostSessionSummary] {
        try send(.list)
        let frame = try waitForControl(timeout: PTYHostCLIDefaults.answerTimeout, what: "the session list") {
            if case .sessions = $0 { return true }; return false
        }
        guard case .sessions(let sessions) = frame else { throw PTYHostCLIError.connectionClosed }
        return sessions
    }

    func journalTail(maxBytes: Int) throws -> [String] {
        try send(.journalTail(PTYHostJournalTail(maxBytes: maxBytes)))
        let frame = try waitForControl(timeout: PTYHostCLIDefaults.answerTimeout, what: "the journal tail") {
            if case .journal = $0 { return true }; return false
        }
        guard case .journal(let journal) = frame else { throw PTYHostCLIError.connectionClosed }
        return journal.lines
    }

    func attach(
        _ identity: PTYHostSessionIdentity,
        receivesOutput: Bool? = nil
    ) throws -> PTYHostAttached {
        try send(.attach(PTYHostAttach(
            id: identity,
            replayBudget: PTYHostReplayDefaults.minimumBudgetBytes,
            receivesOutput: receivesOutput
        )))
        let frame = try waitForControl(timeout: PTYHostCLIDefaults.answerTimeout, what: "the attach") {
            if case .attached = $0 { return true }; return false
        }
        guard case .attached(let attached) = frame else { throw PTYHostCLIError.connectionClosed }
        return attached
    }

    func stop(_ identity: PTYHostSessionIdentity) throws -> PTYHostExited? {
        // A stop needs the ending, not output that can backpressure its acknowledgement.
        _ = try attach(identity, receivesOutput: false)
        try send(.kill(PTYHostKill(id: identity, escalate: true)))
        let frame = try waitForControl(timeout: PTYHostCLIDefaults.stopTimeout, what: "the ending") {
            if case .exited = $0 { return true }; return false
        }
        guard case .exited(let exited) = frame else { return nil }
        return exited
    }

    func sendInput(_ data: Data) throws {
        do { try transport.sendInput(data) } catch { throw mapped(error) }
    }

    func send(_ frame: PTYHostFrame) throws {
        do { try transport.send(frame) } catch { throw mapped(error) }
    }

    func reportedLoss() -> PTYHostLost? { transport.reportedLoss }
    func hangUp() { transport.close() }

    /// Used when detaching after a final keystroke: enqueueing is not socket delivery.
    func drainInput() throws {
        guard transport.drainWrites(until: Date().addingTimeInterval(PTYHostCLIDefaults.answerTimeout)),
              transport.isReady else {
            throw PTYHostCLIError.answerTimedOut(what: "input delivery")
        }
    }

    func nextEvent(timeout: TimeInterval) throws -> Event? {
        do {
            let event = try mailbox.next(timeout: timeout)
            if case .control(.error(let failure))? = event {
                throw PTYHostCLIError.refused("The background host refused the request: \(failure.code).")
            }
            return event
        } catch { throw mapped(error) }
    }

    private func waitForControl(
        timeout: TimeInterval, what: String, matching: (PTYHostFrame) -> Bool
    ) throws -> PTYHostFrame {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if case .control(let frame)? = try nextEvent(timeout: deadline - ProcessInfo.processInfo.systemUptime),
               matching(frame) { return frame }
        }
        throw PTYHostCLIError.answerTimedOut(what: what)
    }

    private func mapped(_ error: Error) -> PTYHostCLIError {
        if let error = error as? PTYHostCLIError { return error }
        guard let error = error as? PTYHostClientError else { return .connectionClosed }
        switch error {
        case .pathTooLong(let bytes): return .socketPathTooLong(bytes: bytes)
        case .socketUnavailable(let code), .connectFailed(let code): return .connectFailed(path: socketPath, code: code)
        case .connectTimedOut: return .connectFailed(path: socketPath, code: ETIMEDOUT)
        case .handshakeTimedOut: return .handshakeTimedOut
        case .incompatible(let compatibility): return .incompatible(compatibility.updateTarget(evaluatedBy: .app) ?? .app)
        default: return .refused("The background host connection failed (\(error.token)).")
        }
    }
}

/// At most 4 MiB and 4,096 events, including control-frame overhead. Expected bursts are 64 KiB;
/// a stalled terminal under an indefinite output flood fails closed rather than retaining the
/// transcript. Cleared slots release payloads immediately; compaction is amortized per batch.
private final class PTYHostCLIMailbox: @unchecked Sendable {
    private enum Limits {
        static let bytes = 4 * 1024 * 1024
        static let events = 4096
    }
    private let condition = NSCondition()
    private var pending: [(PTYHostCLIClient.Event, Int)?] = []
    private var cursor = 0
    private var bytes = 0
    private var closed = false
    private var failure: Error?

    func append(_ event: PTYHostCLIClient.Event) {
        // Controls are bounded by the wire already; measure their encoded size so large lists
        // cannot each count as one tiny event. Bulk output never passes through JSON.
        let cost: Int
        switch event {
        case .output(let data): cost = data.count + PTYHostFramingDefaults.headerBytes
        case .control(let frame):
            guard let encoded = try? JSONEncoder().encode(frame) else {
                finish(PTYHostCLIError.refused("Cannot measure a host control frame.")); return
            }
            cost = encoded.count + PTYHostFramingDefaults.headerBytes
        }
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return }
        guard bytes + cost <= Limits.bytes, pending.count - cursor < Limits.events else {
            failure = PTYHostCLIError.refused("Terminal output exceeded the controller buffer; reconnect to the running agent.")
            closed = true
            pending.removeAll()
            cursor = 0
            bytes = 0
            condition.broadcast()
            return
        }
        if pending.count == Limits.events {
            pending.removeFirst(cursor)
            cursor = 0
        }
        pending.append((event, cost))
        bytes += cost
        condition.signal()
    }

    func finish(_ error: Error?) {
        condition.lock()
        defer { condition.unlock() }
        if !closed { closed = true; failure = error }
        condition.broadcast()
    }

    func next(timeout: TimeInterval) throws -> PTYHostCLIClient.Event? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while cursor == pending.count && !closed {
            guard condition.wait(until: deadline) else { return nil }
        }
        if cursor < pending.count, let (event, cost) = pending[cursor] {
            pending[cursor] = nil
            cursor += 1
            bytes -= cost
            if cursor == pending.count { pending.removeAll(keepingCapacity: true); cursor = 0 }
            return event
        }
        throw failure ?? PTYHostCLIError.connectionClosed
    }
}
