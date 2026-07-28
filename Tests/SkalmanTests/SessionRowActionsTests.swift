import AppKit
import XCTest
@testable import Skalman

/// The row's trailing slot holds the status indicator and the `⋯` actions button *overlaid*,
/// crossfaded on hover. Two views in one 16pt square means the question "which one takes the
/// click" has an answer nothing on screen shows — and a spinner is exactly when a user reaches
/// for the menu, because a working session is the one they want to act on.
@MainActor
final class SessionRowActionsTests: XCTestCase {

    // MARK: - Helpers

    /// A row in a window, since hit testing needs a view tree with real frames.
    ///
    /// The window is built and never ordered on screen: `applicationShouldTerminateAfterLastWindowClosed`
    /// is true, so a shown-then-released window queues a termination AppKit acts on the next
    /// time anything spins the run loop — inside some later, unrelated test.
    private func hostedRow() -> (host: NSView, row: SessionRowView) {
        let row = SessionRowView(customizationLookup: { _ in .empty })
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
        host.layoutSubtreeIfNeeded()

        return (host, row)
    }

    private func enter(_ row: SessionRowView) {
        let event = NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: row.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )
        row.mouseEntered(with: XCTUnwrap2(event))
    }

    private func leave(_ row: SessionRowView) {
        let event = NSEvent.enterExitEvent(
            with: .mouseExited,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: row.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )
        row.mouseExited(with: XCTUnwrap2(event))
    }

    private func XCTUnwrap2(_ event: NSEvent?) -> NSEvent {
        // A synthesized enter/exit event cannot fail to build here; force it rather than make
        // every caller throwing for a value AppKit always returns.
        guard let event else { preconditionFailure("could not synthesize an enter/exit event") }
        return event
    }

    private func view(named identifier: String, in root: NSView) throws -> NSView {
        func walk(_ node: NSView) -> NSView? {
            if node.accessibilityIdentifier() == identifier { return node }
            for child in node.subviews {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return try XCTUnwrap(walk(root), "no view identified as \(identifier)")
    }

    private func session(_ title: String = "Working session") -> AgentSession {
        AgentSession(kind: .claude, title: title)
    }

    // MARK: - Tests

    /// The report that produced this test: the `⋯` could not be clicked on the selected chat,
    /// which was also the one showing a spinner.
    func testTheActionsButtonTakesTheClickWhileTheRowIsWorking() throws {
        let (host, row) = hostedRow()
        row.configure(with: session(), activity: .working)
        enter(row)
        defer { leave(row) }
        host.layoutSubtreeIfNeeded()

        let button = try view(named: "sidebar.session.actions", in: row)
        let centre = host.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)

        let hit = try XCTUnwrap(host.hitTest(centre), "nothing at all answered in the trailing slot")
        XCTAssertTrue(
            hit === button || hit.isDescendant(of: button),
            "the trailing slot's click went to \(type(of: hit)) rather than the actions button"
        )
    }

    /// The same square while the row is *loading*, which is the state the stuck spinner left
    /// every selected row in: the status indicator is opaque and animating underneath.
    func testTheActionsButtonTakesTheClickWhileTheRowIsLoading() throws {
        let (host, row) = hostedRow()
        row.configure(with: session(), activity: .idle, isLoading: true)
        enter(row)
        defer { leave(row) }
        host.layoutSubtreeIfNeeded()

        let button = try view(named: "sidebar.session.actions", in: row)
        let centre = host.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)

        let hit = try XCTUnwrap(host.hitTest(centre))
        XCTAssertTrue(
            hit === button || hit.isDescendant(of: button),
            "a loading row's spinner takes the click meant for its menu (\(type(of: hit)))"
        )
    }

    /// Reconfiguring must not drop the hover: rows are reconfigured continuously while an agent
    /// works, and a `⋯` that vanished under a resting pointer is indistinguishable from one
    /// that cannot be clicked.
    func testReconfiguringUnderThePointerKeepsTheActionsButtonVisible() throws {
        let (host, row) = hostedRow()
        let session = session()
        row.configure(with: session, activity: .idle)
        enter(row)
        defer { leave(row) }

        row.configure(with: session, activity: .working)
        row.configure(with: session, activity: .working, isLoading: true)
        host.layoutSubtreeIfNeeded()

        // The fade lives on the container holding both buttons, so that is what carries the
        // answer — asserting on the `⋯` alone would pass whatever the row did.
        let controls = try view(named: "sidebar.session.hover-controls", in: row)
        XCTAssertEqual(controls.alphaValue, 1, "the hover controls faded out under a resting pointer")
    }

    /// The button has to answer to the accessibility press as well as to the pointer — it is
    /// how the row is reached without a mouse, and how a UI test drives it.
    func testTheActionsButtonReportsItselfAsAPressableButton() throws {
        let (_, row) = hostedRow()
        row.configure(with: session(), activity: .idle)

        let button = try view(named: "sidebar.session.actions", in: row)
        XCTAssertTrue(button.isAccessibilityElement())
        XCTAssertEqual(button.accessibilityRole(), .button)
    }

    // MARK: - Archive

    /// The archive button holds the row's trailing edge, so it — not the `⋯` — is what a click
    /// at the outer edge of the slot reaches.
    func testTheArchiveButtonTakesTheClickAtTheRowsTrailingEdge() throws {
        let (host, row) = hostedRow()
        row.configure(with: session(), activity: .working)
        enter(row)
        defer { leave(row) }
        host.layoutSubtreeIfNeeded()

        let archive = try view(named: "sidebar.session.archive", in: row)
        let centre = host.convert(NSPoint(x: archive.bounds.midX, y: archive.bounds.midY), from: archive)

        let hit = try XCTUnwrap(host.hitTest(centre), "nothing answered at the archive button")
        XCTAssertTrue(
            hit === archive || hit.isDescendant(of: archive),
            "the archive button's click went to \(type(of: hit)) instead"
        )
    }

    /// Both buttons must lie *inside* the trailing slot. One pinned to the slot's edge and left
    /// to overhang draws perfectly and cannot be clicked, because `NSView.hitTest` stops at the
    /// container's bounds — the failure this layout exists to avoid.
    func testBothHoverButtonsLieInsideTheTrailingSlot() throws {
        let (host, row) = hostedRow()
        row.configure(with: session(), activity: .idle)
        enter(row)
        defer { leave(row) }
        host.layoutSubtreeIfNeeded()

        let slot = try view(named: "sidebar.session.trailing", in: row)
        for identifier in ["sidebar.session.actions", "sidebar.session.archive"] {
            let button = try view(named: identifier, in: row)
            let frame = slot.convert(button.bounds, from: button)
            XCTAssertTrue(
                slot.bounds.contains(frame),
                "\(identifier) at \(frame) escapes the slot's \(slot.bounds) and cannot be clicked"
            )
        }
    }

    /// The archive button is the *outer* of the pair. Stated as an assertion because the order
    /// is the request, not an accident of how the stack was built.
    func testTheArchiveButtonSitsOutboardOfTheActionsButton() throws {
        let (host, row) = hostedRow()
        row.configure(with: session(), activity: .idle)
        host.layoutSubtreeIfNeeded()

        let actions = try view(named: "sidebar.session.actions", in: row)
        let archive = try view(named: "sidebar.session.archive", in: row)
        let actionsFrame = row.convert(actions.bounds, from: actions)
        let archiveFrame = row.convert(archive.bounds, from: archive)

        XCTAssertGreaterThan(
            archiveFrame.minX,
            actionsFrame.minX,
            "the archive button should sit outboard of the ⋯, at the row's trailing edge"
        )
    }

    /// The dot must not move when the slot widens to carry a second button: it is shown on every
    /// row at rest, and the pair is shown on one row under the pointer.
    func testTheStatusDotKeepsTheRowsTrailingEdge() throws {
        let (host, row) = hostedRow()
        row.configure(with: session(), activity: .working)
        host.layoutSubtreeIfNeeded()

        let status = try view(named: "sidebar.session.status", in: row)
        let archive = try view(named: "sidebar.session.archive", in: row)
        let statusCentre = row.convert(NSPoint(x: status.bounds.midX, y: status.bounds.midY), from: status)
        let archiveCentre = row.convert(NSPoint(x: archive.bounds.midX, y: archive.bounds.midY), from: archive)

        XCTAssertEqual(
            statusCentre.x,
            archiveCentre.x,
            accuracy: 0.5,
            "the status dot left the row's trailing edge when the slot widened"
        )
    }

    /// Pressing it reports the row's session, which is what the sidebar archives.
    func testPressingArchiveReportsTheRowsSession() throws {
        let (host, row) = hostedRow()
        let session = session()
        row.configure(with: session, activity: .idle)
        enter(row)
        defer { leave(row) }
        host.layoutSubtreeIfNeeded()

        var archived: [SessionID] = []
        row.onArchive = { archived.append($0) }

        let archive = try view(named: "sidebar.session.archive", in: row)
        XCTAssertTrue(archive.accessibilityPerformPress())

        XCTAssertEqual(archived, [session.id])
    }

    /// It is revealed by the pointer and hidden at rest, exactly as the `⋯` is: a list of rows
    /// each showing an archive button is a list inviting an accident.
    func testTheArchiveButtonIsHiddenUntilTheRowIsHovered() throws {
        let (host, row) = hostedRow()
        let session = session()
        row.configure(with: session, activity: .idle)
        host.layoutSubtreeIfNeeded()

        let controls = try view(named: "sidebar.session.hover-controls", in: row)
        XCTAssertEqual(controls.alphaValue, 0, "the archive button was showing on a row at rest")

        // Read through `configure`, which reasserts the hover state without animating. Reading
        // straight after enter/exit would race the crossfade rather than test it.
        enter(row)
        row.configure(with: session, activity: .idle)
        XCTAssertEqual(controls.alphaValue, 1, "the archive button stayed hidden under the pointer")

        leave(row)
        row.configure(with: session, activity: .idle)
        XCTAssertEqual(controls.alphaValue, 0, "the archive button outstayed the pointer")
    }

    /// Reachable and labelled without a mouse.
    func testTheArchiveButtonReportsItselfAsAPressableButton() throws {
        let (_, row) = hostedRow()
        row.configure(with: session(), activity: .idle)

        let archive = try view(named: "sidebar.session.archive", in: row)
        XCTAssertTrue(archive.isAccessibilityElement())
        XCTAssertEqual(archive.accessibilityRole(), .button)
        XCTAssertEqual(
            archive.accessibilityTitle(),
            SidebarRowDefaults.archiveAccessibilityLabel
        )
    }
}
