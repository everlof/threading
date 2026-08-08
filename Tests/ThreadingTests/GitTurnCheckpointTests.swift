import XCTest
@testable import Threading

/// Durable turn attribution, against real repositories and real refs.
///
/// These tests deliberately inspect the ordinary index and worktree around capture. A mock git
/// process could prove the argv, but not the safety property that the alternate-index snapshot
/// leaves the user's staging state and files untouched.
@MainActor
final class GitTurnCheckpointTests: XCTestCase {

    private var container: URL!
    private var root: URL!
    private var metadata: URL!
    private var projectID: ProjectID!

    override func setUp() async throws {
        try await super.setUp()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-turn-checkpoints-\(UUID().uuidString)", isDirectory: true)
        root = container.appendingPathComponent("repository", isDirectory: true)
        metadata = container.appendingPathComponent("metadata", isDirectory: true)
        projectID = ProjectID()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try initializeRepository(at: root, withCommit: true)
    }

    override func tearDown() async throws {
        if let container { try? FileManager.default.removeItem(at: container) }
        GitInfo.invalidateCache(for: root?.path ?? "")
        root = nil
        metadata = nil
        container = nil
        projectID = nil
        try await super.tearDown()
    }

    // MARK: - Exact Attribution

    func testNativeAdmissionGatePublishesBeforeRefBeforeCallingTransport() throws {
        let session = SessionID()
        let store = makeStore()
        let admitted = expectation(description: "native transport admitted")
        var transportCheckpoint: GitTurnCheckpoint?

        NativeGitTurnAdmission.admit(
            store: store,
            sessionID: session,
            userTurnID: ConversationMessageID().wireValue,
            transport: { checkpointID in
                transportCheckpoint = checkpointID.flatMap(store.checkpoint(id:))
                try? self.write("native agent change\n", to: "native.txt")
                return true
            },
            completion: { didAdmit, _ in
                XCTAssertTrue(didAdmit)
                admitted.fulfill()
            }
        )

        wait(for: [admitted], timeout: 5)
        let checkpoint = try XCTUnwrap(transportCheckpoint)
        XCTAssertEqual(checkpoint.status, .inProgress)
        XCTAssertEqual(
            try output("rev-parse", "--verify", try XCTUnwrap(checkpoint.beforeRef) + "^{tree}"),
            checkpoint.beforeTreeHash
        )

        let completed = try finish(store, session: session)
        XCTAssertTrue(try rawDiff(completed, in: root).contains("native.txt"))
    }

