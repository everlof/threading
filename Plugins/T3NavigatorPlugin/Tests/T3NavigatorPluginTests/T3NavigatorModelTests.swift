import AppKit
import XCTest
import ThreadingDesignKit
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

    func testContentUpdateNamesOnlyTheRetainedRowForPresentation() {
        let harness = makeHarness(items: [
            project("one", title: "One"),
            session("first", project: "one", title: "First"),
            session("second", project: "one", title: "Second"),
        ])
        var changes: [T3NavigatorPresentationChange] = []
        harness.store.onPresentationChange = { changes.append($0) }

        harness.context.receiveHostUpdate(PluginWorkspaceUpdate(
            revision: 2,
            items: [session(
                "first",
                project: "one",
                title: "First",
                activity: .working
            )]
        ))

        XCTAssertEqual(changes.count, 1)
        guard case .reloadRow(let row) = changes[0] else {
            return XCTFail("A content edge should not rebuild the virtual table index.")
        }
        XCTAssertTrue(row === harness.store.active[0])
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

    func testChangeRequestStateAndOpenIntentStayHostOwned() {
        let summary = PluginWorkspaceChangeRequest(
            providerName: "Forgejo",
            changeRequestName: "pull request",
            number: 42,
            title: "Provider-neutral sidebar status",
            webURL: URL(string: "https://forge.example/team/project/pulls/42")!,
            lifecycle: .open,
            successfulChecks: 4,
            approvals: 2
        )
        let harness = makeHarness(items: [
            project("one", title: "One"),
            session("first", project: "one", title: "First", changeRequest: summary),
        ])
        let row = harness.store.active[0]

        XCTAssertTrue(row.changeRequest === summary)
        XCTAssertTrue(harness.store.openChangeRequest(row))
        XCTAssertEqual(harness.actions.map(\.0), [.openChangeRequest])
        XCTAssertEqual(harness.actions.map(\.1), ["first"])
    }

    func testVisibleRowsAreReportedThroughTheBoundedContext() {
        let harness = makeHarness(items: [
            project("one", title: "One"),
            session("first", project: "one", title: "First"),
            session("second", project: "one", title: "Second"),
        ])

        harness.store.reportVisibleRows([harness.store.active[1], harness.store.active[0]])

        XCTAssertEqual(harness.visibleItems.map(\.identifier), ["second", "first"])
    }

    func testNativeViewUsesPublishedDesignSystemComponents() {
        let harness = makeHarness(items: [
            project("one", title: "One"),
            session("first", project: "one", title: "First"),
        ])

        let view = T3NavigatorView(store: harness.store)

        XCTAssertTrue(view.subviews.contains { $0 === view.headerForTesting })
        XCTAssertNotNil(descendant(of: PaneHeaderView.self, in: view))
        XCTAssertNotNil(descendant(of: ThemedSearchField.self, in: view))
        XCTAssertNotNil(descendant(of: ThemedTableView.self, in: view))
        XCTAssertNotNil(descendant(of: ThemedScrollView.self, in: view))
    }

    func testChangeRequestUpdateKeepsThreeBandRowStableAndPresentsStatus() throws {
        let harness = makeHarness(items: [
            project("one", title: "One"),
            session("first", project: "one", title: "First"),
        ])
        let navigator = T3NavigatorView(store: harness.store)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 320))
        navigator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(navigator)
        NSLayoutConstraint.activate([
            navigator.topAnchor.constraint(equalTo: container.topAnchor),
            navigator.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            navigator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            navigator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        container.layoutSubtreeIfNeeded()
        let table = navigator.tableForTesting
        table.layoutSubtreeIfNeeded()
        let initialHeight = table.rect(ofRow: 1).height

        harness.context.receiveHostUpdate(PluginWorkspaceUpdate(
            revision: 2,
            items: [session(
                "first",
                project: "one",
                title: "First",
                changeRequest: PluginWorkspaceChangeRequest(
                    providerName: "Forgejo",
                    changeRequestName: "pull request",
                    number: 42,
                    title: "Provider-neutral sidebar status",
                    webURL: URL(string: "https://forge.example/team/project/pulls/42")!,
                    lifecycle: .draft,
                    successfulChecks: 4,
                    activeChecks: 1,
                    approvals: 2
                )
            )]
        ))
        container.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        table.displayIfNeeded()

        let expectedHeight = ceil(
            Design.Typography.lineHeight(of: Design.Typography.detail())
                + Design.Spacing.tight
                + Design.Typography.lineHeight(of: Design.Typography.emphasizedBody())
                + Design.Spacing.hairline
                + Design.Typography.lineHeight(of: Design.Typography.detail())
                + Design.Spacing.medium * 2
        )
        XCTAssertEqual(initialHeight, expectedHeight, accuracy: 1)
        XCTAssertEqual(table.rect(ofRow: 1).height, expectedHeight, accuracy: 1)
        let receipt = try XCTUnwrap(
            descendants(of: NSTextField.self, in: table).first { $0.stringValue == "42" }
        )
        XCTAssertTrue(receipt.toolTip?.contains("Draft") == true)
        XCTAssertTrue(receipt.toolTip?.contains("checks running") == true)
        XCTAssertTrue(receipt.toolTip?.contains("approved") == true)
        XCTAssertFalse(
            descendants(of: NSTextField.self, in: table).contains {
                $0.stringValue.contains("Checks running") || $0.stringValue.contains("approved")
            },
            "Provider detail belongs in the compact receipt's tooltip, not the visible row."
        )
    }

    func testLargeWorkspaceMaterializesOnlyViewportRows() {
        let items = [project("one", title: "One")] + (0..<2_000).map {
            session("session-\($0)", project: "one", title: "Thread \($0)")
        }
        let harness = makeHarness(items: items)
        let navigator = T3NavigatorView(store: harness.store)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 620))
        navigator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(navigator)
        NSLayoutConstraint.activate([
            navigator.topAnchor.constraint(equalTo: container.topAnchor),
            navigator.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            navigator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            navigator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        container.layoutSubtreeIfNeeded()
        navigator.tableForTesting.layoutSubtreeIfNeeded()
        navigator.tableForTesting.displayIfNeeded()

        XCTAssertEqual(navigator.tableForTesting.numberOfRows, 2_001)
        let realized = descendants(of: NSTableCellView.self, in: navigator.tableForTesting).count
        XCTAssertGreaterThan(realized, 0)
        XCTAssertLessThan(realized, 100)
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
            },
            visibleItemsDidChange: { identities in
                harness.visibleItems = identities
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
        archived: Bool = false,
        changeRequest: PluginWorkspaceChangeRequest? = nil
    ) -> PluginWorkspaceItem {
        PluginWorkspaceItem(
            identity: identity(identifier, kind: .session),
            parentIdentity: identity(project, kind: .project),
            title: title,
            branch: branch,
            activity: activity,
            isPinned: pinned,
            isArchived: archived,
            changeRequest: changeRequest
        )
    }

    private func terminal(_ identifier: String, project: String) -> PluginWorkspaceItem {
        PluginWorkspaceItem(
            identity: identity(identifier, kind: .terminal),
            parentIdentity: identity(project, kind: .project),
            title: "Terminal"
        )
    }

    private func descendant<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = descendant(of: type, in: child) { return match }
        }
        return nil
    }

    private func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var result = root is T ? [root as! T] : []
        for child in root.subviews {
            result += descendants(of: type, in: child)
        }
        return result
    }
}

@MainActor
private final class Harness {
    var context: PluginWorkspaceNavigatorContext!
    var store: T3NavigatorStore!
    var activations: [String] = []
    var actions: [(PluginWorkspaceAction, String)] = []
    var visibleItems: [PluginWorkspaceItemIdentity] = []
}
