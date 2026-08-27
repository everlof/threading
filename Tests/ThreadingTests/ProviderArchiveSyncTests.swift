import XCTest
@testable import Threading

final class ProviderArchiveSyncTests: XCTestCase {

    // MARK: - Reconciliation

    func testFirstReconciliationPreservesArchiveIntentFromEitherSide() {
        XCTAssertEqual(
            ProviderArchiveReconciliationPlan.make(
                local: false,
                provider: false,
                lastSynchronized: nil
            ),
            ProviderArchiveReconciliationPlan(providerTarget: nil, synchronizedState: false)
        )
        XCTAssertEqual(
            ProviderArchiveReconciliationPlan.make(
                local: true,
                provider: false,
                lastSynchronized: nil
            ),
            ProviderArchiveReconciliationPlan(providerTarget: true, synchronizedState: true)
        )
        XCTAssertEqual(
            ProviderArchiveReconciliationPlan.make(
                local: false,
                provider: true,
                lastSynchronized: nil
            ),
            ProviderArchiveReconciliationPlan(providerTarget: nil, synchronizedState: true)
        )
        XCTAssertEqual(
            ProviderArchiveReconciliationPlan.make(
                local: true,
                provider: true,
                lastSynchronized: nil
            ),
            ProviderArchiveReconciliationPlan(providerTarget: nil, synchronizedState: true)
        )
    }

    func testExternalProviderChangeIsMirroredLocally() {
        XCTAssertEqual(
            ProviderArchiveReconciliationPlan.make(
                local: false,
                provider: true,
                lastSynchronized: false
            ),
            ProviderArchiveReconciliationPlan(providerTarget: nil, synchronizedState: true)
        )
        XCTAssertEqual(
            ProviderArchiveReconciliationPlan.make(
                local: true,
                provider: false,
                lastSynchronized: true
            ),
            ProviderArchiveReconciliationPlan(providerTarget: nil, synchronizedState: false)
        )
    }

    func testLocalChangeIsPushedToProvider() {
        XCTAssertEqual(
            ProviderArchiveReconciliationPlan.make(
                local: true,
                provider: false,
                lastSynchronized: false
            ),
            ProviderArchiveReconciliationPlan(providerTarget: true, synchronizedState: true)
        )
        XCTAssertEqual(
            ProviderArchiveReconciliationPlan.make(
                local: false,
                provider: true,
                lastSynchronized: true
            ),
            ProviderArchiveReconciliationPlan(providerTarget: false, synchronizedState: false)
        )
    }

    // MARK: - Provider Store

    func testSnapshotDistinguishesActiveArchivedAbsentAndAmbiguousRollouts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let activeID = TranscriptID("019fd131-6e9a-7b02-90f2-c291334e6d83")
        let archivedID = TranscriptID("019f8e9e-5101-7033-922d-916884a443a7")
        let absentID = TranscriptID("019faf76-e5c4-7331-9832-fb6654e397cc")
        let ambiguousID = TranscriptID("019f99c1-98d4-7251-81d4-2ac20e834d30")

