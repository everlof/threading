import XCTest
@testable import Threading

/// How the sidebar decides what nests under what.
///
/// Three rules, all of them invisible until they are wrong, and none of them tested until now:
/// a level appears only when it *earns* one, a side chat hangs off its parent, and a record the
/// tree cannot make sense of is tolerated rather than trusted. That last one is not defensive
/// programming for its own sake — the outline view asks for children lazily, so a cycle in the
/// stored lineage is an infinite recursion rather than a wrong-looking row, and `projects.json`
/// outlives any one release.
@MainActor
final class SidebarTreeBuilderTests: XCTestCase {

    // MARK: - Fixtures

    private func project(
        _ name: String,
        sessions: [AgentSession],
        terminals: [ProjectTerminal] = []
    ) -> Project {
        var project = Project(
            name: name,
            folderURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("threading-tree-\(name)-\(UUID().uuidString)")
        )
        project.sessions = sessions
        project.terminals = terminals
        return project
    }

    private func session(
        _ title: String,
        branch: String? = nil,
        forkedFrom parent: SessionID? = nil,
        isArchived: Bool = false,
        isPinned: Bool = false,
        lastActiveAt: Date? = nil,
        id: SessionID = SessionID()
    ) -> AgentSession {
        let origin = parent.map(ClaudeSessionOrigin.forked(from:)) ?? .original
        var session = AgentSession(
            configuration: .claude(
                remoteControl: nil,
                reasoningEffort: nil,
                origin: origin
            ),
            title: title,
            id: id
        )
        session.branch = branch
        session.isArchived = isArchived
        session.isPinned = isPinned
        if let lastActiveAt {
            session.lastActiveAt = lastActiveAt
        }
        return session
    }

    private func sessionNodes(in nodes: [NSObject]) -> [SessionNode] {
        nodes.compactMap { $0 as? SessionNode }
    }

    private func allSessionIDs(in nodes: [NSObject]) -> [SessionID] {
        nodes.flatMap { node -> [SessionID] in
            let own = (node as? SessionNode).map { [$0.sessionID] } ?? []
            return own + allSessionIDs(in: SidebarTreeBuilder.children(of: node))
        }
    }

    private func terminal(_ path: String, branch: String?) -> ProjectTerminal {
        var terminal = ProjectTerminal(currentDirectory: path)
        terminal.branch = branch
        return terminal
    }

