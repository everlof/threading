import XCTest
@testable import Threading

/// The queue rail's own contract: behaviour, accessibility, a live theme switch, and a picture.
///
/// Every fixture states its width the way the pane does, because a detached `NSView(frame:)`
/// pins nothing and would let a row lay out at whatever width it would prefer — which is how a
/// control comes to be reported as overflowing a pane it was never asked to fit.
@MainActor
final class ConversationOutboxRailTests: XCTestCase {

    private func rows(
        pending: Int = 2,
        includingHandedOver: Bool = false
    ) -> [ConversationOutboxRailView.Row] {
        var values: [ConversationOutboxRailView.Row] = []
        if includingHandedOver {
            values.append(ConversationOutboxRailView.Row(
                id: ConversationMessageID(),
                summary: "Already handed to the agent.",
                state: .started
            ))
        }
        for index in 0..<pending {
            values.append(ConversationOutboxRailView.Row(
                id: ConversationMessageID(),
                summary: "Queued message \(index + 1).",
                state: .queued
            ))
        }
        return values
    }

    private func fixture(
        _ rail: ConversationOutboxRailView,
        width: CGFloat = ConversationDefaults.composerWidth
    ) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(rail)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: width),
            rail.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            rail.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            rail.topAnchor.constraint(equalTo: host.topAnchor),
            rail.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    // MARK: - Behaviour

    func testAnEmptyRailDrawsNothing() {
        let rail = ConversationOutboxRailView()
        _ = fixture(rail)
        XCTAssertTrue(rail.isHidden)

        rail.setRows(rows())
        XCTAssertFalse(rail.isHidden)

        rail.setRows([])
        XCTAssertTrue(rail.isHidden)
    }

    func testMovesAreReportedInPendingTerms() throws {
        let rail = ConversationOutboxRailView()
        let values = rows(pending: 2, includingHandedOver: true)
        rail.setRows(values)
        let host = fixture(rail)

        var moved: (from: Int, to: Int)?
        rail.onMove = { moved = ($0, $1) }

        // The second *pending* row, which is the third row on screen. Reporting storage indices
        // here would land the drag one row off every time a handed-over row is present.
        let target = try XCTUnwrap(rowView(for: values[2].id, in: host))
        target.onMove?(-1)

        XCTAssertEqual(moved?.from, 1)
        XCTAssertEqual(moved?.to, 0)
    }

    /// A row the transport already holds is not ours to withdraw, so it offers neither the
    /// handle nor the remove — the affordances match what the model will actually accept.
    func testHandedOverRowsOfferNoQueueGestures() throws {
        let rail = ConversationOutboxRailView()
        let values = rows(pending: 1, includingHandedOver: true)
        rail.setRows(values)
        let host = fixture(rail)

        let handedOver = try XCTUnwrap(rowView(for: values[0].id, in: host))
        let pending = try XCTUnwrap(rowView(for: values[1].id, in: host))

        XCTAssertFalse(handedOver.isEnabled)
        XCTAssertTrue(pending.isEnabled)
        XCTAssertFalse(handedOver.accessibilityPerformPress())
    }

    func testDeleteRemovesTheRowItIsOn() throws {
        let rail = ConversationOutboxRailView()
        let values = rows(pending: 2)
        rail.setRows(values)
        let host = fixture(rail)

        var removed: ConversationMessageID?
        rail.onRemove = { removed = $0 }

        let row = try XCTUnwrap(rowView(for: values[1].id, in: host))
        row.keyDown(with: key(OutboxRailDefaults.deleteKeyCode))

        XCTAssertEqual(removed, values[1].id)
    }

    func testCommandArrowsReorderFromTheKeyboard() throws {
        let rail = ConversationOutboxRailView()
        let values = rows(pending: 3)
        rail.setRows(values)
        let host = fixture(rail)

        var moved: (from: Int, to: Int)?
        rail.onMove = { moved = ($0, $1) }

        let row = try XCTUnwrap(rowView(for: values[2].id, in: host))
        row.keyDown(with: key(OutboxRailDefaults.upArrowKeyCode, modifiers: .command))

        XCTAssertEqual(moved?.from, 2)
        XCTAssertEqual(moved?.to, 1)
    }

    // MARK: - Accessibility

    func testEveryRowNamesItselfAndItsState() throws {
        let rail = ConversationOutboxRailView()
        let values = rows(pending: 1, includingHandedOver: true)
        rail.setRows(values)
        let host = fixture(rail)

        let handedOver = try XCTUnwrap(rowView(for: values[0].id, in: host))
        XCTAssertEqual(handedOver.accessibilityRole(), .row)
        XCTAssertEqual(handedOver.accessibilityTitle(), "Already handed to the agent.")
        XCTAssertEqual(
            handedOver.accessibilityValue() as? String,
            OutboxRailDefaults.stateName(.started)
        )
    }

    func testPressOpensAWaitingRowForEditing() throws {
        let rail = ConversationOutboxRailView()
        let values = rows(pending: 1)
        rail.setRows(values)
        let host = fixture(rail)

        var edited: ConversationMessageID?
        rail.onEdit = { edited = $0 }

        let row = try XCTUnwrap(rowView(for: values[0].id, in: host))
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(edited, values[0].id)
    }

    // MARK: - Theme

    func testRowsFollowALiveThemeSwitch() throws {
        let rail = ConversationOutboxRailView()
        let values = rows(pending: 2)
        rail.setRows(values)
        let host = fixture(rail)
        let row = try XCTUnwrap(rowView(for: values[0].id, in: host))

        // Asserting it survives the call rather than sampling a colour: the layer's fill is a
        // recorded theme role, and reading a CGColor back is exactly the unrecorded-colour
        // pattern the boundary forbids.
        rail.applyTheme()
        row.applyTheme()
        XCTAssertFalse(row.isHidden)
    }

    // MARK: - Rendered State

    /// Several bugs in this codebase were visible in a picture and in no assertion anyone would
    /// have written. `THREADING_RENDER_OUT` redirects the output.
    func testRendersTheQueue() throws {
        let directory = Self.renderDirectory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let rail = ConversationOutboxRailView()
            let values = rows(pending: 2, includingHandedOver: true)
            rail.setRows(values)
            let host = fixture(rail)
            host.appearance = NSAppearance(named: name)
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            // One row under the pointer, because at rest the grip and the remove are invisible
            // and a picture of only the resting state cannot show whether they land where they
            // should. Both readings have to be reviewable.
            rowView(for: values[1].id, in: host)?.mouseEntered(with: hoverEvent())
            host.layoutSubtreeIfNeeded()

            // Resolved *inside* the appearance, or the ground is whatever the process's current
            // appearance says and the light render comes out on a dark plate.
            var rendered: Data?
            host.appearance?.performAsCurrentDrawingAppearance { rendered = self.png(of: host) }
            let data = try XCTUnwrap(rendered)
            let label = name == .darkAqua ? "dark" : "light"
            try data.write(
                to: directory.appendingPathComponent("conversation-outbox-rail-\(label).png")
            )
        }
    }

    private static var renderDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
    }

    /// The rail sits on the pane's material and has no ground of its own, so one is painted here
    /// or every label draws onto transparency and the picture is unreadable.
    private func png(of host: NSView) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Helpers

    private func rowView(
        for id: ConversationMessageID,
        in root: NSView
    ) -> ConversationOutboxRowView? {
        if let row = root as? ConversationOutboxRowView, row.identity == id { return row }
        for child in root.subviews {
            if let match = rowView(for: id, in: child) { return match }
        }
        return nil
    }

    private func hoverEvent() -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
    }

    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: code
        )!
    }
}
