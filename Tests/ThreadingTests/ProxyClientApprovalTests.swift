import XCTest
@testable import Threading

@MainActor
final class ProxyClientApprovalTests: XCTestCase {
    func testBundledHelperOnceCapturePersistentAndRevocation() async throws {
        let store = ProxyClientGrantStore(suiteName: "ProxyApprovalTests.\(UUID().uuidString)")
        let service = ProxyCaptureService(configuration: .bundled, center: NotificationCenter(), clientGrants: store)
        defer { service.stopAll() }
        let owner = SessionID()
        let arguments = TrafficStartArguments(hosts: [], bodyLimit: nil, upstreamCA: nil, listenAddress: "127.0.0.1")
        var decisions: [ProxyClientDecision] = [.once, .capture, .always, .once]
        var shown = 0
        service.presentClientApproval = { client, scope, session, completion in
            XCTAssertEqual(client.address, "127.0.0.1")
            XCTAssertEqual(session, owner)
            XCTAssertTrue(scope.asksClients)
            shown += 1
            let decision = decisions.removeFirst()
            Task { completion(decision) }
            return {}
        }
        func start() async throws -> Int {
            let result = await service.call(.start(arguments), for: owner)
            XCTAssertFalse(result.isError, result.text)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
            return try XCTUnwrap(payload["port"] as? Int)
        }
        func exchange(_ port: Int) async throws {
            let bytes = try await Task.detached { try ProxyCaptureTests.performExchange(proxyPort: port) }.value
            XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("bad request fixture"))
        }
        var port = try await start()
        try await exchange(port) // Once admits the waiting exchange.
        try await exchange(port) // A later exchange asks; grant this capture.
        try await exchange(port) // Capture grant admits without another prompt.
        XCTAssertEqual(shown, 2)
        _ = await service.call(.stop(TrafficStopArguments(release: false)), for: owner)
        port = try await start()
        try await exchange(port) // Capture grant ended; choose Always.
        XCTAssertEqual(shown, 3)
        // Wait for the host to commit the successful answer, not just the socket to complete.
        let scope = try ProxyLaunchScope(arguments)
        for _ in 0..<50 {
            if await store.contains(address: "127.0.0.1", scope: scope) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = await service.call(.stop(TrafficStopArguments(release: true)), for: owner)
        port = try await start()
        try await exchange(port)
        XCTAssertEqual(shown, 3, "Saved IP survives helper replacement")
        let history = await service.call(.list(TrafficListArguments(after: nil, limit: nil)), for: owner)
        await service.revokeSavedClientAccess()
        let stopped = await service.call(.status, for: owner)
        let stoppedStatus = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stopped.text.utf8)) as? [String: Any])
        XCTAssertEqual(stoppedStatus["running"] as? Bool, false)
        XCTAssertEqual(stoppedStatus["retained_flows"] as? Int, 1, "Revocation preserves debugging history")
        let retained = await service.call(.list(TrafficListArguments(after: nil, limit: nil)), for: owner)
        XCTAssertEqual(history.text, retained.text)
        port = try await start()
        try await exchange(port)
        XCTAssertEqual(shown, 4)
        await store.removeAll()
    }

    func testRememberedClientDoesNotWaitBehindAnotherCapturesPrompt() async throws {
        let store = ProxyClientGrantStore(suiteName: "ProxyApprovalTests.\(UUID().uuidString)")
        let bundled = ProxyProcess.Configuration.bundled
        let configuration = ProxyProcess.Configuration(executable: bundled.executable, setupScript: bundled.setupScript,
            temporaryRoot: bundled.temporaryRoot, authority: { try ProxyCaptureTests.authority() })
        let service = ProxyCaptureService(configuration: configuration, center: NotificationCenter(), clientGrants: store)
        defer { service.stopAll() }
        let savedArguments = TrafficStartArguments(hosts: [], bodyLimit: nil, upstreamCA: nil, listenAddress: "127.0.0.1")
        let savedScope = try ProxyLaunchScope(savedArguments)
        let revision = await store.lookup(address: "127.0.0.1", scope: savedScope).revision
        await store.remember(address: "127.0.0.1", scope: savedScope, revision: revision)
        var answer: (@MainActor (ProxyClientDecision) -> Void)?
        var questions = 0
        service.presentClientApproval = { _, _, _, completion in
            questions += 1
            answer = completion
            return {}
        }
        func start(_ arguments: TrafficStartArguments) async throws -> Int {
            let result = await service.call(.start(arguments), for: SessionID())
            XCTAssertFalse(result.isError, result.text)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
            return try XCTUnwrap(payload["port"] as? Int)
        }
        let unknownPort = try await start(TrafficStartArguments(hosts: ["localhost"], bodyLimit: nil,
            upstreamCA: nil, listenAddress: "127.0.0.1"))
        let waiting = Task.detached { try ProxyCaptureTests.expectRejectedClient(proxyPort: unknownPort) }
        for _ in 0..<100 where answer == nil { try await Task.sleep(for: .milliseconds(20)) }
        let decline = try XCTUnwrap(answer)
        let knownPort = try await start(savedArguments)
        let response = try await Task.detached { try ProxyCaptureTests.performExchange(proxyPort: knownPort) }.value
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("bad request fixture"))
        XCTAssertEqual(questions, 1, "A saved IP must forward while another capture waits for its human answer")
        decline(.deny)
        try await waiting.value
        await store.removeAll()
    }

    func testReleasingPendingCaptureDismissesAndIgnoresLateAlwaysAnswer() async throws {
        let store = ProxyClientGrantStore(suiteName: "ProxyApprovalTests.\(UUID().uuidString)")
        let service = ProxyCaptureService(configuration: .bundled, center: NotificationCenter(), clientGrants: store)
        defer { service.stopAll() }
        let owner = SessionID()
        let arguments = TrafficStartArguments(hosts: [], bodyLimit: nil, upstreamCA: nil, listenAddress: "127.0.0.1")
        var reply: (@MainActor (ProxyClientDecision) -> Void)?
        var dismissals = 0
        service.presentClientApproval = { _, _, _, completion in
            reply = completion
            return { dismissals += 1; completion(.deny) }
        }
        let result = await service.call(.start(arguments), for: owner)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        let port = try XCTUnwrap(payload["port"] as? Int)
        let waiting = Task.detached { try ProxyCaptureTests.expectRejectedClient(proxyPort: port) }
        for _ in 0..<100 where reply == nil { try await Task.sleep(for: .milliseconds(20)) }
        let lateAnswer = try XCTUnwrap(reply)
        service.release(owner)
        try await waiting.value
        XCTAssertEqual(dismissals, 1)
        lateAnswer(.always)
        let saved = await store.contains(address: "127.0.0.1", scope: try ProxyLaunchScope(arguments))
        XCTAssertFalse(saved)
        let status = await service.call(.status, for: owner)
        XCTAssertTrue(status.text.contains("not_started"))
        await store.removeAll()
    }

    func testSavedGrantRoundTripExactScopeAndBoundedCapacity() async throws {
        let suite = "ProxyApprovalTests.\(UUID().uuidString)"
        let store = ProxyClientGrantStore(suiteName: suite)
        let scope = try ProxyLaunchScope(TrafficStartArguments(hosts: ["example.com"], bodyLimit: nil, upstreamCA: nil, listenAddress: "192.168.1.10"))
        let revision = await store.lookup(address: "192.168.1.20", scope: scope).revision
        await store.remember(address: "192.168.1.20", scope: scope, revision: revision)
        let reloaded = ProxyClientGrantStore(suiteName: suite)
        let remembered = await reloaded.contains(address: "192.168.1.20", scope: scope)
        XCTAssertTrue(remembered)
        let otherScope = try ProxyLaunchScope(TrafficStartArguments(hosts: ["other.example"], bodyLimit: nil, upstreamCA: nil, listenAddress: "192.168.1.10"))
        let wrongScope = await reloaded.contains(address: "192.168.1.20", scope: otherScope)
        let wrongIP = await reloaded.contains(address: "192.168.1.21", scope: scope)
        XCTAssertFalse(wrongScope)
        XCTAssertFalse(wrongIP)
        for index in 30..<63 { await store.remember(address: "192.168.1.\(index)", scope: scope, revision: revision) }
        let evicted = await store.contains(address: "192.168.1.20", scope: scope)
        XCTAssertFalse(evicted)
        await store.removeAll()
        await store.remember(address: "192.168.1.20", scope: scope, revision: revision)
        let restoredByStaleSave = await store.contains(address: "192.168.1.20", scope: scope)
        XCTAssertFalse(restoredByStaleSave, "A save queued before revocation cannot restore authority")
    }
}