    /// Sets a defaults key for one test and restores the registered seed afterwards.
    ///
    /// Written straight to `UserDefaults` rather than through `AppSettings.shared`, whose
    /// setter posts `AppSettingsDidChange` into whatever observers the test host has live.
    private func withDefault(_ value: Any?, forKey key: String, run: () throws -> Void) rethrows {
        UserDefaults.standard.set(value, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        try run()
    }

    /// One order, read backwards — the two keys the tree builder consults for that.
    private func withReversedOrder(
        _ order: SidebarSessionOrder,
        run: () throws -> Void
    ) rethrows {
        try withDefault(order.rawValue, forKey: "sidebarSessionOrder") {
            try withDefault(true, forKey: "sidebarSessionOrderIsReversed", run: run)
        }
    }

    /// The main window passes through toolbar and saved-frame layouts before it is shown. A
    /// deferred sidebar must remain a real, laid-out surface during those passes without asking
    /// AppKit to construct rows until the host says its final geometry is ready.
    func testADeferredInitialTreeMountBuildsRowsOnlyAfterTheHostCrossesTheBoundary() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-sidebar-deferred-mount-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = StateManager(appSupportDirectory: directory)
        defer { manager.closeDatabase() }
        let stored = project("Deferred", sessions: [session("Visible")])
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: [stored])))

        let controller = ProjectSidebarViewController(
            projectStore: ProjectStore(stateManager: manager),
            defersInitialTreeMount: true
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 720)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.outlineRowCount, 0)
        XCTAssertEqual(controller.instantiatedRowCount, 0)

        controller.mountInitialTreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.outlineRowCount, 2)
        XCTAssertGreaterThan(controller.instantiatedRowCount, 0)

        controller.mountInitialTreeIfNeeded()
        XCTAssertEqual(controller.outlineRowCount, 2, "a repeated lifecycle signal remounted the tree")
    }

    /// Suppressing the viewport during the atomic first mount must not change disclosure
    /// semantics. Persisted project closure wins initially, while the branch and side-chat
    /// descendants keep their default-open state for the moment the project is opened.
    func testADeferredInitialMountPreservesExpansionInsideACollapsedProject() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-sidebar-collapsed-first-mount-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let parent = session("Parent", branch: "main")
        let child = session("Child", branch: "main", forkedFrom: parent.id)
        let sibling = session("Sibling", branch: "main")
        var stored = project("Collapsed", sessions: [parent, child, sibling])
        stored.isExpanded = false

        let manager = StateManager(appSupportDirectory: directory)
        defer { manager.closeDatabase() }
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: [stored])))

        let controller = ProjectSidebarViewController(
            projectStore: ProjectStore(stateManager: manager),
            defersInitialTreeMount: true
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 720)
        controller.view.layoutSubtreeIfNeeded()
        controller.mountInitialTreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.presentedRowKeys, [.project(stored.id)])

        controller.setExpanded(true, forProject: stored.id)

        XCTAssertEqual(
            Set(controller.presentedRowKeys),
            Set([
                .project(stored.id),
                .branch(stored.id, "main"),
                .session(parent.id),
                .session(child.id),
                .session(sibling.id)
            ]),
            "opening the persisted-closed project left a cold descendant collapsed"
        )
    }

    /// The no-project prompt is an empty-data branch, not part of the populated sidebar's
    /// launch cost. In particular, hiding it must not instantiate and theme two labels merely
    /// so they can remain invisible.
    func testAPopulatedInitialTreeDoesNotMaterializeTheEmptyState() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-sidebar-populated-empty-state-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = StateManager(appSupportDirectory: directory)
        defer { manager.closeDatabase() }
        let stored = project("Populated", sessions: [session("Visible")])
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: [stored])))

        let controller = ProjectSidebarViewController(
            projectStore: ProjectStore(stateManager: manager)
        )
        _ = controller.view

        XCTAssertFalse(controller.emptyStateIsMaterialized)
        controller.setSettingsMode(true)
        controller.setSettingsMode(false)
        XCTAssertFalse(
            controller.emptyStateIsMaterialized,
            "a settings round-trip constructed the hidden no-project prompt"
        )
    }

    /// Cold expansion follows hierarchy, not the selected sort order. A newer nested chat can
    /// sort ahead of its parent in the flat session list, but AppKit cannot expand it until the
    /// parent row exists.
    func testColdMountExpandsNestedSideChatsInTreeOrder() {
        withDefault(
            SidebarSessionOrder.recentActivity.rawValue,
            forKey: "sidebarSessionOrder"
        ) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "threading-sidebar-tree-expansion-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            let parent = session(
                "parent",
                lastActiveAt: Date(timeIntervalSinceReferenceDate: 100)
            )
            let child = session(
                "child",
                forkedFrom: parent.id,
                lastActiveAt: Date(timeIntervalSinceReferenceDate: 200)
            )
            let grandchild = session(
                "grandchild",
                forkedFrom: child.id,
                lastActiveAt: Date(timeIntervalSinceReferenceDate: 300)
            )
            let manager = StateManager(appSupportDirectory: directory)
            defer { manager.closeDatabase() }
            XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: [
                project("Nested", sessions: [parent, child, grandchild])
            ])))

            let controller = ProjectSidebarViewController(
                projectStore: ProjectStore(stateManager: manager)
            )
            _ = controller.view
            controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 720)
            controller.view.layoutSubtreeIfNeeded()

            XCTAssertEqual(controller.outlineRowCount, 4)
        }
    }

    /// A rename under Name order updates the affected project's ordering without disturbing
    /// the rest of the presented tree.
    func testNameOrderedRenameMovesTheSessionWithinItsProject() {
        withDefault(SidebarSessionOrder.name.rawValue, forKey: "sidebarSessionOrder") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "threading-sidebar-name-reorder-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            let later = session("Zulu")
            let earlier = session("Alpha")
            let untouched = session("Other project")
            let firstProject = project("First", sessions: [later, earlier])
            let secondProject = project("Second", sessions: [untouched])
            let manager = StateManager(appSupportDirectory: directory)
            defer { manager.closeDatabase() }
            XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: [
                firstProject, secondProject
            ])))
            let store = ProjectStore(stateManager: manager)
            let controller = ProjectSidebarViewController(projectStore: store)
            _ = controller.view

            XCTAssertEqual(
                controller.presentedRowKeys,
                [
                    .project(firstProject.id), .session(earlier.id), .session(later.id),
                    .project(secondProject.id), .session(untouched.id)
                ]
            )

            XCTAssertEqual(store.renameSession(id: later.id, to: "0 First"), .applied)

            XCTAssertEqual(
                controller.presentedRowKeys,
                [
                    .project(firstProject.id), .session(later.id), .session(earlier.id),
                    .project(secondProject.id), .session(untouched.id)
                ]
            )
        }
    }

    /// The lazy branch still has to cross on the one state that needs it.
    func testAnEmptyInitialTreeMaterializesTheEmptyState() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-sidebar-empty-state-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = StateManager(appSupportDirectory: directory)
        defer { manager.closeDatabase() }
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: [])))

        let controller = ProjectSidebarViewController(
            projectStore: ProjectStore(stateManager: manager)
        )
        _ = controller.view

        XCTAssertTrue(controller.emptyStateIsMaterialized)
    }

    // MARK: - Earning a level

    func testSnoozeScopesFilterWithoutFlatteningTheProjectHierarchy() throws {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        let attentive = session("attentive", isPinned: true)
        var snoozed = session("snoozed", branch: "feature", isPinned: true)
        snoozed.snoozedAt = date.addingTimeInterval(-60)
        snoozed.snoozedUntil = date.addingTimeInterval(3_600)
        let project = project("p", sessions: [attentive, snoozed])

        let attentionRoots = SidebarTreeBuilder.rootNodes(from: [project], at: date)
        let snoozedRoots = SidebarTreeBuilder.rootNodes(
            from: [project],
            visibility: .snoozed,
            at: date
        )

        XCTAssertTrue(try XCTUnwrap(attentionRoots.first) is ProjectNode)
        XCTAssertTrue(try XCTUnwrap(snoozedRoots.first) is ProjectNode)
        XCTAssertEqual(allSessionIDs(in: attentionRoots), [attentive.id])
        XCTAssertEqual(allSessionIDs(in: snoozedRoots), [snoozed.id])
    }

    /// One checkout is a plain project row. The repository level exists to tell *several*
    /// checkouts apart, and an extra level that groups one thing says nothing.
    func testASingleCheckoutIsNotGrouped() {
        let roots = SidebarTreeBuilder.rootNodes(from: [project("one", sessions: [session("a")])])

        XCTAssertEqual(roots.count, 1)
        XCTAssertTrue(roots.first is ProjectNode, "a lone project grew a repository heading")
    }

    /// With the lone-branch refinement off, a branch groups its sessions only when it has
    /// more than one — the original rule, kept reachable because a heading over a single row
    /// costs indentation some users will not want to spend.
    func testALoneBranchStaysAtTheProjectLevelWithTheRefinementOff() throws {
        try withDefault(false, forKey: "groupsLoneBranches") {
            let alone = session("alone", branch: "solo")
            let paired = [session("first", branch: "shared"), session("second", branch: "shared")]

            let roots = SidebarTreeBuilder.rootNodes(
                from: [project("p", sessions: [alone] + paired)]
            )
            let node = try XCTUnwrap(roots.first as? ProjectNode)

            XCTAssertEqual(
                sessionNodes(in: node.childNodes).map(\.sessionID),
                [alone.id],
                "the lone branch's session was hidden under a heading"
            )

            let groups = node.childNodes.compactMap { $0 as? BranchGroupNode }
            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(groups.first?.sessionNodes.map(\.sessionID), paired.map(\.id))
        }
    }

    /// The default: once some branch has earned a heading, a lone branch earns one too. A
    /// heading over the shared branch beside a bare row on its own branch read as though the
    /// bare row had no branch at all — the tree is either fully flat or fully labelled.
    func testALoneBranchEarnsAHeadingOnceAnyBranchIsShared() throws {
        let alone = session("alone", branch: "solo")
        let paired = [session("first", branch: "shared"), session("second", branch: "shared")]

        let roots = SidebarTreeBuilder.rootNodes(
            from: [project("p", sessions: [alone] + paired)]
        )
        let node = try XCTUnwrap(roots.first as? ProjectNode)

        XCTAssertTrue(
            sessionNodes(in: node.childNodes).isEmpty,
            "a session sat bare beside a branch heading"
        )

        let groups = node.childNodes.compactMap { $0 as? BranchGroupNode }
        XCTAssertEqual(groups.map(\.branch), ["solo", "shared"])
        XCTAssertEqual(groups.first?.sessionNodes.map(\.sessionID), [alone.id])
    }

    /// All-or-nothing has a nothing: a project whose branches are all singletons stays flat,
    /// so the common one-branch-per-chat project never pays a level per row.
    func testAProjectOfOnlyLoneBranchesStaysFlat() throws {
        let sessions = [session("a", branch: "one"), session("b", branch: "two")]

        let roots = SidebarTreeBuilder.rootNodes(from: [project("p", sessions: sessions)])
        let node = try XCTUnwrap(roots.first as? ProjectNode)

        XCTAssertEqual(
            sessionNodes(in: node.childNodes).map(\.sessionID),
            sessions.map(\.id),
            "singleton branches grew headings with nothing shared to justify the level"
        )
    }

    /// A session with no recorded branch stays bare even while every branch is labelled —
    /// a heading needs a name, and inventing one would claim something the record never said.
    func testASessionWithNoBranchStaysBareUnderFullLabelling() throws {
        let unbranched = session("unbranched")
        let paired = [session("first", branch: "shared"), session("second", branch: "shared")]

        let roots = SidebarTreeBuilder.rootNodes(
            from: [project("p", sessions: [unbranched] + paired)]
        )
        let node = try XCTUnwrap(roots.first as? ProjectNode)

        XCTAssertEqual(
            sessionNodes(in: node.childNodes).map(\.sessionID),
            [unbranched.id]
        )
    }

    /// A group takes the position of its first session, so grouping rearranges nothing the user
    /// had learned the order of. Run with the lone-branch refinement off so the middle row
    /// stays bare — its position is what the assertion reads.
    func testABranchGroupTakesItsFirstSessionsPlace() throws {
        try withDefault(false, forKey: "groupsLoneBranches") {
            let first = session("first", branch: "shared")
            let middle = session("middle", branch: "lonely")
            let last = session("last", branch: "shared")

            let roots = SidebarTreeBuilder.rootNodes(
                from: [project("p", sessions: [first, middle, last])]
            )
            let node = try XCTUnwrap(roots.first as? ProjectNode)

            XCTAssertTrue(node.childNodes.first is BranchGroupNode, "the group left its place")
            XCTAssertEqual((node.childNodes.last as? SessionNode)?.sessionID, middle.id)
        }
    }

    func testAChatAndTerminalOnTheSameBranchShareAHeading() throws {
        let chat = session("chat", branch: "feature")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-terminal-tree-\(UUID().uuidString)")
            .path
        let shell = terminal(folder, branch: "feature")
        let roots = SidebarTreeBuilder.rootNodes(
            from: [project("p", sessions: [chat], terminals: [shell])]
        )
        let projectNode = try XCTUnwrap(roots.first as? ProjectNode)
        let branch = try XCTUnwrap(projectNode.childNodes.first as? BranchGroupNode)

        XCTAssertEqual(branch.branch, "feature")
        XCTAssertEqual(branch.sessionNodes.map(\.sessionID), [chat.id])
        XCTAssertEqual(branch.terminalNodes.map(\.terminalID), [shell.id])
    }

    /// `NSOutlineView` asks for every child separately while expanding a branch. The indexed
    /// seam must preserve the same sessions-then-terminals order as `childNodes` without making
    /// a fresh combined array for every one of those requests.
    func testABranchServesItsOutlineChildrenDirectlyInDisplayOrder() {
        let branch = BranchGroupNode(branch: "large", projectID: ProjectID())
        let sessions = (0..<5).map { _ in SessionNode(sessionID: SessionID()) }
        let terminals = (0..<3).map { _ in
            TerminalNode(terminalID: TerminalID(), displayProjectFolderPath: "/tmp")
        }
        branch.sessionNodes = sessions
        branch.terminalNodes = terminals

        XCTAssertEqual(branch.outlineChildCount, sessions.count + terminals.count)
        for (index, expected) in (sessions as [NSObject] + terminals as [NSObject]).enumerated() {
            XCTAssertIdentical(branch.outlineChild(at: index), expected)
        }
    }

    // MARK: - Side chats

    func testASideChatNestsUnderItsParent() throws {
        let parent = session("parent")
        let child = session("child", forkedFrom: parent.id)

        let roots = SidebarTreeBuilder.rootNodes(from: [project("p", sessions: [parent, child])])
        let node = try XCTUnwrap(roots.first as? ProjectNode)

        let top = sessionNodes(in: node.childNodes)
            + node.childNodes.compactMap { ($0 as? BranchGroupNode)?.sessionNodes }.flatMap { $0 }
        XCTAssertEqual(top.map(\.sessionID), [parent.id], "the side chat stayed at the top level")

        let parentNode = try XCTUnwrap(top.first)
        XCTAssertEqual(parentNode.childNodes.map(\.sessionID), [child.id])
    }

    /// A parent that is gone — deleted, or archived out of this list — leaves the side chat
    /// where it can still be seen. The lineage dangles; the row must not vanish with it.
    func testASideChatWithNoParentStaysVisible() throws {
        let orphan = session("orphan", forkedFrom: SessionID())

        let roots = SidebarTreeBuilder.rootNodes(from: [project("p", sessions: [orphan])])
        let node = try XCTUnwrap(roots.first as? ProjectNode)

        let top = sessionNodes(in: node.childNodes)
        XCTAssertEqual(top.map(\.sessionID), [orphan.id], "an orphaned side chat disappeared")
    }

    /// The rule that is a hang rather than a wrong row: two sessions each recorded as forked
    /// from the other. The outline view asks for children lazily, so a tree that accepted this
    /// would recurse until the app died. Both must surface at the top level instead.
    func testMutuallyForkedSessionsDoNotRecurse() throws {
        let firstID = SessionID()
        let secondID = SessionID()
        let first = session("first", forkedFrom: secondID, id: firstID)
        let second = session("second", forkedFrom: firstID, id: secondID)

        let roots = SidebarTreeBuilder.rootNodes(
            from: [project("p", sessions: [first, second])]
        )
        let node = try XCTUnwrap(roots.first as? ProjectNode)

        let top = sessionNodes(in: node.childNodes)
        XCTAssertEqual(
            Set(top.map(\.sessionID)),
            [first.id, second.id],
            "a cycle in the stored lineage swallowed a row"
        )
        XCTAssertTrue(
            top.allSatisfy { $0.childNodes.isEmpty },
            "a cycle was attached, which the outline view would follow forever"
        )
    }

    /// A session forked from itself is refused before it can reach the tree.
    func testASelfForkedSessionIsRefusedAtTheModelBoundary() {
        let id = SessionID()
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AgentSession.self,
                from: Data(
                    """
                    {"id":"\(id.uuidString)","kind":"claude","title":"loop",\
                    "forkParent":"\(id.uuidString)"}
                    """.utf8
                )
            )
        )
    }

    // MARK: - Reaching a row

    /// The chain a selection has to open. `NSOutlineView` has no row for a hidden item and
    /// answers `-1`, which every call site reads as "nothing to do" — so a level missing from
    /// this list is a session that cannot be selected at all, silently.
    func testASideChatsChainIncludesTheSessionItWasForkedFrom() throws {
        let parent = session("parent")
        let child = session("child", forkedFrom: parent.id)
        let roots = SidebarTreeBuilder.rootNodes(from: [project("p", sessions: [parent, child])])

        let chain = SidebarTreeBuilder.ancestors(of: child.id, in: roots)

        XCTAssertEqual(chain.count, 2, "the chain should be the project and the parent session")
        XCTAssertTrue(chain.first is ProjectNode, "the project must open before its rows load")
        XCTAssertEqual(
            (chain.last as? SessionNode)?.sessionID,
            parent.id,
            "a folded-away side chat had no row, so selecting it did nothing"
        )
    }

    /// Side chats nest, so the chain does too.
    func testASideChatOfASideChatCarriesBothParents() throws {
        let root = session("root")
        let middle = session("middle", forkedFrom: root.id)
        let leaf = session("leaf", forkedFrom: middle.id)

        let roots = SidebarTreeBuilder.rootNodes(
            from: [project("p", sessions: [root, middle, leaf])]
        )
        let chain = SidebarTreeBuilder.ancestors(of: leaf.id, in: roots)

        XCTAssertEqual(
            chain.compactMap { ($0 as? SessionNode)?.sessionID },
            [root.id, middle.id],
            "every session above the row has to open, outermost first"
        )
    }

    /// A branch heading is a level like any other, and it comes after the project.
    func testAGroupedSessionOpensItsProjectThenItsBranch() throws {
        let first = session("first", branch: "shared")
        let second = session("second", branch: "shared")

        let roots = SidebarTreeBuilder.rootNodes(
            from: [project("p", sessions: [first, second])]
        )
        let chain = SidebarTreeBuilder.ancestors(of: second.id, in: roots)

        XCTAssertTrue(chain.first is ProjectNode)
        XCTAssertEqual((chain.last as? BranchGroupNode)?.branch, "shared")
    }

    func testAGroupedTerminalOpensItsProjectThenItsBranch() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-terminal-chain-\(UUID().uuidString)")
            .path
        let first = terminal(folder, branch: "shared")
        let second = terminal(folder, branch: "shared")
        let roots = SidebarTreeBuilder.rootNodes(
            from: [project("p", sessions: [], terminals: [first, second])]
        )

        let chain = SidebarTreeBuilder.ancestors(of: second.id, in: roots)
        XCTAssertTrue(chain.first is ProjectNode)
        XCTAssertEqual((chain.last as? BranchGroupNode)?.branch, "shared")
    }

    /// The order is what makes it usable: `expandItem` on a level whose parent is still shut
    /// has nothing to expand, so the chain is walked from the root down.
    func testTheChainIsOutermostFirst() throws {
        let parent = session("parent", branch: "shared")
        let sibling = session("sibling", branch: "shared")
        let child = session("child", branch: "shared", forkedFrom: parent.id)

        let roots = SidebarTreeBuilder.rootNodes(
            from: [project("p", sessions: [parent, sibling, child])]
        )
        let chain = SidebarTreeBuilder.ancestors(of: child.id, in: roots)

        XCTAssertEqual(chain.count, 3)
        XCTAssertTrue(chain[0] is ProjectNode)
        XCTAssertTrue(chain[1] is BranchGroupNode)
        XCTAssertEqual((chain[2] as? SessionNode)?.sessionID, parent.id)
    }

    /// A session that is not in the tree — archived, or removed while a notification about it
    /// was still on screen — has no chain rather than a partial one.
    func testAnAbsentSessionHasNoChain() {
        let roots = SidebarTreeBuilder.rootNodes(from: [project("p", sessions: [session("a")])])

        XCTAssertTrue(SidebarTreeBuilder.ancestors(of: SessionID(), in: roots).isEmpty)
    }

    // MARK: - Ordering

    /// Recent activity puts the most recently touched session first; the store order breaks
    /// the tie so two untouched sessions cannot swap between rebuilds.
    func testRecentActivityOrdersSessionsByLastActiveDescending() throws {
        try withDefault(SidebarSessionOrder.recentActivity.rawValue, forKey: "sidebarSessionOrder") {
            let stale = session("stale", lastActiveAt: Date(timeIntervalSinceReferenceDate: 100))
            let fresh = session("fresh", lastActiveAt: Date(timeIntervalSinceReferenceDate: 200))

            let roots = SidebarTreeBuilder.rootNodes(from: [project("p", sessions: [stale, fresh])])
            let node = try XCTUnwrap(roots.first as? ProjectNode)

            XCTAssertEqual(node.sessionNodes.map(\.sessionID), [fresh.id, stale.id])
        }
    }

    func testNameOrderIsAlphabeticalAndCaseInsensitive() throws {
        try withDefault(SidebarSessionOrder.name.rawValue, forKey: "sidebarSessionOrder") {
            let banana = session("banana")
            let apple = session("Apple")
            let cherry = session("cherry")

            let roots = SidebarTreeBuilder.rootNodes(
                from: [project("p", sessions: [banana, apple, cherry])]
            )
            let node = try XCTUnwrap(roots.first as? ProjectNode)

            XCTAssertEqual(
                node.sessionNodes.map(\.sessionID),
                [apple.id, banana.id, cherry.id]
            )
        }
    }

    /// Reversed, the same field is read from the other end: the stalest session leads.
    func testReversedRecentActivityPutsTheLeastRecentFirst() throws {
        try withReversedOrder(.recentActivity) {
            let stale = session("stale", lastActiveAt: Date(timeIntervalSinceReferenceDate: 100))
            let fresh = session("fresh", lastActiveAt: Date(timeIntervalSinceReferenceDate: 200))

            let roots = SidebarTreeBuilder.rootNodes(from: [project("p", sessions: [stale, fresh])])
            let node = try XCTUnwrap(roots.first as? ProjectNode)

            XCTAssertEqual(node.sessionNodes.map(\.sessionID), [stale.id, fresh.id])
        }
    }

    /// Order Added has no field of its own — the store offset *is* the sort — so reversing has
    /// to reach the offset rather than leaving it as an untouched tie-break.
    func testReversedOrderAddedPutsTheNewestFirst() throws {
        try withReversedOrder(.manual) {
            let first = session("first")
            let second = session("second")
            let third = session("third")

            let roots = SidebarTreeBuilder.rootNodes(
                from: [project("p", sessions: [first, second, third])]
            )
            let node = try XCTUnwrap(roots.first as? ProjectNode)

            XCTAssertEqual(node.sessionNodes.map(\.sessionID), [third.id, second.id, first.id])
        }
    }

    /// Manual order is a stable partition rather than a comparison sort: pins lead, while each
    /// side of that boundary keeps the exact order represented by the store.
    func testOrderAddedPreservesStoreOrderWithinPinnedAndUnpinnedSessions() throws {
        try withDefault(SidebarSessionOrder.manual.rawValue, forKey: "sidebarSessionOrder") {
            try withDefault(false, forKey: "sidebarSessionOrderIsReversed") {
                let first = session("first")
                let firstPinned = session("first pinned", isPinned: true)
                let second = session("second")
                let secondPinned = session("second pinned", isPinned: true)

                let roots = SidebarTreeBuilder.rootNodes(
                    from: [project(
                        "p",
                        sessions: [first, firstPinned, second, secondPinned]
                    )]
                )
                let node = try XCTUnwrap(roots.first as? ProjectNode)

                XCTAssertEqual(
                    node.sessionNodes.map(\.sessionID),
                    [firstPinned.id, secondPinned.id, first.id, second.id]
                )
            }
        }
    }

    /// Reversing Order Added reverses each partition, not pin priority itself.
    func testReversedOrderAddedPreservesPinPriority() throws {
        try withReversedOrder(.manual) {
            let first = session("first")
            let firstPinned = session("first pinned", isPinned: true)
            let second = session("second")
            let secondPinned = session("second pinned", isPinned: true)

            let roots = SidebarTreeBuilder.rootNodes(
                from: [project(
                    "p",
                    sessions: [first, firstPinned, second, secondPinned]
                )]
            )
            let node = try XCTUnwrap(roots.first as? ProjectNode)

            XCTAssertEqual(
                node.sessionNodes.map(\.sessionID),
                [secondPinned.id, firstPinned.id, second.id, first.id]
            )
        }
    }

    func testReversedNameOrderRunsZToA() throws {
        try withReversedOrder(.name) {
            let banana = session("banana")
            let apple = session("Apple")
            let cherry = session("cherry")

            let roots = SidebarTreeBuilder.rootNodes(
                from: [project("p", sessions: [banana, apple, cherry])]
            )
            let node = try XCTUnwrap(roots.first as? ProjectNode)

            XCTAssertEqual(
                node.sessionNodes.map(\.sessionID),
                [cherry.id, banana.id, apple.id]
            )
        }
    }

    /// Reversing reverses the sort, not the list: pinning outranks a direction the same way it
    /// outranks an order, so a pinned session leads rather than sinking to the bottom.
    func testPinnedSessionsStillLeadAReversedOrder() throws {
        try withReversedOrder(.recentActivity) {
            let stale = session("stale", lastActiveAt: Date(timeIntervalSinceReferenceDate: 100))
            let pinnedFresh = session(
                "pinned",
                isPinned: true,
                lastActiveAt: Date(timeIntervalSinceReferenceDate: 200)
            )

            let roots = SidebarTreeBuilder.rootNodes(
                from: [project("p", sessions: [stale, pinnedFresh])]
            )
            let node = try XCTUnwrap(roots.first as? ProjectNode)

            XCTAssertEqual(node.sessionNodes.map(\.sessionID), [pinnedFresh.id, stale.id])
        }
    }

    /// Pinning is a stronger statement than any sort: a pinned session leads even when the
    /// order would place it last.
    func testPinnedSessionsLeadEveryOrder() throws {
        try withDefault(SidebarSessionOrder.recentActivity.rawValue, forKey: "sidebarSessionOrder") {
            let fresh = session("fresh", lastActiveAt: Date(timeIntervalSinceReferenceDate: 200))
            let pinnedStale = session(
                "pinned",
                isPinned: true,
                lastActiveAt: Date(timeIntervalSinceReferenceDate: 100)
            )

            let roots = SidebarTreeBuilder.rootNodes(
                from: [project("p", sessions: [fresh, pinnedStale])]
            )
            let node = try XCTUnwrap(roots.first as? ProjectNode)

            XCTAssertEqual(node.sessionNodes.map(\.sessionID), [pinnedStale.id, fresh.id])
        }
    }

    // MARK: - Archived

    /// Archived sessions live in Settings, so the sidebar stays a list of what is active.
    func testArchivedSessionsAreNotInTheTree() throws {
        let live = session("live")
        let archived = session("archived", isArchived: true)

        let roots = SidebarTreeBuilder.rootNodes(
            from: [project("p", sessions: [live, archived])]
        )
        let node = try XCTUnwrap(roots.first as? ProjectNode)

        XCTAssertEqual(node.sessionNodes.map(\.sessionID), [live.id])
    }

    // MARK: - Stress profiling

    /// Opt-in because this loads a real `NSOutlineView` with thousands of production nodes.
    /// The store is backed by a throwaway database, so the workload never reads or changes the
    /// projects in the running app.
    func testStressProjectSidebarWhenEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_SIDEBAR_STRESS"] == "1",
            "Set THREADING_SIDEBAR_STRESS=1 to run the project-sidebar sweep."
        )

        let defaults = UserDefaults.standard
        let stressOrder = ProcessInfo.processInfo.environment["THREADING_SIDEBAR_STRESS_ORDER"]
            .flatMap(SidebarSessionOrder.init(rawValue:))
            ?? .manual
        let deterministicDefaults: [(String, Any)] = [
            ("sidebarSessionOrder", stressOrder.rawValue),
            ("groupsSessionsByBranch", true),
            ("groupsLoneBranches", true)
        ]
        let previousDefaults = deterministicDefaults.map { key, _ in
            (key, defaults.object(forKey: key))
        }
        for (key, value) in deterministicDefaults { defaults.set(value, forKey: key) }
        defer {
            for (key, value) in previousDefaults {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let projectCount = ProcessInfo.processInfo.environment["THREADING_SIDEBAR_STRESS_PROJECTS"]
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
            ?? 10
        let sessionsPerProject = ProcessInfo.processInfo.environment[
            "THREADING_SIDEBAR_STRESS_SESSIONS"
        ]
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
            ?? 100

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-sidebar-stress-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = stressProjects(
            projectCount: projectCount,
            sessionsPerProject: sessionsPerProject,
            directory: directory
        )
        // Seed outside the measured app lifetime. Otherwise the first deletion inherits an
        // automatic WAL checkpoint from constructing 5,000 rows moments earlier — setup work a
        // real launch with an existing sidebar completed in the previous process.
        let seedManager = StateManager(appSupportDirectory: directory)
        XCTAssertTrue(seedManager.saveProjectsState(ProjectsState(projects: fixture.projects)))
        seedManager.closeDatabase()

        let manager = StateManager(appSupportDirectory: directory)
        // This opt-in workload deletes its isolated store on return. Close SQLite first: unlinking
        // the WAL underneath a live connection is an API violation and can crash xctest while
        // its autorelease pool drains, after a perfectly valid performance line was printed.
        defer { manager.closeDatabase() }
        let store = ProjectStore(stateManager: manager)
        // Match MainWindowController: construct and lay out the sidebar shell at its permanent
        // geometry, then cross the explicit initial-tree boundary. Eagerly mounting into a
        // zero-sized standalone view measured a transient layout the product deliberately avoids.
        let controller = ProjectSidebarViewController(
            projectStore: store,
            defersInitialTreeMount: true
        )

        let loadStarted = DispatchTime.now().uptimeNanoseconds
        _ = controller.view
        let shellLoaded = DispatchTime.now().uptimeNanoseconds
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 720)
        controller.view.layoutSubtreeIfNeeded()
        let shellLaidOut = DispatchTime.now().uptimeNanoseconds
        controller.mountInitialTreeIfNeeded()
        let loadEnded = DispatchTime.now().uptimeNanoseconds
        #if DEBUG
        let coldReload = controller.lastReloadPerformance
        #endif
        controller.view.layoutSubtreeIfNeeded()
        let layoutEnded = DispatchTime.now().uptimeNanoseconds

        #if DEBUG
        let allRowsRefreshStarted = DispatchTime.now().uptimeNanoseconds
        controller.refreshAllRowsForPerformanceComparison()
        let allRowsRefreshElapsed = DispatchTime.now().uptimeNanoseconds - allRowsRefreshStarted
        #else
        let allRowsRefreshElapsed: UInt64 = 0
        #endif

        let visibleRowsRefreshStarted = DispatchTime.now().uptimeNanoseconds
        controller.refreshRows()
        let visibleRowsRefreshElapsed = DispatchTime.now().uptimeNanoseconds
            - visibleRowsRefreshStarted

        let refreshStarted = DispatchTime.now().uptimeNanoseconds
        controller.reload()
        let refreshElapsed = DispatchTime.now().uptimeNanoseconds - refreshStarted

        let disclosureStarted = DispatchTime.now().uptimeNanoseconds
        controller.setExpanded(false, forProject: fixture.deepProjectID)
        controller.setExpanded(true, forProject: fixture.deepProjectID)
        controller.view.layoutSubtreeIfNeeded()
        let disclosureElapsed = DispatchTime.now().uptimeNanoseconds - disclosureStarted

        let expandedSessionCount = controller.presentedRowKeys.filter {
            if case .session = $0 { return true }
            return false
        }.count
        XCTAssertEqual(
            expandedSessionCount,
            projectCount * sessionsPerProject,
            "re-expanding the project did not restore every logical session row"
        )

        let deepKey = SidebarNodeKey.session(fixture.deepSessionID)
        let deepLogicalRow = try XCTUnwrap(controller.presentedRow(of: deepKey))
        XCTAssertGreaterThan(
            deepLogicalRow,
            controller.instantiatedRowCount,
            "the stress reveal target did not cross the outline's launch viewport boundary"
        )
        XCTAssertNil(
            controller.presentedRowView(of: deepKey),
            "the deep reveal target was already materialized before exact navigation"
        )

        let revealStarted = DispatchTime.now().uptimeNanoseconds
        controller.reveal(sessionID: fixture.deepSessionID)
        controller.view.layoutSubtreeIfNeeded()
        let revealElapsed = DispatchTime.now().uptimeNanoseconds - revealStarted
        XCTAssertEqual(controller.selectedSessionID, fixture.deepSessionID)
        XCTAssertNotNil(
            controller.presentedRowView(of: deepKey),
            "exact navigation selected the deep row without bringing it into the viewport"
        )

        let titleEventStarted = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(
            store.updateAgentTitle("Indexed sidebar title", for: fixture.deepSessionID),
            .accepted
        )
        let titleEventElapsed = DispatchTime.now().uptimeNanoseconds - titleEventStarted

        let churnIterations = 250
        #if DEBUG
        let scanningChurnStarted = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<churnIterations {
            controller.refreshRowByScanningForPerformanceComparison(
                sessionID: fixture.deepSessionID
            )
        }
        let scanningChurnElapsed = DispatchTime.now().uptimeNanoseconds - scanningChurnStarted
        #else
        let scanningChurnElapsed: UInt64 = 0
        #endif

        let churnStarted = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<churnIterations {
            controller.refreshRow(sessionID: fixture.deepSessionID)
        }
        let churnElapsed = DispatchTime.now().uptimeNanoseconds - churnStarted

        let treeStarted = DispatchTime.now().uptimeNanoseconds
        let roots = SidebarTreeBuilder.rootNodes(from: store.projects)
        let treeElapsed = DispatchTime.now().uptimeNanoseconds - treeStarted

        func nodeCount(_ nodes: [NSObject]) -> Int {
            nodes.reduce(0) { count, node in
                count + 1 + nodeCount(SidebarTreeBuilder.children(of: node))
            }
        }

        // A divider drag changes the sidebar's width once per pointer/display update. Drive the
        // production controller through a complete widening and narrowing pass, keeping each
        // tick separate so one long layout cannot hide inside a cheap total. This deliberately
        // runs after the other phases: resizing should not warm their first-layout measurements.
        let resizeTickCount = 120
        let narrowWidth: CGFloat = 220
        let wideWidth: CGFloat = 600
        var resizeSamples: [UInt64] = []
        resizeSamples.reserveCapacity(resizeTickCount)
        for tick in 0..<resizeTickCount {
            let half = resizeTickCount / 2
            let index = tick < half ? tick : resizeTickCount - tick - 1
            let fraction = CGFloat(index) / CGFloat(half - 1)
            let width = narrowWidth + (wideWidth - narrowWidth) * fraction
            let started = DispatchTime.now().uptimeNanoseconds
            controller.view.frame.size.width = width
            controller.view.layoutSubtreeIfNeeded()
            resizeSamples.append(DispatchTime.now().uptimeNanoseconds - started)
        }
        controller.view.frame.size.width = 300
        controller.view.layoutSubtreeIfNeeded()

        let orderedResizeSamples = resizeSamples.sorted()
        let resizeElapsed = resizeSamples.reduce(0, +)

        // Earlier phases intentionally mutate a title. Flush that independent work so this
        // sample measures removal itself rather than whichever coalesced write happens to win.
        store.flushPendingSave()

        // Permanent removal is a structural edit plus an immediate durable write. Keep it in
        // this same scaling sweep: the reported pause can come from the database walk, the
        // outline diff, or the layout that closes the visible gap, and a small fixture makes all
        // three look free. Keep a direct full reload beside it so broad invalidation stays visible.
        let removalProject = try XCTUnwrap(store.projects.dropFirst().first ?? store.projects.first)
        let dormantRemoval = try XCTUnwrap(
            removalProject.sessions.first(where: { $0.id != fixture.deepSessionID })
        )
        let dormantRemovalStarted = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(store.removeSession(id: dormantRemoval.id), .applied)
        let dormantMutationEnded = DispatchTime.now().uptimeNanoseconds
        #if DEBUG
        let dormantRemovalPhases = store.lastSessionRemovalPhaseNanoseconds
        let dormantSidebarUpdate = controller.lastProjectStructureNanoseconds
        let dormantSidebarPhases = controller.lastProjectStructurePerformance
        #endif
        controller.view.layoutSubtreeIfNeeded()
        let dormantLayoutEnded = DispatchTime.now().uptimeNanoseconds

        let fullReloadComparisonStarted = DispatchTime.now().uptimeNanoseconds
        controller.reload()
        controller.view.layoutSubtreeIfNeeded()
        let fullReloadComparisonEnded = DispatchTime.now().uptimeNanoseconds

        store.selectedSessionID = fixture.deepSessionID
        let selectedRemovalStarted = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(store.removeSession(id: fixture.deepSessionID), .applied)
        let selectedMutationEnded = DispatchTime.now().uptimeNanoseconds
        #if DEBUG
        let selectedRemovalPhases = store.lastSessionRemovalPhaseNanoseconds
        let selectedSidebarUpdate = controller.lastProjectStructureNanoseconds
        let selectedSidebarPhases = controller.lastProjectStructurePerformance
        let groupRuleRefreshCandidateCount = controller.lastGroupRuleRefreshCandidateCount
        #endif
        controller.view.layoutSubtreeIfNeeded()
        let selectedLayoutEnded = DispatchTime.now().uptimeNanoseconds

        XCTAssertFalse(roots.isEmpty)
        XCTAssertNil(store.selectedSessionID)
        XCTAssertFalse(controller.presentedRowKeys.contains(.session(dormantRemoval.id)))
        XCTAssertFalse(controller.presentedRowKeys.contains(.session(fixture.deepSessionID)))
        XCTAssertEqual(
            controller.outlineRowCount,
            nodeCount(roots) - 2,
            "removing two sessions did not leave the expected tree"
        )
        XCTAssertLessThan(controller.instantiatedRowCount, controller.outlineRowCount)
        #if DEBUG
        XCTAssertLessThan(
            groupRuleRefreshCandidateCount,
            controller.outlineRowCount,
            "a structural edit scanned logical rows instead of mounted row views"
        )
        #endif

        var performanceLine =
            "THREADING_PERF project-sidebar "
                + "order=\(stressOrder.rawValue) "
                + "projects=\(projectCount) sessions=\(projectCount * sessionsPerProject) "
                + "rows=\(controller.outlineRowCount) "
                + "instantiated=\(controller.instantiatedRowCount) "
                + "load_ms=\(Self.milliseconds(loadEnded - loadStarted)) "
                + "shell_load_ms=\(Self.milliseconds(shellLoaded - loadStarted)) "
                + "shell_layout_ms=\(Self.milliseconds(shellLaidOut - shellLoaded)) "
                + "cold_mount_ms=\(Self.milliseconds(loadEnded - shellLaidOut)) "
        #if DEBUG
        performanceLine += "cold_reload_ms=\(Self.milliseconds(coldReload.totalNanoseconds)) "
                + "cold_tree_ms=\(Self.milliseconds(coldReload.treeNanoseconds)) "
                + "cold_shape_ms=\(Self.milliseconds(coldReload.shapeNanoseconds)) "
                + "cold_adopt_ms=\(Self.milliseconds(coldReload.adoptionNanoseconds)) "
                + "cold_indexes_ms=\(Self.milliseconds(coldReload.indexingNanoseconds)) "
                + "cold_outline_ms=\(Self.milliseconds(coldReload.outlineNanoseconds)) "
                + "cold_other_ms=\(Self.milliseconds(coldReload.unclassifiedNanoseconds)) "
        #endif
        performanceLine += "layout_ms=\(Self.milliseconds(layoutEnded - loadEnded)) "
                + "cold_total_ms=\(Self.milliseconds(layoutEnded - loadStarted)) "
                + "all_rows_refresh_ms=\(Self.milliseconds(allRowsRefreshElapsed)) "
                + "visible_rows_refresh_ms=\(Self.milliseconds(visibleRowsRefreshElapsed)) "
                + "same_shape_refresh_ms=\(Self.milliseconds(refreshElapsed)) "
                + "disclosure_ms=\(Self.milliseconds(disclosureElapsed)) "
                + "deep_reveal_ms=\(Self.milliseconds(revealElapsed)) "
                + "title_event_ms=\(Self.milliseconds(titleEventElapsed)) "
                + "row_scan_refresh_250_ms=\(Self.milliseconds(scanningChurnElapsed)) "
                + "row_refresh_250_ms=\(Self.milliseconds(churnElapsed)) "
                + "tree_build_ms=\(Self.milliseconds(treeElapsed)) "
                + "resize_ticks=\(resizeTickCount) "
                + "resize_total_ms=\(Self.milliseconds(resizeElapsed)) "
                + "resize_p50_ms=\(Self.milliseconds(Self.percentile(0.50, in: orderedResizeSamples))) "
                + "resize_p95_ms=\(Self.milliseconds(Self.percentile(0.95, in: orderedResizeSamples))) "
                + "resize_max_ms=\(Self.milliseconds(orderedResizeSamples.last ?? 0)) "
                + "remove_dormant_mutation_ms="
                + Self.milliseconds(dormantMutationEnded - dormantRemovalStarted) + " "
                + "remove_dormant_layout_ms="
                + Self.milliseconds(dormantLayoutEnded - dormantMutationEnded) + " "
                + "remove_full_reload_comparison_ms="
                + Self.milliseconds(fullReloadComparisonEnded - fullReloadComparisonStarted) + " "
                + "remove_selected_mutation_ms="
                + Self.milliseconds(selectedMutationEnded - selectedRemovalStarted) + " "
                + "remove_selected_layout_ms="
                + Self.milliseconds(selectedLayoutEnded - selectedMutationEnded)
        #if DEBUG
        performanceLine += " remove_dormant_sidebar_ms="
                + Self.milliseconds(dormantSidebarUpdate)
                + " remove_dormant_tree_ms="
                + Self.milliseconds(dormantSidebarPhases.treeNanoseconds)
                + " remove_dormant_shape_ms="
                + Self.milliseconds(dormantSidebarPhases.shapeNanoseconds)
                + " remove_dormant_adopt_ms="
                + Self.milliseconds(dormantSidebarPhases.adoptionNanoseconds)
                + " remove_dormant_indexes_ms="
                + Self.milliseconds(dormantSidebarPhases.indexingNanoseconds)
                + " remove_dormant_outline_ms="
                + Self.milliseconds(dormantSidebarPhases.outlineNanoseconds)
                + " remove_selected_sidebar_ms="
                + Self.milliseconds(selectedSidebarUpdate)
                + " remove_selected_tree_ms="
                + Self.milliseconds(selectedSidebarPhases.treeNanoseconds)
                + " remove_selected_shape_ms="
                + Self.milliseconds(selectedSidebarPhases.shapeNanoseconds)
                + " remove_selected_adopt_ms="
                + Self.milliseconds(selectedSidebarPhases.adoptionNanoseconds)
                + " remove_selected_indexes_ms="
                + Self.milliseconds(selectedSidebarPhases.indexingNanoseconds)
                + " remove_selected_outline_ms="
                + Self.milliseconds(selectedSidebarPhases.outlineNanoseconds)
                + " remove_dormant_persistence_ms="
                + Self.milliseconds(dormantRemovalPhases["persistence"] ?? 0)
                + " remove_dormant_baselines_ms="
                + Self.milliseconds(dormantRemovalPhases["baselines"] ?? 0)
                + " remove_dormant_work_ms="
                + Self.milliseconds(dormantRemovalPhases["work"] ?? 0)
                + " remove_dormant_handoff_ms="
                + Self.milliseconds(dormantRemovalPhases["handoff"] ?? 0)
                + " remove_dormant_audit_ms="
                + Self.milliseconds(dormantRemovalPhases["audit"] ?? 0)
                + " remove_dormant_scheduled_ms="
                + Self.milliseconds(dormantRemovalPhases["scheduled"] ?? 0)
                + " remove_selected_persistence_ms="
                + Self.milliseconds(selectedRemovalPhases["persistence"] ?? 0)
                + " remove_selected_baselines_ms="
                + Self.milliseconds(selectedRemovalPhases["baselines"] ?? 0)
                + " remove_selected_work_ms="
                + Self.milliseconds(selectedRemovalPhases["work"] ?? 0)
                + " remove_selected_handoff_ms="
                + Self.milliseconds(selectedRemovalPhases["handoff"] ?? 0)
                + " remove_selected_audit_ms="
                + Self.milliseconds(selectedRemovalPhases["audit"] ?? 0)
                + " remove_selected_scheduled_ms="
                + Self.milliseconds(selectedRemovalPhases["scheduled"] ?? 0)
                + " group_rule_candidates=\(groupRuleRefreshCandidateCount)"
        #endif
        print(performanceLine)
    }

    private func stressProjects(
        projectCount: Int,
        sessionsPerProject: Int,
        directory: URL
    ) -> (projects: [Project], deepProjectID: ProjectID, deepSessionID: SessionID) {
        var projects: [Project] = []
        var deepProjectID = ProjectID()
        var deepSessionID = SessionID()

        for projectIndex in 0..<projectCount {
            var sessions: [AgentSession] = []
            let chainStart = max(1, sessionsPerProject - 4)

            for sessionIndex in 0..<sessionsPerProject {
                let parent = sessionIndex >= chainStart ? sessions.last?.id : nil
                let item = session(
                    "Project \(projectIndex) conversation \(sessionIndex)",
                    branch: "branch-\(sessionIndex % 5)",
                    forkedFrom: parent,
                    lastActiveAt: Date(
                        timeIntervalSinceReferenceDate: Double(projectIndex * sessionsPerProject + sessionIndex)
                    )
                )
                sessions.append(item)
            }

            var item = project("stress-\(projectIndex)", sessions: sessions)
            item.folderPath = directory
                .appendingPathComponent("project-\(projectIndex)", isDirectory: true)
                .path
            projects.append(item)

            if projectIndex == projectCount - 1, let last = sessions.last {
                deepProjectID = item.id
                deepSessionID = last.id
            }
        }

        return (projects, deepProjectID, deepSessionID)
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }

    private static func percentile(_ percentile: Double, in orderedValues: [UInt64]) -> UInt64 {
        guard !orderedValues.isEmpty else { return 0 }
        let index = Int((Double(orderedValues.count - 1) * percentile).rounded(.up))
        return orderedValues[index]
    }
}