    func testCompleteTurnKeepsExactEndpointsAfterLaterUserEditsAndPreservesIndex() throws {
        try write("delete me\n", to: "deleted.txt")
        try write("index base\n", to: "staged.txt")
        try git("add", "deleted.txt", "staged.txt")
        try git("commit", "--quiet", "--message", "fixture files")

        try write("ignored\n", to: ".gitignore")
        try git("add", ".gitignore")
        try git("commit", "--quiet", "--message", "ignore rules")

        // These are the user's pre-turn state. The staged and untracked bytes belong in the
        // baseline, but neither is attributable to the agent.
        try write("staged before turn\n", to: "staged.txt")
        try git("add", "staged.txt")
        try write("untracked before turn\n", to: "existing-untracked.txt")
        try write("never checkpoint this\n", to: "ignored")

        let indexBefore = try output("ls-files", "--stage")
        let stagedDiffBefore = try output("diff", "--cached")
        let session = SessionID()
        let store = makeStore()
        let checkpointID = try prepare(store, session: session, userTurnID: "user-stable-id")

        XCTAssertEqual(try output("ls-files", "--stage"), indexBefore)
        XCTAssertEqual(try output("diff", "--cached"), stagedDiffBefore)
        XCTAssertEqual(try read("existing-untracked.txt"), "untracked before turn\n")

        // The provider's turn changes every supported shape.
        try write("agent tracked final\n", to: "tracked.txt")
        try write("agent staged-file final\n", to: "staged.txt")
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.txt"))
        try write("agent changed untracked\n", to: "existing-untracked.txt")
        try write("agent new untracked\n", to: "agent-new.txt")

        let completed = try finish(store, session: session, assistantTurnID: "assistant-stable-id")
        XCTAssertEqual(completed.id, checkpointID)
        XCTAssertEqual(completed.userTurnID, "user-stable-id")
        XCTAssertEqual(completed.assistantTurnID, "assistant-stable-id")
        XCTAssertEqual(completed.status, .complete)
        XCTAssertTrue(completed.beforeRef.map(GitTurnCheckpointRefs.isOwned) == true)
        XCTAssertTrue(completed.afterRef.map(GitTurnCheckpointRefs.isOwned) == true)
        XCTAssertEqual(try output("ls-files", "--stage"), indexBefore)
        XCTAssertEqual(try output("diff", "--cached"), stagedDiffBefore)

        // Later user work must not move Turn 1's endpoint.
        try write("later user edit\n", to: "tracked.txt")
        try write("later user file\n", to: "later-user.txt")

        let patch = try rawDiff(completed, in: root)
        XCTAssertTrue(patch.contains("agent tracked final"))
        XCTAssertTrue(patch.contains("agent staged-file final"))
        XCTAssertTrue(patch.contains("deleted.txt"))
        XCTAssertTrue(patch.contains("agent changed untracked"))
        XCTAssertTrue(patch.contains("agent new untracked"))
        XCTAssertFalse(patch.contains("later user edit"))
        XCTAssertFalse(patch.contains("later-user.txt"))
        XCTAssertFalse(patch.contains("never checkpoint this"), "ignored files stay outside snapshots")

        let endpoint = try endpointPair(path: "tracked.txt", checkpoint: completed, in: root)
        XCTAssertEqual(String(data: try XCTUnwrap(endpoint.old), encoding: .utf8), "base\n")
        XCTAssertEqual(String(data: try XCTUnwrap(endpoint.new), encoding: .utf8), "agent tracked final\n")
        XCTAssertEqual(endpoint.oldTitle, "Turn Start")
        XCTAssertEqual(endpoint.newTitle, "Turn End")
        XCTAssertEqual(try output("ls-files", "--stage"), indexBefore)
        XCTAssertEqual(try output("diff", "--cached"), stagedDiffBefore)
        XCTAssertEqual(try read("tracked.txt"), "later user edit\n")
        XCTAssertEqual(try read("later-user.txt"), "later user file\n")
        XCTAssertEqual(try read("ignored"), "never checkpoint this\n")
    }

    func testUserEditsBetweenTurnsBelongToNeitherAdjacentAgentTurn() throws {
        let session = SessionID()
        let store = makeStore()

        _ = try prepare(store, session: session)
        try write("agent one\n", to: "turn-one.txt")
        let first = try finish(store, session: session)

        try write("between turns\n", to: "user-between.txt")

        _ = try prepare(store, session: session)
        try write("agent two\n", to: "turn-two.txt")
        let second = try finish(store, session: session)

        let firstPatch = try rawDiff(first, in: root)
        let secondPatch = try rawDiff(second, in: root)
        XCTAssertTrue(firstPatch.contains("turn-one.txt"))
        XCTAssertFalse(firstPatch.contains("user-between.txt"))
        XCTAssertTrue(secondPatch.contains("turn-two.txt"))
        XCTAssertFalse(secondPatch.contains("user-between.txt"))
        XCTAssertEqual(first.ordinal, 1)
        XCTAssertEqual(second.ordinal, 2)
    }

    // MARK: - Persistence and Failure Honesty

