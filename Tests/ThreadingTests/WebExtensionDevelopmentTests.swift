import Foundation
import XCTest
@testable import Threading

final class WebExtensionDevelopmentTests: XCTestCase {
    /// The worker contracts need a real interpreter; a machine without one skips them rather
    /// than reporting the transport as broken.
    private func python() throws -> URL {
        guard let python = WebExtensionPythonLocator.locate(loginPath: nil) else {
            throw XCTSkip("No Python 3 interpreter for the WebExtension worker contracts")
        }
        return python
    }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testPythonLocatorPrefersOverridesThenStableInstallsThenLoginPathThenSystem() {
        let candidates = WebExtensionPythonLocator.candidates(
            environment: ["THREADING_WEBEXT_PYTHON": "$(THREADING_WEBEXT_PYTHON)",
                          "THREADING_PLAYWRIGHT_PYTHON": "/custom/bin/python3", "PATH": "/inherited"],
            loginPath: "/Users/me/.local/bin:/opt/homebrew/bin:relative")
        XCTAssertEqual(candidates, ["/custom/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                                    "/Users/me/.local/bin/python3", "/usr/bin/python3"])
        // Without a login PATH the inherited one is still searched before the system stub.
        XCTAssertEqual(WebExtensionPythonLocator.candidates(environment: ["PATH": "/inherited"], loginPath: nil),
                       ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/inherited/python3", "/usr/bin/python3"])
        let found = WebExtensionPythonLocator.locate(environment: [:], loginPath: "/a:/b") { $0 == "/b/python3" }
        XCTAssertEqual(found?.path, "/b/python3")
        XCTAssertNil(WebExtensionPythonLocator.locate(environment: [:], loginPath: nil) { _ in false })
    }

    func testCancellationInterruptsAPartialReplyFromALiveWorker() async throws {
        let python = try python()
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("partial.py")
        try """
        import pathlib, sys, time
        sys.stdin.readline()
        pathlib.Path(sys.argv[1], 'received').write_text('ready')
        sys.stdout.write('{"ok":')
        sys.stdout.flush()
        time.sleep(30)
        """.write(to: script, atomically: true, encoding: .utf8)
        let worker = WebExtensionProcess(project: root, configuration: .init(
            python: python, script: script, state: root.appendingPathComponent("state")))
        let reply = Task { await worker.call(.init(action: .inspect)) }
        let ready = root.appendingPathComponent("received")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let cancelled = Date()
        worker.cancel()
        guard case .failure = await reply.value else { return XCTFail("An incomplete reply succeeded") }
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 8)
    }

    /// A reply this build cannot decode, an empty refusal and an oversized request are not
    /// transport failures: the same worker process answers the next command.
    func testUnreadableRepliesAndRefusalsKeepTheWorkerAndItsBrowsersAlive() async throws {
        let python = try python()
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("counting.py")
        try """
        import json, sys
        count = 0
        for line in sys.stdin:
            count += 1
            action = json.loads(line)['action']
            if action == 'inspect':
                reply = {'ok': True, 'result': {'targets': [{'id': 'a', 'browser': 'chromium'}]}}
            elif action == 'clear':
                reply = {'ok': False, 'error': ''}
            else:
                reply = {'ok': True, 'result': {'cursor': count}}
            print(json.dumps(reply), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let state = root.appendingPathComponent("state")
        let worker = WebExtensionProcess(project: root, configuration: .init(python: python, script: script, state: state))
        defer { worker.cancel() }
        guard case .failure(let unreadable) = await worker.call(.init(action: .inspect)) else {
            return XCTFail("A target without source decoded")
        }
        XCTAssertTrue(unreadable.contains("could not be read"), unreadable)
        guard case .failure(let blank) = await worker.call(.init(action: .clear)) else { return XCTFail("Refusal succeeded") }
        XCTAssertEqual(blank, "The development operation failed without a message.")
        let oversized = WebExtensionRequest(action: .events, query: String(repeating: "x", count: 70_000))
        guard case .failure(let refusal) = await worker.call(oversized) else { return XCTFail("Oversized request was sent") }
        XCTAssertTrue(refusal.contains("64 KiB"), refusal)
        guard case .success(let payload, _) = await worker.call(.init(action: .events)) else {
            return XCTFail("The worker did not survive a recoverable failure")
        }
        XCTAssertEqual(payload.cursor, 3, "A relaunched worker would have counted this as its first command")
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
    }

    func testStoppedWorkerRemovesItsGenerationDirectory() async throws {
        let python = try python()
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("echo.py")
        try """
        import json, sys
        for line in sys.stdin:
            print(json.dumps({'ok': True, 'result': {}}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let state = root.appendingPathComponent("session/generation")
        let worker = WebExtensionProcess(project: root, configuration: .init(python: python, script: script, state: state))
        guard case .success = await worker.call(.init(action: .inspect)) else { return XCTFail("Echo worker failed") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
        worker.cancel()
        _ = await worker.call(.init(action: .inspect))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.deletingLastPathComponent().path))

        // A state directory that holds the checkout is a misconfiguration and is never removed.
        let checkout = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let misconfigured = WebExtensionProcess(project: checkout, configuration: .init(python: python, script: script, state: root))
        guard case .success = await misconfigured.call(.init(action: .inspect)) else { return XCTFail("Echo worker failed") }
        misconfigured.cancel()
        _ = await misconfigured.call(.init(action: .inspect))
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkout.path))
    }

    func testInterpreterThatExitsBeforeItsFirstReplyIsNamed() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = WebExtensionProcess(project: root, configuration: .init(
            python: URL(fileURLWithPath: "/usr/bin/false"), script: root.appendingPathComponent("unused.py"),
            state: root.appendingPathComponent("state")))
        try Data().write(to: root.appendingPathComponent("unused.py"))
        guard case .failure(let message) = await worker.call(.init(action: .inspect)) else {
            return XCTFail("An interpreter that exited replied")
        }
        XCTAssertTrue(message.contains("/usr/bin/false exited before the development worker started"), message)
    }

