import AppKit
import XCTest
@testable import Threading

/// What a project row's `+` does: its press opens the creation menu — **New Chat…** or
/// **New Terminal** — anchored to the button.
///
/// The button has been each way once. It began as this menu, was flattened so the press made a
/// chat directly ("what it is asked for nearly every time") with the menu on the secondary
/// click, and came back when that press turned out to duplicate what clicking the row already
/// does — `select(projectID:)` puts the composer on screen either way, so the shortcut saved
/// nothing and hid the terminal behind a right-click nothing advertised. Opening on the press
/// also puts the `+` on `ThemedIconButton.presentsMenu`, the gesture that cannot lose its
/// release to a row reload.
@MainActor
final class ProjectRowCreateButtonTests: XCTestCase {

    // MARK: - Helpers

    /// A host that records the secondary clicks that reach it, standing in for the outline row
    /// whose own context menu a fall-through would open.
    private final class ClickRecordingHost: NSView {
        var secondaryClicks = 0
        override func rightMouseDown(with event: NSEvent) { secondaryClicks += 1 }
    }

    /// A row in a window, since hit testing and press tracking need real frames. The window is
    /// built and never ordered on screen — see `SessionRowActionsTests` for what showing one
    /// costs the test host.
    private func hostedRow(
        project: Project = Project(
            name: "Threading",
            folderURL: URL(fileURLWithPath: "/tmp/Threading")
        )
    ) -> (host: ClickRecordingHost, row: ProjectRowView) {
        let row = ProjectRowView(customizationLookup: { _ in .empty })
        row.translatesAutoresizingMaskIntoConstraints = false

        let host = ClickRecordingHost(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
            row.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        row.configure(with: project)
        host.layoutSubtreeIfNeeded()

        return (host, row)
    }

    /// The `+`, found the way assistive technology finds it: by what it says it is.
    private func createButton(in root: NSView) throws -> ThemedIconButton {
        func walk(_ node: NSView) -> ThemedIconButton? {
            if let button = node as? ThemedIconButton,
               button.accessibilityTitle() == L10n.string("New chat or terminal") {
                return button
            }
            for child in node.subviews {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return try XCTUnwrap(walk(root), "the row grew no + button")
    }

    private func descendant(identified identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let found = descendant(identified: identifier, in: child) { return found }
        }
        return nil
    }

    private func event(_ type: NSEvent.EventType, on view: NSView) throws -> NSEvent {
        let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: centre,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
    }

    // MARK: - Tests

    func testCollapsedCountMaterializesOnlyWhenItHasDigitsToShow() throws {
        let project = Project(name: "Threading", folderURL: URL(fileURLWithPath: "/tmp/Threading"))
        let row = ProjectRowView(customizationLookup: { _ in .empty })

        row.configure(with: project)
        XCTAssertFalse(row.countLabelIsMaterialized)

        row.configure(with: project, collapsedSessionCount: 3)
        XCTAssertTrue(row.countLabelIsMaterialized)
        let label = try XCTUnwrap(
            descendant(identified: "sidebar.project.count", in: row) as? NSTextField
        )
        XCTAssertEqual(label.stringValue, "3")

        row.configure(with: project)
        XCTAssertTrue(label.isHidden, "a reused count label should stay warm but leave no pixels")
    }

    func testTheCreateButtonOpensItsMenuOnThePress() throws {
        let project = Project(name: "Threading", folderURL: URL(fileURLWithPath: "/tmp/Threading"))
        let (host, row) = hostedRow(project: project)
        var asked: [(ProjectID, ThemedMenuAnchor)] = []
        row.onCreateMenuAction = { projectID, _, anchor in
            asked.append((projectID, anchor))
            return true
        }

        let button = try createButton(in: host)
        button.mouseDown(with: try event(.leftMouseDown, on: button))

        XCTAssertEqual(asked.count, 1, "pressing the + offered nothing")
        XCTAssertEqual(asked.first?.0, project.id, "the menu was not the + button's own project's")
        // A menu the press asked for hangs from the control, the way the `⋯`'s does.
        guard case .control = try XCTUnwrap(asked.first?.1) else {
            return XCTFail("the press's menu was not anchored to the control")
        }
    }

    /// The sidebar recycles rows whenever the tree's shape changes, so the menu is bound to a
    /// project at `configure`, not read from the row when the press fires. The choices offered
    /// have to be the ones for the project the `+` visibly belongs to.
    func testTheMenuBelongsToTheProjectTheRowShowsAtThePress() throws {
        let first = Project(name: "Threading", folderURL: URL(fileURLWithPath: "/tmp/Threading"))
        let next = Project(name: "Skalman", folderURL: URL(fileURLWithPath: "/tmp/Skalman"))
        let (host, row) = hostedRow(project: first)
        var asked: [ProjectID] = []
        row.onCreateMenuAction = { projectID, _, _ in asked.append(projectID); return true }

        let button = try createButton(in: host)
        button.mouseDown(with: try event(.leftMouseDown, on: button))
        row.configure(with: next)
        button.mouseDown(with: try event(.leftMouseDown, on: button))

        XCTAssertEqual(asked, [first.id, next.id], "a press offered another project's choices")
    }

    /// The `+` keeps no secondary menu of its own — its press *is* the menu — so a right-click
    /// falls through to the row, whose context menu is what a secondary click on a row means
    /// everywhere else in the sidebar.
    func testASecondaryClickFallsThroughToTheRowsOwnMenu() throws {
        let project = Project(name: "Threading", folderURL: URL(fileURLWithPath: "/tmp/Threading"))
        let (host, row) = hostedRow(project: project)
        var asked = 0
        row.onCreateMenuAction = { _, _, _ in asked += 1; return true }

        let button = try createButton(in: host)
        button.rightMouseDown(with: try event(.rightMouseDown, on: button))

        XCTAssertEqual(asked, 0, "right-clicking the + opened the press's menu")
        XCTAssertEqual(host.secondaryClicks, 1, "the + swallowed the row's secondary click")
    }

    /// The pointerless route to the same choices: for a button whose press is its menu,
    /// accessibility's "show menu" is that press.
    func testAccessibilityCanShowTheCreateButtonsMenu() throws {
        let (host, row) = hostedRow()
        var anchors: [ThemedMenuAnchor] = []
        row.onCreateMenuAction = { _, _, anchor in anchors.append(anchor); return true }

        let button = try createButton(in: host)
        XCTAssertTrue(button.accessibilityPerformShowMenu())
        XCTAssertEqual(anchors.count, 1)
        guard case .control = try XCTUnwrap(anchors.first) else {
            return XCTFail("a menu shown without a pointer has nothing but the control to hang on")
        }
    }

    /// A button offering no menu of its own must not eat the click: the row it sits in has one,
    /// and a secondary click that lands on the `⋯` by a couple of points should still reach it.
    func testAButtonWithoutASecondaryMenuLetsTheClickThrough() throws {
        let host = ClickRecordingHost(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        let button = ThemedIconButton(
            symbolName: "ellipsis",
            accessibility: "Actions",
            target: .inline
        )
        button.frame = NSRect(x: 40, y: 10, width: 20, height: 20)
        host.addSubview(button)

        button.rightMouseDown(with: try event(.rightMouseDown, on: button))

        XCTAssertEqual(host.secondaryClicks, 1, "the button swallowed a secondary click it had no use for")
    }
}
