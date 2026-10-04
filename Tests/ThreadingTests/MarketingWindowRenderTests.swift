import AppKit
@testable import SwiftTerm
import XCTest
@testable import Threading

/// Draws the website's full-window macOS product masters from the shipping window.
///
/// The picture is the real `MainWindowController`: its app-drawn title band and window controls,
/// the project sidebar, the selected session's provider terminal, and Git Review in the display
/// pane. Nothing in it comes from a developer's machine. The project is a disposable Git
/// repository holding synthetic notes, the session titles are the iPhone marketing story's, and
/// the terminal shows PTY bytes an installed provider TUI produced against synthetic local data
/// (`scripts/record_marketing_terminal_fixtures.py --target mac`). Those bytes are replayed
/// through SwiftTerm, so a recapture never launches a provider or spends a turn.
///
/// The window is built and never shown, then drawn through `cacheDisplay` from its frame view,
/// which is what keeps it in the fast lane. Masters are 1440 × 900 points at 2×, the size
/// `docs/marketing/SCREENSHOT_PLAN.md` fixes for macOS; `THREADING_RENDER_OUT` redirects them.
@MainActor
final class MarketingWindowRenderTests: HostedStoreTestCase {

    // MARK: - Configuration

    private enum Master {
        static let size = NSSize(width: 1_440, height: 900)
        static let scale: CGFloat = 2
        static let sidebarWidth: CGFloat = 270
        static let displayPaneWidth: CGFloat = 440
        static let projectName = "Threading"
        static let repositoryName = "threading-capture"

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        /// Recorded provider PTY streams sized for this window's terminal pane. They live beside
        /// the other test fixtures rather than in the app bundle: only this capture replays them.
        static var fixtureDirectory: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/MarketingTerminal", isDirectory: true)
        }
    }

    /// One recorded provider stream, in the recorder's shared fixture schema.
    private struct TerminalFixture: Decodable {
        let schemaVersion: Int
        let kind: String
        let provider: String
        let providerVersion: String
        let columns: Int
        let rows: Int
        let provenance: String
        let terminalMode: String?
        let payloadBase64: String

        var payload: [UInt8] { Array(Data(base64Encoded: payloadBase64) ?? Data()) }
    }

    private struct Scene {
        let filename: String
        let provider: String
        let selectedTitle: String
        let settledText: String
    }

    private struct StorySession {
        let title: String
        let kind: AgentKind
    }

    /// The iPhone marketing story's chats, so the Mac and iPhone captures describe one workspace.
    private let story: [StorySession] = [
        StorySession(title: "Build App Store capture flow", kind: .codex),
        StorySession(title: "Polish launch screenshots", kind: .claude),
        StorySession(title: "Verify away-from-home access", kind: .codex),
        StorySession(title: "Plan Linux account support", kind: .claude)
    ]

    // The Codex scene returns once its Mac-width recording exists: Codex 0.160 runs its startup
    // hooks and never prints the loopback fixture's final message at 87 columns, so
    // `record_marketing_terminal_fixtures.py --target mac --provider codex` cannot settle yet.
    private let scenes: [Scene] = [
        Scene(
            filename: "mac-threading-claude-review.png",
            provider: "claude",
            selectedTitle: "Polish launch screenshots",
            settledText: "Capture flow verified"
        )
    ]

    /// The repository Git Review reads: the two notes the recorded provider turns edit.
    private let notesBefore = """
    # App Store capture

    Status: Draft
    Opening scene: Active terminal
    Terminal gesture: Scroll past the bottom
    Final scene: Settings

    Theme timing: Best effort
    """

    private let notesAfter = """
    # App Store capture

    Status: Ready for review
    Opening scene: New Session draft and model picker
    Terminal gesture: Reveal earlier tool output
    Final scene: Daily Usage chart

    Theme timing: Fixed 900-frame clock at 30 fps
    Provider usage during recapture: 0 turns
    """

    private let planBefore = """
    # App Store capture

    Opening scene: Active terminal
    Terminal gesture: Scroll past the bottom
    Final scene: Settings
    Timeline: Best effort
    """

    private let planAfter = """
    # App Store capture

    Opening scene: New Session draft
    Terminal gesture: Reveal earlier tool output
    Final scene: Daily Usage chart
    Timeline: Fixed 900-frame clock
    """

    // MARK: - Tests

    func testRendersFullWindowMastersFromRecordedProviderTUIs() throws {
        let directory = Master.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalTheme = AppThemeLibrary.current
        let originalBackdrop = WindowBackdrop.ground
        let originalAppearance = NSApp.appearance
        // The status card floats over the terminal's top-right corner; in a master the pane is
        // narrow enough that it covers the provider's own header. PreferenceStore keeps this
        // write in the test suite's scratch domain.
        let originalStatusCard = StatusCardVisibility.isEnabled
        StatusCardVisibility.isEnabled = false
        defer { StatusCardVisibility.isEnabled = originalStatusCard }
        let theme = AppThemeStyles.threading
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        AppThemeLibrary.apply(theme)
        AppThemePalette.set(theme)
        NSApp.appearance = appearance

        let workspace = try makeWorkspace()
        defer {
            for session in workspace.sessions {
                AgentRuntime.shared.removeFixtureLaunchPlan(for: session.id)
                AgentRuntime.shared.discard(sessionID: session.id)
            }
            ProjectStore.shared.removeProject(id: workspace.project.id)
            try? FileManager.default.removeItem(at: workspace.containerURL)
            AppThemeLibrary.apply(originalTheme)
            AppThemePalette.set(originalTheme)
            WindowBackdrop.set(originalBackdrop)
            NSApp.appearance = originalAppearance
        }

        for scene in scenes {
            let fixture = try loadFixture(provider: scene.provider)
            let session = try XCTUnwrap(
                workspace.sessions.first { $0.title == scene.selectedTitle }
            )
            var result: Result<Data?, Error> = .success(nil)
            appearance.performAsCurrentDrawingAppearance {
                result = Result {
                    try render(
                        scene: scene,
                        fixture: fixture,
                        session: session,
                        workspace: workspace,
                        theme: theme,
                        appearance: appearance
                    )
                }
            }
            let png = try XCTUnwrap(try result.get(), "failed to render \(scene.filename)")
            let image = try XCTUnwrap(NSBitmapImageRep(data: png))
            XCTAssertEqual(image.pixelsWide, Int(Master.size.width * Master.scale))
            XCTAssertEqual(image.pixelsHigh, Int(Master.size.height * Master.scale))
            try png.write(to: directory.appendingPathComponent(scene.filename), options: .atomic)
        }
        print("Rendered the full-window marketing masters to \(directory.path)")
    }

    // MARK: - Rendering

    private func render(
        scene: Scene,
        fixture: TerminalFixture,
        session: AgentSession,
        workspace: Workspace,
        theme: AppTheme,
        appearance: NSAppearance
    ) throws -> Data? {
        // Materialize the selected session's terminal before the sidebar selects it, so the
        // container attaches an existing surface instead of launching a provider.
        let terminal = AgentRuntime.shared.makeController(for: session)
        _ = terminal.view
        var profile = TerminalProfile.default
        profile.theme = theme.terminalPalette(for: appearance)
        profile.cursorBlink = false
        terminal.session.updateProfile(profile)
        WindowBackdrop.set(.terminal(profile.theme.background))

        let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let window = try XCTUnwrap(controller.window, "the shipping main window was not created")
        window.appearance = appearance
        window.animationBehavior = .none
        window.setContentSize(Master.size)
        defer {
            window.delegate = nil
            window.contentViewController = nil
            controller.window = nil
        }
        let content = try XCTUnwrap(window.contentView)
        content.appearance = appearance
        applyKeyFixtureState(in: content)
        controller.sidebarViewController.mountInitialTreeIfNeeded()
        controller.displayPaneController.showSession(session.id)
        let review = try XCTUnwrap(
            controller.displayPaneController.activateReview(for: session.id),
            "the shipping display pane did not create Git Review"
        )

        controller.sidebarViewController.select(sessionID: session.id)
        let selectionDeadline = Date().addingTimeInterval(2)
        while controller.containerViewController.currentSessionID != session.id,
              Date() < selectionDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(controller.containerViewController.currentSessionID, session.id)
        XCTAssertTrue(controller.containerViewController.activeTerminalSession === terminal.session)
        XCTAssertFalse(terminal.isRunning, "a marketing capture must never launch a provider")

        controller.setDisplayPaneVisible(true, animated: false)
        let split = controller.splitViewController.splitView
        content.layoutSubtreeIfNeeded()
        split.setPosition(Master.sidebarWidth, ofDividerAt: 0)
        split.setPosition(Master.size.width - Master.displayPaneWidth, ofDividerAt: 1)
        content.layoutSubtreeIfNeeded()
        let visiblePanes = split.arrangedSubviews.filter {
            !$0.isHidden && $0.bounds.width > 1 && $0.bounds.height > 1
        }
        XCTAssertEqual(visiblePanes.count, 3, "the master must show the full three-pane app")

        let terminalView = terminal.session.terminalView
        terminalView.suspendsRenderingWhenNotVisible = false
        terminalView.cursorStyle = .steadyBlock
        settle(terminalView)
        let grid = terminalView.terminalDimensions
        // A recording carries absolute cursor addressing for the grid it was drawn into. Replaying
        // it into another grid reflows a provider's layout into something it never drew.
        XCTAssertEqual(
            "\(grid.cols)x\(grid.rows)",
            "\(fixture.columns)x\(fixture.rows)",
            "re-record with: scripts/record_marketing_terminal_fixtures.py --target mac "
                + "--columns \(grid.cols) --rows \(grid.rows)"
        )
        // A mismatched grid still draws the window (without the replay) so the failure can be
        // looked at; the assertion above is what fails the run.
        if grid.cols == fixture.columns, grid.rows == fixture.rows {
            terminalView.feed(byteArray: fixture.payload[...])
            settle(terminalView)
            let screen = terminalView.terminalStateSnapshot().visibleRows.map(\.text)
                .joined(separator: "\n")
            XCTAssertTrue(
                screen.contains(scene.settledText),
                "the recorded \(scene.provider) TUI did not reach its settled frame"
            )
            XCTAssertFalse(
                screen.contains("/Users/"),
                "a marketing frame must not name a home folder"
            )
        }

        // Git Review reads the disposable repository through its shipping git process; present
        // the exact Git-parsed models so the capture does not wait on that background read.
        review.activeDiffCancellation?.cancel()
        review.generation += 1
        review.isLoading = false
        review.loadedDiffRoot = review.repositoryRoot
        review.show(.files(workspace.reviewFiles), forceRebuild: true)
        review.setChangeRequestBarVisible(false)
        XCTAssertEqual(
            review.renderedFiles.map(\.path).sorted(),
            ["capture-notes.md", "capture-plan.md"]
        )

        applyKeyFixtureState(in: content)
        AppThemeRefresh.repaint(content)
        content.layoutSubtreeIfNeeded()
        settle(terminalView)
        review.setChangeRequestBarVisible(false)
        pinSyntheticChrome(of: controller, in: content)
        applyKeyFixtureState(in: content)
        content.layoutSubtreeIfNeeded()


        // The frame view, not the content view, so the window controls are in the master.
        let frameView = content.superview ?? content
        return png(of: frameView, ground: profile.theme.background)
    }

    /// Removes the two pieces of chrome that would otherwise report the machine running the test:
    /// the usage pill reads the developer's real provider account, and the footer's channel mark
    /// says DEV because tests run a Debug build. Each is put in the state the shipping app shows
    /// for its absent case: no account to report, and a release build that wears no mark.
    private func pinSyntheticChrome(of controller: MainWindowController, in content: NSView) {
        controller.materializedAccountUsageItemView?.onHandoff = nil
        controller.materializedAccountUsageItemView?.configure(account: nil)
        let badges = descendants(in: content).filter {
            $0.accessibilityIdentifier() == "sidebar.buildChannel"
        }
        badges.forEach { $0.isHidden = true }
    }

    /// Advances SwiftTerm's real render loop: the first surface in a process has to compile its
    /// Metal pipeline, and a terminal that only marks `needsDisplay` caches as an empty pane.
    private func settle(_ terminal: TerminalView) {
        let deadline = Date().addingTimeInterval(0.35)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            terminal.needsDisplay = true
            terminal.frameTick()
            terminal.window?.displayIfNeeded()
        } while Date() < deadline
    }

    /// Draws the view into a fixed 2× bitmap and flattens it over the terminal ground, which the
    /// window compositor normally supplies beneath the transparent terminal backing.
    private func png(of view: NSView, ground: NSColor) -> Data? {
        let pixels = NSSize(
            width: view.bounds.width * Master.scale,
            height: view.bounds.height * Master.scale
        )
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixels.width),
            pixelsHigh: Int(pixels.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let cachedImage = rep.cgImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: rep.pixelsWide,
                  height: rep.pixelsHigh,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let resolvedGround = ground.usingColorSpace(.sRGB) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        context.setFillColor(resolvedGround.cgColor)
        context.fill(bounds)
        context.draw(cachedImage, in: bounds)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private func applyKeyFixtureState(in view: NSView) {
        (view as? WindowTitleBandView)?.fixtureIsKey = true
        (view as? ThemedTableView)?.fixtureIsKey = true
        (view as? ThemedOutlineView)?.fixtureIsKey = true
        if let row = view as? SidebarHoverRowView, row.isSelected {
            row.isEmphasized = true
            row.needsDisplay = true
            descendants(in: row).compactMap { $0 as? SessionRowView }.forEach {
                $0.backgroundStyle = .emphasized
            }
        }
        view.subviews.forEach { applyKeyFixtureState(in: $0) }
    }

    private func descendants(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    // MARK: - Fixtures

    private struct Workspace {
        let containerURL: URL
        let project: Project
        let sessions: [AgentSession]
        let reviewFiles: [GitFileDiff]
    }

    private func loadFixture(provider: String) throws -> TerminalFixture {
        let url = Master.fixtureDirectory
            .appendingPathComponent("marketing-\(provider)-tui-mac.json")
        let fixture = try JSONDecoder().decode(TerminalFixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.kind, "threading-mobile-terminal-pty-fixture")
        XCTAssertEqual(fixture.provider, provider)
        XCTAssertEqual(fixture.terminalMode ?? "dark", "dark")
        let payload = fixture.payload
        XCTAssertGreaterThan(payload.count, 1_500, "the \(provider) recording is not a PTY stream")
        for marker in ["/Users/", "/home/"] {
            XCTAssertNil(
                Data(payload).range(of: Data(marker.utf8)),
                "the \(provider) recording names a private home path"
            )
        }
        return fixture
    }

    private func makeWorkspace() throws -> Workspace {
        // A short fixed path, because a grouped checkout prints its path beside its branch and a
        // per-user temporary folder would put the test machine's identity into the picture.
        let container = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(Master.repositoryName, isDirectory: true)
        let repository = container
        try? FileManager.default.removeItem(at: container)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let notes = repository.appendingPathComponent("capture-notes.md")
        let plan = repository.appendingPathComponent("capture-plan.md")
        try (notesBefore + "\n").write(to: notes, atomically: true, encoding: .utf8)
        try (planBefore + "\n").write(to: plan, atomically: true, encoding: .utf8)
        try runGit(["init", "--quiet", "--initial-branch=main"], in: repository)
        try runGit(["config", "user.email", "evidence@threading.local"], in: repository)
        try runGit(["config", "user.name", "Threading Evidence"], in: repository)
        try runGit(["add", "."], in: repository)
        try runGit(["commit", "--quiet", "-m", "Seed the capture notes"], in: repository)
        try (notesAfter + "\n").write(to: notes, atomically: true, encoding: .utf8)
        try (planAfter + "\n").write(to: plan, atomically: true, encoding: .utf8)
        let reviewFiles = GitDiffParser.files(fromUnifiedDiff: GitDiffParser.decode(
            try runGit(["diff", "--no-ext-diff", "--unified=3"], in: repository)
        ))

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: repository))
        XCTAssertTrue(store.renameProject(id: project.id, to: Master.projectName).succeeded)
        var sessions: [AgentSession] = []
        // The sidebar lists the newest chat first; create the story oldest first so it reads
        // top to bottom in the order the iPhone dashboard shows it.
        for entry in story.reversed() {
            let session = try XCTUnwrap(store.addSession(
                to: project.id,
                kind: entry.kind,
                // The model and effort the recorded provider turns name, so the session's own
                // chrome agrees with its terminal instead of reporting this machine's defaults.
                model: entry.kind == .codex ? "gpt-5.6-sol" : "fable",
                reasoningEffort: "xhigh",
                usesNativeUI: false,
                title: entry.title
            ))
            // Every story session is materialized by the test before it is selected. Should any
            // path try to start one anyway, it fails here instead of reaching a provider.
            XCTAssertTrue(AgentRuntime.shared.installFixtureLaunchPlan(for: session.id) { _, _, _ in
                XCTFail("the marketing capture tried to launch \(entry.title)")
                return AgentLaunchPlan(
                    executable: "/usr/bin/true",
                    arguments: [],
                    resumeState: .awaitingIdentifier
                )
            })
            sessions.append(try XCTUnwrap(store.session(withID: session.id)))
        }
        return Workspace(
            containerURL: container,
            project: try XCTUnwrap(store.project(withID: project.id)),
            sessions: sessions,
            reviewFiles: reviewFiles
        )
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "MarketingWindowRenderTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"]
            )
        }
        return data
    }
}
