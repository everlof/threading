import Foundation
import Darwin

/// Finds the interpreter for the bundled worker. It checks files and may resolve the login
/// shell's PATH, so it runs on the worker queue, never on the main actor.
enum WebExtensionPythonLocator {
    static let overrideKeys = ["THREADING_WEBEXT_PYTHON", "THREADING_PLAYWRIGHT_PYTHON"]
    /// Stable installations come first: a version manager's shim on PATH can choose a different
    /// Python per checkout. `/usr/bin/python3` is last because, without the Command Line Tools,
    /// it is only the stub that offers to install them.
    static let preferred = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
    static let system = "/usr/bin/python3"

    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        loginPath: String?,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        candidates(environment: environment, loginPath: loginPath)
            .first(where: isExecutable)
            .map(URL.init(fileURLWithPath:))
    }

    /// An unexpanded test-plan placeholder such as `$(THREADING_WEBEXT_PYTHON)` is not a path.
    static func candidates(environment: [String: String], loginPath: String?) -> [String] {
        let overrides = overrideKeys.compactMap { environment[$0] }.filter { $0.hasPrefix("/") }
        let searched = (loginPath ?? environment[EnvironmentKeys.path] ?? "")
            .split(separator: ":")
            .filter { $0.hasPrefix("/") }
            .map { "\($0)/python3" }
        var seen = Set<String>()
        return (overrides + preferred + searched + [system]).filter { seen.insert($0).inserted }
    }
}

/// One serialized helper transport. Neither pipe reads nor JSON/file work runs on the main actor.
/// Cancellation wakes the polling read within 100 ms; process teardown has a separate deadline.
final class WebExtensionProcess: @unchecked Sendable {
    struct Configuration: Sendable {
        /// `nil` locates an interpreter when the worker launches, off the main actor.
        let python: URL?
        let script: URL
        /// This worker generation's own directory: profiles, development copies, screenshots.
        /// It is removed when the worker stops. Its parent is shared by the chat's generations.
        let state: URL

        static func bundled(sessionID: SessionID) -> Self {
            let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
            return Self(python: nil,
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
    private var python: URL?
    private var hasReplied = false
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    init(project: URL, configuration: Configuration) {
        self.project = project
        self.configuration = configuration
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func call(_ request: WebExtensionRequest) async -> WebExtensionReply {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: perform(request)) }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        queue.async { [self] in stop() }
    }

    /// Only a transport failure ends the helper. A refusal, an oversized request or a reply this
    /// build cannot decode leaves the one-line-per-reply protocol in step, so the live browsers
    /// keep running.
    private func perform(_ request: WebExtensionRequest) -> WebExtensionReply {
        guard !isCancelled else { return .failure("This development session has ended.") }
        guard var data = try? JSONEncoder().encode(request) else {
            return .failure("The development request could not be encoded.")
        }
        data.append(10)
        guard data.count <= WebExtensionDefaults.maximumRequestBytes else {
            return .failure("Development request exceeds \(WebExtensionDefaults.maximumRequestBytes / 1_024) KiB.")
        }
        let reply: Data
        do {
            if process == nil { try launch() }
            try writeRequest(data)
            reply = try readReply(timeout: WebExtensionDefaults.timeout(for: request.action))
        } catch {
            stop()
            return .failure(error.localizedDescription)
        }
        hasReplied = true
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: reply)
        } catch {
            return .failure("The development worker's reply could not be read: \(error.localizedDescription)")
        }
        guard envelope.ok else {
            let message = envelope.error.flatMap { $0.isEmpty ? nil : $0 }
            return .failure(message ?? "The development operation failed without a message.")
        }
        guard let payload = envelope.result,
              let object = try? JSONSerialization.jsonObject(with: reply),
              let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure("Invalid development worker reply.")
        }
        return .success(payload, text: String(decoding: formatted, as: UTF8.self))
    }

    private func launch() throws {
        // A Finder-launched app has launchd's PATH. The login shell's PATH is what finds the
        // project's npm, web-ext and adb, exactly as they resolve in the user's terminal.
        let loginPath = GitChildEnvironment.loginShellPath()
        guard let python = configuration.python ?? WebExtensionPythonLocator.locate(loginPath: loginPath) else {
            throw Failure("""
                Python 3 was not found in /opt/homebrew/bin, /usr/local/bin, your login shell's PATH \
                or /usr/bin. Install Python 3.9 or later, then try again.
                """)
        }
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw Failure("\(python.path) is not an executable Python 3.")
        }
        guard FileManager.default.fileExists(atPath: configuration.script.path) else {
            throw Failure("The bundled WebExtension development worker is missing.")
        }
        try FileManager.default.createDirectory(at: configuration.state, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        if let loginPath { environment[EnvironmentKeys.path] = loginPath }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        child.executableURL = python
        child.arguments = ["-u", configuration.script.path, project.path, configuration.state.path]
        child.environment = environment
        child.currentDirectoryURL = project
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        self.python = python
        hasReplied = false
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
            if count < 0, errno == EPIPE { throw exitFailure() }
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
            guard count > 0 else { throw exitFailure() }
            chunk.count = count
            guard buffer.count + chunk.count <= WebExtensionDefaults.maximumResponseBytes else {
                throw Failure("Development worker response exceeded its \(WebExtensionDefaults.maximumResponseBytes / 1_048_576) MiB limit.")
            }
            buffer.append(chunk)
        }
        throw Failure(isCancelled ? "Development session cancelled." : "Development operation timed out.")
    }

    /// An interpreter that exits before its first reply is the wrong Python (or the Command Line
    /// Tools stub), not a worker that crashed mid-session; name it so the remedy is clear.
    private func exitFailure() -> Failure {
        guard !hasReplied else { return Failure("Development worker exited. Restart the target to reconnect.") }
        return Failure("""
            \(python?.path ?? "Python") exited before the development worker started. Install \
            Python 3.9 or later, then try again.
            """)
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
        // The worker removes its generation on a clean exit; this covers one that was killed.
        // A relaunch after a transport failure recreates the directory from nothing. A state
        // directory that holds the checkout is a misconfiguration and is never deleted.
        let state = configuration.state.standardizedFileURL.path
        let checkout = project.standardizedFileURL.path
        if checkout != state, !checkout.hasPrefix(state + "/") {
            try? FileManager.default.removeItem(at: configuration.state)
        }
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
