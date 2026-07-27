import XCTest
@testable import Skalman

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

    private func project(_ name: String, sessions: [AgentSession]) -> Project {
        var project = Project(
            name: name,
            folderURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("skalman-tree-\(name)-\(UUID().uuidString)")
        )
        project.sessions = sessions
        return project
    }

    private func session(
        _ title: String,
        branch: String? = nil,
        forkedFrom parent: SessionID? = nil,
        isArchived: Bool = false,
        isPinned: Bool = false,
        lastActiveAt: Date? = nil
    ) -> AgentSession {
        var session = AgentSession(kind: .claude, title: title, forkedFrom: parent)
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
        var first = session("first")
        var second = session("second")
        first.forkedFrom = second.id
        second.forkedFrom = first.id

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

    /// A session forked from itself is the smallest cycle there is.
    func testASelfForkedSessionStaysAtTheTopLevel() throws {
        var loop = session("loop")
        loop.forkedFrom = loop.id

        let roots = SidebarTreeBuilder.rootNodes(from: [project("p", sessions: [loop])])
        let node = try XCTUnwrap(roots.first as? ProjectNode)

        XCTAssertEqual(sessionNodes(in: node.childNodes).map(\.sessionID), [loop.id])
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
}
