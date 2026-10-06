import AppKit
import XCTest
@testable import Threading

/// The sidebar's staged chat preview: five chats per project, "Show 5 more" twice, then the rest —
/// the phone dashboard's disclosure, on the Mac.
///
/// Three layers, tested where each lives. The arithmetic is a value (`SidebarChatPreview`), the cut
/// is the tree builder's (hidden chats never become nodes), and the press, the reveal and the
/// incremental paths are the live sidebar's, driven through its production data source.
@MainActor
final class SidebarChatPreviewTests: XCTestCase {

    // MARK: - Fixtures

    private var directories: [URL] = []
    private var stateManagers: [StateManager] = []
    private var windows: [NSWindow] = []

    private static let preferenceKeys = [
        "sidebarSessionOrder", "sidebarSessionOrderIsReversed", "previewsSidebarChats",
        "groupsSessionsByBranch", "groupsLoneBranches",
    ]

    override func setUp() async throws {
        try await super.setUp()
        // Deterministic arrangement: store order, no branch headings, preview on.
        let defaults = UserDefaults.standard
        defaults.set(SidebarSessionOrder.manual.rawValue, forKey: "sidebarSessionOrder")
        defaults.set(false, forKey: "sidebarSessionOrderIsReversed")
        defaults.set(true, forKey: "previewsSidebarChats")
        defaults.set(false, forKey: "groupsSessionsByBranch")
        defaults.set(true, forKey: "groupsLoneBranches")
    }

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        windows = []
        for manager in stateManagers { manager.closeDatabase() }
        stateManagers = []
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories = []
        for key in Self.preferenceKeys { UserDefaults.standard.removeObject(forKey: key) }
        try await super.tearDown()
    }

    private func session(
        _ title: String,
        forkedFrom parent: SessionID? = nil,
        isPinned: Bool = false,
        lastActiveAt: Date? = nil
    ) -> AgentSession {
        let origin = parent.map(ClaudeSessionOrigin.forked(from:)) ?? .original
        var session = AgentSession(
            configuration: .claude(
                remoteControl: nil,
                fullscreenRenderer: nil,
                reasoningEffort: nil,
                origin: origin
            ),
            title: title
        )
        session.isPinned = isPinned
        if let lastActiveAt { session.lastActiveAt = lastActiveAt }
        return session
    }

    private func project(
        _ name: String,
        sessionCount: Int,
        terminals: [ProjectTerminal] = []
    ) -> Project {
        var project = Project(
            name: name,
            folderURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("threading-preview-\(name)-\(UUID().uuidString)")
        )
        project.sessions = (0..<sessionCount).map { session("Chat \($0)") }
        project.terminals = terminals
        return project
    }

    private func options(
        order: SidebarSessionOrder = .manual,
        chatPreview: Bool = true
    ) -> NativeSidebarPipelineOptionValues {
        NativeSidebarPipelineOptionValues(
            sessionOrder: order,
            sessionOrderReversed: false,
            branchGrouping: false,
            loneBranchHeadings: true,
            compactTree: false,
            chatPreview: chatPreview
        )
    }

    private func build(
        _ project: Project,
        stage: SidebarChatPreviewStage = .compact,
        revealing: Set<SessionID> = [],
        visibility: SidebarSessionVisibility = .attention,
        chatPreview: Bool = true
    ) throws -> ProjectNode {
        let roots = SidebarTreeBuilder.rootNodes(
            from: [project],
            visibility: visibility,
            optionValues: options(chatPreview: chatPreview),
            chatPreviewStages: [project.id: stage],
            revealingSessionIDs: revealing
        )
        return try XCTUnwrap(roots.first as? ProjectNode)
    }

    private func presentedSessionIDs(of node: ProjectNode) -> [SessionID] {
        node.childNodes.compactMap { ($0 as? SessionNode)?.sessionID }
    }

    /// A live sidebar over its own store, in a window that is never shown.
    private func makeSidebar(
        projects: [Project]
    ) -> (controller: ProjectSidebarViewController, store: ProjectStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-sidebar-preview-\(UUID().uuidString)",
            isDirectory: true
        )
        directories.append(directory)
        let manager = StateManager(appSupportDirectory: directory)
        stateManagers.append(manager)
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: projects)))
        let store = ProjectStore(stateManager: manager)
        let controller = ProjectSidebarViewController(projectStore: store)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 900),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        // Installing the controller sizes the window to the view's fitting size; restate the
        // column's real size or the outline has no viewport to build rows in.
        window.setContentSize(NSSize(width: 320, height: 900))
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 900)
        windows.append(window)
        draw()
        return (controller, store)
    }

    /// Lays out and draws without ordering anything on screen, so the outline builds row views.
    private func draw() {
        for window in windows {
            guard let view = window.contentView else { continue }
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                continue
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
    }

    private func sessionRowIDs(_ controller: ProjectSidebarViewController) -> [SessionID] {
        controller.presentedRowKeys.compactMap {
            if case .session(let id) = $0 { return id }
            return nil
        }
    }

    // MARK: - The arithmetic

    /// Five, then five more twice, then everything, then back — the phone's stages at the Mac's
    /// page size, including the short last page that says how many it really adds.
    func testStagesRevealFiveTwiceThenTheRestAndFoldBack() {
        for count in [6, 10, 11, 15, 16, 1_000] {
            var stage = SidebarChatPreviewStage.compact
            var seenLimits: [Int] = []
            for _ in 0..<5 {
                let visible = min(count, stage.limit)
                let preview = SidebarChatPreview(
                    stage: stage,
                    totalCount: count,
                    visibleCount: visible,
                    hiddenSessionIDs: []
                )
                seenLimits.append(visible)
                XCTAssertEqual(preview.hiddenCount, count - visible)
                if preview.isExpanded {
                    XCTAssertEqual(preview.nextStage, .compact)
                    XCTAssertEqual(SidebarChatDisclosureRowView.title(for: preview), "Show fewer")
                    break
                }
                let title = SidebarChatDisclosureRowView.title(for: preview)
                if preview.nextStage == .all {
                    XCTAssertEqual(title, "Show remaining (\(count - visible))")
                } else {
                    XCTAssertEqual(title, "Show \(min(count, stage.next.limit) - visible) more")
                }
                stage = preview.nextStage
            }
            XCTAssertEqual(seenLimits.first, 5, "\(count) chats open on five")
            XCTAssertEqual(seenLimits.last, count, "\(count) chats end with every chat shown")
        }
        XCTAssertFalse(SidebarChatPreview.isWorthShowing(totalCount: 5))
        XCTAssertTrue(SidebarChatPreview.isWorthShowing(totalCount: 6))
    }

    func testRevealingPicksTheSmallestStageThatShowsTheChat() {
        XCTAssertEqual(SidebarChatPreviewStage.revealing(offset: 0), .compact)
        XCTAssertEqual(SidebarChatPreviewStage.revealing(offset: 4), .compact)
        XCTAssertEqual(SidebarChatPreviewStage.revealing(offset: 5), .firstBatch)
        XCTAssertEqual(SidebarChatPreviewStage.revealing(offset: 14), .secondBatch)
        XCTAssertEqual(SidebarChatPreviewStage.revealing(offset: 15), .all)
    }

    // MARK: - The cut

    /// Hidden chats never become outline children, yet stay in the project's flat list so a
    /// folded project still counts them; the disclosure row is the last child, after terminals.
    func testTheBuilderCutsBeforeCreatingRowsAndClosesWithTheDisclosure() throws {
        let terminal = ProjectTerminal(currentDirectory: "/tmp")
        let project = project("Long", sessionCount: 12, terminals: [terminal])
        let node = try build(project)

        XCTAssertEqual(presentedSessionIDs(of: node), project.sessions.prefix(5).map(\.id))
        XCTAssertEqual(node.sessionNodes.count, 12)
        XCTAssertTrue(node.childNodes[5] is TerminalNode)
        let disclosure = try XCTUnwrap(node.childNodes.last as? ChatDisclosureNode)
        XCTAssertTrue(node.chatDisclosureNode === disclosure)
        XCTAssertEqual(disclosure.preview.hiddenCount, 7)
        XCTAssertEqual(
            disclosure.preview.hiddenSessionIDs,
            Set(project.sessions.dropFirst(5).map(\.id))
        )
    }

    func testAProjectThatFitsOrAPreviewSwitchedOffHasNoDisclosure() throws {
        XCTAssertNil(try build(project("Short", sessionCount: 5)).chatDisclosureNode)

        let long = project("Long", sessionCount: 40)
        let whole = try build(long, chatPreview: false)
        XCTAssertNil(whole.chatDisclosureNode)
        XCTAssertEqual(presentedSessionIDs(of: whole).count, 40)
    }

    func testEachStageShowsItsPage() throws {
        let long = project("Long", sessionCount: 12)
        XCTAssertEqual(presentedSessionIDs(of: try build(long, stage: .firstBatch)).count, 10)
        let all = try build(long, stage: .all)
        XCTAssertEqual(presentedSessionIDs(of: all).count, 12)
        XCTAssertEqual(all.chatDisclosureNode?.preview.isExpanded, true)
    }

    /// The selected chat is never cut: the stage rises just far enough to show it.
    func testARevealedChatRaisesTheStageJustFarEnough() throws {
        let long = project("Long", sessionCount: 20)

        let seventh = try build(long, revealing: [long.sessions[7].id])
        XCTAssertEqual(seventh.chatDisclosureNode?.preview.stage, .firstBatch)
        XCTAssertEqual(presentedSessionIDs(of: seventh).count, 10)

        let last = try build(long, revealing: [long.sessions[19].id])
        XCTAssertEqual(last.chatDisclosureNode?.preview.stage, .all)
        XCTAssertEqual(presentedSessionIDs(of: last).count, 20)

        let onPage = try build(long, revealing: [long.sessions[2].id])
        XCTAssertEqual(onPage.chatDisclosureNode?.preview.stage, .compact)
    }

    /// A side chat travels with the chat it was forked from: hidden with it and counted as
    /// hidden, and revealing the side chat reveals its parent.
    func testSideChatsFollowTheirParentAcrossTheCut() throws {
        var long = project("Long", sessionCount: 8)
        let hiddenParent = long.sessions[6]
        let sideChat = session("Side", forkedFrom: hiddenParent.id)
        long.sessions.insert(sideChat, at: 1)

        let folded = try build(long)
        XCTAssertFalse(presentedSessionIDs(of: folded).contains(sideChat.id))
        XCTAssertEqual(folded.chatDisclosureNode?.preview.totalCount, 8)
        XCTAssertTrue(
            folded.chatDisclosureNode?.preview.hiddenSessionIDs.contains(sideChat.id) == true
        )

        let revealed = try build(long, revealing: [sideChat.id])
        let parentNode = try XCTUnwrap(
            revealed.childNodes.compactMap { $0 as? SessionNode }
                .first { $0.sessionID == hiddenParent.id }
        )
        XCTAssertEqual(parentNode.childNodes.map(\.sessionID), [sideChat.id])
    }

    /// Pinned chats lead the page, whatever the order put first.
    func testPinnedChatsTakeThePageFirst() throws {
        var long = project("Pinned", sessionCount: 9)
        long.sessions[8].isPinned = true
        let node = try build(long)
        XCTAssertEqual(presentedSessionIDs(of: node).first, long.sessions[8].id)
        XCTAssertEqual(presentedSessionIDs(of: node).count, 5)
    }

    /// The snoozed list is asked for on purpose and shows whole, as the phone's does.
    func testTheSnoozedScopeIsNeverCut() throws {
        var long = project("Snoozed", sessionCount: 8)
        for index in long.sessions.indices {
            long.sessions[index].snoozedAt = .distantPast
            long.sessions[index].snoozedUntil = .distantFuture
        }
        let node = try build(long, visibility: .snoozed)
        XCTAssertNil(node.chatDisclosureNode)
        XCTAssertEqual(presentedSessionIDs(of: node).count, 8)
    }

    // MARK: - The live sidebar

    /// The row's press walks the stages in the shipping outline and keeps its own identity, so
    /// it is moved rather than replaced as the chats above it arrive and leave.
    func testPressingTheDisclosureWalksTheStagesInTheOutline() throws {
        let long = project("Long", sessionCount: 12)
        let (controller, _) = makeSidebar(projects: [long])

        XCTAssertEqual(sessionRowIDs(controller), long.sessions.prefix(5).map(\.id))
        XCTAssertEqual(controller.presentedRowKeys.last, .chatDisclosure(long.id))
        let disclosureView = try XCTUnwrap(
            controller.presentedRowView(of: .chatDisclosure(long.id))
        )

        controller.advanceChatPreview(ofProjectID: long.id)
        draw()
        XCTAssertEqual(sessionRowIDs(controller).count, 10)
        XCTAssertEqual(
            controller.presentedChatPreview(ofProjectID: long.id).map {
                SidebarChatDisclosureRowView.title(for: $0)
            },
            "Show 2 more"
        )
        XCTAssertTrue(
            controller.presentedRowView(of: .chatDisclosure(long.id)) === disclosureView,
            "the disclosure row kept its view across the press"
        )

        controller.advanceChatPreview(ofProjectID: long.id)
        XCTAssertEqual(sessionRowIDs(controller), long.sessions.map(\.id))
        XCTAssertEqual(controller.presentedChatPreview(ofProjectID: long.id)?.isExpanded, true)

        controller.advanceChatPreview(ofProjectID: long.id)
        XCTAssertEqual(sessionRowIDs(controller).count, 5)
        XCTAssertEqual(controller.presentedRowKeys.last, .chatDisclosure(long.id))
    }

    /// The row's own button is what a click reaches inside the outline, and pressing it — by
    /// pointer or by assistive technology — advances the preview on the next turn.
    func testTheRowsButtonTakesItsOwnPressInsideTheOutline() throws {
        let long = project("Long", sessionCount: 7)
        let (controller, _) = makeSidebar(projects: [long])
        draw()

        let rowView = try XCTUnwrap(controller.presentedRowView(of: .chatDisclosure(long.id)))
        let cell = try XCTUnwrap(
            rowView.subviews.compactMap { $0 as? SidebarChatDisclosureRowView }.first
        )
        let outline = try XCTUnwrap(rowView.superview as? ThemedOutlineView)
        rowView.layoutSubtreeIfNeeded()

        // Mid-row and at the trailing edge, where the activity summary sits.
        for x in [cell.frame.midX, cell.frame.maxX - 4] {
            let point = outline.convert(NSPoint(x: x, y: cell.frame.midY), from: rowView)
            let hit = try XCTUnwrap(outline.hitTest(outline.superview.map {
                outline.convert(point, to: $0)
            } ?? point))
            XCTAssertTrue(RowControls.takesItsOwnClick(hit), "a press at x=\(x) is the button's")
        }

        let button = try XCTUnwrap(cell.subviews.compactMap { $0 as? ThemedButton }.first)
        XCTAssertEqual(button.accessibilityTitle(), "Show 2 more")
        XCTAssertTrue(button.accessibilityPerformPress())
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(sessionRowIDs(controller).count, 7)
        XCTAssertEqual(controller.presentedChatPreview(ofProjectID: long.id)?.isExpanded, true)
    }

    /// Selecting a chat past the page — from a notification or search — opens the page to it
    /// instead of silently selecting nothing, and the opened stage outlives the selection.
    func testSelectingAHiddenChatRevealsItAndKeepsItRevealed() throws {
        let long = project("Long", sessionCount: 14)
        let (controller, _) = makeSidebar(projects: [long])
        let target = long.sessions[8].id
        XCTAssertNil(controller.presentedRow(of: .session(target)))

        controller.select(sessionID: target, notifyDelegate: false)
        XCTAssertEqual(controller.selectedSessionID, target)
        XCTAssertEqual(sessionRowIDs(controller).count, 10)

        controller.select(sessionID: long.sessions[0].id, notifyDelegate: false)
        controller.reload()
        XCTAssertEqual(
            sessionRowIDs(controller).count,
            10,
            "a later rebuild does not fold away what the reveal opened"
        )
    }

    /// Removing a chat on the page pulls the next one onto it, and the row's count follows.
    func testRemovingAChatOnThePagePullsTheNextOneOn() throws {
        let long = project("Long", sessionCount: 8)
        let (controller, store) = makeSidebar(projects: [long])

        _ = store.removeSession(id: long.sessions[1].id)
        XCTAssertEqual(
            sessionRowIDs(controller),
            [0, 2, 3, 4, 5].map { long.sessions[$0].id }
        )
        XCTAssertEqual(controller.presentedChatPreview(ofProjectID: long.id)?.hiddenCount, 2)

        _ = store.removeSession(id: long.sessions[7].id)
        XCTAssertEqual(controller.presentedChatPreview(ofProjectID: long.id)?.hiddenCount, 1)
        XCTAssertEqual(
            controller.presentedChatPreview(ofProjectID: long.id).map {
                SidebarChatDisclosureRowView.title(for: $0)
            },
            "Show 1 more"
        )
    }

    /// Under Recent Activity — the default — a new chat arrives on top and the fifth leaves the
    /// page, while the project's row count still includes every chat.
    func testANewChatUnderRecentActivityTakesThePageFromTheOldest() throws {
        UserDefaults.standard.set(
            SidebarSessionOrder.recentActivity.rawValue,
            forKey: "sidebarSessionOrder"
        )
        var long = project("Recent", sessionCount: 6)
        for index in long.sessions.indices {
            long.sessions[index].lastActiveAt = Date(timeIntervalSinceReferenceDate: Double(index))
        }
        let (controller, store) = makeSidebar(projects: [long])
        XCTAssertEqual(sessionRowIDs(controller).first, long.sessions[5].id)

        let added = try XCTUnwrap(store.addSession(to: long.id, kind: .codex, title: "Newest"))
        XCTAssertEqual(sessionRowIDs(controller).first, added.id)
        XCTAssertEqual(sessionRowIDs(controller).count, 5)
        XCTAssertEqual(controller.presentedChatPreview(ofProjectID: long.id)?.hiddenCount, 2)
    }

    /// Switching the preview off from the menu command rebuilds the tree whole.
    func testTheToggleRemovesTheCutEverywhere() throws {
        let long = project("Long", sessionCount: 9)
        let (controller, _) = makeSidebar(projects: [long])
        XCTAssertEqual(sessionRowIDs(controller).count, 5)

        NativeSidebarPipelineOptions.toggleChatPreview()
        XCTAssertFalse(NativeSidebarPipelineOptions.chatPreview)
        XCTAssertEqual(sessionRowIDs(controller).count, 9)
        XCTAssertNil(controller.presentedChatPreview(ofProjectID: long.id))
    }

    // MARK: - Rendered

    /// The folded and the opened project as a reader meets them, light and dark — the review
    /// surface for where the row's words sit against the chat titles above it and how quietly it
    /// reads beside them, which no frame assertion can judge.
    func testRendersTheFoldedAndOpenedPreview() throws {
        var long = project("Threading", sessionCount: 8)
        let titles = [
            "Sidebar sort default", "Show 5 more on the Mac", "Hidden projects",
            "Command palette shortcuts", "Linux PTY host", "Release notes",
            "Theme shadows on iOS", "Keyboard dismissal",
        ]
        for (index, title) in titles.enumerated() {
            long.sessions[index].customTitle = title
        }
        let short = project("SwiftTerm", sessionCount: 2)
        let (controller, _) = makeSidebar(projects: [long, short])
        let window = try XCTUnwrap(windows.last)
        let view = try XCTUnwrap(window.contentView)

        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func render(_ state: String) throws {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                AppThemeRefresh.repaint(view)
                draw()
                let bounds = NSRect(x: 0, y: view.bounds.height - 420, width: 320, height: 420)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
                view.cacheDisplay(in: bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(
                    to: directory.appendingPathComponent("sidebar-chat-preview-\(state)-\(name).png")
                )
            }
        }

        try render("folded")
        controller.advanceChatPreview(ofProjectID: long.id)
        // The arriving rows fade in; a capture inside the fade shows the gap they are filling.
        RunLoop.main.run(until: Date().addingTimeInterval(Design.Motion.standard + 0.1))
        try render("opened")
    }
}
