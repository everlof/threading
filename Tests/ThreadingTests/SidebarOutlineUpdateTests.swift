import AppKit
import XCTest
@testable import Threading

/// How the sidebar turns "the tree is different now" into "these rows arrived, left and moved".
///
/// The half worth testing without a window is what the outline is *told*: `NSOutlineView` raises
/// an exception rather than drawing something wrong when the steps do not add up, so the steps
/// adding up is the load-bearing part. Every case here is checked twice — once against the exact
/// instructions, and once by replaying them the way AppKit does, which is the assertion that
/// would catch a diff that is merely plausible.
@MainActor
final class SidebarOutlineUpdateTests: XCTestCase {

    // MARK: - Fixtures

    private func project(_ id: ProjectID = ProjectID(), children: [NSObject] = []) -> ProjectNode {
        let node = ProjectNode(projectID: id)
        node.childNodes = children
        node.sessionNodes = children.compactMap { $0 as? SessionNode }
        node.terminalNodes = children.compactMap { $0 as? TerminalNode }
        return node
    }

    private func session(_ id: SessionID = SessionID(), children: [SessionNode] = []) -> SessionNode {
        let node = SessionNode(sessionID: id)
        node.childNodes = children
        return node
    }

    private func branch(
        _ name: String,
        in projectID: ProjectID,
        sessions: [SessionNode]
    ) -> BranchGroupNode {
        let node = BranchGroupNode(branch: name, projectID: projectID)
        node.sessionNodes = sessions
        return node
    }

    /// Stands in for `NSOutlineView` while the steps are applied to it.
    ///
    /// Two behaviours, both measured against the real outline view before they were written
    /// down. **The steps are sequential** — each reads the state the previous ones left, with a
    /// parent's child indexes independent of every other parent's. And **a row the outline is
    /// given reads its own subtree from the data source**, which is already showing the new
    /// tree: an arriving row brings its children with it, and a leaving row takes its own away.
    /// That is exactly why the update never describes the children of a row it re-inserts.
    private func replay(
        _ steps: [SidebarOutlineStep],
        from old: SidebarTreeShape,
        to new: SidebarTreeShape
    ) -> [SidebarNodeKey?: [SidebarNodeKey]] {
        var model = old.childrenByParent

        func drop(_ key: SidebarNodeKey) {
            for child in model[key] ?? [] { drop(child) }
            model[key] = nil
        }

        func graft(_ key: SidebarNodeKey) {
            let children = new.children(of: key)
            guard !children.isEmpty else { return }
            model[key] = children
            children.forEach(graft)
        }

        for step in steps {
            switch step {
            case .remove(let parent, let indexes):
                var children = model[parent] ?? []
                for index in indexes.sorted(by: >) where children.indices.contains(index) {
                    drop(children.remove(at: index))
                }
                model[parent] = children

            case .move(let parent, let from, let to):
                var children = model[parent] ?? []
                guard children.indices.contains(from), to <= children.count else { break }
                let moved = children.remove(at: from)
                children.insert(moved, at: to)
                model[parent] = children

            case .insert(let parent, let indexes):
                var children = model[parent] ?? []
                for index in indexes.sorted() {
                    let arriving = new.children(of: parent)[index]
                    children.insert(arriving, at: min(index, children.count))
                    graft(arriving)
                }
                model[parent] = children
            }
        }

        return model.filter { !$0.value.isEmpty }
    }

    /// Applying the steps to the tree on screen reaches the tree the store now describes —
    /// every row, in order, at every level.
    private func assertReplayMatches(
        from old: SidebarTreeShape,
        to new: SidebarTreeShape,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let steps = SidebarOutlineUpdate.steps(from: old, to: new)
        XCTAssertEqual(
            replay(steps, from: old, to: new),
            new.childrenByParent,
            "replaying the update did not reach the new tree",
            file: file,
            line: line
        )
    }

    // MARK: - Nothing to do

