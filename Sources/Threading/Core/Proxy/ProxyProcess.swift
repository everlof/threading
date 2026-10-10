import Foundation
import Security
import CryptoKit
import Darwin

struct ProxyLaunchScope: Equatable, Sendable {
    let hosts: [String]
    let bodyLimit: Int
    let upstreamCA: String?

    init(_ arguments: TrafficStartArguments) throws {
        guard let hosts = arguments.hosts, hosts.count <= 16, Set(hosts).count == hosts.count else {
            throw ProxyProcess.Failure.message("Supply hosts: an array of up to 16 unique exact DNS/IP names.")
        }
        for host in hosts {
            let bytes = Array(host.utf8)
            guard !bytes.isEmpty, bytes.count <= 254, host == host.lowercased(),
                  bytes.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [45, 46, 58].contains($0) }),
                  (!host.contains(":") || RemoteSubjectAlternativeName.ipAddress(parsing: host) != nil),
                  !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else {
                throw ProxyProcess.Failure.message("TLS hosts must be exact lowercase DNS/IP names without schemes, ports or wildcards.")
            }
        }
        let limit = arguments.bodyLimit ?? 65536
        guard (1...1048576).contains(limit) else { throw ProxyProcess.Failure.message("body_limit must be 1–1048576.") }
        if let path = arguments.upstreamCA, !path.hasPrefix("/") { throw ProxyProcess.Failure.message("upstream_ca must be an absolute PEM path.") }
        self.hosts = hosts.sorted()
        bodyLimit = limit
        upstreamCA = arguments.upstreamCA
    }
}

