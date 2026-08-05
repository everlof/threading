import AppKit
import XCTest
@testable import Threading

/// What a project row's `+` does, and what it costs when the answer is a menu.
///
/// It used to open one on every press: **New Chat…** or **New Terminal**, two gestures for the
/// thing asked for nearly every time. So the press makes the chat and the secondary click keeps
/// the choice — the same split a row's own actions already use, and the reason `ThemedIconButton`
/// grew an `onContextMenu` beside `presentsMenu` rather than instead of it.
@MainActor
final class ProjectRowCreateButtonTests: XCTestCase {

    // MARK: - Helpers

    /// A row in a window, since hit testing and press tracking need real frames. The window is
    /// built and never ordered on screen — see `SessionRowActionsTests` for what showing one
    /// costs the test host.
    private func hostedRow(
        project: Project = Project(
            name: "Threading",
            folderURL: URL(fileURLWithPath: "/tmp/Threading")
        )
    ) -> (host: NSView, row: ProjectRowView) {
        let row = ProjectRowView(customizationLookup: { _ in .empty })
        row.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
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
               button.accessibilityTitle() == L10n.string("New chat") {
                return button
            }
            for child in node.subviews {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return try XCTUnwrap(walk(root), "the row grew no + button")
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

    func testTheCreateButtonMakesAChatOnItsPressWithoutAskingFirst() throws {
        let project = Project(name: "Threading", folderURL: URL(fileURLWithPath: "/tmp/Threading"))
        let (host, row) = hostedRow(project: project)
        var created: [ProjectID] = []
        var asked = 0
        row.onCreateAction = { created.append($0) }
        row.onCreateMenuAction = { _, _, _ in asked += 1; return true }

        let button = try createButton(in: host)
        button.mouseDown(with: try event(.leftMouseDown, on: button))
        button.mouseUp(with: try event(.leftMouseUp, on: button))

        XCTAssertEqual(created, [project.id], "the + did not make a chat in its own project")
        XCTAssertEqual(asked, 0, "the + still asked which kind before making anything")
    }

    /// A press outlives the row it started on, and the sidebar recycles rows whenever the tree's
    /// shape changes. The chat has to land in the project the `+` was aimed at.
    func testAPressStartedOnOneProjectNeverMakesAChatInTheRowsNext() throws {
        let aimed = Project(name: "Threading", folderURL: URL(fileURLWithPath: "/tmp/Threading"))
        let next = Project(name: "Skalman", folderURL: URL(fileURLWithPath: "/tmp/Skalman"))
        let (host, row) = hostedRow(project: aimed)
        var created: [ProjectID] = []
        row.onCreateAction = { created.append($0) }

        let button = try createButton(in: host)
        button.mouseDown(with: try event(.leftMouseDown, on: button))
        row.configure(with: next)
        button.mouseUp(with: try event(.leftMouseUp, on: button))

        XCTAssertEqual(created, [aimed.id], "the release made a chat in the row's new project")
    }

    func testTheCreateButtonKeepsTheOtherChoicesOnItsSecondaryClick() throws {
        let project = Project(name: "Threading", folderURL: URL(fileURLWithPath: "/tmp/Threading"))
        let (host, row) = hostedRow(project: project)
        var created = 0
        var asked: [(ProjectID, ThemedMenuAnchor)] = []
        row.onCreateAction = { _ in created += 1 }
        row.onCreateMenuAction = { projectID, _, anchor in
            asked.append((projectID, anchor))
            return true
        }

        let button = try createButton(in: host)
        button.rightMouseDown(with: try event(.rightMouseDown, on: button))

        XCTAssertEqual(asked.count, 1, "right-clicking the + offered nothing")
        XCTAssertEqual(asked.first?.0, project.id)
        XCTAssertEqual(created, 0, "right-clicking the + also made a chat")
        // A menu asked for by a secondary click belongs to the pointer, not to the control —
        // see `ThemedMenuAnchor`.
        guard case .pointer = try XCTUnwrap(asked.first?.1) else {
            return XCTFail("the secondary click's menu was anchored to the control")
        }
    }

    /// The pointerless route to the same choices, which is the whole reason the gesture is not
    /// the only way to reach them.
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
        final class ContextMenuHost: NSView {
            var clicks = 0
            override func rightMouseDown(with event: NSEvent) { clicks += 1 }
        }

        let host = ContextMenuHost(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        let button = ThemedIconButton(
            symbolName: "ellipsis",
            accessibility: "Actions",
            target: .inline
        )
        button.frame = NSRect(x: 40, y: 10, width: 20, height: 20)
        host.addSubview(button)

        button.rightMouseDown(with: try event(.rightMouseDown, on: button))

        XCTAssertEqual(host.clicks, 1, "the button swallowed a secondary click it had no use for")
    }
}