    func testAnUnchangedTreeAsksTheOutlineForNothing() {
        let projectID = ProjectID()
        let first = SessionID()
        let second = SessionID()

        let before = SidebarTreeShape(roots: [
            project(projectID, children: [session(first), session(second)])
        ])
        let after = SidebarTreeShape(roots: [
            project(projectID, children: [session(first), session(second)])
        ])

        XCTAssertEqual(before, after)
        XCTAssertTrue(SidebarOutlineUpdate.steps(from: before, to: after).isEmpty)
    }

    // MARK: - Arriving and leaving

    func testAnArrivingRowIsOneInsertionAtItsPlace() {
        let projectID = ProjectID()
        let first = SessionID()
        let second = SessionID()
        let arriving = SessionID()

        let before = SidebarTreeShape(roots: [
            project(projectID, children: [session(first), session(second)])
        ])
        let after = SidebarTreeShape(roots: [
            project(projectID, children: [session(first), session(arriving), session(second)])
        ])

        XCTAssertEqual(
            SidebarOutlineUpdate.steps(from: before, to: after),
            [.insert(parent: .project(projectID), indexes: IndexSet(integer: 1))]
        )
        assertReplayMatches(from: before, to: after)
    }

    func testALeavingRowIsOneRemovalWhereItStood() {
        let projectID = ProjectID()
        let staying = SessionID()
        let leaving = SessionID()

        let before = SidebarTreeShape(roots: [
            project(projectID, children: [session(staying), session(leaving)])
        ])
        let after = SidebarTreeShape(roots: [project(projectID, children: [session(staying)])])

        XCTAssertEqual(
            SidebarOutlineUpdate.steps(from: before, to: after),
            [.remove(parent: .project(projectID), indexes: IndexSet(integer: 1))]
        )
        assertReplayMatches(from: before, to: after)
    }

    /// A project whose last session was deleted keeps its row and loses everything under it.
    /// The emptied parent has no entry left in the new shape at all, and a walk that only
    /// follows the new one never reaches it — which left the row on screen with nothing behind
    /// it, and the outline holding a child it had not been told about.
    func testAParentThatLostItsLastChildIsStillDescribed() {
        let projectID = ProjectID()
        let leaving = SessionID()

        let before = SidebarTreeShape(roots: [project(projectID, children: [session(leaving)])])
        let after = SidebarTreeShape(roots: [project(projectID)])

        XCTAssertEqual(
            SidebarOutlineUpdate.steps(from: before, to: after),
            [.remove(parent: .project(projectID), indexes: IndexSet(integer: 0))]
        )
        assertReplayMatches(from: before, to: after)
    }

    /// And the same the other way: a project that had nothing under it and now has a session.
    func testAParentThatGainedItsFirstChildIsDescribed() {
        let projectID = ProjectID()

        let before = SidebarTreeShape(roots: [project(projectID)])
        let after = SidebarTreeShape(roots: [project(projectID, children: [session()])])

        XCTAssertEqual(
            SidebarOutlineUpdate.steps(from: before, to: after),
            [.insert(parent: .project(projectID), indexes: IndexSet(integer: 0))]
        )
        assertReplayMatches(from: before, to: after)
    }

    func testAWholeProjectArrivesAsOneRowAtTheRoot() {
        let existing = ProjectID()
        let arriving = ProjectID()
        let standing = SessionID()

        let before = SidebarTreeShape(roots: [project(existing, children: [session(standing)])])
        let after = SidebarTreeShape(roots: [
            project(existing, children: [session(standing)]),
            project(arriving, children: [session(), session()])
        ])

        // One insertion at the root — the sessions under it are the outline's to read once the
        // row exists, not rows this update has to name.
        XCTAssertEqual(
            SidebarOutlineUpdate.steps(from: before, to: after),
            [.insert(parent: nil, indexes: IndexSet(integer: 1))]
        )
        assertReplayMatches(from: before, to: after)
    }

    // MARK: - Rearranging

