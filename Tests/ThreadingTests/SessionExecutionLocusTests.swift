import Foundation
import XCTest
@testable import Threading

/// The reconciliation of what an agent reports about its working directory against the checkout
/// that owns its chat.
///
/// The resolver is injected throughout, which is the point of these tests as much as the
/// classification is: they assert how many times it is consulted, because the production
/// resolver is `git rev-parse` and these reports arrive on every turn boundary and every
/// brokered tool call of every running session.
@MainActor
final class SessionExecutionLocusTests: XCTestCase {

    private var root: URL!
    private var state: StateManager!
    private var store: ProjectStore!
    private var project: Project!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionExecutionLocusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        state = StateManager(appSupportDirectory: root.appendingPathComponent("state"))
        store = ProjectStore(stateManager: state)
        let checkout = root.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        project = try XCTUnwrap(store.addProject(folderURL: checkout))
    }

    override func tearDown() {
        state?.closeDatabase()
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    // MARK: - The reported directory

    /// Both hook-capable runtimes report where they are working, on every event.
    ///
    /// Measured rather than assumed. Claude CLI 2.1.251 builds its payload as
    /// `session_id / transcript_path / cwd`; Codex 0.151.0 was captured through Threading's own
    /// installed hook, and `sessionStarted`, `turnStarted` and `turnFinished` each arrived
    /// carrying `cwd`. Threading read the other two keys out of that dictionary for a long time
    /// while stepping over this one, which is why a chat could work in a sibling worktree for
    /// hours with every surface still naming the checkout it launched from.
    func testEveryEventCarriesTheReportedWorkingDirectory() throws {
        for event in HookLifecycleEvent.allCases {
            let report = try XCTUnwrap(HookLifecycleReport(
                sessionID: SessionID(),
                event: event,
                payload: ["cwd": "/Users/someone/repo/app/.git-worktrees/feature"]
            ))

            XCTAssertEqual(
                report.workingDirectory,
                "/Users/someone/repo/app/.git-worktrees/feature",
                "\(event.rawValue) dropped the directory it was carrying"
            )
        }
    }

    /// Absent and empty are the same fact — the report named no directory — and both must read
    /// as *unknown*. A runtime with no lifecycle hooks and a user who has switched reporting off
    /// both land here, and neither is evidence that a chat has come back to its own checkout.
    func testAPayloadNamingNoDirectoryReportsNone() throws {
        for payload in [[:], ["cwd": ""]] as [[String: Any]] {
            let report = try XCTUnwrap(HookLifecycleReport(
                sessionID: SessionID(),
                event: .turnFinished,
                payload: payload
            ))

            XCTAssertNil(report.workingDirectory)
        }
    }

    // MARK: - Classification

    func testWorkingInsideTheOwnedCheckoutIsNotDrift() throws {
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let tracker = makeTracker()

        tracker.observe(report(session.id, cwd: ownedPath + "/deep/inside"))

        try waitForClassification(of: session.id, in: tracker)
        XCTAssertEqual(tracker.drift(forSessionID: session.id), .none)
    }

    /// A reported directory is routinely several levels *inside* a checkout, and the move that
    /// follows must be asked for at the root — `validate` refuses anything else. This is the
    /// case the real defect was found in: the drifting chats reported paths like
    /// `…/worktrees/x/iOS/App/Source/Coordinators`, never the worktree root.
    func testASubdirectoryOfASiblingResolvesToThatSiblingsRoot() throws {
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let sibling = siblingCheckout()
        let tracker = makeTracker(resolving: [ownedPath: ownedCheckout, sibling.root: sibling])

        tracker.observe(report(session.id, cwd: sibling.root + "/iOS/App/Source"))

        try waitForClassification(of: session.id, in: tracker)
        guard case .siblingCheckout(let observed) = tracker.drift(forSessionID: session.id) else {
            return XCTFail("expected a sibling checkout, got \(tracker.drift(forSessionID: session.id))")
        }
        XCTAssertEqual(observed.root, sibling.root)
        XCTAssertEqual(observed.branch, "feature/elsewhere")
    }

    func testAnotherRepositoryIsUnrelatedRatherThanASibling() throws {
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let foreign = ObservedCheckout(
            root: "/elsewhere/other",
            worktreeIdentity: "/elsewhere/other/.git",
            repositoryIdentity: "/elsewhere/other/.git",
            branch: "main",
            displayName: "other"
        )
        let tracker = makeTracker(resolving: [ownedPath: ownedCheckout, foreign.root: foreign])

        tracker.observe(report(session.id, cwd: foreign.root))

        try waitForClassification(of: session.id, in: tracker)
        XCTAssertEqual(
            tracker.drift(forSessionID: session.id),
            .unrelated(path: foreign.root)
        )
    }

    func testADirectoryOutsideAnyRepositoryIsUnrelated() throws {
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let tracker = makeTracker(resolving: [ownedPath: ownedCheckout])

        tracker.observe(report(session.id, cwd: "/tmp/scratch"))

        try waitForClassification(of: session.id, in: tracker)
        XCTAssertEqual(tracker.drift(forSessionID: session.id), .unrelated(path: "/tmp/scratch"))
    }

    /// A terminal runtime need not implement lifecycle cwd hooks for the host to see the real
    /// child process it spawned. This is the raw-Git safety net: the model can create and use an
    /// ordinary worktree without knowing any Threading-specific command.
    func testAChildProcessWorkingInASiblingCheckoutIsDriftWithoutLifecycleCapability() throws {
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .grok))
        let sibling = siblingCheckout()
        let tracker = makeTracker(resolving: [ownedPath: ownedCheckout, sibling.root: sibling])

        tracker.observeProcessWorkingDirectories(
            [ownedPath, sibling.root + "/Sources/Feature"],
            sessionID: session.id
        )

        try waitForClassification(of: session.id, in: tracker)
        XCTAssertEqual(tracker.drift(forSessionID: session.id), .siblingCheckout(sibling))

        // A later tool back in the owned checkout is equally concrete process evidence. It must
        // retire the old marker, especially under Always Ask where the user may leave the move
        // offer unanswered while the agent comes home on its own.
        tracker.observeProcessWorkingDirectories([ownedPath], sessionID: session.id)
        XCTAssertEqual(tracker.drift(forSessionID: session.id), .none)
    }

    /// Two sibling checkouts active under one agent root are real evidence but not a unique
    /// destination. Picking whichever process happened to be sampled first would move the chat
    /// nondeterministically, so the observer leaves ownership alone.
    func testChildProcessObservationRequiresOneUnambiguousSibling() throws {
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let first = siblingCheckout()
        let secondRoot = root.appendingPathComponent("second-sibling").path
        let second = ObservedCheckout(
            root: secondRoot,
            worktreeIdentity: ownedPath + "/.git/worktrees/second-sibling",
            repositoryIdentity: ownedPath + "/.git",
            branch: "feature/second",
            displayName: "second-sibling"
        )
        let tracker = makeTracker(resolving: [
            ownedPath: ownedCheckout,
            first.root: first,
            second.root: second
        ])

        tracker.observeProcessWorkingDirectories(
            [first.root + "/one", second.root + "/two"],
            sessionID: session.id
        )

        try waitForClassification(of: session.id, in: tracker)
        XCTAssertEqual(tracker.drift(forSessionID: session.id), .none)
    }

    /// The process-table half has a fixed retained bound even when a build fans out. Newest
    /// children win, and walking nested parentage neither loses grandchildren nor loops on a
    /// malformed cycle.
    func testProcessSnapshotKeepsOnlyTheNewestBoundedDescendants() {
        let rootPID: pid_t = 100
        var table: [pid_t: ProcessSummary] = [:]
        for offset in 1...40 {
            let pid = rootPID + pid_t(offset)
            table[pid] = process(pid: pid, parent: rootPID, order: UInt64(offset))
        }
        table[500] = process(pid: 500, parent: 140, order: 50)
        table[rootPID] = process(pid: rootPID, parent: 601, order: 0)
        table[601] = process(pid: 601, parent: rootPID, order: 1)

        let candidates = SessionExecutionProcessSnapshot(table: table)
            .candidateProcessIDs(below: rootPID, limit: 4)

        XCTAssertEqual(candidates, [500, 140, 139, 138])
    }

    // MARK: - Cost

    /// The load-bearing property. These reports are the highest-frequency callback in the app
    /// that carries a path, so an unchanged directory must not reach git at all.
    func testRepeatingTheSameDirectoryResolvesNothing() throws {
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        var resolutions = 0
        let tracker = makeTracker(resolving: [ownedPath: ownedCheckout]) { resolutions += 1 }

        tracker.observe(report(session.id, cwd: ownedPath))
        try waitForClassification(of: session.id, in: tracker)
        let afterFirst = resolutions

        for _ in 0..<50 {
            tracker.observe(report(session.id, cwd: ownedPath))
        }

        XCTAssertEqual(resolutions, afterFirst)
        XCTAssertGreaterThan(afterFirst, 0)
        XCTAssertEqual(tracker.classificationsApplied, 1)
    }

    /// A report that names no directory is a runtime without the capability, or a user with
    /// lifecycle reporting switched off. Both mean *unknown*, and unknown must not be recorded
    /// as "came home" — that would have the card and the row assert something nothing said.
    func testAReportWithNoDirectoryLeavesTheLastClassificationAlone() throws {
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let sibling = siblingCheckout()
        let tracker = makeTracker(resolving: [ownedPath: ownedCheckout, sibling.root: sibling])

        tracker.observe(report(session.id, cwd: sibling.root))
        try waitForClassification(of: session.id, in: tracker)

        tracker.observe(report(session.id, cwd: nil))

        guard case .siblingCheckout = tracker.drift(forSessionID: session.id) else {
            return XCTFail("a silent report cleared a classification it said nothing about")
        }
    }

    /// A managed workspace runs in a worktree Threading made for it, so every report it sends
    /// is drift by construction and every resulting move would be refused. It is excluded
    /// before the resolution rather than after it.
    func testAManagedWorkspaceSessionIsNeverResolved() throws {
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let managed = root.appendingPathComponent("managed").path
        store.update(sessionID: session.id) {
            $0.managedWorkspace = ManagedWorkspace(
                repositoryRoot: self.ownedPath,
                sourceCheckoutPath: self.ownedPath,
                worktreeRoot: managed,
                executionPath: managed,
                targetBranch: "main",
                baseCommit: String(repeating: "b", count: 40),
                delivery: .mergeAndCleanUp,
                publication: nil,
                remoteBranch: nil,
                state: .active
            )
        }
        var resolutions = 0
        let tracker = makeTracker(resolving: [:]) { resolutions += 1 }

        tracker.observe(report(session.id, cwd: "/anywhere/at/all"))

        XCTAssertEqual(resolutions, 0)
        XCTAssertEqual(tracker.classificationsApplied, 0)
        XCTAssertEqual(tracker.drift(forSessionID: session.id), .none)
    }

    /// Ownership moving is what makes a stored reading stale, so the coordinator drops it. A
    /// chat that arrives where it was already working must stop being marked as elsewhere.
    func testForgettingClearsTheClassification() throws {
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let sibling = siblingCheckout()
        let tracker = makeTracker(resolving: [ownedPath: ownedCheckout, sibling.root: sibling])

        tracker.observe(report(session.id, cwd: sibling.root))
        try waitForClassification(of: session.id, in: tracker)

        tracker.forget(sessionID: session.id)

        XCTAssertEqual(tracker.drift(forSessionID: session.id), .none)
    }

    // MARK: - Fixture

    private var ownedPath: String { project.folderPath }

    private var ownedCheckout: ObservedCheckout {
        ObservedCheckout(
            root: ownedPath,
            worktreeIdentity: ownedPath + "/.git",
            repositoryIdentity: ownedPath + "/.git",
            branch: "main",
            displayName: "main"
        )
    }

    private func siblingCheckout() -> ObservedCheckout {
        ObservedCheckout(
            root: root.appendingPathComponent("sibling").path,
            worktreeIdentity: ownedPath + "/.git/worktrees/sibling",
            repositoryIdentity: ownedPath + "/.git",
            branch: "feature/elsewhere",
            displayName: "sibling"
        )
    }

    private func process(
        pid: pid_t,
        parent: pid_t,
        order: UInt64
    ) -> ProcessSummary {
        ProcessSummary(
            pid: pid,
            parentPid: parent,
            command: "fixture",
            state: .running,
            startTime: ProcessStartTime(seconds: order, microseconds: 0)
        )
    }

    /// Resolves by longest matching prefix, the way the real resolver resolves a subdirectory
    /// back to the checkout containing it.
    private func makeTracker(
        resolving table: [String: ObservedCheckout]? = nil,
        onResolve: (@Sendable () -> Void)? = nil
    ) -> SessionExecutionLocusTracker {
        let table = table ?? [ownedPath: ownedCheckout]
        return SessionExecutionLocusTracker(
            projects: store,
            resolutionQueue: DispatchQueue(label: "SessionExecutionLocusTests")
        ) { path in
            onResolve?()
            return table
                .filter { path == $0.key || path.hasPrefix($0.key + "/") }
                .max { $0.key.count < $1.key.count }?
                .value
        }
    }

    private func report(_ sessionID: SessionID, cwd: String?) -> HookLifecycleReport {
        var payload: [String: Any] = ["session_id": sessionID.uuidString.lowercased()]
        if let cwd { payload["cwd"] = cwd }
        return HookLifecycleReport(
            sessionID: sessionID,
            event: .turnStarted,
            payload: payload
        )!
    }

    /// The resolution is deliberately off the main actor, so the assertion has to wait for it.
    private func waitForClassification(
        of sessionID: SessionID,
        in tracker: SessionExecutionLocusTracker,
        beyond previous: Int = 0
    ) throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            if tracker.classificationsApplied > previous { return }
        }
        XCTFail("the reported directory was never classified")
    }
}
