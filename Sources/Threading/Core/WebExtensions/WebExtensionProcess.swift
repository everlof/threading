import Foundation
import Darwin

/// One serialized helper transport. Neither pipe reads nor JSON/file work runs on the main actor.
/// Cancellation wakes the polling read within 100 ms; process teardown has a separate deadline.
final class WebExtensionProcess: @unchecked Sendable {
    struct Configuration: Sendable {
        let python: URL
        let script: URL
        let state: URL

        static func bundled(sessionID: SessionID) -> Self {
            let environment = ProcessInfo.processInfo.environment
            let python = [environment["THREADING_WEBEXT_PYTHON"], environment["THREADING_PLAYWRIGHT_PYTHON"]]
                .compactMap { $0 }.first { !$0.isEmpty && !$0.hasPrefix("$(") } ?? "/opt/homebrew/bin/python3"
            let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
            return Self(python: URL(fileURLWithPath: python),
                        script: resources.appendingPathComponent("WebExtensions/workbench.py"),
                        state: FileManager.default.temporaryDirectory
                            .appendingPathComponent("threading-webextensions-\(sessionID)")
                            .appendingPathComponent(UUID().uuidString))
        }
    }

    private let configuration: Configuration
    private let project: URL
    private let queue = DispatchQueue(label: "codes.threading.webextension.worker", qos: .utility)
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private static let maximumResponseBytes = 4 * 1_024 * 1_024
    private static let operationTimeout: TimeInterval = 180

    init(project: URL, configuration: Configuration) {
        self.project = project
        self.configuration = configuration
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func call(_ request: WebExtensionRequest) async -> WebExtensionReply {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    guard !isCancelled else { throw Failure("This development session has ended.") }
                    if process == nil { try launch() }
                    var data = try JSONEncoder().encode(request)
                    data.append(10)
                    guard data.count <= 65_536 else { throw Failure("Development request exceeds 64 KiB.") }
                    try writeRequest(data)
                    let reply = try readReply(timeout: request.action == .setup ? 360 : Self.operationTimeout)
                    let envelope = try JSONDecoder().decode(Envelope.self, from: reply)
                    guard envelope.ok, let payload = envelope.result else {
                        continuation.resume(returning: .failure(envelope.error ?? "Invalid development worker reply."))
                        return
                    }
                    let object = try JSONSerialization.jsonObject(with: reply)
                    let formatted = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                    continuation.resume(returning: .success(payload, text: String(decoding: formatted, as: UTF8.self)))
                } catch {
                    stop()
                    continuation.resume(returning: .failure(error.localizedDescription))
                }
            }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        queue.async { [self] in stop() }
    }

    private func launch() throws {
        guard FileManager.default.isExecutableFile(atPath: configuration.python.path) else {
            throw Failure("Python 3 is required. Install Python, or set THREADING_WEBEXT_PYTHON to its executable.")
        }
        guard FileManager.default.fileExists(atPath: configuration.script.path) else {
            throw Failure("The bundled WebExtension development worker is missing.")
        }
        try FileManager.default.createDirectory(at: configuration.state, withIntermediateDirectories: true)
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        child.executableURL = configuration.python
        child.arguments = ["-u", configuration.script.path, project.path, configuration.state.path]
        child.currentDirectoryURL = project
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        try stdin.fileHandleForReading.close()
        try stdout.fileHandleForWriting.close()
        for handle in [input, output].compactMap({ $0 }) {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw Failure("Could not configure development worker pipes.")
            }
        }
        guard let input, fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw Failure("Could not protect the development worker pipe.")
        }
    }

    private func writeRequest(_ data: Data) throws {
        guard let input else { throw Failure("Development worker disconnected.") }
        let deadline = Date().addingTimeInterval(5)
        var offset = 0
        while offset < data.count, Date() < deadline, !isCancelled {
            var descriptor = pollfd(fd: input.fileDescriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw Failure("Could not write to the development worker.") }
            guard ready > 0 else { continue }
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(input.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { throw Failure("Development worker stopped accepting commands.") }
            offset += count
        }
        guard offset == data.count else { throw Failure("Development command cancelled or timed out.") }
    }

    private func readReply(timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !isCancelled {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            guard let output else { throw Failure("Development worker disconnected.") }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw Failure("Could not read the development worker.") }
            guard ready > 0 else { continue }
            // FileHandle.read(upToCount:) can keep filling a live pipe until that byte count
            // or EOF. A single nonblocking POSIX read lets a short NDJSON reply complete.
            var chunk = Data(count: 65_536)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { throw Failure("Development worker exited. Restart the target to reconnect.") }
            chunk.count = count
            guard buffer.count + chunk.count <= Self.maximumResponseBytes else {
                throw Failure("Development worker response exceeded its 4 MiB limit.")
            }
            buffer.append(chunk)
        }
        throw Failure(isCancelled ? "Development session cancelled." : "Development operation timed out.")
    }

    private func stop() {
        try? input?.close()
        input = nil
        if let process {
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { process.terminate() }
            let killDeadline = Date().addingTimeInterval(15)
            while process.isRunning, Date() < killDeadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning {
                let pid = process.processIdentifier
                if getpgid(pid) == pid { kill(-pid, SIGKILL) }
                else { kill(pid, SIGKILL) }
            }
        }
        try? output?.close()
        output = nil
        process = nil
        buffer.removeAll(keepingCapacity: false)
    }

    private struct Envelope: Decodable {
        let ok: Bool
        let result: WebExtensionPayload?
        let error: String?
    }
    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