    func testRearrangingIsMovesThatLandTheNewOrder() {
        let projectID = ProjectID()
        let first = SessionID()
        let second = SessionID()
        let third = SessionID()

        let before = SidebarTreeShape(roots: [
            project(projectID, children: [session(first), session(second), session(third)])
        ])
        // The session that just became active is hoisted to the top.
        let after = SidebarTreeShape(roots: [
            project(projectID, children: [session(third), session(first), session(second)])
        ])

        XCTAssertEqual(
            SidebarOutlineUpdate.steps(from: before, to: after),
            [.move(parent: .project(projectID), from: 2, to: 0)]
        )
        assertReplayMatches(from: before, to: after)
    }

    /// A shuffle costs one move per row that actually moved, not one per row.
    func testRowsThatDidNotMoveAreNotMoved() {
        let projectID = ProjectID()
        let ids = (0..<6).map { _ in SessionID() }

        let before = SidebarTreeShape(roots: [
            project(projectID, children: ids.map { session($0) })
        ])
        let reordered = [ids[0], ids[1], ids[4], ids[2], ids[3], ids[5]]
        let after = SidebarTreeShape(roots: [
            project(projectID, children: reordered.map { session($0) })
        ])

        let moves = SidebarOutlineUpdate.steps(from: before, to: after).filter {
            if case .move = $0 { return true } else { return false }
        }
        XCTAssertEqual(moves.count, 1)
        assertReplayMatches(from: before, to: after)
    }

    func testArrivingLeavingAndMovingAtOnceStillLandsTheNewOrder() {
        let projectID = ProjectID()
        let kept = (0..<4).map { _ in SessionID() }

        let before = SidebarTreeShape(roots: [
            project(projectID, children: kept.map { session($0) })
        ])
        let after = SidebarTreeShape(roots: [
            project(
                projectID,
                children: [
                    session(kept[3]),
                    session(),           // arriving
                    session(kept[0]),
                    session(),           // arriving
                    session(kept[2])     // kept[1] left
                ]
            )
        ])

        assertReplayMatches(from: before, to: after)
    }

    // MARK: - Across parents

    /// Turning branch grouping on moves sessions from the project into a heading under it. The
    /// same row is named twice — once leaving, once arriving — and every removal has to be
    /// issued before any insertion, or the row would have to exist in both places at once.
    func testARowChangingParentLeavesBeforeItArrives() {
        let projectID = ProjectID()
        let grouped = SessionID()
        let loose = SessionID()

        let before = SidebarTreeShape(roots: [
            project(projectID, children: [session(grouped), session(loose)])
        ])
        let after = SidebarTreeShape(roots: [
            project(
                projectID,
                children: [
                    branch("main", in: projectID, sessions: [session(grouped)]),
                    session(loose)
                ]
            )
        ])

        let steps = SidebarOutlineUpdate.steps(from: before, to: after)
        let firstInsertion = steps.firstIndex {
            if case .insert = $0 { return true } else { return false }
        }
        let lastRemoval = steps.lastIndex {
            if case .remove = $0 { return true } else { return false }
        }

        XCTAssertNotNil(firstInsertion)
        XCTAssertNotNil(lastRemoval)
        XCTAssertLessThan(lastRemoval ?? 0, firstInsertion ?? 0)
        assertReplayMatches(from: before, to: after)
    }

    /// A row the outline is about to rebuild has nothing to be told about its children: the
    /// insertion brings the subtree with it. Describing that subtree twice is how a diff ends up
    /// naming rows that no longer exist.
    func testTheChildrenOfARowThatChangedParentAreNotDescribed() {
        let projectID = ProjectID()
        let parentSession = SessionID()
        let sideChat = SessionID()

        let before = SidebarTreeShape(roots: [
            project(projectID, children: [session(parentSession, children: [session(sideChat)])])
        ])
        let after = SidebarTreeShape(roots: [
            project(
                projectID,
                children: [
                    branch(
                        "main",
                        in: projectID,
                        sessions: [session(parentSession, children: [session(sideChat)])]
                    )
                ]
            )
        ])

        let steps = SidebarOutlineUpdate.steps(from: before, to: after)
        XCTAssertFalse(
            steps.contains { step in
                switch step {
                case .remove(let parent, _), .insert(let parent, _), .move(let parent, _, _):
                    return parent == .session(parentSession)
                }
            },
            "the moved session's own children were described as well as moved"
        )
        assertReplayMatches(from: before, to: after)
    }

