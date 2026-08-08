import XCTest
@testable import Threading

/// Process-level managed-workspace coverage with no developer repository and no network.
///
/// Every test builds a source checkout and, where needed, a bare remote under one temporary
/// container. `ManagedWorkspaceFixtureAgent` is an external process with deterministic output:
/// it stands in for Claude/Codex only after Threading has chosen the execution directory. That
/// keeps the fixture out of `AgentKind` and the Draft UI while still proving that real process
/// work lands in the detached checkout production code later validates and disposes.
final class ManagedWorkspaceLifecycleE2ETests: XCTestCase {

    /// The boundary the process-only scenarios below intentionally do not cross: this launches
    /// the fixture through the ordinary terminal runtime, addresses the real loopback MCP server
    /// with this session's token, and lets the production lifecycle relay, archive scheduler and
    /// session coordinator finish the managed checkout.
    @MainActor
    func testRunningFixtureUsesSessionMCPThenCoordinatorIntegratesArchivesAndDisposes() throws {
        let fixture = try ManagedWorkspaceScenarioRepository()
        let store = ProjectStore.shared
        let sessionID = SessionID()
        let workspace = try fixture.provision(sessionID: sessionID)
        let project = store.addProject(folderURL: fixture.project)
        let session = try XCTUnwrap(store.addSession(
            to: project.id,
            kind: .claude,
            usesNativeUI: false,
            title: "Whole-app fixture",
            managedWorkspace: workspace,
            id: sessionID
        ))

        let priorHandler = MCPServer.shared.handler
        let priorLifecycleObserver = HookLifecycleRelay.observe
        let priorSettleDelay = SessionArchiveScheduler.shared.settleDelay
        let priorSessionTools = AppSettings.shared.isToolGroupEnabled(MCPToolCatalog.session.id)
        let serverWasRunning = MCPServer.shared.port != nil
        defer {
            SessionArchiveScheduler.shared.cancel(sessionID: sessionID)
            AgentRuntime.shared.discard(sessionID: sessionID)
            AgentRuntime.shared.removeFixtureLaunchPlan(for: sessionID)
            MCPServer.shared.handler = priorHandler
            HookLifecycleRelay.observe = priorLifecycleObserver
            SessionArchiveScheduler.shared.settleDelay = priorSettleDelay
            AppSettings.shared.setToolGroup(
                MCPToolCatalog.session.id,
                enabled: priorSessionTools
            )
            if !serverWasRunning { MCPServer.shared.stop() }
            store.removeProject(id: project.id)
            fixture.remove()
        }

        let listenerReady = expectation(description: "real MCP listener is ready")
        MCPServer.shared.start { listenerReady.fulfill() }
        wait(for: [listenerReady], timeout: 3)

        let endpoint = try XCTUnwrap(MCPSessionRegistry.endpointURL(for: sessionID))
        let token = MCPSessionRegistry.token(for: sessionID)
        let lifecycleBase = "http://\(MCPDefaults.host):\(try XCTUnwrap(MCPServer.shared.port))"
            + "\(MCPDefaults.lifecyclePathPrefix)\(token)"
        let responseURL = fixture.container.appendingPathComponent("fixture-mcp-response.json")

        let sidebar = ProjectSidebarViewController()
        let container = TerminalContainerViewController(recovery: false)
        let sessionCoordinator = SessionCoordinator(
            sidebar: sidebar,
            container: container,
            onPresentationChanged: {}
        )
        let toolCoordinator = AgentToolCoordinator(
            displayPaneController: DisplayPaneController(),
            visibleSessionID: { container.currentSessionID },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )
        MCPServer.shared.handler = toolCoordinator
        HookLifecycleRelay.observe = { AgentRuntime.shared.applyLifecycle($0) }
        SessionArchiveScheduler.shared.settleDelay = 0.05
        AppSettings.shared.setToolGroup(MCPToolCatalog.session.id, enabled: true)

        XCTAssertTrue(AgentRuntime.shared.installFixtureLaunchPlan(for: session.id) { _, _, _ in
            ManagedWorkspaceFixtureAgent.launchPlan(
                in: workspace.executionURL,
                endpoint: endpoint,
                lifecycleBase: lifecycleBase,
                responseURL: responseURL
            )
        })

        _ = sidebar.view
        _ = container.view
        container.view.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        container.view.layoutSubtreeIfNeeded()
        container.show(sessionID: session.id)

        XCTAssertTrue(
            waitForMainRunLoop(timeout: 10) {
                store.session(withID: session.id)?.isArchived == true
            },
            "the real MCP request never reached the archive coordinator"
        )

        let response = try String(contentsOf: responseURL, encoding: .utf8)
        XCTAssertTrue(response.contains(#""id":"fixture-archive""#))
        XCTAssertTrue(response.contains(#""isError":false"#))
        XCTAssertTrue(response.contains("will be archived when this turn ends"))

        let completed = try XCTUnwrap(store.session(withID: session.id)?.managedWorkspace)
        XCTAssertEqual(completed.state, .integrated)
        XCTAssertNotNil(completed.finalCommit)
        XCTAssertTrue(store.session(withID: session.id)?.isArchived == true)
        XCTAssertFalse(AgentRuntime.shared.hasTerminal(sessionID: session.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.worktreeRoot))
        XCTAssertEqual(
            try String(contentsOf: fixture.project.appendingPathComponent("agent-change.txt")),
            ManagedWorkspaceFixtureAgent.changeContents + "\n"
        )
        XCTAssertFalse(
            try fixture.output("worktree", "list", "--porcelain")
                .contains(workspace.worktreeRoot)
        )
        withExtendedLifetime((sessionCoordinator, toolCoordinator)) {}
    }

    func testFixtureAgentCommitsThenLocalDeliveryIntegratesAndDisposes() throws {
        let fixture = try ManagedWorkspaceScenarioRepository()
        defer { fixture.remove() }

        let sourceHead = try fixture.output("rev-parse", "HEAD")
        let branchesBefore = try fixture.output("branch", "--format=%(refname:short)")
        let sessionID = SessionID()
        let workspace = try fixture.provision(sessionID: sessionID)

        XCTAssertEqual(workspace.state, .active)
        XCTAssertEqual(
            try fixture.output("rev-parse", "--abbrev-ref", "HEAD", in: workspace.executionURL),
            "HEAD"
        )

        let agent = try ManagedWorkspaceFixtureAgent.run(.commit, in: workspace.executionURL)
        XCTAssertEqual(agent.output, [
            "fixture-agent: started",
            "fixture-agent: committed",
            "fixture-agent: archive_session"
        ])

        guard case .completed(let completed) =
                ManagedGitWorkspace.finishLocalDelivery(workspace) else {
            return XCTFail("a clean committed fixture run should complete")
        }

        XCTAssertEqual(completed.state, .integrated)
        XCTAssertNotEqual(try fixture.output("rev-parse", "HEAD"), sourceHead)
        XCTAssertEqual(
            try String(contentsOf: fixture.project.appendingPathComponent("agent-change.txt")),
            ManagedWorkspaceFixtureAgent.changeContents + "\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.worktreeRoot))
        XCTAssertEqual(try fixture.output("branch", "--format=%(refname:short)"), branchesBefore)
        XCTAssertFalse(
            try fixture.output("worktree", "list", "--porcelain")
                .contains(workspace.worktreeRoot)
        )
    }

    func testKeepForReviewRetainsTheExactWorkspaceAndRestoreMakesItActive() throws {
        let fixture = try ManagedWorkspaceScenarioRepository()
        defer { fixture.remove() }

        let workspace = try fixture.provision(
            sessionID: SessionID(),
            plan: ManagedWorkspacePlan(delivery: .keepForReview)
        )
        _ = try ManagedWorkspaceFixtureAgent.run(.commit, in: workspace.executionURL)

        guard case .completed(let kept) =
                ManagedGitWorkspace.finishLocalDelivery(workspace) else {
            return XCTFail("keep-for-review should be a completed local delivery")
        }

        XCTAssertEqual(kept.state, .kept)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.worktreeRoot))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.project.appendingPathComponent("agent-change.txt").path
            ),
            "retaining an isolated checkout must not modify the source checkout"
        )

        let restored = try ManagedGitWorkspace.restore(kept)
        XCTAssertEqual(restored.state, .active)
        XCTAssertEqual(restored.worktreeRoot, kept.worktreeRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.worktreeRoot))
    }

