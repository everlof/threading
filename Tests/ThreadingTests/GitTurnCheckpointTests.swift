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

    /// The neutral floor's whole input: every path the turn changed, including the ones no tool
    /// could have named. A rename is two of them, because both names are files the turn touched.
    func testCheckpointChangedPathsNamesEveryFileTheTurnTouchedIncludingUnnamedOnes() throws {
        try write("moved\n", to: "renamed-from.txt")
        try git("add", "renamed-from.txt")
        try git("commit", "--quiet", "--message", "fixture")

        let session = SessionID()
        let store = makeStore()
        _ = try prepare(store, session: session)

        // A shell edit, a new file and a rename: none of these name themselves to any tool.
        try write("shell wrote this\n", to: "tracked.txt")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("nested"), withIntermediateDirectories: true
        )
        try write("generated\n", to: "nested/built.txt")
        try git("mv", "renamed-from.txt", "renamed-to.txt")

        let completed = try finish(store, session: session)
        XCTAssertEqual(
            try changedPaths(completed, in: root).sorted(),
            ["nested/built.txt", "renamed-from.txt", "renamed-to.txt", "tracked.txt"]
        )
    }

    /// The common turn: a question answered, nothing written. It must cost no process and say
    /// nothing, or every quiet turn would light the panel.
    func testACheckpointThatChangedNothingNamesNothing() throws {
        let session = SessionID()
        let store = makeStore()
        _ = try prepare(store, session: session)
        let completed = try finish(store, session: session)

        XCTAssertEqual(completed.beforeTreeHash, completed.afterTreeHash)
        XCTAssertEqual(try changedPaths(completed, in: root), [])
    }

    /// Paths come back relative to the directory they were asked from, and changes outside it are
    /// not mentioned. The observed floor writes into a trace whose paths are relative to the
    /// session's execution folder, which is not always the repository root.
    func testChangedPathsAreRelativeToTheDirectoryTheyWereAskedFrom() throws {
        let nested = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("base\n", to: "workspace/inside.txt")
        try git("add", "workspace/inside.txt")
        try git("commit", "--quiet", "--message", "nested fixture")

        let session = SessionID()
        let store = makeStore()
        _ = try prepare(store, session: session)
        try write("changed inside\n", to: "workspace/inside.txt")
        try write("changed outside\n", to: "tracked.txt")
        let completed = try finish(store, session: session)

        XCTAssertEqual(try changedPaths(completed, in: root).sorted(), ["tracked.txt", "workspace/inside.txt"])
        XCTAssertEqual(try changedPaths(completed, in: nested), ["inside.txt"])
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

    // MARK: - Observed Contention

    /// Two chats editing one checkout is not prevented, so the record has to admit it happened.
    /// The second chat here opens *and* closes entirely inside the first one's turn: by the time
    /// the first turn ends there is nothing in flight left for it to notice, which is why both
    /// sides are stamped at admission rather than at completion.
    func testOverlappingTurnsInOneCheckoutRecordEachOther() throws {
        let first = SessionID()
        let second = SessionID()
        let store = makeStore()

        _ = try prepare(store, session: first)
        _ = try prepare(store, session: second)
        try write("second chat change\n", to: "second-chat.txt")
        let secondTurn = try finish(store, session: second)
        try write("first chat change\n", to: "first-chat.txt")
        let firstTurn = try finish(store, session: first)

        XCTAssertEqual(firstTurn.overlappingSessionIDs, [second])
        XCTAssertEqual(secondTurn.overlappingSessionIDs, [first])
        // Attribution stays best effort and the comparison stays exact: the first turn's tree
        // pair still contains the other chat's file. Naming the contention is the whole fix.
        XCTAssertTrue(try rawDiff(firstTurn, in: root).contains("second-chat.txt"))
        XCTAssertEqual(
            makeStore().checkpoint(id: firstTurn.id)?.overlappingSessionIDs,
            [second],
            "an observed overlap is durable, not just in-memory"
        )
    }

    func testSequentialTurnsInOneCheckoutRecordNoOverlap() throws {
        let first = SessionID()
        let second = SessionID()
        let store = makeStore()

        _ = try prepare(store, session: first)
        try write("first chat change\n", to: "first-chat.txt")
        let firstTurn = try finish(store, session: first)
        _ = try prepare(store, session: second)
        try write("second chat change\n", to: "second-chat.txt")
        let secondTurn = try finish(store, session: second)

        XCTAssertNil(firstTurn.overlappingSessionIDs)
        XCTAssertNil(secondTurn.overlappingSessionIDs)
    }

    /// Same repository, different checkouts: neither turn's tree pair can contain the other's
    /// writes, so hedging there would be noise rather than honesty.
    func testOverlappingTurnsInSeparateWorktreesRecordNoOverlap() throws {
        let worktree = container.appendingPathComponent("second-worktree", isDirectory: true)
        try git("worktree", "add", "--quiet", "--detach", worktree.path, "HEAD")
        let mainContext = captureContext(for: root)
        let worktreeContext = captureContext(for: worktree, logicalRoot: root)
        XCTAssertEqual(mainContext.repositoryIdentity, worktreeContext.repositoryIdentity)
        XCTAssertNotEqual(mainContext.worktreeIdentity, worktreeContext.worktreeIdentity)

        let mainSession = SessionID()
        let worktreeSession = SessionID()
        let store = GitTurnBaselineStore(directory: metadata) { session in
            session == worktreeSession ? worktreeContext : mainContext
        }

        _ = try prepare(store, session: mainSession)
        _ = try prepare(store, session: worktreeSession)
        try write("main checkout change\n", to: "main-turn.txt")
        try "second checkout change\n".write(
            to: worktree.appendingPathComponent("worktree-turn.txt"),
            atomically: true,
            encoding: .utf8
        )
        let worktreeTurn = try finish(store, session: worktreeSession)
        let mainTurn = try finish(store, session: mainSession)

        XCTAssertNil(mainTurn.overlappingSessionIDs)
        XCTAssertNil(worktreeTurn.overlappingSessionIDs)
    }

    /// The field is additive, so a history written before it existed must still load — including
    /// the completed records `validate` holds to the strictest invariants.
    func testArchiveWrittenWithoutOverlapFieldLoadsAsNoObservedOverlap() throws {
        let first = SessionID()
        let second = SessionID()
        let store = makeStore()
        _ = try prepare(store, session: first)
        _ = try prepare(store, session: second)
        try write("shared\n", to: "shared.txt")
        let secondTurn = try finish(store, session: second)
        let firstTurn = try finish(store, session: first)
        XCTAssertNotNil(firstTurn.overlappingSessionIDs)

        try rewriteArchive(dropping: ["overlappingSessionIDs"])

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.checkpoint(id: firstTurn.id)?.status, .complete)
        XCTAssertEqual(relaunched.checkpoint(id: secondTurn.id)?.status, .complete)
        XCTAssertNil(relaunched.checkpoint(id: firstTurn.id)?.overlappingSessionIDs)
        XCTAssertNil(relaunched.checkpoint(id: secondTurn.id)?.overlappingSessionIDs)
        XCTAssertTrue(try rawDiff(try XCTUnwrap(relaunched.checkpoint(id: firstTurn.id)), in: root)
            .contains("shared.txt"))
    }

    // MARK: - Claimed Edits

    /// Claims arrive one tool call at a time while the turn is open, and must survive the turn
    /// without the store rewriting the archive once per edit.
    func testClaimsRecordedDuringATurnPersistInOrderWithoutDuplicates() throws {
        let session = SessionID()
        let store = makeStore()
        _ = try prepare(store, session: session)

        store.recordClaimedEdits(sessionID: session, paths: [root.appendingPathComponent("a.txt").path])
        store.recordClaimedEdits(sessionID: session, paths: ["b.txt", "a.txt"])
        try write("one\n", to: "a.txt")
        try write("two\n", to: "b.txt")
        let completed = try finish(store, session: session)

        XCTAssertEqual(completed.claimedEditPaths, ["a.txt", "b.txt"])
        XCTAssertEqual(completed.claimedEditsOverflowed, false)
        XCTAssertEqual(
            makeStore().checkpoint(id: completed.id)?.claimedEditPaths,
            ["a.txt", "b.txt"],
            "claims ride out on the completion save, not a save per edit"
        )
    }

    /// The two empty answers are not the same answer, and the difference is what a surface is
    /// allowed to say about a file it cannot find in the list.
    func testUntrackedClaimsStayNilWhileATrackedTurnWithNoEditsIsEmpty() throws {
        let unfed = SessionID()
        let fed = SessionID()
        let store = makeStore()

        _ = try prepare(store, session: unfed)
        try write("shell edit\n", to: "shell.txt")
        let unfedTurn = try finish(store, session: unfed)

        _ = try prepare(store, session: fed)
        // A read-only tool call: the feed ran and named no edited file.
        store.recordClaimedEdits(sessionID: fed, paths: [])
        let fedTurn = try finish(store, session: fed)

        XCTAssertNil(unfedTurn.claimedEditPaths)
        XCTAssertNil(unfedTurn.claimedEditsOverflowed)
        XCTAssertFalse(unfedTurn.hasUsableEditClaims)
        XCTAssertEqual(fedTurn.claimedEditPaths, [])
        XCTAssertTrue(fedTurn.hasUsableEditClaims)
    }

    func testClaimsStopGrowingAtTheCapAndSayThatTheyDid() throws {
        let session = SessionID()
        let store = makeStore()
        _ = try prepare(store, session: session)

        let cap = GitTurnCheckpointDefaults.maximumClaimedEditPaths
        store.recordClaimedEdits(
            sessionID: session,
            paths: (0..<(cap + 20)).map { "file-\($0).txt" }
        )
        let completed = try finish(store, session: session)

        XCTAssertEqual(completed.claimedEditPaths?.count, cap)
        XCTAssertEqual(completed.claimedEditsOverflowed, true)
        XCTAssertFalse(completed.hasUsableEditClaims, "a prefix cannot license per-file marks")
        XCTAssertNil(
            TurnAttribution(checkpoint: completed, claimedByOtherChats: []),
            "an overflowed list with nothing from anyone else can mark no row"
        )
    }

    /// A claim that no diff row could ever match is worse than no claim, so it is dropped rather
    /// than stamped.
    func testClaimsAreStoredCheckoutRelativeAndPathsOutsideTheCheckoutAreDropped() throws {
        let session = SessionID()
        let store = makeStore()
        _ = try prepare(store, session: session)

        store.recordClaimedEdits(sessionID: session, paths: [
            root.appendingPathComponent("nested/deep.txt").path,
            "relative.txt",
            container.appendingPathComponent("outside.txt").path,
            "/etc/hosts",
            ""
        ])
        let completed = try finish(store, session: session)

        XCTAssertEqual(completed.claimedEditPaths, ["nested/deep.txt", "relative.txt"])
    }

    func testMarkingRuleNeedsContentionAndWholeClaims() throws {
        let first = SessionID()
        let second = SessionID()
        let store = makeStore()

        _ = try prepare(store, session: first)
        store.recordClaimedEdits(sessionID: first, paths: ["mine.txt"])
        let uncontested = try finish(store, session: first)
        XCTAssertNil(
            TurnAttribution(checkpoint: uncontested, claimedByOtherChats: []),
            "with nobody else in the checkout there is nothing to mark against"
        )

        _ = try prepare(store, session: first)
        _ = try prepare(store, session: second)
        store.recordClaimedEdits(sessionID: first, paths: ["mine.txt"])
        _ = try finish(store, session: second)
        let contested = try finish(store, session: first)

        XCTAssertEqual(contested.overlappingSessionIDs, [second])
        let attribution = try XCTUnwrap(
            TurnAttribution(checkpoint: contested, claimedByOtherChats: [])
        )
        XCTAssertEqual(attribution.mark(for: "mine.txt"), .none)
        XCTAssertEqual(attribution.mark(for: "somebody-elses.txt"), .unclaimed)
    }

    func testArchiveWrittenWithoutClaimFieldsLoadsAsUntracked() throws {
        let session = SessionID()
        let store = makeStore()
        _ = try prepare(store, session: session)
        store.recordClaimedEdits(sessionID: session, paths: ["claimed.txt"])
        try write("claimed\n", to: "claimed.txt")
        let completed = try finish(store, session: session)
        XCTAssertNotNil(completed.claimedEditPaths)

        try rewriteArchive(dropping: ["claimedEditPaths", "claimedEditsOverflowed"])

        let relaunched = makeStore()
        let restored = try XCTUnwrap(relaunched.checkpoint(id: completed.id))
        XCTAssertEqual(restored.status, .complete)
        XCTAssertNil(restored.claimedEditPaths)
        XCTAssertNil(restored.claimedEditsOverflowed)
        XCTAssertFalse(restored.hasUsableEditClaims)
    }

    // MARK: - Cross-Chat Attribution

    /// Two fed chats in one checkout can each say what the other named, which is what turns a
    /// binary "claimed or not" into an honest split.
    func testOverlappingChatsSeeEachOthersClaims() throws {
        let mine = SessionID()
        let theirs = SessionID()
        let store = makeStore()

        _ = try prepare(store, session: mine)
        _ = try prepare(store, session: theirs)
        store.recordClaimedEdits(sessionID: mine, paths: ["mine.txt", "shared.txt"])
        store.recordClaimedEdits(sessionID: theirs, paths: ["theirs.txt", "shared.txt"])
        let theirTurn = try finish(store, session: theirs)
        let myTurn = try finish(store, session: mine)

        XCTAssertEqual(
            store.otherChatsClaimedPaths(overlapping: myTurn),
            ["theirs.txt", "shared.txt"]
        )
        XCTAssertEqual(
            store.otherChatsClaimedPaths(overlapping: theirTurn),
            ["mine.txt", "shared.txt"]
        )
    }

    func testSequentialTurnsSeeNoOtherChatsClaims() throws {
        let first = SessionID()
        let second = SessionID()
        let store = makeStore()

        _ = try prepare(store, session: first)
        store.recordClaimedEdits(sessionID: first, paths: ["first.txt"])
        let firstTurn = try finish(store, session: first)
        _ = try prepare(store, session: second)
        store.recordClaimedEdits(sessionID: second, paths: ["second.txt"])
        let secondTurn = try finish(store, session: second)

        XCTAssertTrue(store.otherChatsClaimedPaths(overlapping: firstTurn).isEmpty)
        XCTAssertTrue(store.otherChatsClaimedPaths(overlapping: secondTurn).isEmpty)
    }

    /// A contender whose own list is a prefix contributes nothing at all. Half a list would let a
    /// file it did write read as unclaimed, which is the inference this must never enable.
    func testOverflowedContenderContributesNoClaims() throws {
        let mine = SessionID()
        let theirs = SessionID()
        let store = makeStore()

        _ = try prepare(store, session: mine)
        _ = try prepare(store, session: theirs)
        store.recordClaimedEdits(sessionID: mine, paths: ["mine.txt"])
        store.recordClaimedEdits(
            sessionID: theirs,
            paths: (0...GitTurnCheckpointDefaults.maximumClaimedEditPaths).map { "theirs-\($0).txt" }
        )
        _ = try finish(store, session: theirs)
        let myTurn = try finish(store, session: mine)

        XCTAssertTrue(store.otherChatsClaimedPaths(overlapping: myTurn).isEmpty)
        let attribution = try XCTUnwrap(
            TurnAttribution(
                checkpoint: myTurn,
                claimedByOtherChats: store.otherChatsClaimedPaths(overlapping: myTurn)
            )
        )
        XCTAssertEqual(
            attribution.mark(for: "theirs-0.txt"),
            .unclaimed,
            "their unusable list leaves the honest weaker statement standing"
        )
    }

    /// Fix 3 never stamps contention across worktrees, but the read guards on identity anyway:
    /// two checkouts of one repository share path spellings without sharing files.
    func testContenderInAnotherWorktreeContributesNoClaims() throws {
        let worktree = container.appendingPathComponent("second-worktree", isDirectory: true)
        try git("worktree", "add", "--quiet", "--detach", worktree.path, "HEAD")
        let mainContext = captureContext(for: root)
        let worktreeContext = captureContext(for: worktree, logicalRoot: root)

        let mine = SessionID()
        let elsewhere = SessionID()
        let store = GitTurnBaselineStore(directory: metadata) { session in
            session == elsewhere ? worktreeContext : mainContext
        }

        _ = try prepare(store, session: mine)
        _ = try prepare(store, session: elsewhere)
        store.recordClaimedEdits(sessionID: elsewhere, paths: ["tracked.txt"])
        _ = try finish(store, session: elsewhere)
        var myTurn = try finish(store, session: mine)
        XCTAssertNil(myTurn.overlappingSessionIDs)

        // Fabricate the contention fix 3 refuses to record, so only the identity guard can
        // reject it.
        myTurn.overlappingSessionIDs = [elsewhere]
        XCTAssertTrue(store.otherChatsClaimedPaths(overlapping: myTurn).isEmpty)
    }

    func testAttributionSplitsMineTheirsSharedAndUnproven() throws {
        let mine = SessionID()
        let theirs = SessionID()
        let store = makeStore()

        _ = try prepare(store, session: mine)
        _ = try prepare(store, session: theirs)
        store.recordClaimedEdits(sessionID: mine, paths: ["mine.txt", "shared.txt"])
        store.recordClaimedEdits(sessionID: theirs, paths: ["theirs.txt", "shared.txt"])
        _ = try finish(store, session: theirs)
        let myTurn = try finish(store, session: mine)

        let attribution = try XCTUnwrap(
            TurnAttribution(
                checkpoint: myTurn,
                claimedByOtherChats: store.otherChatsClaimedPaths(overlapping: myTurn)
            )
        )
        XCTAssertEqual(attribution.mark(for: "mine.txt"), .none)
        XCTAssertEqual(attribution.mark(for: "theirs.txt"), .otherChat)
        XCTAssertEqual(attribution.mark(for: "shared.txt"), .shared)
        XCTAssertEqual(attribution.mark(for: "shell-edit.txt"), .unclaimed)
    }

    /// The asymmetry, which is the whole point of keeping the rule monotone: their claims are a
    /// positive fact that survives our own claims being unavailable, and our silence still buys
    /// no statement about anything else.
    func testAnotherChatsClaimsSurviveOurOwnClaimsBeingUntracked() throws {
        let terminalLike = SessionID()
        let native = SessionID()
        let store = makeStore()

        _ = try prepare(store, session: terminalLike)
        _ = try prepare(store, session: native)
        store.recordClaimedEdits(sessionID: native, paths: ["theirs.txt"])
        _ = try finish(store, session: native)
        let myTurn = try finish(store, session: terminalLike)
        XCTAssertNil(myTurn.claimedEditPaths, "a runtime with no live feed claims nothing")

        let attribution = try XCTUnwrap(
            TurnAttribution(
                checkpoint: myTurn,
                claimedByOtherChats: store.otherChatsClaimedPaths(overlapping: myTurn)
            )
        )
        XCTAssertEqual(attribution.mark(for: "theirs.txt"), .otherChat)
        XCTAssertEqual(
            attribution.mark(for: "anything-else.txt"),
            .none,
            "without claims of our own, absence from theirs proves nothing"
        )
    }

    func testNeitherSideHavingUsableClaimsMarksNothing() throws {
        let first = SessionID()
        let second = SessionID()
        let store = makeStore()

        _ = try prepare(store, session: first)
        _ = try prepare(store, session: second)
        _ = try finish(store, session: second)
        let contested = try finish(store, session: first)

        XCTAssertEqual(contested.overlappingSessionIDs, [second])
        XCTAssertNil(
            TurnAttribution(
                checkpoint: contested,
                claimedByOtherChats: store.otherChatsClaimedPaths(overlapping: contested)
            ),
            "a contested turn nobody could attribute renders exactly as it always did"
        )
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

    private func changedPaths(
        _ checkpoint: GitTurnCheckpoint,
        in checkout: URL
    ) throws -> [String] {
        let result: Result<[String], GitFailure> = try perform { completion in
            GitReviewReader.checkpointChangedPaths(checkpoint, in: checkout, completion: completion)
        }
        switch result {
        case .success(let paths): return paths
        case .failure(let failure): throw failure
        }
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

    /// Rewrites the stored archive the way a build that predates these fields wrote it: the same
    /// records, with the keys absent rather than null.
    private func rewriteArchive(dropping keys: [String]) throws {
        let archiveURL = metadata.appendingPathComponent(GitTurnCheckpointDefaults.fileName)
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: archiveURL)) as? [String: Any]
        )
        var archive = try XCTUnwrap(envelope["value"] as? [String: Any])
        let records = try XCTUnwrap(archive["checkpoints"] as? [[String: Any]])
        XCTAssertTrue(
            records.contains { record in keys.contains { record[$0] != nil } },
            "the fixture must contain the fields this removes, or it proves nothing"
        )
        archive["checkpoints"] = records.map { record -> [String: Any] in
            var legacy = record
            for key in keys { legacy.removeValue(forKey: key) }
            return legacy
        }
        envelope["value"] = archive
        try JSONSerialization.data(withJSONObject: envelope).write(to: archiveURL)
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