    /// A side chat arriving under a session that stayed put is an ordinary insertion one level
    /// down — the walk has to reach parents below the root.
    func testAChangeBelowTheTopLevelIsFound() {
        let projectID = ProjectID()
        let parentSession = SessionID()

        let before = SidebarTreeShape(roots: [
            project(projectID, children: [session(parentSession)])
        ])
        let after = SidebarTreeShape(roots: [
            project(projectID, children: [session(parentSession, children: [session()])])
        ])

        XCTAssertEqual(
            SidebarOutlineUpdate.steps(from: before, to: after),
            [.insert(parent: .session(parentSession), indexes: IndexSet(integer: 0))]
        )
        assertReplayMatches(from: before, to: after)
    }

    // MARK: - Shape

    /// The shape carries identity, not content — which is what lets a rename take the in-place
    /// refresh rather than a rebuild.
    func testAHeadingsNameIsNotItsIdentity() {
        let renamed = RepoGroupNode(identity: "/repos/one.git", name: "One")
        renamed.projectNodes = [project()]
        let again = RepoGroupNode(identity: "/repos/one.git", name: "Renamed")
        again.projectNodes = renamed.projectNodes

        XCTAssertEqual(SidebarTreeShape(roots: [renamed]), SidebarTreeShape(roots: [again]))
    }

    /// Two repositories can be called the same thing. Keyed by name they would be one heading,
    /// and the outline would be told about a row that does not exist.
    func testTwoRepositoriesWithOneNameAreTwoHeadings() {
        let first = RepoGroupNode(identity: "/repos/a/app.git", name: "app")
        first.projectNodes = [project()]
        let second = RepoGroupNode(identity: "/repos/b/app.git", name: "app")
        second.projectNodes = [project()]

        let shape = SidebarTreeShape(roots: [first, second])
        XCTAssertEqual(shape.children(of: nil).count, 2)
        XCTAssertEqual(shape.keys.count, 4)
    }

    /// A project-scoped update must preserve every unrelated root and descendant in the global
    /// snapshot. Removing those identities would make the next outline diff reinsert the whole
    /// sidebar even though the visible edit belonged to one project.
    func testReplacingOneProjectSubtreePreservesTheRestOfTheSidebar() {
        let changedProjectID = ProjectID()
        let otherProjectID = ProjectID()
        let leaving = SessionID()
        let staying = SessionID()
        let other = SessionID()

        let originalProject = project(
            changedProjectID,
            children: [session(staying), session(leaving)]
        )
        let otherProject = project(otherProjectID, children: [session(other)])
        var global = SidebarTreeShape(roots: [originalProject, otherProject])
        let original = SidebarTreeShape(roots: [originalProject])
        let replacement = SidebarTreeShape(roots: [
            project(changedProjectID, children: [session(staying)])
        ])

        XCTAssertTrue(global.replaceSubtree(original, with: replacement))
        XCTAssertEqual(global.children(of: nil), [.project(changedProjectID), .project(otherProjectID)])
        XCTAssertEqual(global.children(of: .project(changedProjectID)), [.session(staying)])
        XCTAssertEqual(global.children(of: .project(otherProjectID)), [.session(other)])
        XCTAssertFalse(global.keys.contains(.session(leaving)))
    }

    func testReplacingASubtreeRefusesADifferentRootWithoutMutation() {
        let standingProjectID = ProjectID()
        let standing = project(standingProjectID, children: [session()])
        var global = SidebarTreeShape(roots: [standing])
        let before = global

        XCTAssertFalse(global.replaceSubtree(
            SidebarTreeShape(roots: [standing]),
            with: SidebarTreeShape(roots: [project()])
        ))
        XCTAssertEqual(global, before)
    }

    // MARK: - Adoption

