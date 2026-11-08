import AppKit
import XCTest
@testable import Threading

@MainActor
final class MissingCheckoutRecoveryTests: HostedStoreTestCase {
    func testRecoveryInTheShippingWindowPreservesTheConversationAndResumes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("checkout-recovery-\(UUID())")
        let main = root.appendingPathComponent("main")
        let removed = root.appendingPathComponent("removed-worktree")
        let login = root.appendingPathComponent("login")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: login, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); AgentAccountDiscovery.invalidate() }
        _ = try GitProcess.run(["init", "-b", "main"], in: main)
        _ = try GitProcess.run(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "commit", "--allow-empty", "-m", "Fixture"], in: main)
        _ = try GitProcess.run(["worktree", "add", "-b", "work", removed.path], in: main)
        let handle = AccountHandle.named("checkout-recovery-fixture")
        XCTAssertTrue(AgentAccountLocationRegistry.shared.register(provider: .claude,
            handle: handle, configPath: login.path))
        AgentAccountDiscovery.invalidate()
        let account = try XCTUnwrap(AgentAccountDiscovery.account(for: .claude, handle: handle))
        XCTAssertEqual(account.configPath, login.path)
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: removed))
        let target = try XCTUnwrap(store.addProject(folderURL: main))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude,
            accountHandle: handle, usesNativeUI: false, title: "GAMMA"))
        let transcriptID = TranscriptID(session.id.uuidString.lowercased())
        let source = try XCTUnwrap(ClaudeTranscript.storageURL(sessionID: transcriptID,
            account: account, in: project))
        let destination = try XCTUnwrap(ClaudeTranscript.storageURL(sessionID: transcriptID,
            account: account, in: target))
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let history = Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Saved conversation\"}}\n".utf8)
        try history.write(to: source)
        let children = ClaudeTranscript.subagentsDirectory(forRoot: source)
        try FileManager.default.createDirectory(at: children, withIntermediateDirectories: true)
        try history.write(to: children.appendingPathComponent("agent-child.jsonl"))
        _ = try GitProcess.run(["worktree", "remove", "--force", removed.path], in: main)
        let diagnosis = try XCTUnwrap(ProjectLaunchPreflight.launchFailure(for: project))
        XCTAssertEqual(diagnosis.knownCause, SessionLaunchFailure.missingProjectFolderCause)
        // Keep the real preflight result and recovery identity, while excluding the random
        // scratch directory from the canonical UI evidence.
        let failure = SessionLaunchFailure(origin: diagnosis.origin,
            summary: diagnosis.summary.replacingOccurrences(of: removed.path,
                with: "/Users/example/repo/removed-worktree"), knownCause: diagnosis.knownCause)
        XCTAssertTrue(store.update(sessionID: session.id) {
            $0.resumeState = .resumable(transcriptID)
            $0.hasLaunched = true
            $0.backgroundHost = false
            $0.lastLaunchFailure = failure
        }.succeeded)
        let triggers = TriggerStore(url: root.appendingPathComponent("triggers.db"))
        addTeardownBlock { await triggers.close() }
        let shell = makeMainWindowController(initialFramePlan: .useDefaultFrame, triggerStore: triggers)
        let window = try XCTUnwrap(shell.window)
        defer { window.orderOut(nil); AgentRuntime.shared.discard(sessionID: session.id) }
        window.setContentSize(NSSize(width: 1100, height: 760))
        shell.containerViewController.show(sessionID: session.id)
        let surface = try XCTUnwrap(descendants(shell.containerViewController.view)
            .compactMap { $0 as? LaunchFailureView }.first)
        XCTAssertFalse(surface.isHidden)
        XCTAssertFalse(AgentRuntime.shared.hasTerminal(sessionID: session.id), "Opening the error must not retry")
        XCTAssertEqual(descendants(surface).compactMap { $0 as? ThemedButton }.map(\.title),
            ["Choose Existing Checkout…", "Try Again", "Copy Details"])
        let menus = shell.sidebarViewController.sessionActionEntries(for: try XCTUnwrap(store.session(withID: session.id)))
        XCTAssertTrue(menuTitles(menus).contains("Choose Existing Checkout…"), "The sidebar must also retain recovery")
        try render(window)

        let relaunched = expectation(description: "same chat resumes in replacement checkout")
        XCTAssertTrue(AgentRuntime.shared.installFixtureLaunchPlan(for: session.id) { stored, executionProject, _ in
            XCTAssertEqual(stored.id, session.id)
            XCTAssertEqual(stored.resumeState.transcriptID, transcriptID)
            XCTAssertEqual(executionProject.folderPath, target.folderPath)
            XCTAssertNil(stored.lastLaunchFailure)
            XCTAssertEqual(try? Data(contentsOf: destination), history)
            relaunched.fulfill()
            return AgentLaunchPlan(executable: "/bin/cat", arguments: [], resumeState: .resumable(transcriptID))
        })
        // The folder picker's accepted URL enters this same operation from the error button,
        // session menu and command palette. No real provider or credential is used by the test.
        shell.sidebarViewController.requestCheckoutMove(for: session.id, to: main.path)
        wait(for: [relaunched], timeout: 10)
        XCTAssertEqual(try Data(contentsOf: source), history, "Keep the original transcript")
        XCTAssertEqual(try Data(contentsOf: ClaudeTranscript.subagentsDirectory(forRoot: destination)
            .appendingPathComponent("agent-child.jsonl")), history)
        XCTAssertEqual(store.project(forSessionID: session.id)?.id, target.id)
        XCTAssertNil(store.session(withID: session.id)?.lastLaunchFailure)
        XCTAssertTrue(surface.isHidden)
    }

    private func render(_ window: NSWindow) throws {
        let previous = AppThemeLibrary.current
        let palette = AppThemePalette.current
        defer { AppThemeLibrary.installResolved(previous); AppThemePalette.set(palette) }
        let content = try XCTUnwrap(window.contentView)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            AppThemeLibrary.installResolved(.system)
            window.appearance = NSAppearance(named: appearance)
            AppThemeRefresh.repaint(content)
            content.layoutSubtreeIfNeeded()
            content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("missing-checkout-recovery-\(name).png"))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func menuTitles(_ entries: [ThemedMenuEntry]) -> [String] {
        entries.flatMap { entry -> [String] in
            guard case .item(let item) = entry else { return [] }
            return [item.title] + menuTitles(item.submenu ?? [])
        }
    }
}