    func testCompletedCheckpointSurvivesStoreRelaunch() throws {
        let session = SessionID()
        let firstStore = makeStore()
        _ = try prepare(firstStore, session: session)
        try write("durable\n", to: "durable.txt")
        let completed = try finish(firstStore, session: session)

        let relaunched = makeStore()
        let restored = try XCTUnwrap(relaunched.latestCheckpoint(forSessionID: session))
        XCTAssertEqual(restored.id, completed.id)
        XCTAssertEqual(restored.projectID, completed.projectID)
        XCTAssertEqual(restored.sessionID, completed.sessionID)
        XCTAssertEqual(restored.ordinal, completed.ordinal)
        XCTAssertEqual(restored.userTurnID, completed.userTurnID)
        XCTAssertEqual(restored.assistantTurnID, completed.assistantTurnID)
        XCTAssertEqual(restored.repositoryIdentity, completed.repositoryIdentity)
        XCTAssertEqual(restored.worktreeIdentity, completed.worktreeIdentity)
        XCTAssertEqual(restored.beforeRef, completed.beforeRef)
        XCTAssertEqual(restored.afterRef, completed.afterRef)
        XCTAssertEqual(restored.beforeTreeHash, completed.beforeTreeHash)
        XCTAssertEqual(restored.afterTreeHash, completed.afterTreeHash)
        XCTAssertEqual(restored.status, .complete)
        XCTAssertLessThan(abs(restored.requestedAt.timeIntervalSince(completed.requestedAt)), 1)
        XCTAssertLessThan(
            abs(try XCTUnwrap(restored.completedAt).timeIntervalSince(
                try XCTUnwrap(completed.completedAt)
            )),
            1
        )
        XCTAssertTrue(try rawDiff(restored, in: root).contains("durable.txt"))
    }

    func testRelaunchMarksTurnWithoutFinalCheckpointIncomplete() throws {
        let session = SessionID()
        let firstStore = makeStore()
        _ = try prepare(firstStore, session: session)

        let relaunched = makeStore()
        let interrupted = try XCTUnwrap(relaunched.latestCheckpoint(forSessionID: session))
        XCTAssertEqual(interrupted.status, .incomplete)
        XCTAssertNotNil(interrupted.beforeTreeHash)
        XCTAssertNil(interrupted.afterTreeHash)
        XCTAssertFalse(interrupted.canPresentDiff)
    }

    func testReportingProcessExitWithoutFinalBoundaryMarksTurnIncomplete() throws {
        let session = SessionID()
        let store = makeStore()
        _ = try prepare(store, session: session)

        store.noteActivity(.working, sessionID: session, hasAuthoritativeReporting: true)
        store.noteActivity(.idle, sessionID: session, hasAuthoritativeReporting: true)

        let interrupted = try XCTUnwrap(store.latestCheckpoint(forSessionID: session))
        XCTAssertEqual(interrupted.status, .incomplete)
        XCTAssertNotNil(interrupted.beforeTreeHash)
        XCTAssertNil(interrupted.afterTreeHash)
        XCTAssertFalse(interrupted.canPresentDiff)
    }

    func testFailedNewCaptureNeverReusesOlderCheckpoint() throws {
        let session = SessionID()
        var contextAvailable = true
        let context = captureContext(for: root)
        let store = GitTurnBaselineStore(directory: metadata) { _ in
            contextAvailable ? context : nil
        }

        let firstID = try prepare(store, session: session)
        try write("first\n", to: "first.txt")
        _ = try finish(store, session: session)

        contextAvailable = false
        let failedID = try prepare(store, session: session)
        let latest = try XCTUnwrap(store.latestCheckpoint(forSessionID: session))
        XCTAssertNotEqual(failedID, firstID)
        XCTAssertEqual(latest.id, failedID)
        XCTAssertEqual(latest.ordinal, 2)
        XCTAssertEqual(latest.status, .beforeCaptureFailed)
        XCTAssertFalse(latest.canPresentDiff)
        XCTAssertEqual(store.checkpoints(forSessionID: session).count, 2)
    }

