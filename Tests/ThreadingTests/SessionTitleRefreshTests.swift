import XCTest
@testable import Threading

@MainActor
final class SessionTitleRefreshTests: HostedStoreTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("title-refresh-\(UUID().uuidString)", isDirectory: true)
    private var didPrepareDirectory = false

    func testRepeatedRefreshesCoalesceWhileTheWorkerIsBlocked() async throws {
        let session = try makeSession()
        let account = makeAccount()
        let gate = TitleReadGate()
        var discoveries = 0
        let refresh = {
            SessionNaming.refreshAgentTitle(
                forSessionID: session.id,
                accountProvider: { _, _ in discoveries += 1; return account },
                titleReader: { gate.read($0) }
            )
        }
        refresh()
        await gate.waitUntilStarted()
        defer { gate.proceed() }
        for _ in 0..<1_000 { refresh() }
        XCTAssertEqual(gate.readCount, 1)
        XCTAssertEqual(discoveries, 1)
        gate.proceed()
        try await waitUntilFinished(session.id)
        XCTAssertEqual(gate.readCount, 2)
        XCTAssertEqual(discoveries, 2)
        XCTAssertFalse(gate.readOnMain)
        XCTAssertEqual(ProjectStore.shared.session(withID: session.id)?.agentTitle, "Fresh title 2")
    }

    func testAMovedAccountRejectsAnOldWorkerResult() async throws {
        let session = try makeSession()
        let account = makeAccount()
        let gate = TitleReadGate()
        SessionNaming.refreshAgentTitle(
            forSessionID: session.id,
            accountProvider: { _, _ in account },
            titleReader: { gate.read($0) }
        )
        await gate.waitUntilStarted()
        defer { gate.proceed() }
        XCTAssertEqual(ProjectStore.shared.setAccountHandle(.named("changed"), for: session.id), .applied)
        gate.proceed()
        try await waitUntilFinished(session.id)
        XCTAssertNil(ProjectStore.shared.session(withID: session.id)?.agentTitle)
    }

    func testAChosenTitleStillWinsOverAnInFlightProviderRead() async throws {
        let session = try makeSession()
        let account = makeAccount()
        let gate = TitleReadGate()
        SessionNaming.refreshAgentTitle(
            forSessionID: session.id,
            accountProvider: { _, _ in account },
            titleReader: { gate.read($0) }
        )
        await gate.waitUntilStarted()
        defer { gate.proceed() }
        ProjectStore.shared.updateAgentTitle("Chosen name", for: session.id, source: .chosen)
        gate.proceed()
        try await waitUntilFinished(session.id)
        XCTAssertEqual(ProjectStore.shared.session(withID: session.id)?.agentTitle, "Chosen name")
    }

    func testLaunchDiscoversAccountsOnceForManyRetainedSessions() async throws {
        let sessions = try (0..<120).map { _ in try makeSession() }
        let account = makeAccount()
        let index = sessions.enumerated().map { index, session in
            "{\"id\":\"\(session.resumeState.transcriptID!.rawValue)\",\"thread_name\":\"Retained title \(index)\"}"
        }.joined(separator: "\n") + "\n"
        try Data(index.utf8).write(to: directory.appendingPathComponent("session_index.jsonl"))
        var discoveries = 0
        SessionNaming.refreshProviderTitlesAtLaunch(accountsProvider: {
            discoveries += 1
            return [account]
        })
        let deadline = Date().addingTimeInterval(5)
        while ProjectStore.shared.session(withID: sessions.last!.id)?.agentTitle == nil,
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(discoveries, 1)
        for (index, session) in sessions.enumerated() {
            XCTAssertEqual(
                ProjectStore.shared.session(withID: session.id)?.agentTitle, "Retained title \(index)"
            )
        }
    }

    private func makeAccount() -> AgentAccount {
        AgentAccount(provider: .codex, handle: .standard, configPath: directory.path)
    }

    private func makeSession() throws -> AgentSession {
        try prepareDirectory()
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let imported = ImportableSession(
            agentSessionID: TranscriptID(UUID().uuidString),
            kind: .codex,
            accountHandle: .standard,
            title: "Fixture conversation",
            lastActiveAt: Date()
        )
        return try XCTUnwrap(store.importSessions([imported], into: project.id).first)
    }

    private func prepareDirectory() throws {
        guard !didPrepareDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        didPrepareDirectory = true
        addTeardownBlock { [directory] in
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func waitUntilFinished(_ sessionID: SessionID) async throws {
        let deadline = Date().addingTimeInterval(5)
        while SessionNaming.isRefreshingAgentTitle(for: sessionID), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(SessionNaming.isRefreshingAgentTitle(for: sessionID))
    }

    private final class TitleReadGate: @unchecked Sendable {
        private let lock = NSLock()
        private let started = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private var reads = 0
        private var onMain = false

        var readCount: Int { lock.withLock { reads } }
        var readOnMain: Bool { lock.withLock { onMain } }

        func read(_ reading: SessionNaming.TitleReading) -> SessionNaming.ProviderTitle {
            let count = lock.withLock {
                onMain = onMain || Thread.isMainThread
                reads += 1
                return reads
            }
            if count == 1 {
                started.signal()
                _ = release.wait(timeout: .now() + 10)
            }
            return .init(title: "Fresh title \(count)", source: .provider)
        }

        func waitUntilStarted() async {
            let didStart = await Task.detached { self.waitForStart() }.value
            XCTAssertTrue(didStart, "title worker did not start")
        }

        private func waitForStart() -> Bool {
            started.wait(timeout: .now() + 5) == .success
        }

        func proceed() { release.signal() }
    }
}