    @MainActor
    func testStaleOrArchivedChatCannotRecreateAWorker() async {
        let id = SessionID()
        let previous = URL(fileURLWithPath: "/tmp/previous-checkout")
        var current: URL? = URL(fileURLWithPath: "/tmp/current-checkout")
        let service = WebExtensionDevelopmentService(currentProject: { _ in current })
        for active in [current, nil] {
            current = active
            let reply = await service.call(.init(action: .inspect), sessionID: id, project: previous)
            guard case .failure(let reason) = reply else { return XCTFail("Stale checkout created a worker") }
            XCTAssertTrue(reason.contains("no longer active"))
            XCTAssertFalse(service.isBusy(id))
        }
    }

    @MainActor
    func testUserCommandWaitsForAnInFlightReadAndReleaseCancelsAQueuedCommand() async throws {
        let python = try python()
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try controlledScript(in: root)
        let id = SessionID()
        let service = WebExtensionDevelopmentService(currentProject: { _ in root }, configuration: { _ in
            .init(python: python, script: script, state: root.appendingPathComponent("state"))
        })
        defer { service.release(id) }
        let received = root.appendingPathComponent("received")
        let proceed = root.appendingPathComponent("continue")
        let inspect = Task { await service.call(.init(action: .inspect), sessionID: id, project: root) }
        try await Self.awaitFile(received)
        var entered = false
        let scaffold = Task {
            entered = true
            return await service.call(.init(action: .scaffold), sessionID: id, project: root)
        }
        while !entered { await Task.yield() }
        try Data().write(to: proceed)
        guard case .success = await scaffold.value else { return XCTFail("A polling read refused a user command") }
        _ = await inspect.value
        try FileManager.default.removeItem(at: proceed)
        try FileManager.default.removeItem(at: received)

        let read = Task { await service.call(.init(action: .inspect), sessionID: id, project: root) }
        try await Self.awaitFile(received)
        entered = false
        let pending = Task {
            entered = true
            return await service.call(.init(action: .clear), sessionID: id, project: root)
        }
        while !entered { await Task.yield() }
        service.release(id)
        _ = await read.value
        guard case .failure = await pending.value else { return XCTFail("A released worker accepted queued work") }
    }