    func testASurvivingRowKeepsTheObjectTheOutlineWasHanded() {
        let projectID = ProjectID()
        let sessionID = SessionID()

        let presentedSession = session(sessionID)
        let presented = project(projectID, children: [presentedSession])

        let rebuilt = project(projectID, children: [session(sessionID), session()])
        let adopted = SidebarOutlineUpdate.adopt([rebuilt], reusing: [presented])

        XCTAssertIdentical(adopted.first, presented)
        XCTAssertIdentical((adopted.first as? ProjectNode)?.childNodes.first, presentedSession)
        XCTAssertEqual((adopted.first as? ProjectNode)?.childNodes.count, 2)
        XCTAssertEqual((adopted.first as? ProjectNode)?.sessionNodes.count, 2)
    }

    func testARowWithNoPredecessorArrivesAsTheRebuiltNode() {
        let rebuilt = project(ProjectID(), children: [session()])
        let adopted = SidebarOutlineUpdate.adopt([rebuilt], reusing: [])

        XCTAssertIdentical(adopted.first, rebuilt)
    }

    /// The surviving object keeps the row; the rebuild still owns what the row *says*. A heading
    /// whose repository was renamed, and a terminal whose owning project moved folders, are both
    /// content on the node rather than row identity.
    func testASurvivingRowTakesTheRebuiltContent() {
        let terminalID = TerminalID()
        let presentedTerminal = TerminalNode(
            terminalID: terminalID,
            projectFolderPath: "/repos/one"
        )
        let presentedHeading = RepoGroupNode(identity: "/repos/one.git", name: "One")
        let presentedProject = project(ProjectID(), children: [presentedTerminal])
        presentedHeading.projectNodes = [presentedProject]

        let rebuiltTerminal = TerminalNode(
            terminalID: terminalID,
            projectFolderPath: "/repos/two"
        )
        let rebuiltHeading = RepoGroupNode(identity: "/repos/one.git", name: "Renamed")
        let rebuiltProject = project(presentedProject.projectID, children: [rebuiltTerminal])
        rebuiltHeading.projectNodes = [rebuiltProject]

        let adopted = SidebarOutlineUpdate.adopt([rebuiltHeading], reusing: [presentedHeading])

        XCTAssertIdentical(adopted.first, presentedHeading)
        XCTAssertEqual(presentedHeading.name, "Renamed")
        XCTAssertIdentical(presentedHeading.projectNodes.first, presentedProject)
        XCTAssertIdentical(presentedProject.terminalNodes.first, presentedTerminal)
        XCTAssertEqual(presentedTerminal.projectFolderPath, "/repos/two")
    }

    /// A session that moved from the project into a branch heading is the same row in a new
    /// place — the object has to travel, or the outline is told to move a row it has never seen.
    func testARowThatChangedParentKeepsItsObject() {
        let projectID = ProjectID()
        let sessionID = SessionID()

        let presentedSession = session(sessionID)
        let presented = project(projectID, children: [presentedSession])

        let rebuilt = project(
            projectID,
            children: [branch("main", in: projectID, sessions: [session(sessionID)])]
        )
        let adopted = SidebarOutlineUpdate.adopt([rebuilt], reusing: [presented])

        let heading = (adopted.first as? ProjectNode)?.childNodes.first as? BranchGroupNode
        XCTAssertIdentical(heading?.sessionNodes.first, presentedSession)
    }

    /// Adoption must leave one object per identity — a tree holding both the surviving node and
    /// its rebuilt twin would hand `NSOutlineView` two rows claiming to be the same row.
    func testAdoptionLeavesOneObjectPerRow() throws {
        let projectID = ProjectID()
        let sessionID = SessionID()
        let presented = project(projectID, children: [session(sessionID)])

        let rebuiltSession = session(sessionID)
        let rebuilt = project(projectID, children: [rebuiltSession])
        let adopted = SidebarOutlineUpdate.adopt([rebuilt], reusing: [presented])

        var seen: [SidebarNodeKey: ObjectIdentifier] = [:]
        func walk(_ nodes: [NSObject]) {
            for node in nodes {
                guard let node = node as? any SidebarOutlineNode else { continue }
                if let first = seen[node.sidebarKey] {
                    XCTAssertEqual(first, ObjectIdentifier(node), "two objects for one row")
                }
                seen[node.sidebarKey] = ObjectIdentifier(node)
                walk(node.sidebarChildren)
            }
        }
        walk(adopted)

        // The flat list and the displayed one hold the same object, not two of it.
        let adoptedProject = try XCTUnwrap(adopted.first as? ProjectNode)
        XCTAssertIdentical(adoptedProject.childNodes.first, adoptedProject.sessionNodes.first)
        XCTAssertNotIdentical(adoptedProject.childNodes.first, rebuiltSession)
    }