    func testMissingOrMismatchedCheckpointIsRefused() throws {
        let session = SessionID()
        let store = makeStore()
        _ = try prepare(store, session: session)
        try write("agent\n", to: "agent.txt")
        let completed = try finish(store, session: session)

        let other = container.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try initializeRepository(at: other, withCommit: true)
        XCTAssertEqual(try diffFailure(completed, in: other), .checkpointRepositoryMismatch)

        try git("update-ref", "-d", try XCTUnwrap(completed.beforeRef))
        XCTAssertEqual(try diffFailure(completed, in: root), .checkpointMissing)
    }

    func testFinalCaptureFailureRemainsAttachedToItsTurn() throws {
        let session = SessionID()
        let store = makeStore()
        let checkpointID = try prepare(store, session: session)
        GitInfo.invalidateCache(for: root.path)
        try FileManager.default.moveItem(
            at: root,
            to: container.appendingPathComponent("repository-moved", isDirectory: true)
        )

        let failed = try finish(store, session: session)
        XCTAssertEqual(failed.id, checkpointID)
        XCTAssertEqual(failed.status, .finalCaptureFailed)
        XCTAssertFalse(failed.canPresentDiff)
    }

    func testRetriedProviderAdmissionIsIdempotentButANewTurnMarksTheOldOneIncomplete() throws {
        let session = SessionID()
        let store = makeStore()
        let first = try prepare(store, session: session, providerTurnID: "provider-turn-1")
        let retried = try prepare(store, session: session, providerTurnID: "provider-turn-1")
        XCTAssertEqual(retried, first)
        XCTAssertEqual(store.checkpoints(forSessionID: session).count, 1)

        let second = try prepare(store, session: session, providerTurnID: "provider-turn-2")
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(store.checkpoint(id: first)?.status, .incomplete)
        XCTAssertEqual(store.activeCheckpoint(forSessionID: session)?.id, second)
    }

    func testConcurrentRetryJoinsTheSameProviderAdmissionBarrier() throws {
        let session = SessionID()
        let store = makeStore()
        let bothReady = expectation(description: "both provider retries admitted")
        bothReady.expectedFulfillmentCount = 2
        var checkpointIDs: [GitTurnCheckpointID?] = []

        for _ in 0..<2 {
            store.prepareTurn(
                sessionID: session,
                providerTurnID: "provider-turn-retry"
            ) {
                checkpointIDs.append($0)
                bothReady.fulfill()
            }
        }

        wait(for: [bothReady], timeout: 5)
        XCTAssertEqual(checkpointIDs.count, 2)
        XCTAssertEqual(checkpointIDs[0], checkpointIDs[1])
        XCTAssertEqual(store.checkpoints(forSessionID: session).count, 1)
    }

    // MARK: - Repository Shapes and Concurrency