    /// An agent's read that lands while the panel's poll is in flight waits for it instead of
    /// failing, and does so without taking the queued-command slot.
    @MainActor
    func testReadWaitsBrieflyBehindAnotherReadWithoutTakingTheCommandSlot() async throws {
        let python = try python()
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try controlledScript(in: root)
        let id = SessionID()
        let service = WebExtensionDevelopmentService(currentProject: { _ in root }, configuration: { _ in
            .init(python: python, script: script, state: root.appendingPathComponent("state"))
        })
        defer { service.release(id) }
        let poll = Task { await service.call(.init(action: .inspect), sessionID: id, project: root) }
        try await Self.awaitFile(root.appendingPathComponent("received"))
        var entered = false
        let agentRead = Task {
            entered = true
            return await service.call(.init(action: .events), sessionID: id, project: root)
        }
        while !entered { await Task.yield() }
        // The command slot is still free: a user command queues behind the read, not behind the agent.
        let command = Task { await service.call(.init(action: .clear), sessionID: id, project: root) }
        try await Task.sleep(nanoseconds: 100_000_000)
        try Data().write(to: root.appendingPathComponent("continue"))
        guard case .success = await poll.value else { return XCTFail("The first read failed") }
        guard case .success = await command.value else { return XCTFail("A waiting read took the command slot") }
        guard case .success = await agentRead.value else { return XCTFail("A read behind a read was refused") }
    }

