import Foundation
import os
import XCTest
@testable import Threading

final class FileSystemEventStreamTests: XCTestCase {
    @MainActor
    func testSelectionWatchersReturnWhileDaemonRegistrationIsBlocked() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitBackend = Backend(blockStart: true)
        let scriptBackend = Backend()
        defer { gitBackend.releaseStart.signal() }
        let git = try XCTUnwrap(GitCheckoutWatcher(root: root, backend: gitBackend) {})
        let script = ProjectScriptConfigurationWatcher(repositoryRoot: root, backend: scriptBackend) {}

        git.start()
        wait(for: [gitBackend.startEntered], timeout: 5)
        script.start()
        let responsive = expectation(description: "main queue runs while daemon RPC is blocked")
        DispatchQueue.main.async { responsive.fulfill() }
        wait(for: [responsive], timeout: 5)
        XCTAssertFalse(gitBackend.startFinished)
        XCTAssertEqual(scriptBackend.startCount, 0, "registration has one shared worker")

        git.stop()
        script.stop()
        gitBackend.releaseStart.signal()
        wait(for: [gitBackend.stopEntered], timeout: 5)
        // Enqueue a fresh stream behind both discarded requests to prove the lane has drained.
        let drained = expectation(description: "later stream registered")
        let later = makeStream(backend: Backend(), onChange: { drained.fulfill() })
        later.start()
        wait(for: [drained], timeout: 5)
        later.stop()
        XCTAssertEqual(scriptBackend.startCount, 0, "a discarded checkout never registers")
        XCTAssertEqual(gitBackend.mainThreadOperations, 0)
    }

    @MainActor
    func testRapidRestartCoalescesRegistrationAndRejectsOldCallbacks() {
        let backend = Backend(blockStart: true)
        defer { backend.releaseStart.signal() }
        let armed = expectation(description: "current generation armed")
        let changed = expectation(description: "current generation event delivered")
        var reports = 0
        let stream = makeStream(backend: backend) {
            reports += 1
            if reports == 1 { armed.fulfill() }
            if reports == 2 { changed.fulfill() }
        }
        stream.start()
        wait(for: [backend.startEntered], timeout: 5)
        for _ in 0..<1_000 {
            stream.stop()
            stream.start()
        }
        backend.releaseStart.signal()
        wait(for: [armed], timeout: 5)
        XCTAssertEqual(backend.startCount, 2)
        XCTAssertEqual(backend.stopCount, 1)
        backend.emit(from: 0)
        backend.emit(from: 1)
        wait(for: [changed], timeout: 5)
        XCTAssertEqual(reports, 2, "retired registration and events must not publish")
        stream.stop()
    }

    @MainActor
    func testStopRevokesQueuedDeliveryBeforeSlowDaemonTeardownCompletes() {
        let backend = Backend(blockStop: true)
        defer { backend.releaseStop.signal() }
        let armed = expectation(description: "registered")
        var reports = 0
        let stream = makeStream(backend: backend) {
            reports += 1
            armed.fulfill()
        }
        stream.start()
        wait(for: [armed], timeout: 5)
        let eventQueued = DispatchSemaphore(value: 0)
        backend.emit(from: 0, processed: eventQueued)
        // This wait does not pump main, leaving the event's delivery pending when stop runs.
        XCTAssertEqual(eventQueued.wait(timeout: .now() + 5), .success)
        stream.stop()
        wait(for: [backend.stopEntered], timeout: 5)
        let responsive = expectation(description: "UI runs during blocked teardown")
        DispatchQueue.main.async { responsive.fulfill() }
        wait(for: [responsive], timeout: 5)
        XCTAssertFalse(backend.stopFinished)
        XCTAssertEqual(reports, 1)
        XCTAssertEqual(backend.mainThreadOperations, 0)
    }

    @MainActor
    func testEventBurstsKeepOnePendingMainQueueNotification() {
        let backend = Backend()
        let armed = expectation(description: "armed")
        let changed = expectation(description: "one pending change delivered")
        var reports = 0
        let stream = makeStream(backend: backend) {
            reports += 1
            if reports == 1 { armed.fulfill() }
            if reports == 2 { changed.fulfill() }
        }
        stream.start()
        wait(for: [armed], timeout: 5)
        for _ in 0..<100 {
            let queued = DispatchSemaphore(value: 0)
            backend.emit(from: 0, processed: queued)
            XCTAssertEqual(queued.wait(timeout: .now() + 5), .success)
        }
        wait(for: [changed], timeout: 5)
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(reports, 2)
        stream.stop()
    }

    @MainActor
    func testDroppingOwnerDuringRegistrationStillCleansUpWithoutPublishing() {
        let backend = Backend(blockStart: true)
        defer { backend.releaseStart.signal() }
        let unexpected = expectation(description: "discarded owner receives no initial read")
        unexpected.isInverted = true
        var stream: FileSystemEventStream? = makeStream(backend: backend) { unexpected.fulfill() }
        weak var owner = stream
        stream?.start()
        wait(for: [backend.startEntered], timeout: 5)
        stream = nil
        XCTAssertNil(owner)
        backend.releaseStart.signal()
        wait(for: [backend.stopEntered], timeout: 5)
        wait(for: [unexpected], timeout: 0.1)
    }

    @MainActor
    func testNativeStreamCatchesUpAfterRegistrationAndReportsAtomicReplacement() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let armed = expectation(description: "initial read after native registration")
        let replaced = expectation(description: "atomic configuration replacement observed")
        let configuration = root.appendingPathComponent(ProjectScriptDefaults.configurationFileName)
        let replacement = Data("{}".utf8)
        var isArmed = false
        var observedReplacement = false
        let watcher = ProjectScriptConfigurationWatcher(repositoryRoot: root) {
            guard isArmed else {
                isArmed = true
                armed.fulfill()
                return
            }
            guard !observedReplacement,
                  (try? Data(contentsOf: configuration)) == replacement else { return }
            observedReplacement = true
            replaced.fulfill()
        }
        watcher.start()
        defer { watcher.stop() }
        wait(for: [armed], timeout: 10)
        try replacement.write(to: configuration, options: .atomic)
        wait(for: [replaced], timeout: 10)
    }

    private func makeStream(
        backend: Backend,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) -> FileSystemEventStream {
        FileSystemEventStream(
            paths: ["/fixture"], latency: 0, coalesce: 0,
            isRelevant: { _, _ in true }, onChange: onChange, backend: backend
        )
    }

    private func makeRoot() throws -> URL {
        // macOS normalizes /private/var back to /var in standardized URLs, while FSEvents
        // reports /private/var. Use a disposable cache checkout without that system alias.
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let root = caches.appendingPathComponent("threading-watch-test-\(UUID().uuidString)")
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        return root.resolvingSymlinksInPath()
    }

    private final class Backend: FileSystemEventStreamBackend, @unchecked Sendable {
        private struct Registration: Sendable {
            let queue: DispatchQueue
            let receive: @Sendable ([String], [FSEventStreamEventFlags]) -> Void
        }
        private struct State {
            var registrations: [Registration] = []
            var stops = 0
            var mainThreadOperations = 0
            var startFinished = false
            var stopFinished = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let blockStart: Bool
        private let blockStop: Bool
        let startEntered = XCTestExpectation(description: "entered registration")
        let stopEntered = XCTestExpectation(description: "entered teardown")
        let releaseStart = DispatchSemaphore(value: 0)
        let releaseStop = DispatchSemaphore(value: 0)
        var startCount: Int { state.withLock { $0.registrations.count } }
        var stopCount: Int { state.withLock { $0.stops } }
        var mainThreadOperations: Int { state.withLock { $0.mainThreadOperations } }
        var startFinished: Bool { state.withLock { $0.startFinished } }
        var stopFinished: Bool { state.withLock { $0.stopFinished } }

        init(blockStart: Bool = false, blockStop: Bool = false) {
            self.blockStart = blockStart
            self.blockStop = blockStop
            startEntered.assertForOverFulfill = false
            stopEntered.assertForOverFulfill = false
        }

        func start(
            deliveryQueue: DispatchQueue,
            onEvent: @escaping @Sendable ([String], [FSEventStreamEventFlags]) -> Void
        ) -> Bool {
            let first = state.withLock { state in
                state.registrations.append(Registration(queue: deliveryQueue, receive: onEvent))
                if Thread.isMainThread { state.mainThreadOperations += 1 }
                return state.registrations.count == 1
            }
            startEntered.fulfill()
            if first && blockStart { _ = releaseStart.wait(timeout: .now() + 5) }
            state.withLock { $0.startFinished = true }
            return true
        }

        func stop() {
            state.withLock { state in
                state.stops += 1
                if Thread.isMainThread { state.mainThreadOperations += 1 }
            }
            stopEntered.fulfill()
            if blockStop { _ = releaseStop.wait(timeout: .now() + 5) }
            state.withLock { $0.stopFinished = true }
        }

        func emit(from index: Int, processed: DispatchSemaphore? = nil) {
            let registration = state.withLock { $0.registrations[index] }
            registration.queue.async {
                registration.receive(["/fixture/change"], [0])
                // Coalescing is queued on this same serial lane, so place the fence after it.
                registration.queue.async { processed?.signal() }
            }
        }
    }
}
