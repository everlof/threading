import Foundation
import XCTest
@testable import Threading

final class WebExtensionDevelopmentTests: XCTestCase {
    func testCancellationInterruptsAPartialReplyFromALiveWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        let bundled = WebExtensionProcess.Configuration.bundled(sessionID: SessionID())
        let worker = WebExtensionProcess(project: root, configuration: .init(
            python: bundled.python, script: script, state: root.appendingPathComponent("state")))
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let id = SessionID()
        let python = WebExtensionProcess.Configuration.bundled(sessionID: id).python
        let service = WebExtensionDevelopmentService(currentProject: { _ in root }, configuration: { _ in
            .init(python: python, script: script, state: root.appendingPathComponent("state"))
        })
        defer { service.release(id) }
        let received = root.appendingPathComponent("received")
        let proceed = root.appendingPathComponent("continue")
        func awaitRead() async throws {
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: received.path), Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: received.path))
        }
        let inspect = Task { await service.call(.init(action: .inspect), sessionID: id, project: root) }
        try await awaitRead()
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
        try await awaitRead()
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

    func testBundledWorkerRunsARealChromiumDevelopmentLoop() async throws {
        guard ProcessInfo.processInfo.environment["THREADING_WEBEXT_E2E"] == "1" else {
            throw XCTSkip("Set THREADING_WEBEXT_E2E=1 with development tools installed for the real-browser lane")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = WebExtensionProcess.Configuration.bundled(sessionID: SessionID())
        let worker = WebExtensionProcess(project: project, configuration: .init(
            python: bundled.python, script: bundled.script, state: root.appendingPathComponent("state")))
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = WebExtensionProcess.Configuration.bundled(sessionID: SessionID())
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundled.script.path))
        let worker = WebExtensionProcess(project: project, configuration: .init(
            python: bundled.python, script: bundled.script, state: root.appendingPathComponent("state")))
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
        XCTAssertTrue(events.events?.contains { $0.level == "error" } == true)

        worker.cancel()
        guard case .failure = await worker.call(.init(action: .inspect)) else {
            return XCTFail("Cancelled worker accepted more work")
        }
    }
}
