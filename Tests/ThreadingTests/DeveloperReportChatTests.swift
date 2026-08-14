import AppKit
import XCTest
@testable import Threading

#if DEBUG

/// The development build's second route for a report: a chat in the repository the running
/// binary was compiled from, instead of the private intake.
///
/// Every decision the route makes is a decision over values — which project, configured how,
/// opened with what — so all of it is held here without a store, a window or an agent process.
/// The two sheet cases are driven through the injected closure the sheets already expose for
/// their private-intake path.
final class DeveloperReportChatTests: XCTestCase {

    // MARK: - Which Project

    func testTheChatOpensInTheProjectThisBuildWasCompiledFrom() {
        let root = URL(fileURLWithPath: "/Users/dev/repo/Threading")
        let source = Project(name: "Threading", folderURL: root)
        let elsewhere = Project(name: "Notes", folderURL: URL(fileURLWithPath: "/Users/dev/notes"))

        XCTAssertEqual(
            DeveloperReportChat.targetProjectID(
                projects: [elsewhere, source],
                sourceRoot: root,
                fallback: elsewhere.id
            ),
            source.id,
            "a report about this window went to whatever happened to be on screen"
        )
    }

    /// A prefix is not a match. One repository holds several projects here — checkouts,
    /// worktrees, a dogfooded extension beside the app — and the report belongs to the tree that
    /// drew the window, not to the first row sharing a path prefix with it.
    func testAProjectInsideTheRepositoryIsNotMistakenForTheRepository() {
        let root = URL(fileURLWithPath: "/Users/dev/repo/Threading")
        let inside = Project(
            name: "GitHubChecks",
            folderURL: root.appendingPathComponent("Extensions/GitHubChecks")
        )

        XCTAssertNil(
            DeveloperReportChat.targetProjectID(
                projects: [inside],
                sourceRoot: root,
                fallback: nil
            ),
            "a project merely under the repository was taken for the repository"
        )
    }

    /// `/var` is a symlink to `/private/var` on this platform, so a temporary checkout compares
    /// unequal to its own path unless both sides are resolved.
    func testAPathIsMatchedThroughItsSymlinks() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("report-chat-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("checkout", isDirectory: true)
        let link = base.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }

        let project = Project(name: "Threading", folderURL: link)