        let active = root.appendingPathComponent("sessions/2026/08/08", isDirectory: true)
        let archived = root.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)

        try Data().write(to: rollout(in: active, id: activeID))
        try Data().write(to: rollout(in: archived, id: archivedID))
        try Data().write(to: rollout(in: active, id: ambiguousID))
        try Data().write(to: rollout(in: archived, id: ambiguousID))

        let account = AgentAccount(
            provider: .codex,
            handle: .standard,
            configPath: root.path
        )
        let snapshot = try XCTUnwrap(ProviderArchiveSnapshot.read(
            account: account,
            sessionIDs: [activeID, archivedID, absentID, ambiguousID]
        ))

        XCTAssertEqual(snapshot[activeID], .active)
        XCTAssertEqual(snapshot[archivedID], .archived)
        XCTAssertEqual(snapshot[absentID], .absent)
        XCTAssertEqual(snapshot[ambiguousID], .ambiguous)
    }

    // MARK: - Persistence and Routing

    func testLastAgreementSurvivesSessionCoding() throws {
        var session = AgentSession(kind: .codex, title: "Retained")
        session.synchronizeArchiveState(true)

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)

        XCTAssertTrue(decoded.isArchived)
        XCTAssertEqual(decoded.lastSynchronizedArchiveState, true)
    }

    @MainActor
    func testArchiveCommandUsesTheSessionsAccountRoute() {
        let transcriptID = TranscriptID("019fd131-6e9a-7b02-90f2-c291334e6d83")
        let session = AgentSession(kind: .codex, title: "Routed")
        let account = AgentAccount(
            provider: .codex,
            handle: .named("work"),
            configPath: "/tmp/codex work"
        )

        let command = ProviderArchiveCommand.make(
            archives: true,
            session: session,
            transcriptID: transcriptID,
            account: account
        )

        XCTAssertEqual(
            command.source,
            "'env' 'CODEX_HOME=/tmp/codex work' 'codex' 'archive' '\(transcriptID.rawValue)'"
        )
    }

    @MainActor
    func testDefaultAccountExplicitlyClearsAnInheritedHome() {
        let transcriptID = TranscriptID("019fd131-6e9a-7b02-90f2-c291334e6d83")
        let session = AgentSession(kind: .codex, title: "Default")
        let account = AgentAccount(
            provider: .codex,
            handle: .standard,
            configPath: "/Users/example/.codex"
        )

        let command = ProviderArchiveCommand.make(
            archives: false,
            session: session,
            transcriptID: transcriptID,
            account: account
        )

        XCTAssertEqual(
            command.source,
            "'env' '-u' 'CODEX_HOME' 'codex' 'unarchive' '\(transcriptID.rawValue)'"
        )
    }

    /// A local-only archive used to report success after `ProjectStore.save()` had restored the
    /// standing snapshot. Recovery mode makes that refusal deterministic without damaging a
    /// database, and the synchronizer must neither hide the session nor claim that it did.
    @MainActor
    func testKnownPersistenceRefusalStopsBeforeArchiveSideEffectsAndIsReported() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-archive-refusal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = StateManager(appSupportDirectory: directory)
        let seed = ProjectStore(stateManager: manager, refusesWrites: false)
        let project = try XCTUnwrap(seed.addProject(folderURL: directory))
        let session = try XCTUnwrap(seed.addSession(to: project.id, kind: .claude))

        let recovery = ProjectStore(stateManager: manager, refusesWrites: true)
        let synchronizer = ProviderArchiveSync(store: recovery)
        var received: Result<Void, ProviderArchiveFailure>?
        synchronizer.setArchived(true, for: session.id) { received = $0 }

        guard case .failure(let failure) = try XCTUnwrap(received) else {
            return XCTFail("a refused write was acknowledged as a successful archive")
        }
        XCTAssertEqual(failure, .persistenceUnavailable(processStopped: false))
        XCTAssertFalse(try XCTUnwrap(recovery.session(withID: session.id)).isArchived)
    }

    @MainActor
    func testAMissingArchiveTargetIsNotAcknowledgedAsSuccess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-archive-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let synchronizer = ProviderArchiveSync(store: ProjectStore(
            stateManager: StateManager(appSupportDirectory: directory),
            refusesWrites: false
        ))
        var received: Result<Void, ProviderArchiveFailure>?
        synchronizer.setArchived(true, for: SessionID()) { received = $0 }

        guard case .failure(let failure) = try XCTUnwrap(received) else {
            return XCTFail("a missing session was acknowledged as a successful archive")
        }
        XCTAssertEqual(failure, .sessionNotFound)
    }

    /// Local-only agents can be daemon-owned too. The durable row moves first because there is no
    /// provider transaction to protect, but success must wait until the shared process stopper
    /// has dealt with both the runtime cache and `threading-ptyd`.
    @MainActor
    func testLocalOnlyArchiveWaitsForTheProcessStopper() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-archive-stop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(
            stateManager: StateManager(appSupportDirectory: directory),
            refusesWrites: false
        )
        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        var stoppedSessionID: SessionID?
        var releaseStop: (@MainActor @Sendable () -> Void)?
        let synchronizer = ProviderArchiveSync(
            store: store,
            processStopper: { sessionID, completion in
                stoppedSessionID = sessionID
                releaseStop = completion
            }
        )
        var received: Result<Void, ProviderArchiveFailure>?

        synchronizer.setArchived(true, for: session.id) { received = $0 }

        XCTAssertEqual(stoppedSessionID, session.id)
        XCTAssertTrue(try XCTUnwrap(store.session(withID: session.id)).isArchived)
        XCTAssertNil(received, "archive completion must wait for the daemon-owned writer")

        try XCTUnwrap(releaseStop)()
        guard case .success = try XCTUnwrap(received) else {
            return XCTFail("the archive did not complete after its process stopped")
        }
    }

    private func rollout(in directory: URL, id: TranscriptID) -> URL {
        directory.appendingPathComponent("rollout-2026-08-08T00-00-00-\(id.rawValue).jsonl")
    }
}