    // MARK: - Branch renames

    /// The update after the rename is folded out, replayed the way AppKit applies it.
    private func assertRenamedReplayMatches(
        from old: SidebarTreeShape,
        to new: SidebarTreeShape,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let renames = SidebarOutlineUpdate.branchRenames(from: old, to: new)
        let standing = old.renamingKeys(renames)
        let steps = SidebarOutlineUpdate.steps(from: standing, to: new)
        XCTAssertEqual(
            replay(steps, from: standing, to: new),
            new.childrenByParent,
            "replaying the update did not reach the new tree",
            file: file,
            line: line
        )
    }

    /// The bug this exists for: `git checkout` moves every chat in the checkout at once, and
    /// keyed by name that reads as one group leaving and another arriving — the branch visibly
    /// disappearing from the sidebar and coming back a moment later with its rows re-expanded.
    func testACheckoutSwitchingBranchRenamesTheHeadingInsteadOfReplacingIt() {
        let projectID = ProjectID()
        let first = SessionID()
        let second = SessionID()

        let before = SidebarTreeShape(roots: [
            project(projectID, children: [
                branch("master", in: projectID, sessions: [session(first), session(second)])
            ])
        ])
        let after = SidebarTreeShape(roots: [
            project(projectID, children: [
                branch("feature", in: projectID, sessions: [session(first), session(second)])
            ])
        ])

        let renames = SidebarOutlineUpdate.branchRenames(from: before, to: after)
        XCTAssertEqual(renames, [.branch(projectID, "master"): .branch(projectID, "feature")])

        // Read as a rename, no row moves at all.
        XCTAssertTrue(
            SidebarOutlineUpdate.steps(from: before.renamingKeys(renames), to: after).isEmpty
        )
        // Read as two different groups, the heading and both chats under it leave and return.
        XCTAssertFalse(SidebarOutlineUpdate.steps(from: before, to: after).isEmpty)
    }

    /// The row the outline is showing has to be the row that gets the new name — a replaced node
    /// is a replaced row, which is what loses the group's collapsed state and the morph.
    func testARenamedHeadingKeepsTheObjectTheOutlineWasHanded() throws {
        let projectID = ProjectID()
        let sessionID = SessionID()

        let presentedHeading = branch("master", in: projectID, sessions: [session(sessionID)])
        let presented = project(projectID, children: [presentedHeading])
        let rebuilt = project(projectID, children: [
            branch("feature", in: projectID, sessions: [session(sessionID)])
        ])

        let renames = SidebarOutlineUpdate.branchRenames(
            from: SidebarTreeShape(roots: [presented]),
            to: SidebarTreeShape(roots: [rebuilt])
        )
        let adopted = SidebarOutlineUpdate.adopt(
            [rebuilt],
            reusing: [presented],
            renaming: renames
        )

        let heading = try XCTUnwrap(
            (adopted.first as? ProjectNode)?.childNodes.first as? BranchGroupNode
        )
        XCTAssertIdentical(heading, presentedHeading)
        XCTAssertEqual(heading.branch, "feature")
        XCTAssertEqual(heading.sidebarKey, .branch(projectID, "feature"))
    }

    /// A rename is a relabelling of the rows a heading already had. Gaining a chat in the same
    /// pass is a regrouping, and regrouping is what moving rows is for.
    func testASwitchThatAlsoGainsAChatIsNotARename() {
        let projectID = ProjectID()
        let first = SessionID()
        let arriving = SessionID()

        let before = SidebarTreeShape(roots: [
            project(projectID, children: [
                branch("master", in: projectID, sessions: [session(first)])
            ])
        ])
        let after = SidebarTreeShape(roots: [
            project(projectID, children: [
                branch("feature", in: projectID, sessions: [session(first), session(arriving)])
            ])
        ])

        XCTAssertTrue(SidebarOutlineUpdate.branchRenames(from: before, to: after).isEmpty)
        assertReplayMatches(from: before, to: after)
    }