    func testAgentEventPageIsOneLinePerEventAndAnEventIDReturnsItsFullRecord() throws {
        let stack = """
            Error
                at console.<computed> (chrome-extension://abcdef/threading_diagnostics.js:104:68)
                at refresh (chrome-extension://abcdef/background/main.js:42:7)
            """
        let event = WebExtensionEvent(id: 7, target: "chrome", level: "error", kind: "console",
                                      message: "Boom\nsecond line", stack: stack, context: "background",
                                      contextID: "context", build: "build", url: "chrome-extension://abcdef/",
                                      received: 0, tab: 3, frame: 0)
        XCTAssertEqual(event.sourceFrame, "background/main.js:42:7")
        var payload = WebExtensionPayload()
        payload.events = [event]
        payload.cursor = 7
        payload.retained = 1
        payload.generation = "worker-1"
        payload.runs = [WebExtensionRun(target: "chrome", browser: "chrome", build: "build", status: "connected",
                                        directory: "/tmp/development", instructions: nil, contexts: ["background"])]
        let page = WebExtensionReply.success(payload, text: "{}").toolResult(for: .init(action: .events))
        XCTAssertFalse(page.isError)
        let lines = page.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("Worker worker-1 · cursor 7"), lines[0])
        XCTAssertTrue(lines.contains("#7 ERROR chrome/background tab 3 console: Boom — background/main.js:42:7"), page.text)
        XCTAssertFalse(page.text.contains("threading_diagnostics"))
        let single = WebExtensionReply.success(payload, text: "{}").toolResult(for: .init(action: .events, event: 7))
        XCTAssertTrue(single.text.contains("second line") && single.text.contains("threading_diagnostics.js"))
        let other = WebExtensionReply.success(payload, text: "{\"raw\":true}").toolResult(for: .init(action: .inspect))
        XCTAssertEqual(other.text, "{\"raw\":true}")
    }

    func testBundledWorkerRunsARealChromiumDevelopmentLoop() async throws {
        guard ProcessInfo.processInfo.environment["THREADING_WEBEXT_E2E"] == "1" else {
            throw XCTSkip("Set THREADING_WEBEXT_E2E=1 with development tools installed for the real-browser lane")
        }
        let python = try python()
        let root = try scratch()
        let project = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = WebExtensionProcess.Configuration.bundled(sessionID: SessionID())
        let worker = WebExtensionProcess(project: project, configuration: .init(
            python: python, script: bundled.script, state: root.appendingPathComponent("state")))
        defer { worker.cancel() }
        for request in [WebExtensionRequest(action: .scaffold),
                        .init(action: .start, target: "chromium", headless: true),
                        .init(action: .test, target: "chromium"),
                        .init(action: .reload, target: "chromium"),
                        .init(action: .test, target: "chromium"),
                        .init(action: .stop, target: "chromium")] {
            let reply = await worker.call(request)
            guard case .success = reply else {
                return XCTFail("Bundled real-browser action failed: \(request.action): \(reply)")
            }
        }
    }

    func testBundledWorkerScaffoldsInspectsAndRejectsOverwriteOverRealPipe() async throws {
        let python = try python()
        let root = try scratch()
        let project = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = WebExtensionProcess.Configuration.bundled(sessionID: SessionID())
        XCTAssertNil(bundled.python, "The shipping configuration locates Python off the main actor")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundled.script.path))
        let worker = WebExtensionProcess(project: project, configuration: .init(
            python: python, script: bundled.script, state: root.appendingPathComponent("state")))
        let created = await worker.call(.init(action: .scaffold))
        guard case .success(let payload, _) = created else {
            worker.cancel()
            return XCTFail("Starter failed: \(created)")
        }
        let configurationPath = try XCTUnwrap(payload.project)
        XCTAssertEqual(URL(fileURLWithPath: configurationPath).resolvingSymlinksInPath(),
                       project.appendingPathComponent(".threading/web-extensions.json").resolvingSymlinksInPath())
        guard case .success(let inspection, _) = await worker.call(.init(action: .inspect)) else {
            worker.cancel()
            return XCTFail("The worker could not inspect its starter")
        }
        XCTAssertEqual(inspection.targets?.map(\.browser), ["chromium", "chrome", "firefox", "safari"])
        let generation = try XCTUnwrap(inspection.generation)
        guard case .failure(let refusal) = await worker.call(.init(action: .scaffold)) else {
            worker.cancel()
            return XCTFail("Scaffold overwrote an existing project")
        }
        XCTAssertTrue(refusal.contains("refuses to replace"))
        // An operation refusal must leave the protocol usable and publish its diagnostic.
        guard case .success(let events, _) = await worker.call(.init(action: .events)) else {
            worker.cancel()
            return XCTFail("Worker disconnected after a recoverable refusal")
        }
        XCTAssertEqual(events.generation, generation)
        let error = try XCTUnwrap(events.events?.first { $0.level == "error" })
        guard case .success(let single, _) = await worker.call(.init(action: .events, event: error.id, generation: generation)) else {
            worker.cancel()
            return XCTFail("The worker could not return one event by ID")
        }
        XCTAssertEqual(single.events?.map(\.id), [error.id])
        guard case .failure(let stale) = await worker.call(.init(action: .events, event: error.id, generation: "earlier")) else {
            worker.cancel()
            return XCTFail("An event ID from another worker generation was reinterpreted")
        }
        XCTAssertTrue(stale.contains("earlier development worker"), stale)

        worker.cancel()
        guard case .failure = await worker.call(.init(action: .inspect)) else {
            return XCTFail("Cancelled worker accepted more work")
        }
    }

    // MARK: - Fixtures

    /// Blocks each `inspect` until `continue` exists; every other action answers at once.
    private func controlledScript(in root: URL) throws -> URL {
        let script = root.appendingPathComponent("controlled.py")
        try """
        import json, pathlib, sys, time
        root = pathlib.Path(sys.argv[1])
        for line in sys.stdin:
            if json.loads(line)['action'] == 'inspect':
                (root / 'received').write_text('ready')
                while not (root / 'continue').exists(): time.sleep(0.01)
            print(json.dumps({'ok': True, 'result': {}}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        return script
    }

    private static func awaitFile(_ url: URL) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
