import Foundation
import XCTest
@testable import Threading

@MainActor
final class SessionCheckoutCoordinatorTests: XCTestCase {
    private var root: URL!
    private var main: URL!
    private var sibling: URL!
    private var other: URL!
    private var state: StateManager!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionCheckoutCoordinatorTests-\(UUID().uuidString)")
        main = root.appendingPathComponent("main")
        sibling = root.appendingPathComponent("sibling")
        other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try makeRepository(at: main, branch: "main")
        try git(["worktree", "add", "-b", "feature/move", sibling.path], in: main)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try makeRepository(at: other, branch: "other")
        state = StateManager(appSupportDirectory: root.appendingPathComponent("state"))
        store = ProjectStore(stateManager: state)
    }

    override func tearDown() {
        state?.closeDatabase()
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    func testValidationUsesCanonicalWorktreeIdentity() throws {
        let project = try XCTUnwrap(store.addProject(folderURL: main))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .codex))
        let link = root.appendingPathComponent("linked-sibling")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sibling)
        let coordinator = makeCoordinator()

        let result = try coordinator.validate(
            checkoutPath: link.path,
            forSessionID: session.id
        ).get()

        XCTAssertEqual(result.path, sibling.resolvingSymlinksInPath().path)
        XCTAssertEqual(result.branch, "feature/move")
        XCTAssertEqual(
            result.repositoryIdentity,
            GitInfo.repositoryIdentity(for: main.path)
        )
        XCTAssertNotEqual(
            result.worktreeIdentity,
            GitInfo.worktreeIdentity(for: main.path)
        )
    }

    func testValidationRejectsMissingDetachedCrossRepositoryAndSubdirectory() throws {
        let project = try XCTUnwrap(store.addProject(folderURL: main))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .codex))
        let coordinator = makeCoordinator()
        let nested = sibling.appendingPathComponent("nested")
        let file = root.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: file)

        XCTAssertEqual(failure(coordinator.validate(
            checkoutPath: "relative/checkout",
            forSessionID: session.id
        )), .pathMustBeAbsolute)
        XCTAssertEqual(failure(coordinator.validate(
            checkoutPath: file.path,
            forSessionID: session.id
        )), .targetNotDirectory)
        XCTAssertEqual(failure(coordinator.validate(
            checkoutPath: root.appendingPathComponent("missing").path,
            forSessionID: session.id
        )), .targetMissing)
        XCTAssertEqual(failure(coordinator.validate(
            checkoutPath: nested.path,
            forSessionID: session.id
        )), .targetNotCheckoutRoot)
        XCTAssertEqual(failure(coordinator.validate(
            checkoutPath: other.path,
            forSessionID: session.id
        )), .differentRepository)

        try git(["checkout", "--detach"], in: sibling)
        GitInfo.invalidateCache(for: sibling.path)
        XCTAssertEqual(failure(coordinator.validate(
            checkoutPath: sibling.path,
            forSessionID: session.id
        )), .detachedHead)
    }

    func testValidationRejectsManagedWorkspaceSessions() throws {
        let project = try XCTUnwrap(store.addProject(folderURL: main))
        let workspace = ManagedWorkspace(
            repositoryRoot: main.path,
            sourceCheckoutPath: main.path,
            worktreeRoot: main.path,
            executionPath: main.path,
            targetBranch: "main",
            baseCommit: "deadbeef",
            delivery: .mergeAndCleanUp,
            publication: nil,
            remoteBranch: nil,
            finalCommit: nil,
            changeRequest: nil,
            remoteBranchState: nil,
            state: .active,
            lastError: nil
        )
        let session = try XCTUnwrap(store.addSession(
            to: project.id,
            kind: .codex,
            managedWorkspace: workspace
        ))

        XCTAssertEqual(failure(makeCoordinator().validate(
            checkoutPath: sibling.path,
            forSessionID: session.id
        )), .managedWorkspace)
    }

    func testAtomicMoveCreatesTargetAndPreservesSessionRecord() throws {
        let source = try XCTUnwrap(store.addProject(folderURL: main))
        let remaining = try XCTUnwrap(store.addSession(to: source.id, kind: .claude))
        let moving = try XCTUnwrap(store.addSession(to: source.id, kind: .codex))
        let providerConversation = TranscriptID("codex-provider-conversation")
        _ = store.update(sessionID: moving.id) {
            $0.customTitle = "Fortnox recovery"
            $0.model = "gpt-test"
            $0.isPinned = true
            $0.resumeState = .resumable(providerConversation)
            $0.hasLaunched = true
        }
        store.flushPendingSave()
        let target = try XCTUnwrap(GitInfo.worktreeLocation(for: sibling.path))

        let result = store.moveSessionsToCheckout(
            [moving.id],
            checkoutPath: sibling.path,
            repositoryIdentity: target.repositoryIdentity,
            worktreeIdentity: target.worktreeIdentity,
            branch: try XCTUnwrap(GitInfo.currentBranch(for: sibling.path))
        )

        guard case .moved(let destination) = result else {
            return XCTFail("Expected an atomic move, got \(result)")
        }
        XCTAssertTrue(destination.createdProject)
        XCTAssertEqual(store.project(forSessionID: moving.id)?.folderPath, sibling.path)
        XCTAssertEqual(store.project(forSessionID: remaining.id)?.id, source.id)
        XCTAssertEqual(store.session(withID: moving.id)?.customTitle, "Fortnox recovery")
        XCTAssertEqual(store.session(withID: moving.id)?.model, "gpt-test")
        XCTAssertEqual(store.session(withID: moving.id)?.isPinned, true)
        XCTAssertEqual(
            store.session(withID: moving.id)?.resumeState.transcriptID,
            providerConversation
        )

        let reloaded = ProjectStore(stateManager: state)
        XCTAssertEqual(reloaded.project(forSessionID: moving.id)?.id, destination.projectID)
        XCTAssertEqual(reloaded.project(forSessionID: moving.id)?.folderPath, sibling.path)
        XCTAssertEqual(reloaded.project(forSessionID: source.sessions.first?.id ?? remaining.id)?.id, source.id)
    }

    func testAtomicMoveReusesAddedTargetByWorktreeIdentity() throws {
        let source = try XCTUnwrap(store.addProject(folderURL: main))
        let target = try XCTUnwrap(store.addProject(folderURL: sibling))
        let existing = try XCTUnwrap(store.addSession(to: target.id, kind: .claude))
        let moving = try XCTUnwrap(store.addSession(to: source.id, kind: .codex))
        let location = try XCTUnwrap(GitInfo.worktreeLocation(for: sibling.path))

        let result = store.moveSessionsToCheckout(
            [moving.id],
            checkoutPath: sibling.path,
            repositoryIdentity: location.repositoryIdentity,
            worktreeIdentity: location.worktreeIdentity,
            branch: "feature/move"
        )

        guard case .moved(let destination) = result else {
            return XCTFail("Expected a move into the added project, got \(result)")
        }
        XCTAssertFalse(destination.createdProject)
        XCTAssertEqual(destination.projectID, target.id)
        XCTAssertEqual(store.project(forSessionID: moving.id)?.id, target.id)
        XCTAssertEqual(store.project(forSessionID: existing.id)?.id, target.id)
        XCTAssertEqual(store.projects.filter { $0.folderPath == sibling.path }.count, 1)
    }

    func testAtomicMoveRollsBackInMemoryWhenTheStoreGenerationIsStale() throws {
        let source = try XCTUnwrap(store.addProject(folderURL: main))
        let moving = try XCTUnwrap(store.addSession(to: source.id, kind: .codex))
        let competingState = StateManager(appSupportDirectory: root.appendingPathComponent("state"))
        let competingStore = ProjectStore(stateManager: competingState)
        defer { competingState.closeDatabase() }
        XCTAssertNotNil(competingStore.addProject(folderURL: other))
        let target = try XCTUnwrap(GitInfo.worktreeLocation(for: sibling.path))

        XCTAssertEqual(store.moveSessionsToCheckout(
            [moving.id],
            checkoutPath: sibling.path,
            repositoryIdentity: target.repositoryIdentity,
            worktreeIdentity: target.worktreeIdentity,
            branch: "feature/move"
        ), .persistenceRefused)

        XCTAssertEqual(store.project(forSessionID: moving.id)?.id, source.id)
        XCTAssertFalse(store.projects.contains { $0.folderPath == sibling.path })
        let reloaded = ProjectStore(stateManager: competingState)
        XCTAssertEqual(reloaded.project(forSessionID: moving.id)?.id, source.id)
        XCTAssertFalse(reloaded.projects.contains { $0.folderPath == sibling.path })
    }

    func testActiveTurnKeepsDurableFenceUntilBarrierAndRelaunch() throws {
        let source = try XCTUnwrap(store.addProject(folderURL: main))
        let session = try XCTUnwrap(store.addSession(to: source.id, kind: .codex))
        var hasTurnInFlight = true
        let coordinator = SessionCheckoutCoordinator(
            projects: store,
            runtime: AgentRuntime(currentSessionProjection: .projectStore(store)),
            hasTurnInFlight: { _ in hasTurnInFlight }
        )

        guard case .queued = coordinator.requestMove(
            sessionID: session.id,
            checkoutPath: sibling.path,
            authorityBasis: .explicitUserRequest,
            reason: "Wait for the active turn",
            policy: .allowExplicitRequests
        ) else { return XCTFail("Expected the active move to queue") }

        XCTAssertEqual(store.project(forSessionID: session.id)?.id, source.id)
        XCTAssertNotNil(store.session(withID: session.id)?.pendingCheckoutMove)
        XCTAssertTrue(coordinator.isHoldingInput(sessionID: session.id))

        hasTurnInFlight = false
        var completed = false
        coordinator.finishPendingMove(sessionID: session.id) { succeeded in
            XCTAssertTrue(succeeded)
            completed = true
        }

        XCTAssertTrue(completed)
        XCTAssertEqual(store.project(forSessionID: session.id)?.folderPath, sibling.path)
        XCTAssertNil(store.session(withID: session.id)?.pendingCheckoutMove)
        XCTAssertTrue(
            coordinator.isHoldingInput(sessionID: session.id),
            "the transient fence must survive the store commit until relaunch starts"
        )
        coordinator.runtimeRelaunchDidStart(sessionID: session.id)
        XCTAssertFalse(coordinator.isHoldingInput(sessionID: session.id))
    }

    func testCallingToolAlwaysWaitsForItsOwnTurnBoundary() throws {
        let source = try XCTUnwrap(store.addProject(folderURL: main))
        let session = try XCTUnwrap(store.addSession(to: source.id, kind: .codex))
        let coordinator = SessionCheckoutCoordinator(
            projects: store,
            runtime: AgentRuntime(currentSessionProjection: .projectStore(store)),
            hasTurnInFlight: { _ in false }
        )

        guard case .queued = coordinator.requestMove(
            sessionID: session.id,
            checkoutPath: sibling.path,
            authorityBasis: .explicitUserRequest,
            reason: "tool call is itself inside the turn",
            policy: .allowExplicitRequests,
            waitForCurrentTurnBoundary: true
        ) else { return XCTFail("Expected the tool move to queue") }

        XCTAssertEqual(store.project(forSessionID: session.id)?.id, source.id)
        XCTAssertNotNil(store.session(withID: session.id)?.pendingCheckoutMove)
        XCTAssertTrue(coordinator.cancelPendingMove(sessionID: session.id))
    }

    func testMoveToCurrentCheckoutIsIdempotent() throws {
        let project = try XCTUnwrap(store.addProject(folderURL: main))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .codex))
        let coordinator = makeCoordinator()

        let request = coordinator.requestMove(
            sessionID: session.id,
            checkoutPath: main.path,
            authorityBasis: .explicitUserRequest,
            reason: "Already here",
            policy: .allowExplicitRequests
        )

        guard case .queued = request else { return XCTFail("Expected an idempotent queue") }
        XCTAssertEqual(store.project(forSessionID: session.id)?.id, project.id)
        XCTAssertNil(store.session(withID: session.id)?.pendingCheckoutMove)
        XCTAssertEqual(store.projects.count, 1)
    }

    func testUnstartedClaudeSideChatDependencyMovesTogether() throws {
        let project = try XCTUnwrap(store.addProject(folderURL: main))
        let parent = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        _ = store.update(sessionID: parent.id) {
            $0.resumeState = .resumable(TranscriptID(UUID().uuidString))
        }
        let child = try XCTUnwrap(store.addSideChat(of: parent.id))

        let request = makeCoordinator().requestMove(
            sessionID: child.id,
            checkoutPath: sibling.path,
            authorityBasis: .explicitUserRequest,
            reason: "Move the unstarted fork",
            policy: .allowExplicitRequests
        )

        guard case .queued = request else { return XCTFail("Expected the move to queue") }
        XCTAssertEqual(store.project(forSessionID: child.id)?.folderPath, sibling.path)
        XCTAssertEqual(store.project(forSessionID: parent.id)?.folderPath, sibling.path)
    }

    func testStartedClaudeSideChatMovesIndependently() throws {
        let project = try XCTUnwrap(store.addProject(folderURL: main))
        let parent = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        _ = store.update(sessionID: parent.id) {
            $0.resumeState = .resumable(TranscriptID(UUID().uuidString))
        }
        let child = try XCTUnwrap(store.addSideChat(of: parent.id))
        _ = store.update(sessionID: child.id) { $0.hasLaunched = true }

        _ = makeCoordinator().requestMove(
            sessionID: child.id,
            checkoutPath: sibling.path,
            authorityBasis: .explicitUserRequest,
            reason: "Move the established fork",
            policy: .allowExplicitRequests
        )

        XCTAssertEqual(store.project(forSessionID: child.id)?.folderPath, sibling.path)
        XCTAssertEqual(store.project(forSessionID: parent.id)?.folderPath, main.path)
    }

    func testPendingMoveSurvivesReloadAndCanBeCancelled() throws {
        let project = try XCTUnwrap(store.addProject(folderURL: main))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .codex))
        let target = try XCTUnwrap(GitInfo.worktreeLocation(for: sibling.path))
        let pending = PendingCheckoutMove(
            checkoutPath: sibling.path,
            repositoryIdentity: target.repositoryIdentity,
            worktreeIdentity: target.worktreeIdentity,
            authorityBasis: .explicitUserRequest,
            reason: "test",
            requestedAt: Date()
        )
        XCTAssertTrue(store.setPendingCheckoutMove(pending, forSessionID: session.id))

        let reloaded = ProjectStore(stateManager: state)
        XCTAssertEqual(reloaded.session(withID: session.id)?.pendingCheckoutMove, pending)
        let coordinator = SessionCheckoutCoordinator(
            projects: reloaded,
            runtime: AgentRuntime(currentSessionProjection: .projectStore(reloaded))
        )
        XCTAssertTrue(coordinator.cancelPendingMove(sessionID: session.id))
        XCTAssertNil(reloaded.session(withID: session.id)?.pendingCheckoutMove)
    }

    func testLaunchRecoveryCommitsPersistedPendingMoveBeforeOrdinaryResume() throws {
        let source = try XCTUnwrap(store.addProject(folderURL: main))
        let session = try XCTUnwrap(store.addSession(to: source.id, kind: .codex))
        let target = try XCTUnwrap(GitInfo.worktreeLocation(for: sibling.path))
        XCTAssertTrue(store.setPendingCheckoutMove(PendingCheckoutMove(
            checkoutPath: sibling.path,
            repositoryIdentity: target.repositoryIdentity,
            worktreeIdentity: target.worktreeIdentity,
            authorityBasis: .explicitUserRequest,
            reason: "survive relaunch",
            requestedAt: Date()
        ), forSessionID: session.id))

        let reloaded = ProjectStore(stateManager: state)
        let coordinator = SessionCheckoutCoordinator(
            projects: reloaded,
            runtime: AgentRuntime(currentSessionProjection: .projectStore(reloaded)),
            hasTurnInFlight: { _ in false }
        )
        coordinator.resumePendingMovesAtLaunch()

        XCTAssertEqual(reloaded.project(forSessionID: session.id)?.folderPath, sibling.path)
        XCTAssertNil(reloaded.session(withID: session.id)?.pendingCheckoutMove)
        XCTAssertTrue(coordinator.isHoldingInput(sessionID: session.id))
    }

    func testAuthorityPolicyMatrix() {
        XCTAssertTrue(SessionCheckoutCoordinator.requiresApproval(
            policy: .alwaysAsk, authorityBasis: .explicitUserRequest
        ))
        XCTAssertFalse(SessionCheckoutCoordinator.requiresApproval(
            policy: .allowExplicitRequests, authorityBasis: .explicitUserRequest
        ))
        XCTAssertTrue(SessionCheckoutCoordinator.requiresApproval(
            policy: .allowExplicitRequests, authorityBasis: .agentInitiated
        ))
        XCTAssertFalse(SessionCheckoutCoordinator.requiresApproval(
            policy: .allowSameRepository, authorityBasis: .agentInitiated
        ))
    }

    func testMCPArgumentsDecodeAbsolutePathAuthorityAndReason() throws {
        let arguments = try JSONDecoder().decode(
            SetSessionCheckoutArguments.self,
            from: Data(#"{"checkout_path":"/tmp/checkout","authority_basis":"explicit_user_request","reason":"the user asked"}"#.utf8)
        )

        XCTAssertEqual(arguments.checkoutPath, "/tmp/checkout")
        XCTAssertEqual(arguments.authorityBasis, .explicitUserRequest)
        XCTAssertEqual(arguments.reason, "the user asked")
        let definition = try XCTUnwrap(MCPTools.definition(for: .setSessionCheckout))
        XCTAssertEqual(
            definition.inputSchema.required,
            ["checkout_path", "authority_basis", "reason"]
        )
        XCTAssertEqual(definition.annotations?.idempotentHint, true)
        XCTAssertEqual(definition.annotations?.destructiveHint, false)
        XCTAssertTrue(MCPToolCatalog.project.tools.contains { $0.name == "set_session_checkout" })
        XCTAssertTrue(MCPToolCatalog.project.tools.contains {
            $0.name == "cancel_session_checkout_move"
        })
    }


    func testApprovalIsResolvedBeforePendingStateIsWritten() throws {
        let project = try XCTUnwrap(store.addProject(folderURL: main))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .codex))
        let coordinator = makeCoordinator()

        let waiting = coordinator.requestMove(
            sessionID: session.id,
            checkoutPath: sibling.path,
            authorityBasis: .agentInitiated,
            reason: "Agent chose a checkout",
            policy: .allowExplicitRequests
        )
        guard case .approvalRequired = waiting else {
            return XCTFail("Expected approval")
        }
        XCTAssertNil(store.session(withID: session.id)?.pendingCheckoutMove)

        XCTAssertEqual(coordinator.requestMove(
            sessionID: session.id,
            checkoutPath: sibling.path,
            authorityBasis: .agentInitiated,
            reason: "Agent chose a checkout",
            policy: .allowExplicitRequests,
            approval: false
        ), .denied)
        XCTAssertNil(store.session(withID: session.id)?.pendingCheckoutMove)
    }

    func testClaudeTranscriptBundleRollsBackAndCopiesSubagents() throws {
        let source = root.appendingPathComponent("transcript/source.jsonl")
        let sourceChildren = root.appendingPathComponent("transcript/source/subagents")
        let destination = root.appendingPathComponent("destination/chat.jsonl")
        let destinationChildren = root.appendingPathComponent("destination/chat/subagents")
        try FileManager.default.createDirectory(
            at: sourceChildren,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationChildren,
            withIntermediateDirectories: true
        )
        try Data("new transcript".utf8).write(to: source)
        try Data("new child".utf8).write(to: sourceChildren.appendingPathComponent("child.jsonl"))
        try Data("old transcript".utf8).write(to: destination)
        try Data("old child".utf8).write(to: destinationChildren.appendingPathComponent("old.jsonl"))
        let pair = CheckoutTranscriptCopyPair(
            sourceTranscript: source,
            destinationTranscript: destination,
            sourceSubagents: sourceChildren,
            destinationSubagents: destinationChildren
        )

        let refused = try CheckoutTranscriptCopyTransaction.prepare([pair])
        XCTAssertThrowsError(try refused.install(commit: { false }))
        XCTAssertEqual(try String(contentsOf: destination), "old transcript")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationChildren.appendingPathComponent("old.jsonl").path
        ))

        let accepted = try CheckoutTranscriptCopyTransaction.prepare([pair])
        XCTAssertTrue(try accepted.install(commit: { true }))
        XCTAssertEqual(try String(contentsOf: destination), "new transcript")
        XCTAssertEqual(
            try String(contentsOf: destinationChildren.appendingPathComponent("child.jsonl")),
            "new child"
        )
    }

    private func makeCoordinator() -> SessionCheckoutCoordinator {
        SessionCheckoutCoordinator(
            projects: store,
            runtime: AgentRuntime(currentSessionProjection: .projectStore(store))
        )
    }

    private func failure(
        _ result: Result<ValidatedSessionCheckout, SessionCheckoutValidationFailure>
    ) -> SessionCheckoutValidationFailure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }

    private func makeRepository(at url: URL, branch: String) throws {
        try git(["init", "--initial-branch=\(branch)"], in: url)
        try git(["config", "user.email", "tests@example.com"], in: url)
        try git(["config", "user.name", "Threading Tests"], in: url)
        try Data("seed".utf8).write(to: url.appendingPathComponent("README.md"))
        try git(["add", "."], in: url)
        try git(["commit", "-m", "seed"], in: url)
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus))
        }
    }
}