    /// Two branches becoming one is a merge, not a rename: one heading really does leave.
    func testTwoHeadingsMergingIntoOneIsNotARename() {
        let projectID = ProjectID()
        let first = SessionID()
        let second = SessionID()

        let before = SidebarTreeShape(roots: [
            project(projectID, children: [
                branch("master", in: projectID, sessions: [session(first)]),
                branch("feature", in: projectID, sessions: [session(second)])
            ])
        ])
        let after = SidebarTreeShape(roots: [
            project(projectID, children: [
                branch("feature", in: projectID, sessions: [session(first), session(second)])
            ])
        ])

        XCTAssertTrue(SidebarOutlineUpdate.branchRenames(from: before, to: after).isEmpty)
        assertReplayMatches(from: before, to: after)
    }

    /// Two checkouts of one repository sit on different branches; switching one must not claim
    /// the other's heading moved.
    func testARenameIsScopedToTheProjectWhoseCheckoutMoved() {
        let moved = ProjectID()
        let stayed = ProjectID()
        let here = SessionID()
        let there = SessionID()

        func tree(_ branchName: String) -> SidebarTreeShape {
            SidebarTreeShape(roots: [
                project(moved, children: [
                    branch(branchName, in: moved, sessions: [session(here)])
                ]),
                project(stayed, children: [
                    branch("master", in: stayed, sessions: [session(there)])
                ])
            ])
        }

        let renames = SidebarOutlineUpdate.branchRenames(from: tree("master"), to: tree("feature"))
        XCTAssertEqual(renames, [.branch(moved, "master"): .branch(moved, "feature")])
    }

    /// A rename alongside a real change: the heading stays put and only the arriving chat is
    /// described, which is exactly the update a switch during a new chat should produce.
    func testARenameAlongsideAnArrivingRowStillLandsTheNewTree() {
        let projectID = ProjectID()
        let first = SessionID()
        let ungrouped = SessionID()

        let before = SidebarTreeShape(roots: [
            project(projectID, children: [
                branch("master", in: projectID, sessions: [session(first)])
            ])
        ])
        let after = SidebarTreeShape(roots: [
            project(projectID, children: [
                branch("feature", in: projectID, sessions: [session(first)]),
                session(ungrouped)
            ])
        ])

        let renames = SidebarOutlineUpdate.branchRenames(from: before, to: after)
        XCTAssertEqual(renames, [.branch(projectID, "master"): .branch(projectID, "feature")])
        XCTAssertEqual(
            SidebarOutlineUpdate.steps(from: before.renamingKeys(renames), to: after),
            [.insert(parent: .project(projectID), indexes: IndexSet(integer: 1))]
        )
        assertRenamedReplayMatches(from: before, to: after)
    }

    /// Renaming rewrites both sides of the parent map — a heading whose key moved is still the
    /// parent of the rows under it, or the diff would describe them as orphans.
    func testRenamingKeysCarriesTheRowsUnderTheHeading() {
        let projectID = ProjectID()
        let sessionID = SessionID()

        let before = SidebarTreeShape(roots: [
            project(projectID, children: [
                branch("master", in: projectID, sessions: [session(sessionID)])
            ])
        ])
        let renamed = before.renamingKeys(
            [.branch(projectID, "master"): .branch(projectID, "feature")]
        )

        XCTAssertEqual(renamed.children(of: .branch(projectID, "feature")), [.session(sessionID)])
        XCTAssertTrue(renamed.children(of: .branch(projectID, "master")).isEmpty)
        XCTAssertEqual(renamed.children(of: .project(projectID)), [.branch(projectID, "feature")])
        XCTAssertTrue(renamed.keys.contains(.branch(projectID, "feature")))
        XCTAssertFalse(renamed.keys.contains(.branch(projectID, "master")))
    }
}
