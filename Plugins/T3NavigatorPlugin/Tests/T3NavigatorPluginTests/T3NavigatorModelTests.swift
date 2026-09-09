import XCTest
import ThreadingPluginKit
@testable import T3NavigatorPlugin

@MainActor
final class T3NavigatorModelTests: XCTestCase {
    func testInitialSnapshotBuildsStableLifecycleSectionsAndIgnoresNonSessions() {
        let selected = identity("active", kind: .session)
        let harness = makeHarness(
            items: [
                project("one", title: "One"),
                session("pinned", project: "one", title: "Pinned", pinned: true),
                session("active", project: "one", title: "Active", activity: .working),
                session("archived", project: "one", title: "Archived", archived: true),
                terminal("terminal", project: "one"),
            ],
            selected: selected
        )

        XCTAssertEqual(harness.store.pinned.map(\.title), ["Pinned"])
        XCTAssertEqual(harness.store.active.map(\.title), ["Active"])
        XCTAssertEqual(harness.store.archived.map(\.title), ["Archived"])
        XCTAssertEqual(harness.store.projects, [.init(id: "one", title: "One")])
        XCTAssertTrue(harness.store.active[0].isSelected)
    }

    func testSearchIsTitleOnlyAndProjectFilterComposesWithIt() {
        let harness = makeHarness(items: [
            project("one", title: "One"),
            project("two", title: "Two"),
            session("alpha", project: "one", title: "Release Alpha", branch: "find-me"),
            session("beta", project: "two", title: "Release Beta"),
        ])

        harness.store.searchText = "release"
        harness.store.selectProject("one")
        XCTAssertEqual(harness.store.visibleRows(in: .active).map(\.title), ["Release Alpha"])

        harness.store.searchText = "find-me"
        XCTAssertTrue(harness.store.visibleRows(in: .active).isEmpty)
    }

    func testProjectSearchHandlesTheContractMaximumWithoutTruncatingResults() {
        let projects = (0..<2_000).map {
            project("project-\($0)", title: "Workspace \($0)")
        }
        let harness = makeHarness(items: projects)

        XCTAssertEqual(harness.store.projects.count, 2_000)
        XCTAssertEqual(
            harness.store.visibleProjects(matching: "Workspace 1999"),
            [.init(id: "project-1999", title: "Workspace 1999")]
        )
    }

    func testContentUpdateRetainsRowIdentityAndStableOrder() {
        let harness = makeHarness(items: [
            project("one", title: "One"),
            session("first", project: "one", title: "First"),
            session("second", project: "one", title: "Second"),
        ])
        let original = harness.store.active[0]

        harness.context.receiveHostUpdate(PluginWorkspaceUpdate(
            revision: 2,
            items: [session(
                "first",
                project: "one",
                title: "Changed",
                activity: .awaitingUser
            )]
        ))

        XCTAssertTrue(harness.store.active[0] === original)
        XCTAssertEqual(harness.store.active.map(\.title), ["Changed", "Second"])
        XCTAssertEqual(original.activity, .awaitingUser)
    }

    func testStructuralUpdateMovesOnlyTheChangedRow() {
        let harness = makeHarness(items: [
            project("one", title: "One"),
            session("first", project: "one", title: "First"),
            session("second", project: "one", title: "Second"),
        ])
        let first = harness.store.active[0]
        let second = harness.store.active[1]

        harness.context.receiveHostUpdate(PluginWorkspaceUpdate(
            revision: 2,
            items: [session("first", project: "one", title: "First", pinned: true)]
        ))

        XCTAssertTrue(harness.store.pinned[0] === first)
        XCTAssertTrue(harness.store.active[0] === second)
    }

    func testReplacementPreservesSelectionWhenSelectionDidNotChange() {
        let harness = makeHarness(
            items: [
                project("one", title: "One"),
                session("selected", project: "one", title: "Before"),
            ],
            selected: identity("selected", kind: .session)
        )

        harness.context.receiveHostUpdate(PluginWorkspaceUpdate(
            revision: 2,
            isReplacement: true,
            items: [
                project("one", title: "One"),
                session("selected", project: "one", title: "After"),
            ]
        ))

        XCTAssertEqual(harness.store.active.first?.title, "After")
        XCTAssertTrue(harness.store.active.first?.isSelected == true)
    }

    func testActivationAndMutationsStayHostOwned() {
        let harness = makeHarness(items: [
            project("one", title: "One"),
            session("first", project: "one", title: "First"),
        ])
        let row = harness.store.active[0]

        harness.store.activate(row)
        harness.store.togglePin(row)
        harness.store.archive(row)

        XCTAssertEqual(harness.activations, ["first"])
        XCTAssertEqual(harness.actions.map(\.0), [.pin, .archive])
        XCTAssertEqual(harness.actions.map(\.1), ["first", "first"])
        XCTAssertFalse(row.isPinned, "The plugin waits for host-authored state.")
    }

    private func makeHarness(
        items: [PluginWorkspaceItem],
        selected: PluginWorkspaceItemIdentity? = nil
    ) -> Harness {
        let harness = Harness()
        let context = PluginWorkspaceNavigatorContext(
            navigatorIdentifier: "t3-native",
            initialSnapshot: PluginWorkspaceSnapshot(
                revision: 1,
                items: items,
                selectedItemIdentity: selected
            ),
            activate: { identity in
                harness.activations.append(identity.identifier)
                return true
            },
            perform: { action, identity in
                harness.actions.append((action, identity.identifier))
                return true
            }
        )
        harness.context = context
        harness.store = T3NavigatorStore(context: context)
        return harness
    }

    private func identity(
        _ identifier: String,
        kind: PluginWorkspaceItemKind
    ) -> PluginWorkspaceItemIdentity {
        PluginWorkspaceItemIdentity(kind: kind, identifier: identifier)
    }

    private func project(_ identifier: String, title: String) -> PluginWorkspaceItem {
        PluginWorkspaceItem(identity: identity(identifier, kind: .project), title: title)
    }

    private func session(
        _ identifier: String,
        project: String,
        title: String,
        branch: String? = nil,
        activity: PluginWorkspaceActivity = .idle,
        pinned: Bool = false,
        archived: Bool = false
    ) -> PluginWorkspaceItem {
        PluginWorkspaceItem(
            identity: identity(identifier, kind: .session),
            parentIdentity: identity(project, kind: .project),
            title: title,
            branch: branch,
            activity: activity,
            isPinned: pinned,
            isArchived: archived
        )
    }

    private func terminal(_ identifier: String, project: String) -> PluginWorkspaceItem {
        PluginWorkspaceItem(
            identity: identity(identifier, kind: .terminal),
            parentIdentity: identity(project, kind: .project),
            title: "Terminal"
        )
    }
}

@MainActor
private final class Harness {
    var context: PluginWorkspaceNavigatorContext!
    var store: T3NavigatorStore!
    var activations: [String] = []
    var actions: [(PluginWorkspaceAction, String)] = []
}
