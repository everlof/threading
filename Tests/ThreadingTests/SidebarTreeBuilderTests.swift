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
            configuration: .claude(remoteControl: nil, origin: origin),
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

    // MARK: - Earning a level

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
        let deterministicDefaults: [(String, Any)] = [
            ("sidebarSessionOrder", SidebarSessionOrder.manual.rawValue),
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
        let manager = StateManager(appSupportDirectory: directory)
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: fixture.projects)))
        let store = ProjectStore(stateManager: manager)
        let controller = ProjectSidebarViewController(projectStore: store)

        let loadStarted = DispatchTime.now().uptimeNanoseconds
        _ = controller.view
        let loadEnded = DispatchTime.now().uptimeNanoseconds
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 720)
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

        let revealStarted = DispatchTime.now().uptimeNanoseconds
        controller.reveal(sessionID: fixture.deepSessionID)
        controller.view.layoutSubtreeIfNeeded()
        let revealElapsed = DispatchTime.now().uptimeNanoseconds - revealStarted

        let titleEventStarted = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(
            store.updateAgentTitle("Indexed sidebar title", for: fixture.deepSessionID)
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

        XCTAssertFalse(roots.isEmpty)
        XCTAssertEqual(controller.selectedSessionID, fixture.deepSessionID)
        XCTAssertGreaterThan(controller.outlineRowCount, projectCount * sessionsPerProject)
        XCTAssertLessThan(controller.instantiatedRowCount, controller.outlineRowCount)

        print(
            "THREADING_PERF project-sidebar "
                + "projects=\(projectCount) sessions=\(projectCount * sessionsPerProject) "
                + "rows=\(controller.outlineRowCount) "
                + "instantiated=\(controller.instantiatedRowCount) "
                + "load_ms=\(Self.milliseconds(loadEnded - loadStarted)) "
                + "layout_ms=\(Self.milliseconds(layoutEnded - loadEnded)) "
                + "all_rows_refresh_ms=\(Self.milliseconds(allRowsRefreshElapsed)) "
                + "visible_rows_refresh_ms=\(Self.milliseconds(visibleRowsRefreshElapsed)) "
                + "same_shape_refresh_ms=\(Self.milliseconds(refreshElapsed)) "
                + "disclosure_ms=\(Self.milliseconds(disclosureElapsed)) "
                + "deep_reveal_ms=\(Self.milliseconds(revealElapsed)) "
                + "title_event_ms=\(Self.milliseconds(titleEventElapsed)) "
                + "row_scan_refresh_250_ms=\(Self.milliseconds(scanningChurnElapsed)) "
                + "row_refresh_250_ms=\(Self.milliseconds(churnElapsed)) "
                + "tree_build_ms=\(Self.milliseconds(treeElapsed))"
        )
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
}
