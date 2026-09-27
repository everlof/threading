import Darwin
import Foundation
import ThreadingRemoteKit

// MARK: - Defaults

enum SecretApprovalLocalDefaults {
    /// Owner-only, like the MCP bridge: the directory is the boundary, the socket's own mode is
    /// defence in depth.
    static let directoryName = "approvals"
    static let directoryPermissions = 0o700
    static let socketFileName = "approvals.sock"
    static let socketPermissions: mode_t = 0o600
    static let maximumSocketPathBytes = 103
    static let backlog: Int32 = 8
    /// One line of JSON. An envelope, a title and a dozen lines fit many times over.
    static let maximumRequestBytes = 32 * 1024
    /// A client has this long to send its one line; the wait for the phone is not bounded here.
    static let receiveTimeoutSeconds = 5
    static let requesterDepth = 5
    static let queueLabel = "codes.threading.secret-approval.local"
}

// MARK: - Wire

/// What a local client (keyvault) sends: one JSON object on one line.
struct SecretApprovalLocalRequest: Decodable, Sendable {
    enum Operation: String, Decodable, Sendable { case status, wrap, unwrap }
    let op: Operation
    let secret: Data?
    let client: String?
    let title: String?
    let lines: [String]?
    let envelope: RemoteSecretApproval.Envelope?
}

/// One JSON object on one line back, then the connection closes.
struct SecretApprovalLocalResponse: Encodable, Sendable {
    var ok: Bool
    var error: String?
    var enabled: Bool?
    var enrolled: Bool?
    var fingerprint: String?
    var envelope: RemoteSecretApproval.Envelope?
    var secret: Data?

    static func failure(_ error: Error) -> Self {
        let name: String
        switch error as? SecretApprovalBroker.Failure {
        case .disabled?: name = "disabled"
        case .notEnrolled?: name = "not-enrolled"
        case .busy?: name = "busy"
        case .expired?: name = "expired"
        case .denied?: name = "denied"
        case .wrongDevice?: name = "wrong-device"
        case .malformed?: name = "malformed"
        default: name = "refused"
        }
        return .init(ok: false, error: name)
    }
}

// MARK: - Server

/// A unix socket for local clients of `SecretApprovalBroker`, in a `0700` directory beside the
/// MCP bridge's.
///
/// Plain BSD sockets rather than `NWListener` for one reason: the kernel's `LOCAL_PEERPID` tells
/// the broker which process is asking, and that chain — not anything the client claims — is what
/// the phone shows under "requested by". Same-user processes can all connect; the person deciding
/// on the phone is the boundary, as the Touch ID prompt is for keyvault today, but with the
/// request and its requester in front of them.
final class SecretApprovalLocalServer: @unchecked Sendable {
    /// `errno` exactly as the call left it: no guessing which POSIX case it was meant to be.
    enum Failure: Error, Equatable { case pathTooLong, socket(errno: Int32) }

    // MARK: Properties

    static var directory: URL {
        (StateManager.isHostedTest ? StateManager.hostedTestDirectory() : AppDataLocations.supportDirectory)
            .appendingPathComponent(SecretApprovalLocalDefaults.directoryName, isDirectory: true)
    }

    static var socketPath: String {
        directory.appendingPathComponent(SecretApprovalLocalDefaults.socketFileName).path
    }

    private let path: String
    private let broker: SecretApprovalBroker
    private let queue = DispatchQueue(label: SecretApprovalLocalDefaults.queueLabel)
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    // MARK: Initialization

    init(path: String = SecretApprovalLocalServer.socketPath, broker: SecretApprovalBroker = .shared) {
        self.path = path
        self.broker = broker
    }

    deinit { stop() }

    // MARK: Public Methods

    var isRunning: Bool { lock.withLock { descriptor >= 0 } }