    func testUnbornRepositoryCapturesUntrackedTurnExactly() throws {
        let unborn = container.appendingPathComponent("unborn", isDirectory: true)
        let unbornMetadata = container.appendingPathComponent("unborn-metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unbornMetadata, withIntermediateDirectories: true)
        try initializeRepository(at: unborn, withCommit: false)
        try "before\n".write(
            to: unborn.appendingPathComponent("only.txt"), atomically: true, encoding: .utf8
        )

        let context = captureContext(for: unborn)
        let store = GitTurnBaselineStore(directory: unbornMetadata) { _ in context }
        let session = SessionID()
        _ = try prepare(store, session: session)
        try "after\n".write(
            to: unborn.appendingPathComponent("only.txt"), atomically: true, encoding: .utf8
        )
        let checkpoint = try finish(store, session: session)

        let patch = try rawDiff(checkpoint, in: unborn)
        XCTAssertTrue(patch.contains("-before"))
        XCTAssertTrue(patch.contains("+after"))
        XCTAssertTrue(try output("status", "--porcelain", in: unborn).contains("?? only.txt"))
    }

    func testConcurrentSessionsInOneRepositoryPublishDisjointRefs() throws {
        let firstSession = SessionID()
        let secondSession = SessionID()
        let store = makeStore()
        let firstReady = expectation(description: "first before")
        let secondReady = expectation(description: "second before")
        var firstID: GitTurnCheckpointID?
        var secondID: GitTurnCheckpointID?

        store.prepareTurn(sessionID: firstSession) { firstID = $0; firstReady.fulfill() }
        store.prepareTurn(sessionID: secondSession) { secondID = $0; secondReady.fulfill() }
        wait(for: [firstReady, secondReady], timeout: 20)

        let first = try XCTUnwrap(store.checkpoint(id: try XCTUnwrap(firstID)))
        let second = try XCTUnwrap(store.checkpoint(id: try XCTUnwrap(secondID)))
        XCTAssertEqual(first.status, .inProgress)
        XCTAssertEqual(second.status, .inProgress)
        XCTAssertNotEqual(first.beforeRef, second.beforeRef)
        XCTAssertTrue(try XCTUnwrap(first.beforeRef).contains(firstSession.uuidString.lowercased()))
        XCTAssertTrue(try XCTUnwrap(second.beforeRef).contains(secondSession.uuidString.lowercased()))

        try write("shared change\n", to: "concurrent.txt")
        XCTAssertEqual(try finish(store, session: firstSession).status, .complete)
        XCTAssertEqual(try finish(store, session: secondSession).status, .complete)
    }

    func testManagedWorktreeCheckpointCanBeReadThroughMainCheckout() throws {
        let worktree = container.appendingPathComponent("managed", isDirectory: true)
        try git("worktree", "add", "--quiet", "--detach", worktree.path, "HEAD")
        let mainLocation = try XCTUnwrap(GitInfo.worktreeLocation(for: root.path))
        let managedLocation = try XCTUnwrap(GitInfo.worktreeLocation(for: worktree.path))
        XCTAssertEqual(mainLocation.repositoryIdentity, managedLocation.repositoryIdentity)
        XCTAssertNotEqual(mainLocation.worktreeIdentity, managedLocation.worktreeIdentity)

        let context = captureContext(for: worktree, logicalRoot: root)
        let store = GitTurnBaselineStore(directory: metadata) { _ in context }
        let session = SessionID()
        _ = try prepare(store, session: session)
        try "managed change\n".write(
            to: worktree.appendingPathComponent("managed.txt"), atomically: true, encoding: .utf8
        )
        let checkpoint = try finish(store, session: session)

        GitInfo.invalidateCache(for: worktree.path)
        try git("worktree", "remove", "--force", worktree.path)
        XCTAssertEqual(store.repositoryRoot(for: checkpoint, preferredPath: root.path), root)
        XCTAssertTrue(try rawDiff(checkpoint, in: root).contains("managed.txt"))
    }

    // MARK: - Bounded, Namespaced Cleanup

    func testRetentionAndPermanentDeletionRemoveOnlyOwnedRefs() throws {
        try git("branch", "user-branch")
        try git("tag", "user-tag")
        let head = try output("rev-parse", "HEAD")
        try git("update-ref", "refs/remotes/origin/user-remote", head)

        let session = SessionID()
        let store = GitTurnBaselineStore(
            directory: metadata,
            maximumPerSession: 2,
            maximumTotal: 2
        ) { [context = captureContext(for: root)] _ in context }

        for ordinal in 1...3 {
            _ = try prepare(store, session: session)
            try write("turn \(ordinal)\n", to: "retained.txt")
            _ = try finish(store, session: session)
        }

        try waitUntil("retention garbage collection") {
            store.checkpoints(forSessionID: session).count == 2
                && (try? self.ownedRefs().count) == 4
        }
        XCTAssertEqual(store.checkpoints(forSessionID: session).map(\.ordinal), [2, 3])

        // Archive/Restore keeps the session in ProjectStore's live-id set and therefore keeps
        // its complete checkpoint unit unchanged.
        store.retainOnly(sessionIDs: [session])
        XCTAssertEqual(store.checkpoints(forSessionID: session).map(\.ordinal), [2, 3])
        XCTAssertEqual(try ownedRefs().count, 4)

        store.remove(sessionID: session)
        try waitUntil("permanent deletion garbage collection") {
            store.checkpoints(forSessionID: session).isEmpty
                && (try? self.ownedRefs().isEmpty) == true
        }
        XCTAssertEqual(try output("show-ref", "--verify", "refs/heads/user-branch"),
                       "\(head) refs/heads/user-branch")
        XCTAssertEqual(try output("show-ref", "--verify", "refs/tags/user-tag"),
                       "\(head) refs/tags/user-tag")
        XCTAssertEqual(try output("show-ref", "--verify", "refs/remotes/origin/user-remote"),
                       "\(head) refs/remotes/origin/user-remote")
        XCTAssertTrue(makeStore().checkpoints(forSessionID: session).isEmpty)
    }

    func testStartupOrphanSweepDeletesOnlyUnreferencedOwnedRefs() throws {
        let session = SessionID()
        let store = makeStore()
        _ = try prepare(store, session: session)
        try write("kept\n", to: "kept.txt")
        let kept = try finish(store, session: session)

        let orphanRef = GitTurnCheckpointRefs.pair(
            sessionID: SessionID(),
            checkpointID: GitTurnCheckpointID()
        ).before
        try git("update-ref", orphanRef, try output("rev-parse", "HEAD"))
        try git("branch", "user-kept-by-orphan-sweep")

        store.garbageCollectOrphanedRefs(in: [root])
        try waitUntil("startup orphan collection") {
            (try? self.output(
                "for-each-ref",
                "--format=%(refname)",
                GitTurnCheckpointRefs.prefix
            ).contains(orphanRef)) == false
        }
        XCTAssertEqual(
            try output("rev-parse", "--verify", try XCTUnwrap(kept.beforeRef) + "^{tree}"),
            kept.beforeTreeHash
        )
        XCTAssertFalse(
            try output("show-ref", "--verify", "refs/heads/user-kept-by-orphan-sweep").isEmpty
        )
    }

    func testRefNamespaceRejectsLookalikesAndUserRefs() {
        let session = SessionID()
        let checkpoint = GitTurnCheckpointID()
        let refs = GitTurnCheckpointRefs.pair(sessionID: session, checkpointID: checkpoint)
        XCTAssertTrue(GitTurnCheckpointRefs.isOwned(refs.before))
        XCTAssertTrue(GitTurnCheckpointRefs.isOwned(refs.after))
        XCTAssertFalse(GitTurnCheckpointRefs.isOwned("refs/heads/main"))
        XCTAssertFalse(GitTurnCheckpointRefs.isOwned(GitTurnCheckpointRefs.prefix + "before"))
        XCTAssertFalse(GitTurnCheckpointRefs.isOwned(refs.before + "/child"))
    }

    // MARK: - Helpers

    private func makeStore() -> GitTurnBaselineStore {
        GitTurnBaselineStore(directory: metadata) { [context = captureContext(for: root)] _ in
            context
        }
    }

    private func captureContext(for checkout: URL, logicalRoot: URL? = nil) -> GitTurnCaptureContext {
        let location = GitInfo.worktreeLocation(for: checkout.path)!
        return GitTurnCaptureContext(
            projectID: projectID,
            logicalProjectPath: (logicalRoot ?? checkout).path,
            root: location.root,
            repositoryIdentity: location.repositoryIdentity,
            worktreeIdentity: location.worktreeIdentity
        )
    }

    private func prepare(
        _ store: GitTurnBaselineStore,
        session: SessionID,
        userTurnID: String? = nil,
        providerTurnID: String? = nil
    ) throws -> GitTurnCheckpointID {
        let captured = expectation(description: "turn start")
        var checkpointID: GitTurnCheckpointID?
        store.prepareTurn(
            sessionID: session,
            userTurnID: userTurnID,
            providerTurnID: providerTurnID
        ) {
            checkpointID = $0
            captured.fulfill()
        }
        wait(for: [captured], timeout: 20)
        return try XCTUnwrap(checkpointID)
    }

    private func finish(
        _ store: GitTurnBaselineStore,
        session: SessionID,
        assistantTurnID: String? = nil
    ) throws -> GitTurnCheckpoint {
        let captured = expectation(description: "turn end")
        var checkpoint: GitTurnCheckpoint?
        store.finishTurn(sessionID: session, assistantTurnID: assistantTurnID) {
            checkpoint = $0
            captured.fulfill()
        }
        wait(for: [captured], timeout: 20)
        return try XCTUnwrap(checkpoint)
    }

    private func rawDiff(_ checkpoint: GitTurnCheckpoint, in checkout: URL) throws -> String {
        let result: Result<String, GitFailure> = try perform { completion in
            GitReviewReader.rawDiff(.turnCheckpoint(checkpoint), in: checkout, completion: completion)
        }
        switch result {
        case .success(let patch): return patch
        case .failure(let failure): throw failure
        }
    }

    private func diffFailure(_ checkpoint: GitTurnCheckpoint, in checkout: URL) throws -> GitFailure {
        let result: Result<[GitFileDiff], GitFailure> = try perform { completion in
            GitReviewReader.diff(.turnCheckpoint(checkpoint), in: checkout, completion: completion)
        }
        switch result {
        case .success:
            XCTFail("expected checkpoint diff failure")
            return .gitFailed("")
        case .failure(let failure):
            return failure
        }
    }

    private func endpointPair(
        path: String,
        checkpoint: GitTurnCheckpoint,
        in checkout: URL
    ) throws -> GitEndpointFilePair {
        let result: Result<GitEndpointFilePair, GitFailure> = try perform { completion in
            GitReviewReader.endpointFilePair(
                path: path,
                request: .turnCheckpoint(checkpoint),
                in: checkout,
                completion: completion
            )
        }
        return try result.get()
    }

    private func perform<Value>(
        _ work: (@escaping @MainActor @Sendable (Result<Value, GitFailure>) -> Void) -> Void
    ) throws -> Result<Value, GitFailure> {
        let completed = expectation(description: "git operation")
        var result: Result<Value, GitFailure>?
        work { outcome in result = outcome; completed.fulfill() }
        wait(for: [completed], timeout: 20)
        return try XCTUnwrap(result)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 20,
        condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)")
    }

    private func ownedRefs() throws -> [String] {
        try output("for-each-ref", "--format=%(refname)", GitTurnCheckpointRefs.prefix)
            .split(separator: "\n")
            .map(String.init)
    }

    private func initializeRepository(at checkout: URL, withCommit: Bool) throws {
        _ = try output("init", "--quiet", in: checkout)
        _ = try output("config", "user.email", "tests@threading.codes", in: checkout)
        _ = try output("config", "user.name", "Threading Tests", in: checkout)
        _ = try output("config", "commit.gpgsign", "false", in: checkout)
        guard withCommit else { return }
        try "base\n".write(
            to: checkout.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8
        )
        _ = try output("add", "tracked.txt", in: checkout)
        _ = try output("commit", "--quiet", "--message", "initial", in: checkout)
    }

    private func write(_ contents: String, to name: String) throws {
        try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        try output(arguments, in: root)
    }

    private func output(_ arguments: String..., in checkout: URL? = nil) throws -> String {
        try output(arguments, in: checkout ?? root)
    }

    private func output(_ arguments: [String], in checkout: URL) throws -> String {
        GitDiffParser.decode(try GitProcess.run(arguments, in: checkout))
            .trimmingCharacters(in: .newlines)
    }
}