    func testDirtyFixtureAgentBecomesNeedsAttentionAndNothingIsDisposed() throws {
        let fixture = try ManagedWorkspaceScenarioRepository()
        defer { fixture.remove() }

        let sourceHead = try fixture.output("rev-parse", "HEAD")
        let workspace = try fixture.provision(sessionID: SessionID())
        let agent = try ManagedWorkspaceFixtureAgent.run(.leaveDirty, in: workspace.executionURL)
        XCTAssertEqual(agent.output, [
            "fixture-agent: started",
            "fixture-agent: left dirty",
            "fixture-agent: archive_session"
        ])

        guard case .needsAttention(let failed) =
                ManagedGitWorkspace.finishLocalDelivery(workspace) else {
            return XCTFail("an uncommitted handoff must be retained for attention")
        }

        XCTAssertEqual(failed.state, .needsAttention)
        XCTAssertNotNil(failed.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.worktreeRoot))
        XCTAssertEqual(try fixture.output("rev-parse", "HEAD"), sourceHead)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.project.appendingPathComponent("agent-change.txt").path
            )
        )
    }

    func testFixtureAgentPublishesLocallyAndAnOpenReviewRetainsItsBranch() async throws {
        let published = try await makePublishedFixture()
        defer { published.repository.remove() }

        XCTAssertEqual(published.workspace.state, .published)
        XCTAssertEqual(
            published.workspace.remoteBranchState,
            .awaitingReviewCompletion
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: published.workspace.worktreeRoot)
        )
        let publishedRevision = try await published.repository.remoteRevision(
            of: published.branch
        )
        XCTAssertEqual(publishedRevision, published.finalCommit)

        let cleaner = ManagedWorkspaceRemoteCleaner(github: published.github(state: "open"))
        let outcome = await cleaner.reconcile(
            sessionID: published.sessionID,
            workspace: published.workspace
        )
        XCTAssertEqual(outcome, .waiting)
        let retainedRevision = try await published.repository.remoteRevision(
            of: published.branch
        )
        XCTAssertEqual(retainedRevision, published.finalCommit)
    }

    func testClosedReviewLeaseDeletesItsExactGeneratedBranch() async throws {
        let published = try await makePublishedFixture()
        defer { published.repository.remove() }

        let cleaner = ManagedWorkspaceRemoteCleaner(github: published.github(state: "closed"))
        let outcome = await cleaner.reconcile(
            sessionID: published.sessionID,
            workspace: published.workspace
        )

        XCTAssertEqual(outcome, .disposed(.deleted))
        let remainingRevision = try await published.repository.remoteRevision(
            of: published.branch
        )
        XCTAssertNil(remainingRevision)
    }

    func testClosedReviewRecordsAnAlreadyAbsentGeneratedBranch() async throws {
        let published = try await makePublishedFixture()
        defer { published.repository.remove() }

        try await ChangeRequestGit.deleteRemoteBranch(
            published.branch,
            ifRevisionIs: published.finalCommit,
            in: published.repository.source
        )
        let cleaner = ManagedWorkspaceRemoteCleaner(github: published.github(state: "closed"))
        let outcome = await cleaner.reconcile(
            sessionID: published.sessionID,
            workspace: published.workspace
        )

        XCTAssertEqual(outcome, .disposed(.alreadyAbsent))
        let remainingRevision = try await published.repository.remoteRevision(
            of: published.branch
        )
        XCTAssertNil(remainingRevision)
    }

    func testClosedReviewPreservesAGeneratedBranchThatSomeoneAdvanced() async throws {
        let published = try await makePublishedFixture()
        defer { published.repository.remove() }

        let tree = try published.repository.output("rev-parse", "\(published.finalCommit)^{tree}")
        let advanced = try published.repository.output(
            "commit-tree", tree,
            "-p", published.finalCommit,
            "-m", "Advance generated branch"
        )
        _ = try published.repository.output(
            "push", "origin", "\(advanced):refs/heads/\(published.branch)"
        )

        let cleaner = ManagedWorkspaceRemoteCleaner(github: published.github(
            state: "closed",
            reportedRevision: published.finalCommit
        ))
        let outcome = await cleaner.reconcile(
            sessionID: published.sessionID,
            workspace: published.workspace
        )

        guard case .ownershipLost = outcome else {
            return XCTFail("a moved generated branch must leave Threading's ownership")
        }
        let retainedRevision = try await published.repository.remoteRevision(
            of: published.branch
        )
        XCTAssertEqual(retainedRevision, advanced)
    }

    // MARK: - Publication fixture

    private func makePublishedFixture() async throws -> PublishedManagedWorkspaceFixture {
        let repository = try ManagedWorkspaceScenarioRepository(withRemote: true)
        do {
            let sessionID = SessionID()
            let workspace = try repository.provision(
                sessionID: sessionID,
                plan: ManagedWorkspacePlan(publication: .draft)
            )
            _ = try ManagedWorkspaceFixtureAgent.run(.commit, in: workspace.executionURL)
            let snapshot = try ManagedGitWorkspace.publicationSnapshot(for: workspace)
            let github = Self.github(
                branch: snapshot.branch,
                revision: snapshot.finalCommit,
                state: "open"
            )
            let result = try await ManagedWorkspacePublisher(github: github).publish(workspace)

            var recorded = workspace
            recorded.finalCommit = result.finalCommit
            recorded.changeRequest = result.changeRequest
            recorded.remoteBranchState = .awaitingReviewCompletion
            let completed = try ManagedGitWorkspace.cleanPublished(recorded)

            return PublishedManagedWorkspaceFixture(
                repository: repository,
                sessionID: sessionID,
                workspace: completed,
                branch: snapshot.branch,
                finalCommit: snapshot.finalCommit
            )
        } catch {
            repository.remove()
            throw error
        }
    }

    fileprivate static func github(
        branch: String,
        revision: String,
        state: String,
        reportedRevision: String? = nil
    ) -> GitHubPullRequestClient {
        let resolver = GitHubCredentialResolver(
            appConnection: FakeAppTokens(token: "fixture-token"),
            ghSource: FakeTokenSource(token: nil),
            gitSource: FakeTokenSource(token: nil)
        )
        return GitHubPullRequestClient(resolver: resolver) { request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            let data: Data
            let status: Int

            switch (method, path) {
            case ("GET", "/repos/fixture/managed-workspace"):
                data = Data(#"{"default_branch":"main"}"#.utf8)
                status = 200
            case ("GET", "/repos/fixture/managed-workspace/pulls"):
                data = Data("[]".utf8)
                status = 200
            case ("GET", let value) where value.hasSuffix("/check-runs"):
                data = Data(#"{"check_runs":[]}"#.utf8)
                status = 200
            case ("POST", "/repos/fixture/managed-workspace/pulls"),
                 ("GET", "/repos/fixture/managed-workspace/pulls/42"):
                data = pullResponse(
                    branch: branch,
                    revision: reportedRevision ?? revision,
                    state: state
                )
                status = method == "POST" ? 201 : 200
            default:
                data = Data(#"{"message":"missing fixture"}"#.utf8)
                status = 404
            }

            return (
                data,
                HTTPURLResponse(
                    url: request.url ?? URL(fileURLWithPath: "/"),
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    }

    private static func pullResponse(
        branch: String,
        revision: String,
        state: String
    ) -> Data {
        Data("""
        {
          "number": 42,
          "title": "Fixture agent change",
          "body": "Deterministic managed-workspace fixture",
          "html_url": "https://github.com/fixture/managed-workspace/pull/42",
          "state": "\(state)",
          "draft": true,
          "merged_at": null,
          "base": {"ref":"main","sha":"base"},
          "head": {"ref":"\(branch)","sha":"\(revision)"},
          "requested_reviewers": []
        }
        """.utf8)
    }

    @MainActor
    private func waitForMainRunLoop(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.02)))
        }
        return condition()
    }
}

private struct PublishedManagedWorkspaceFixture {
    let repository: ManagedWorkspaceScenarioRepository
    let sessionID: SessionID
    let workspace: ManagedWorkspace
    let branch: String
    let finalCommit: String

    func github(state: String, reportedRevision: String? = nil) -> GitHubPullRequestClient {
        ManagedWorkspaceLifecycleE2ETests.github(
            branch: branch,
            revision: finalCommit,
            state: state,
            reportedRevision: reportedRevision
        )
    }
}

private final class ManagedWorkspaceScenarioRepository {
    static let remoteIdentity = "git@github.com:fixture/managed-workspace.git"

    let container: URL
    let source: URL
    let project: URL
    let workspaces: URL
    let remote: URL

    init(withRemote: Bool = false) throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ThreadingManagedLifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        source = container.appendingPathComponent("source", isDirectory: true)
        project = source.appendingPathComponent("Package", isDirectory: true)
        workspaces = container.appendingPathComponent("workspaces", isDirectory: true)
        remote = container.appendingPathComponent("remote.git", isDirectory: true)

        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try GitProcess.run(["init", "--quiet", "--initial-branch=main"], in: source)
        _ = try GitProcess.run(["config", "user.email", "fixture-agent@invalid.example"], in: source)
        _ = try GitProcess.run(["config", "user.name", "Threading Fixture Agent"], in: source)
        _ = try GitProcess.run(["config", "commit.gpgsign", "false"], in: source)
        let emptyHooks = container.appendingPathComponent("empty-hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyHooks, withIntermediateDirectories: true)
        _ = try GitProcess.run(["config", "core.hooksPath", emptyHooks.path], in: source)
        try "seed\n".write(
            to: project.appendingPathComponent("seed.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try GitProcess.run(["add", "Package/seed.txt"], in: source)
        _ = try GitProcess.run(["commit", "--quiet", "--message", "Seed fixture"], in: source)

        if withRemote {
            _ = try GitProcess.run(["init", "--quiet", "--bare", remote.path], in: container)
            _ = try GitProcess.run(["remote", "add", "origin", Self.remoteIdentity], in: source)
            _ = try GitProcess.run([
                "config",
                "url.\(remote.absoluteString).insteadOf",
                Self.remoteIdentity
            ], in: source)
            _ = try GitProcess.run(["push", "--quiet", "-u", "origin", "main"], in: source)
        }
    }

    func provision(
        sessionID: SessionID,
        plan: ManagedWorkspacePlan = ManagedWorkspacePlan()
    ) throws -> ManagedWorkspace {
        try ManagedGitWorkspace.provision(
            sessionID: sessionID,
            from: Project(name: "Fixture Package", folderURL: project),
            plan: plan,
            rootDirectory: workspaces
        )
    }

    @discardableResult
    func output(_ arguments: String..., in directory: URL? = nil) throws -> String {
        GitDiffParser.decode(try GitProcess.run(arguments, in: directory ?? source))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remoteRevision(of branch: String) async throws -> String? {
        try await ChangeRequestGit.remoteRevision(of: branch, in: source)
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }
}

private enum ManagedWorkspaceFixtureAgent {
    enum Scenario {
        case commit
        case leaveDirty
    }

    struct Result {
        let output: [String]
    }

    static let changeContents = "change written by deterministic fixture agent"

    /// A fake agent process, not a fake app bridge. Its only special treatment is how its
    /// executable is chosen; every callback it makes uses the same HTTP endpoints as a real CLI.
    static func launchPlan(
        in directory: URL,
        endpoint: String,
        lifecycleBase: String,
        responseURL: URL
    ) -> AgentLaunchPlan {
        let turnStarted = lifecycleBase
            + "?\(MCPDefaults.lifecycleEventParameter)=\(HookLifecycleEvent.turnStarted.rawValue)"
        let turnFinished = lifecycleBase
            + "?\(MCPDefaults.lifecycleEventParameter)=\(HookLifecycleEvent.turnFinished.rawValue)"
        let script = """
        set -eu
        cd \(shellQuoted(directory.path))
        /usr/bin/curl --fail --silent --show-error --request POST \\
          --header 'Content-Type: application/json' --data '{}' \\
          \(shellQuoted(turnStarted)) >/dev/null
        printf '%s\\n' 'fixture-agent: started'
        printf '%s\\n' \(shellQuoted(changeContents)) > agent-change.txt
        git add -- agent-change.txt
        git -c commit.gpgsign=false commit --quiet --message 'Fixture agent change'
        printf '%s\\n' 'fixture-agent: committed'
        /usr/bin/curl --fail --silent --show-error --request POST \\
          --header 'Content-Type: application/json' \\
          --data '{"jsonrpc":"2.0","id":"fixture-archive","method":"tools/call","params":{"name":"archive_session","arguments":{"reason":"fixture committed its managed change"}}}' \\
          \(shellQuoted(endpoint)) > \(shellQuoted(responseURL.path))
        printf '%s\\n' 'fixture-agent: archive_session returned'
        printf '%s\\n' 'fixture-agent: final reply complete'
        /usr/bin/curl --fail --silent --show-error --request POST \\
          --header 'Content-Type: application/json' --data '{}' \\
          \(shellQuoted(turnFinished)) >/dev/null
        /bin/sleep 30
        """
        return AgentLaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", script],
            resumeState: .unavailable
        )
    }

    static func run(_ scenario: Scenario, in directory: URL) throws -> Result {
        let script: String
        switch scenario {
        case .commit:
            script = """
            set -eu
            printf '%s\\n' 'fixture-agent: started'
            printf '%s\\n' "$THREADING_FIXTURE_CHANGE" > agent-change.txt
            git add -- agent-change.txt
            git -c commit.gpgsign=false commit --quiet --message 'Fixture agent change'
            printf '%s\\n' 'fixture-agent: committed'
            printf '%s\\n' 'fixture-agent: archive_session'
            """
        case .leaveDirty:
            script = """
            set -eu
            printf '%s\\n' 'fixture-agent: started'
            printf '%s\\n' "$THREADING_FIXTURE_CHANGE" > agent-change.txt
            printf '%s\\n' 'fixture-agent: left dirty'
            printf '%s\\n' 'fixture-agent: archive_session'
            """
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["THREADING_FIXTURE_CHANGE"] = changeContents
        process.environment = environment

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw FixtureAgentFailure.failed(
                String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let output = String(decoding: outputData, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
        return Result(output: output)
    }

    enum FixtureAgentFailure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message): message.isEmpty ? "Fixture agent failed." : message
            }
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private extension ManagedWorkspace {
    var executionURL: URL {
        URL(fileURLWithPath: executionPath, isDirectory: true)
    }
}
