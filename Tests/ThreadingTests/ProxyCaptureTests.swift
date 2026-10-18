import XCTest
import Foundation
import Security
import Darwin
@testable import Threading

final class ProxyCaptureTests: XCTestCase {
    static func authority() throws -> ProxyCertificateAuthority {
        let key = try RemoteIdentityCertificateBuilder.makeKey()
        return ProxyCertificateAuthority(key: key, certificate: try ProxyCertificateAuthority.makeCertificate(subjectKey: key, signingKey: key, host: nil))
    }

    func testCertificatesValidateWithIndependentPlatformTLSVerifierAndExactHostname() async throws {
        try await Task.detached { try ProxyCaptureTests.validateCertificates() }.value
    }

    private static func validateCertificates() throws {
        let authority = try Self.authority()
        let leaf = try authority.leaf(for: "api.example.test")
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, authority.certificate as CFData))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, leaf.certificate as CFData))
        for (host, expected) in [("api.example.test", true), ("other.example.test", false)] {
            var trust: SecTrust?
            XCTAssertEqual(SecTrustCreateWithCertificates([certificate] as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust), errSecSuccess)
            let evaluator = try XCTUnwrap(trust)
            XCTAssertEqual(SecTrustSetAnchorCertificates(evaluator, [root] as CFArray), errSecSuccess)
            XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(evaluator, true), errSecSuccess)
            XCTAssertEqual(SecTrustSetNetworkFetchAllowed(evaluator, false), errSecSuccess)
            XCTAssertEqual(SecTrustEvaluateWithError(evaluator, nil), expected)
        }
    }

    func testHostScopeRejectsBroadOrAmbiguousInspection() throws {
        for hosts in [["*.example.com"], ["https://example.com"], ["example.com:443"], ["UPPER.example"], ["a", "a"], Array(repeating: "a", count: 17)] {
            XCTAssertThrowsError(try ProxyLaunchScope(TrafficStartArguments(hosts: hosts, bodyLimit: nil, upstreamCA: nil)))
        }
        XCTAssertNoThrow(try ProxyLaunchScope(TrafficStartArguments(hosts: ["::1", "127.0.0.1", "example.com"], bodyLimit: 1048576, upstreamCA: nil)))
        XCTAssertThrowsError(try ProxyLaunchScope(TrafficStartArguments(hosts: [], bodyLimit: 0, upstreamCA: nil)))
    }

    func testDeviceScopeAllowsApprovalWithoutPredefinedClientAndDecodesFromMCP() throws {
        let decoded = try JSONDecoder().decode(TrafficStartArguments.self, from: Data(#"{"hosts":["example.com"],"listen_address":"192.168.1.10","client_address":"192.168.1.20"}"#.utf8))
        let scope = try ProxyLaunchScope(decoded)
        XCTAssertEqual(scope.listenAddress, "192.168.1.10")
        XCTAssertEqual(scope.clientAddress, "192.168.1.20")
        let local = try ProxyLaunchScope(TrafficStartArguments(hosts: [], bodyLimit: nil, upstreamCA: nil))
        XCTAssertEqual(local.listenAddress, "127.0.0.1")
        XCTAssertEqual(local.clientAddress, "127.0.0.1")
        let asking = try ProxyLaunchScope(TrafficStartArguments(hosts: [], bodyLimit: nil, upstreamCA: nil, listenAddress: "192.168.1.10"))
        XCTAssertTrue(asking.asksClients)
        XCTAssertFalse(local.asksClients)
        XCTAssertThrowsError(try ProxyLaunchScope(TrafficStartArguments(hosts: [], bodyLimit: nil, upstreamCA: nil, clientAddress: "192.168.1.20")))
        for address in ["0.0.0.0", "::", "::1", "localhost", "8.8.8.8", "224.0.0.1", "255.255.255.255", "192.168.01.1", "127.1", "127.0.0.1:8080", "172.32.0.1", "169.253.1.2"] {
            XCTAssertThrowsError(try ProxyLaunchScope(TrafficStartArguments(hosts: [], bodyLimit: nil, upstreamCA: nil, listenAddress: address, clientAddress: "127.0.0.1")), address)
            XCTAssertThrowsError(try ProxyLaunchScope(TrafficStartArguments(hosts: [], bodyLimit: nil, upstreamCA: nil, listenAddress: "127.0.0.1", clientAddress: address)), address)
        }
    }

    @MainActor
    func testBundledHelperEnforcesClientScopeWithoutRetainingRejectedTraffic() async throws {
        let service = ProxyCaptureService(configuration: .bundled, center: NotificationCenter())
        defer { service.stopAll() }
        let owner = SessionID()
        let arguments = TrafficStartArguments(hosts: [], bodyLimit: nil, upstreamCA: nil, listenAddress: "127.0.0.1", clientAddress: "127.0.0.2")
        let started = try Self.object(await service.call(.start(arguments), for: owner))
        XCTAssertEqual(started["listen_address"] as? String, "127.0.0.1")
        XCTAssertEqual(started["client_address"] as? String, "127.0.0.2")
        let port = try XCTUnwrap(started["port"] as? Int)
        try await Task.detached { try ProxyCaptureTests.expectRejectedClient(proxyPort: port) }.value
        let status = try Self.object(await service.call(.status, for: owner))
        XCTAssertEqual(status["rejected_clients"] as? String, "1")
        XCTAssertEqual(status["retained_flows"] as? Int, 0)
        let changed = await service.call(.start(TrafficStartArguments(hosts: [], bodyLimit: nil, upstreamCA: nil)), for: owner)
        XCTAssertTrue(changed.isError, "Changing the admitted device requires explicit release")
    }

    @MainActor
    func testBundledHelperCapturesRealHTTPAndKeepsSessionsSeparate() async throws {
        let configuration = ProxyProcess.Configuration.bundled
        let service = ProxyCaptureService(configuration: .init(executable: configuration.executable, setupScript: configuration.setupScript,
            temporaryRoot: FileManager.default.temporaryDirectory, authority: { throw ProxyProcess.Failure.message("HTTP capture must not access Keychain") }), center: NotificationCenter())
        defer { service.stopAll() }
        let owner = SessionID(), other = SessionID()
        let started = await service.call(.start(TrafficStartArguments(hosts: [], bodyLimit: 65536, upstreamCA: nil, listenAddress: "127.0.0.1", clientAddress: "127.0.0.1")), for: owner)
        let status = try Self.object(started)
        let proxyPort = try XCTUnwrap(status["port"] as? Int)
        let bytes = try await Task.detached { try ProxyCaptureTests.performExchange(proxyPort: proxyPort) }.value
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("bad request fixture"))
        var flowID: String?
        for _ in 0..<20 {
            let listing = try Self.object(await service.call(.list(TrafficListArguments(after: nil, limit: nil)), for: owner))
            flowID = (listing["flows"] as? [[String: Any]])?.first?["id"] as? String
            if flowID != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let id = try XCTUnwrap(flowID)
        let detail = try Self.object(await service.call(.get(TrafficGetArguments(id: id, redact: true)), for: owner))
        XCTAssertEqual(detail["status"] as? Int, 400)
        let body = try Self.object(await service.call(.body(TrafficBodyArguments(id: id, side: "response", offset: nil, limit: nil, decode: nil, redact: nil)), for: owner))
        XCTAssertTrue((body["data"] as? String)?.contains("bad request fixture") == true)
        XCTAssertFalse((body["data"] as? String)?.contains("private-fixture") == true)
        let denied = await service.call(.get(TrafficGetArguments(id: id, redact: false)), for: other)
        XCTAssertTrue(denied.isError)
        let stale = await service.call(.get(TrafficGetArguments(id: "old-capture:1", redact: false)), for: owner)
        XCTAssertTrue(stale.isError)
        let invalidPage = await service.call(.body(TrafficBodyArguments(id: id, side: "response", offset: -1, limit: nil, decode: nil, redact: nil)), for: owner)
        XCTAssertTrue(invalidPage.isError)
        let stillRunning = try Self.object(await service.call(.status, for: owner))
        XCTAssertEqual(stillRunning["running"] as? Bool, true)
        let stopped = await service.call(.stop(TrafficStopArguments(release: true)), for: owner)
        XCTAssertFalse(stopped.isError)
        let gone = try Self.object(await service.call(.status, for: owner))
        XCTAssertEqual(gone["capture"] as? String, "not_started")
    }

    @MainActor
    func testBundledTLSHelperAcceptsHostIssuedLeavesAndExportsOnlyPublicMaterial() async throws {
        let bundled = ProxyProcess.Configuration.bundled
        let center = NotificationCenter()
        let service = ProxyCaptureService(configuration: .init(executable: bundled.executable, setupScript: bundled.setupScript,
            temporaryRoot: FileManager.default.temporaryDirectory, authority: { try Self.authority() }), center: center)
        defer { service.stopAll() }
        let owner = SessionID()
        let started = try Self.object(await service.call(.start(TrafficStartArguments(hosts: ["localhost", "127.0.0.1"], bodyLimit: nil, upstreamCA: nil)), for: owner))
        XCTAssertEqual(started["tls_hosts"] as? [String], ["127.0.0.1", "localhost"])
        let cert = try Self.object(await service.call(.certificate, for: owner))
        XCTAssertNotNil(cert["certificate_der_base64"])
        XCTAssertFalse(String(describing: cert).contains("PRIVATE KEY"))
        let path = try XCTUnwrap(cert["certificate_path"] as? String)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let profile = try XCTUnwrap(cert["profile_path"] as? String)
        // The trust command handed to the agent runs a script the bundle has to carry.
        let setupScript = try XCTUnwrap((cert["macos_setup_argv"] as? [String])?.dropFirst().first)
        let inspection = try await Task.detached {
            (try FileManager.default.contentsOfDirectory(atPath: directory.path),
             (try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: profile)), format: nil) as? [String: Any])?["PayloadType"] as? String,
             FileManager.default.isReadableFile(atPath: setupScript))
        }.value
        XCTAssertFalse(inspection.0.contains { $0.hasSuffix(".key") })
        XCTAssertEqual(inspection.1, "Configuration")
        XCTAssertTrue(inspection.2, "\(setupScript) is not in the bundle")
        center.post(SessionArchivedStateDidChange(sessionID: owner, isArchived: true))
        let status = try Self.object(await service.call(.status, for: owner))
        XCTAssertEqual(status["capture"] as? String, "not_started")
    }

    private static func object(_ result: MCPToolResult) throws -> [String: Any] {
        XCTAssertFalse(result.isError, result.text)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
    }

    static func expectRejectedClient(proxyPort: Int) throws {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { throw ProxyProcess.Failure.message("fixture client") }
        defer { close(client) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(proxyPort).bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw ProxyProcess.Failure.message("fixture connect") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        XCTAssertEqual(read(client, &byte, 1), 0, "Unapproved client must close before any protocol data")
    }

    /// A real origin and client; no URLSession connection-pool/proxy bypass behavior in the fixture.
    static func performExchange(proxyPort: Int) throws -> Data {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ProxyProcess.Failure.message("fixture socket") }
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw ProxyProcess.Failure.message("fixture bind") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 5000) > 0 else { return }
            let origin = accept(listener, nil, nil)
            guard origin >= 0 else { return }
            defer { close(origin) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(origin, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = fcntl(origin, F_SETNOSIGPIPE, 1)
            var bytes = [UInt8](repeating: 0, count: 8192)
            guard read(origin, &bytes, bytes.count) > 0 else { return }
            let body = #"{"error":"bad request fixture","token":"private-fixture"}"#
            let reply = Data("HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
            reply.withUnsafeBytes { buffer in _ = Darwin.write(origin, buffer.baseAddress, buffer.count) }
        }
        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { throw ProxyProcess.Failure.message("fixture client") }
        defer { close(client); _ = done.wait(timeout: .now() + 6) }
        address.sin_port = UInt16(proxyPort).bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw ProxyProcess.Failure.message("fixture connect") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = fcntl(client, F_SETNOSIGPIPE, 1)
        let request = Data("GET http://127.0.0.1:\(port)/fixture HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8)
        request.withUnsafeBytes { buffer in _ = Darwin.write(client, buffer.baseAddress, buffer.count) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(client, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw ProxyProcess.Failure.message("fixture read timed out") }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}