    func start() throws {
        guard !isRunning else { return }
        guard path.utf8.count <= SecretApprovalLocalDefaults.maximumSocketPathBytes else {
            throw Failure.pathTooLong
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: SecretApprovalLocalDefaults.directoryPermissions])
        try FileManager.default.setAttributes(
            [.posixPermissions: SecretApprovalLocalDefaults.directoryPermissions], ofItemAtPath: directory.path)

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure.socket(errno: errno) }
        unlink(path)     // a socket file left by a previous run of this app
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, SecretApprovalLocalDefaults.socketPermissions) == 0,
              listen(listener, SecretApprovalLocalDefaults.backlog) == 0 else {
            let failure = Failure.socket(errno: errno)
            close(listener)
            throw failure
        }
        let readable = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        readable.setEventHandler { [weak self] in self?.acceptOne(listener) }
        readable.setCancelHandler { close(listener) }
        lock.withLock {
            descriptor = listener
            source = readable
        }
        readable.resume()
    }

    func stop() {
        let readable: DispatchSourceRead? = lock.withLock {
            defer {
                source = nil
                descriptor = -1
            }
            return source
        }
        guard let readable else { return }
        readable.cancel()
        unlink(path)
    }

    // MARK: Private Methods

    private func acceptOne(_ listener: Int32) {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        var timeout = timeval(tv_sec: SecretApprovalLocalDefaults.receiveTimeoutSeconds, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let requester = Self.requester(of: client)
        // Reading and the wait for a person happen off the accept queue.
        DispatchQueue.global(qos: .userInitiated).async { [broker] in
            guard let line = Self.readLine(client) else {
                Self.reply(.init(ok: false, error: "malformed"), to: client)
                return
            }
            Task {
                let response = await Self.respond(to: line, requester: requester, broker: broker)
                Self.reply(response, to: client)
            }
        }
    }

    static func respond(to line: Data, requester: String, broker: SecretApprovalBroker) async -> SecretApprovalLocalResponse {
        guard let request = try? JSONDecoder().decode(SecretApprovalLocalRequest.self, from: line) else {
            return .init(ok: false, error: "malformed")
        }
        do {
            switch request.op {
            case .status:
                let status = await broker.status()
                return .init(ok: true, enabled: status.enabled, enrolled: status.enrollment != nil,
                             fingerprint: status.enrollment?.fingerprint)
            case .wrap:
                guard let secret = request.secret else { return .init(ok: false, error: "malformed") }
                return .init(ok: true, envelope: try await broker.wrap(secret))
            case .unwrap:
                guard let client = request.client, let title = request.title,
                      let envelope = request.envelope else { return .init(ok: false, error: "malformed") }
                let secret = try await broker.unwrap(client: client, title: title, lines: request.lines ?? [],
                                                     requester: requester, envelope: envelope)
                return .init(ok: true, secret: secret)
            }
        } catch {
            return .failure(error)
        }
    }

    private static func readLine(_ client: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count <= SecretApprovalLocalDefaults.maximumRequestBytes {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { return nil }
            if let newline = chunk[0..<count].firstIndex(of: UInt8(ascii: "\n")) {
                buffer.append(contentsOf: chunk[0..<newline])
                return buffer
            }
            buffer.append(contentsOf: chunk[0..<count])
        }
        return nil
    }

    private static func reply(_ response: SecretApprovalLocalResponse, to client: Int32) {
        defer { close(client) }
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(client, bytes.baseAddress! + offset, bytes.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    /// `nc<keyvault<claude<zsh`: the connecting process and its ancestors, named by what they run
    /// (a script's name rather than `bash`), as the kernel reports them.
    static func requester(of client: Int32) -> String {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return "?" }
        return requester(startingAt: pid)
    }

    static func requester(startingAt pid: pid_t) -> String {
        var names: [String] = []
        var current = pid
        while names.count < SecretApprovalLocalDefaults.requesterDepth, current > 1,
              let details = ProcessUtility.getProcessInfo(forPid: current) {
            names.append(displayName(pid: current, fallback: details.command))
            current = details.parentPid
        }
        let chain = names.isEmpty ? "?" : names.joined(separator: "<")
        return String(decoding: chain.utf8.prefix(RemoteSecretApproval.maximumRequesterBytes), as: UTF8.self)
    }

    private static let interpreters: Set<String> = ["bash", "sh", "zsh", "env", "python3", "perl"]

    private static func displayName(pid: pid_t, fallback: String) -> String {
        guard let arguments = ProcessUtility.commandLine(forPid: pid)?.arguments, let first = arguments.first else {
            return fallback
        }
        let program = (first as NSString).lastPathComponent
        if interpreters.contains(program.hasPrefix("-") ? String(program.dropFirst()) : program),
           let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            return (script as NSString).lastPathComponent
        }
        return program.isEmpty ? fallback : program
    }
}
