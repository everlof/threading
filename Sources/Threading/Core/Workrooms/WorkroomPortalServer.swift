import Foundation
import Network
import ThreadingController
import ThreadingWorkroomPortal

// MARK: - Workroom Portal Server

/// The loopback socket a tunnel publishes. It serves only `WorkroomPortal`, whose routes are
/// participant routes: it shares no router, port or handler with `MCPServer` or
/// `RemoteAccessServer`, so publishing it publishes nothing else of this Mac.
///
/// One request per connection, answered and closed. Headers must arrive within
/// `WorkroomPortalDefaults.headerDeadline`, the head is capped at `maximumHeaderBytes` and the
/// body at `WorkroomPortal.maximumBodyBytes`, and at most `maximumConnections` are open at once.
@MainActor
final class WorkroomPortalServer {

    private(set) var port: UInt16?
    private var listener: NWListener?
    private let portal: WorkroomPortal
    private let queue = DispatchQueue(label: "codes.threading.workroom-portal")
    private let gate = WorkroomConnectionGate(limit: WorkroomPortalDefaults.maximumConnections)
    private var startCompletion: (@MainActor (UInt16?) -> Void)?

    init(portal: WorkroomPortal) {
        self.portal = portal
    }

    /// Calls back once with the bound port, or nil when the listener could not start.
    func start(completion: @escaping @MainActor (UInt16?) -> Void) {
        guard listener == nil else { return completion(port) }
        let parameters = NWParameters.tcp
        // Loopback only: the tunnel connects out and forwards here; the network never reaches it.
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(WorkroomPortalDefaults.host), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch {
            ThreadingLogger.mcp.error("Workroom portal listener failed: \(error.localizedDescription, privacy: .private(mask: .hash))")
            return completion(nil)
        }
        self.listener = listener
        startCompletion = completion
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue
                    self.reportStart(self.port)
                case .failed, .cancelled:
                    self.port = nil
                    self.reportStart(nil)
                default:
                    break
                }
            }
        }
        let portal = self.portal
        let gate = self.gate
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            guard gate.enter() else { connection.cancel(); return }
            WorkroomPortalConnection(connection: connection, portal: portal, queue: queue) { gate.leave() }.start()
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        reportStart(nil)
    }

    private func reportStart(_ port: UInt16?) {
        guard let completion = startCompletion else { return }
        startCompletion = nil
        completion(port)
    }
}

/// Counts open connections across the listener's callbacks.
final class WorkroomConnectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = 0
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func enter() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard open < limit else { return false }
        open += 1
        return true
    }

    func leave() {
        lock.lock(); open = max(0, open - 1); lock.unlock()
    }
}

/// One request, read on the server's queue, answered by the portal actor, then closed.
final class WorkroomPortalConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let portal: WorkroomPortal
    private let queue: DispatchQueue
    private let onClose: @Sendable () -> Void
    private var buffer = Data()
    private var finished = false
    private var deadline: DispatchWorkItem?

    init(connection: NWConnection, portal: WorkroomPortal, queue: DispatchQueue, onClose: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.portal = portal
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        let deadline = DispatchWorkItem { [self] in close() }
        self.deadline = deadline
        queue.asyncAfter(deadline: .now() + WorkroomPortalDefaults.headerDeadline, execute: deadline)
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, isComplete, error in
            guard !finished else { return }
            if let data { buffer.append(data) }
            guard buffer.count <= WorkroomPortalDefaults.maximumHeaderBytes + WorkroomPortal.maximumBodyBytes else {
                return reply(status: 413)
            }
            switch MCPConnection.parseRequest(from: buffer, maximumBodyBytes: WorkroomPortal.maximumBodyBytes) {
            case .incomplete:
                if buffer.range(of: Data("\r\n\r\n".utf8)) == nil, buffer.count > WorkroomPortalDefaults.maximumHeaderBytes {
                    return reply(status: 431)
                }
                if isComplete || error != nil { return close() }
                receive()
            case .malformed(let status, _):
                reply(status: status)
            case .request(let request, _):
                deadline?.cancel()
                guard !Self.repeatsGuardedHeader(buffer) else { return reply(status: 400) }
                let portalRequest = PortalRequest(method: request.method, target: request.path,
                                                  headers: request.headers, body: request.body)
                let portal = self.portal
                Task {
                    let response = await portal.handle(portalRequest)
                    self.queue.async { self.send(response) }
                }
            }
        }
    }

    /// The shared parser keeps the last of repeated headers; for these a repeat is an attempt to
    /// make a proxy and this origin disagree, so the request is refused instead.
    static func repeatsGuardedHeader(_ buffer: Data) -> Bool {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var seen = Set<String>()
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard WorkroomPortalDefaults.singleHeaders.contains(name) else { continue }
            guard seen.insert(name).inserted else { return true }
        }
        return false
    }

    private func reply(status: Int) {
        send(PortalResponse(status: status, headers: [PortalHeader("Content-Type", "text/plain; charset=utf-8"),
                                                      PortalHeader("Cache-Control", "no-store")], body: Data()))
    }

    private func send(_ response: PortalResponse) {
        guard !finished else { return }
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for header in response.headers where !header.value.contains(where: { $0 == "\r" || $0 == "\n" }) {
            head += "\(header.name): \(header.value)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { [self] _ in close() })
    }

    private func close() {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        connection.cancel()
        onClose()
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 303: return "See Other"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 421: return "Misdirected Request"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 501: return "Not Implemented"
        default: return status >= 500 ? "Service Unavailable" : "Error"
        }
    }
}

enum WorkroomPortalDefaults {
    static let host = "127.0.0.1"
    static let headerDeadline: TimeInterval = 10
    static let maximumHeaderBytes = 16 * 1024
    static let maximumConnections = 32
    /// Headers whose repetition is refused rather than resolved.
    static let singleHeaders: Set<String> = ["host", "origin", "cookie", "content-type", "content-length"]
}