/// One serial worker and one child per capture. All process, pipe, certificate and file work
/// happens on `queue`. `cancel` only flips a locked flag; the bounded poll notices within 100 ms.
final class ProxyProcess: @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
    struct Configuration: Sendable {
        let executable: URL
        let setupScript: URL
        let temporaryRoot: URL
        let authority: @Sendable () throws -> ProxyCertificateAuthority

        static var bundled: Self {
            let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
            return Self(
                executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/threading-proxyd"),
                setupScript: resources.appendingPathComponent("ProxySource/tools/apple_certificate.py"),
                temporaryRoot: FileManager.default.temporaryDirectory,
                authority: { try ProxyCertificateAuthority.loadOrCreate() }
            )
        }
    }
    let scope: ProxyLaunchScope
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "codes.threading.proxy.process", qos: .utility)
    private let cancellation = NSLock()
    private var cancelled = false
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var directory: URL?
    private var publicCertificate: URL?
    private var profile: URL?
    private var fingerprint: String?
    private let captureID = UUID().uuidString.lowercased()
    private var sequence = 0
    private let exited = DispatchSemaphore(value: 0)

    init(scope: ProxyLaunchScope, configuration: Configuration) {
        self.scope = scope
        self.configuration = configuration
    }

    func call(_ request: TrafficRequest) async -> MCPToolResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    guard !isCancelled else { throw Failure.message("This capture session has ended.") }
                    if process == nil { try launch() }
                    let call = try request.helperCall
                    var arguments = (try JSONSerialization.jsonObject(with: call.arguments)) as? [String: Any] ?? [:]
                    for key in ["id", "after"] {
                        guard let value = arguments[key] as? String else { continue }
                        let prefix = captureID + ":"
                        guard value.hasPrefix(prefix) else {
                            continuation.resume(returning: .failure("That flow reference belongs to a different capture. Read traffic_list again."))
                            return
                        }
                        arguments[key] = String(value.dropFirst(prefix.count))
                    }
                    let response = try rpc("tools/call", params: ["name": call.name, "arguments": arguments])
                    if let error = response["error"] as? [String: Any] {
                        continuation.resume(returning: .failure(error["message"] as? String ?? "Invalid proxy arguments."))
                        return
                    }
                    guard let result = response["result"] as? [String: Any],
                          let content = result["content"] as? [[String: Any]],
                          let text = content.first?["text"] as? String else { throw Failure.message("Invalid proxy tool response.") }
                    if result["isError"] as? Bool == true { continuation.resume(returning: .failure(text)); return }
                    guard var data = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                        throw Failure.message("Proxy returned an invalid tool payload.")
                    }
                    data["capture_id"] = captureID
                    if let id = data["id"] as? String { data["id"] = captureID + ":" + id }
                    if let cursor = data["next_cursor"] as? String { data["next_cursor"] = captureID + ":" + cursor }
                    if let flows = data["flows"] as? [[String: Any]] {
                        data["flows"] = flows.map { flow in
                            var item = flow
                            if let id = item["id"] as? String { item["id"] = captureID + ":" + id }
                            return item
                        }
                    }
                    switch request {
                    case .start, .status, .certificate: addSetup(to: &data)
                    default: break
                    }
                    let encoded = try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
                    continuation.resume(returning: .success(String(decoding: encoded, as: UTF8.self)))
                } catch {
                    cancellation.lock(); cancelled = true; cancellation.unlock()
                    stop()
                    continuation.resume(returning: .failure(error.localizedDescription))
                }
            }
        }
    }

    func cancel(completion: @escaping @Sendable () -> Void = {}) {
        cancellation.lock(); cancelled = true; cancellation.unlock()
        queue.async { [self] in stop(); completion() }
    }

    var isCancelled: Bool {
        cancellation.lock(); defer { cancellation.unlock() }; return cancelled
    }

    private func launch() throws {
        guard FileManager.default.isExecutableFile(atPath: configuration.executable.path) else {
            throw Failure.message("The app bundle is missing threading-proxyd. Rebuild Threading with its proxy helper.")
        }
        let directory = configuration.temporaryRoot.appendingPathComponent("threading-proxy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        var arguments = ["--mcp", "--body-limit", String(scope.bodyLimit)]
        if !scope.hosts.isEmpty {
            let authority = try configuration.authority()
            let root = try write(authority.certificate, named: "inspection.cer")
            publicCertificate = root
            fingerprint = SHA256.hash(data: authority.certificate).map { String(format: "%02x", $0) }.joined()
            arguments += ["--inspection-ca", root.path]
            var trust = Data()
            if let path = scope.upstreamCA {
                trust = try readTrustBundle(path)
            } else {
                var anchors: CFArray?
                let status = SecTrustCopyAnchorCertificates(&anchors)
                guard status == errSecSuccess, let certificates = anchors as? [SecCertificate] else { throw Failure.message("Could not read macOS trusted anchors.") }
                for certificate in certificates {
                    let data = SecCertificateCopyData(certificate) as Data
                    if data != authority.certificate { trust.append(ProxyCertificateAuthority.pem(data, label: "CERTIFICATE")) }
                }
            }
            arguments += ["--upstream-ca", try write(trust, named: "upstream.pem").path]
            for (index, host) in scope.hosts.enumerated() {
                let leaf = try authority.leaf(for: host)
                let cert = try write(ProxyCertificateAuthority.pem(leaf.certificate, label: "CERTIFICATE"), named: "leaf-\(index).pem")
                let key = try write(ProxyCertificateAuthority.pem(leaf.privateKey, label: "EC PRIVATE KEY"), named: "leaf-\(index).key")
                arguments += ["--tls-identity", host, cert.path, key.path]
            }
        }
        guard !isCancelled else { throw Failure.message("This capture session has ended.") }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = configuration.executable
        child.arguments = arguments
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        let exited = self.exited
        child.terminationHandler = { _ in exited.signal() }
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        try stdin.fileHandleForReading.close()
        try stdout.fileHandleForWriting.close()
        for handle in [input, output].compactMap({ $0 }) {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Failure.message("Could not configure proxy pipes.") }
        }
        guard let input, fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.message("Could not protect the proxy pipe from SIGPIPE.") }
        let initialized = try rpc("initialize", params: ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "Threading", "version": "1"]])
        guard let initializedResult = initialized["result"] as? [String: Any], initializedResult["protocolVersion"] as? String == "2025-11-25" else {
            throw Failure.message("Proxy MCP initialization failed.")
        }
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"], deadline: .now() + 5)
        if publicCertificate != nil {
            let response = try rpc("tools/call", params: ["name": "traffic_certificate", "arguments": [:]])
            guard let result = response["result"] as? [String: Any], let items = result["content"] as? [[String: Any]],
                  let text = items.first?["text"] as? String,
                  let certificate = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  certificate["sha256"] as? String == fingerprint,
                  let mobileconfig = certificate["apple_mobileconfig"] as? String else { throw Failure.message("Proxy certificate handshake failed.") }
            profile = try write(Data(mobileconfig.utf8), named: "Threading-Inspection.mobileconfig")
        }
        // The child has loaded the only private material it needs. Delete the staged leaf keys.
        for index in scope.hosts.indices { try FileManager.default.removeItem(at: directory.appendingPathComponent("leaf-\(index).key")) }
    }

    private func readTrustBundle(_ path: String) throws -> Data {
        // Nonblocking open plus fstat rejects FIFOs/devices before a caller-controlled path can
        // occupy a worker indefinitely. The open descriptor fixes the bytes being staged.
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.message("Could not open the upstream CA bundle.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0, metadata.st_size <= 2 * 1024 * 1024 else {
            throw Failure.message("The upstream CA bundle must be a regular file of 1 byte–2 MiB.")
        }
        let data = try handle.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024 else { throw Failure.message("The upstream CA bundle exceeds its size limit.") }
        return data
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        guard let directory else { throw Failure.message("Capture directory is unavailable.") }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.message("Could not stage proxy certificates.")
        }
        return url
    }

    private func addSetup(to data: inout [String: Any]) {
        guard let publicCertificate, let profile, let fingerprint else { return }
        data["certificate_path"] = publicCertificate.path
        data["profile_path"] = profile.path
        data["inspection_ca_sha256"] = fingerprint
        data["macos_setup_argv"] = ["python3", configuration.setupScript.path, publicCertificate.path, "--sha256", fingerprint, "--target", "macos", "--apply"]
        data["simulator_setup_argv"] = ["python3", configuration.setupScript.path, publicCertificate.path, "--sha256", fingerprint, "--target", "simulator", "--udid", "EXACT_BOOTED_SIMULATOR_UDID", "--apply"]
        data["setup"] = "Trust installation is explicit. The helper listens on 127.0.0.1; physical iOS devices need a separate reachable route. Share only the public .mobileconfig; install it in iOS Settings, then enable full trust in General > About > Certificate Trust Settings."
    }

    private func rpc(_ method: String, params: [String: Any]) throws -> [String: Any] {
        sequence += 1
        let deadline = DispatchTime.now() + 15
        try send(["jsonrpc": "2.0", "id": sequence, "method": method, "params": params], deadline: deadline)
        guard let output else { throw Failure.message("Proxy output is closed.") }
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while line.count <= 65536 {
            try ready(output.fileDescriptor, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.read(output.fileDescriptor, &buffer, buffer.count)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { throw Failure.message("Proxy helper exited before replying.") }
            line.append(contentsOf: buffer.prefix(count))
            if let newline = line.firstIndex(of: 10) {
                guard line.count <= 65536, newline == line.count - 1,
                      let response = try JSONSerialization.jsonObject(with: line.prefix(newline)) as? [String: Any],
                      response["id"] as? Int == sequence, response["jsonrpc"] as? String == "2.0" else { throw Failure.message("Proxy returned an invalid RPC response.") }
                return response
            }
        }
        throw Failure.message("Proxy reply exceeded 64 KiB.")
    }

    private func send(_ object: [String: Any], deadline: DispatchTime) throws {
        guard let input else { throw Failure.message("Proxy input is closed.") }
        var bytes = try JSONSerialization.data(withJSONObject: object)
        bytes.append(10)
        guard bytes.count <= 65536 else { throw Failure.message("Proxy request exceeded 64 KiB.") }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                try ready(input.fileDescriptor, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(input.fileDescriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EAGAIN || errno == EINTR { continue }
                guard count > 0 else { throw Failure.message("Proxy input closed before accepting a request.") }
                offset += count
            }
        }
    }

    private func ready(_ fd: Int32, events: Int16, deadline: DispatchTime) throws {
        while !isCancelled, DispatchTime.now() < deadline {
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result < 0, errno == EINTR { continue }
            if result > 0, descriptor.revents & events != 0 { return }
            if result < 0 || descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw Failure.message("Proxy pipe closed.") }
        }
        throw Failure.message(isCancelled ? "This capture session has ended." : "Proxy request timed out.")
    }

    private func stop() {
        try? input?.close(); input = nil
        if let child = process, child.isRunning {
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                child.terminate()
                if exited.wait(timeout: .now() + 0.5) == .timedOut { kill(child.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        try? output?.close(); output = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}