        XCTAssertEqual(
            DeveloperReportChat.targetProjectID(
                projects: [project],
                sourceRoot: real,
                fallback: nil
            ),
            project.id,
            "the build's own checkout did not match the project pointing at it"
        )
    }

    func testAnUnknownSourceRootFallsBackToTheProjectOnScreen() {
        let onScreen = Project(name: "Notes", folderURL: URL(fileURLWithPath: "/Users/dev/notes"))

        XCTAssertEqual(
            DeveloperReportChat.targetProjectID(
                projects: [onScreen],
                sourceRoot: URL(fileURLWithPath: "/Volumes/rsync/Threading"),
                fallback: onScreen.id
            ),
            onScreen.id,
            "a build compiled outside Threading's projects had nowhere to send a report"
        )
    }

    func testWithNoMatchAndNothingOnScreenThereIsNowhereToSend() {
        XCTAssertNil(
            DeveloperReportChat.targetProjectID(
                projects: [],
                sourceRoot: URL(fileURLWithPath: "/Users/dev/repo/Threading"),
                fallback: nil
            )
        )
    }

    // MARK: - How The Chat Is Configured

    func testTheChatInheritsTheMostRecentlyUsedChatInThatProject() {
        let projectID = ProjectID()
        var older = AgentSession(kind: .codex, title: "Older", usesNativeUI: true)
        older.lastActiveAt = Date(timeIntervalSince1970: 1_000)
        var newer = AgentSession(
            kind: .claude,
            title: "Newer",
            accountHandle: .named("work"),
            model: "claude-opus-5",
            usesNativeUI: true
        )
        newer.lastActiveAt = Date(timeIntervalSince1970: 2_000)
        newer.permissionMode = .acceptEdits

        let plan = DeveloperReportChat.plan(
            projectID: projectID,
            sessions: [older, newer],
            defaultKind: .codex
        )

        XCTAssertEqual(plan.kind, .claude)
        XCTAssertEqual(plan.accountHandle, .named("work"))
        XCTAssertEqual(plan.model, "claude-opus-5")
        XCTAssertEqual(plan.permissionMode, .acceptEdits)
        XCTAssertTrue(plan.usesNativeUI)
    }

    /// `lastTurnAt` is when the chat was last *used*; `lastActiveAt` is when the runtime last
    /// touched it, which a background relaunch does to every session at once. Inheriting from
    /// the wrong one copies whichever chat the app happened to restore last.
    func testTheMostRecentChatIsTheOneLastUsedRatherThanLastTouched() {
        var relaunched = AgentSession(kind: .codex, title: "Relaunched this morning")
        relaunched.lastActiveAt = Date(timeIntervalSince1970: 9_000)
        relaunched.lastTurnAt = Date(timeIntervalSince1970: 1_000)

        var worked = AgentSession(kind: .claude, title: "Worked in last night")
        worked.lastActiveAt = Date(timeIntervalSince1970: 8_000)
        worked.lastTurnAt = Date(timeIntervalSince1970: 5_000)

        let plan = DeveloperReportChat.plan(
            projectID: ProjectID(),
            sessions: [relaunched, worked],
            defaultKind: .codex
        )

        XCTAssertEqual(plan.kind, .claude, "the report chat copied a session nobody had used")
    }

    func testAnArchivedChatIsNotWhatTheReportChatCopies() {
        var archived = AgentSession(kind: .claude, title: "Put away")
        archived.lastActiveAt = Date(timeIntervalSince1970: 9_000)
        archived.isArchived = true
        var live = AgentSession(kind: .codex, title: "Still here")
        live.lastActiveAt = Date(timeIntervalSince1970: 1_000)

        let plan = DeveloperReportChat.plan(
            projectID: ProjectID(),
            sessions: [archived, live],
            defaultKind: .claude
        )

        XCTAssertEqual(plan.kind, .codex, "a deliberately archived chat decided the new one")
    }

    func testAProjectWithNoChatsFallsBackToTheDefaultAgent() {
        let plan = DeveloperReportChat.plan(
            projectID: ProjectID(),
            sessions: [],
            defaultKind: .claude
        )

        XCTAssertEqual(plan.kind, .claude)
        XCTAssertEqual(plan.accountHandle, .standard)
        XCTAssertNil(plan.model)
        XCTAssertNil(plan.permissionMode)
    }

    /// `AgentSessionConfiguration` refuses a login for a runtime that has none, and the refusal
    /// is a nil session two steps later. The clamp belongs where the value is chosen.
    func testALoginIsNotCarriedToARuntimeThatHasNone() throws {
        try XCTSkipIf(AgentKind.grok.supportsAccounts, "Grok has grown account routing")

        var session = AgentSession(kind: .grok, title: "Grok")
        session.accountHandle = .named("work")
        session.permissionMode = .plan

        let plan = DeveloperReportChat.plan(
            projectID: ProjectID(),
            sessions: [session],
            defaultKind: .claude
        )

        XCTAssertEqual(plan.accountHandle, .standard, "a login was carried to a runtime with none")
        XCTAssertEqual(plan.permissionMode, .plan, "a mode the runtime does support was dropped")
    }

    /// A UI report is read against the tree the build came from. A detached worktree, or a
    /// branch checkout, would put the agent somewhere the screenshot is not about.
    func testAReportChatNeverGetsAManagedWorkspaceOrABranch() {
        let plan = DeveloperReportChat.plan(
            projectID: ProjectID(),
            sessions: [AgentSession(kind: .claude, title: "Any")],
            defaultKind: .claude
        )

        XCTAssertNil(plan.managedWorkspacePlan)
        XCTAssertNil(plan.branch)
    }

    // MARK: - What The Chat Is Opened With

    func testTheFrameLeadsAndTheReportFollowsItWhole() throws {
        let report = """
            The usage strip is cramped

            ## Element report — UsageReadingLabel
            - Window screenshot, target outlined: /tmp/threading-inspect-1.png
            """

        let framed = try XCTUnwrap(DeveloperReportChat.framedReport(report))

        XCTAssertTrue(
            framed.hasPrefix(DeveloperReportChatStrings.frame),
            "the app's own line did not lead the report"
        )
        XCTAssertTrue(
            framed.hasSuffix(report),
            "the report was rewritten on its way to the chat"
        )
        XCTAssertTrue(
            framed.contains("/tmp/threading-inspect-1.png"),
            "the screenshot path did not survive, which is the whole reason for this route"
        )
    }

    func testAnEmptyReportOpensNoChat() {
        XCTAssertNil(DeveloperReportChat.framedReport("   \n  "))
    }

    // MARK: - The Sheet

    /// The private route strips the temporary screenshot path, because a file on this machine
    /// means nothing to an intake service. The chat route keeps it, because it means everything
    /// to an agent standing next to it. Both readings of the same sheet, held together.
    @MainActor
    func testTheChatRequestKeepsTheScreenshotPathThePrivateReportStrips() {
        let sheet = makeSheet()
        sheet.loadView()

        XCTAssertTrue(
            sheet.chatRequest().report.contains(Fixture.screenshotPath),
            "the chat was sent a report it cannot look at"
        )
        XCTAssertFalse(
            sheet.reportDraft().details.contains(Fixture.screenshotPath),
            "a local path escaped into the private report"
        )
    }

    @MainActor
    func testAStartedChatNamesTheProjectAndClosesTheSheet() {
        let sheet = makeSheet()
        sheet.loadView()

        var dismissed = false
        sheet.onDone = { dismissed = true }
        sheet.onSendToChat = { _ in .started(projectName: "Threading") }

        sheet.sendToChat()

        XCTAssertTrue(sheet.statusMessage.contains("Threading"), sheet.statusMessage)
        XCTAssertTrue(dismissed, "the sheet stayed over the chat the user asked to watch")
    }

    @MainActor
    func testAChatThatCouldNotStartSaysSoAndKeepsTheReport() {
        let sheet = makeSheet()
        sheet.loadView()

        var dismissed = false
        sheet.onDone = { dismissed = true }
        sheet.onSendToChat = { _ in .failed(message: DeveloperReportChatStrings.noProject) }

        sheet.sendToChat()

        XCTAssertEqual(sheet.statusMessage, DeveloperReportChatStrings.noProject)
        XCTAssertFalse(dismissed, "a failed send threw the typed report away")
    }

    // MARK: - Fixture

    private enum Fixture {
        static let screenshotPath = "/tmp/threading-inspect-20260814-091925.png"
    }

    @MainActor
    private func makeSheet() -> InspectorReportViewController {
        InspectorReportViewController(
            heading: InspectorStrings.elementHeading,
            subheading: "UsageReadingLabel",
            markdown: """
            - Element: UsageReadingLabel
            - Frame: {{1612, 80}, {74, 15}}
            - Window screenshot, target outlined: \(Fixture.screenshotPath)
            """,
            environment: "- Threading 1.0 (1) · Version 15.5 (Build 24F74)",
            screenshot: nil
        )
    }
}

#endif
