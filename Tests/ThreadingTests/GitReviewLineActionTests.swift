import AppKit
import XCTest
@testable import Threading

/// The `+` plate beside a review line: a drag from it names a run of lines, a shift-click
/// reaches back to the last plate pressed, and what it paints lands on the device pixel grid
/// and leaves nothing behind when the pointer moves on.
@MainActor
final class GitReviewLineActionTests: XCTestCase {

    private let fixture = """
    diff --git a/Sources/Foo.swift b/Sources/Foo.swift
    index 1111111..2222222 100644
    --- a/Sources/Foo.swift
    +++ b/Sources/Foo.swift
    @@ -1,6 +1,6 @@
     context
    -old line
    +new line
    -older
    +newer
     tail
     more
     last
    """

    private var lines: [GitDiffLine] {
        GitDiffParser.files(fromUnifiedDiff: fixture).first?.hunks.flatMap(\.lines) ?? []
    }

    // MARK: - Naming a run of lines

    /// Pressing the plate and dragging down the hunk lights every line the pointer crosses,
    /// and the menu — which waits for the release — speaks for that run. The plate itself
    /// stays where the drag began.
    func testDraggingThePlateDownTheHunkSpeaksForTheRun() throws {
        let (view, _) = hostedDiffView()
        let press = try plateCentre(of: view, line: 1)
        let target = try XCTUnwrap(view.lineHoverRectForTesting(atDisplayedLine: 4))

        view.mouseMoved(with: mouse(.mouseMoved, at: press, in: view))
        view.mouseDown(with: mouse(.leftMouseDown, at: press, in: view))
        XCTAssertFalse(view.isLineMenuPresentedForTesting, "the menu waits for the release")

        view.mouseDragged(with: mouse(
            .leftMouseDragged, at: NSPoint(x: press.x, y: target.midY), in: view
        ))
        XCTAssertEqual(view.selectedSourceText(), "old line\nnew line\nolder\nnewer")
        XCTAssertEqual(view.hoveredLineIndex, 1, "the plate left the line the drag began on")

        view.mouseUp(with: mouse(
            .leftMouseUp, at: NSPoint(x: press.x, y: target.midY), in: view
        ))
        XCTAssertTrue(view.isLineMenuPresentedForTesting)
        XCTAssertEqual(view.targetSpan(forClickedLine: 1), 1...4)
        XCTAssertEqual(view.selectedSourceText(), "old line\nnew line\nolder\nnewer")

        view.dismissContextMenuForTesting()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(view.selectedRange().length, 0, "a cancelled menu keeps the drag's selection")
    }

    /// A drag that leaves the hunk keeps naming its edge line — upwards past the first line,
    /// downwards past the last — rather than losing the run at the boundary.
    func testDraggingPastTheHunkClampsToItsEdges() throws {
        let (view, _) = hostedDiffView()
        let press = try plateCentre(of: view, line: 4)
        view.mouseMoved(with: mouse(.mouseMoved, at: press, in: view))
        view.mouseDown(with: mouse(.leftMouseDown, at: press, in: view))

        view.mouseDragged(with: mouse(
            .leftMouseDragged, at: NSPoint(x: press.x, y: view.bounds.minY - 80), in: view
        ))
        XCTAssertEqual(view.selectedSourceText(), "context\nold line\nnew line\nolder\nnewer")

        view.mouseDragged(with: mouse(
            .leftMouseDragged, at: NSPoint(x: press.x, y: view.bounds.maxY + 80), in: view
        ))
        XCTAssertEqual(view.selectedSourceText(), "newer\ntail\nmore\nlast")

        view.mouseUp(with: mouse(
            .leftMouseUp, at: NSPoint(x: press.x, y: view.bounds.maxY + 80), in: view
        ))
        XCTAssertEqual(view.targetSpan(forClickedLine: 4), 4...7)
        view.dismissContextMenuForTesting()
    }

    /// Dragging away and back again is a click on the line it began on, not a memory of the
    /// furthest line the pointer reached.
    func testDraggingBackToThePressIsAClickOnThatLine() throws {
        let (view, _) = hostedDiffView()
        let press = try plateCentre(of: view, line: 2)
        let away = try XCTUnwrap(view.lineHoverRectForTesting(atDisplayedLine: 5))
        view.mouseMoved(with: mouse(.mouseMoved, at: press, in: view))
        view.mouseDown(with: mouse(.leftMouseDown, at: press, in: view))
        view.mouseDragged(with: mouse(
            .leftMouseDragged, at: NSPoint(x: press.x, y: away.midY), in: view
        ))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: press, in: view))
        view.mouseUp(with: mouse(.leftMouseUp, at: press, in: view))

        XCTAssertEqual(view.selectedSourceText(), "new line")
        XCTAssertEqual(view.targetSpan(forClickedLine: 2), 2...2)
        view.dismissContextMenuForTesting()
    }

    /// A plate released where it was pressed still answers for the selection it sits inside —
    /// the rule the right-click follows — so a run chosen by selecting text is not thrown
    /// away by the more discoverable entry point.
    func testAPlateClickInsideASelectionKeepsTheSelection() throws {
        let (view, _) = hostedDiffView()
        view.highlightLines(1...3)
        let press = try plateCentre(of: view, line: 2)
        view.mouseMoved(with: mouse(.mouseMoved, at: press, in: view))
        view.mouseDown(with: mouse(.leftMouseDown, at: press, in: view))
        view.mouseDragged(with: mouse(
            .leftMouseDragged, at: NSPoint(x: press.x + 2, y: press.y + 1), in: view
        ))
        view.mouseUp(with: mouse(
            .leftMouseUp, at: NSPoint(x: press.x + 2, y: press.y + 1), in: view
        ))

        XCTAssertEqual(view.selectedSourceText(), "old line\nnew line\nolder")
        XCTAssertEqual(view.targetSpan(forClickedLine: 2), 1...3)
        view.dismissContextMenuForTesting()
    }

    /// Clicking one plate and shift-clicking another names everything between them — the way
    /// to reach a run longer than the pane without dragging past its edge.
    func testShiftClickingASecondPlateExtendsFromTheFirst() throws {
        let (view, _) = hostedDiffView()
        let first = try plateCentre(of: view, line: 1)
        view.mouseMoved(with: mouse(.mouseMoved, at: first, in: view))
        view.mouseDown(with: mouse(.leftMouseDown, at: first, in: view))
        view.mouseUp(with: mouse(.leftMouseUp, at: first, in: view))
        XCTAssertTrue(view.isLineMenuPresentedForTesting)
        view.dismissContextMenuForTesting()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(view.selectedRange().length, 0)

        let second = try plateCentre(of: view, line: 5)
        view.mouseMoved(with: mouse(.mouseMoved, at: second, in: view))
        view.mouseDown(with: mouse(.leftMouseDown, at: second, in: view, modifiers: .shift))

        XCTAssertTrue(view.isLineMenuPresentedForTesting, "a shift-click opens the menu at once")
        XCTAssertEqual(view.selectedSourceText(), "old line\nnew line\nolder\nnewer\ntail")
        XCTAssertEqual(view.targetSpan(forClickedLine: 5), 1...5)
        view.dismissContextMenuForTesting()
    }

    /// With text already selected, a shift-click on a plate grows that selection to reach the
    /// clicked line, as it would in an editor.
    func testShiftClickingAPlateGrowsAnExistingSelection() throws {
        let (view, _) = hostedDiffView()
        view.highlightLines(2...3)
        let plate = try plateCentre(of: view, line: 6)
        view.mouseMoved(with: mouse(.mouseMoved, at: plate, in: view))
        view.mouseDown(with: mouse(.leftMouseDown, at: plate, in: view, modifiers: .shift))

        XCTAssertEqual(view.targetSpan(forClickedLine: 6), 2...6)
        view.dismissContextMenuForTesting()
    }

    /// A shift-click with nothing to extend from is an ordinary press.
    func testShiftClickingWithNothingToExtendFromIsAnOrdinaryPress() throws {
        let (view, _) = hostedDiffView()
        let plate = try plateCentre(of: view, line: 3)
        view.mouseMoved(with: mouse(.mouseMoved, at: plate, in: view))
        view.mouseDown(with: mouse(.leftMouseDown, at: plate, in: view, modifiers: .shift))
        XCTAssertFalse(view.isLineMenuPresentedForTesting)
        view.mouseUp(with: mouse(.leftMouseUp, at: plate, in: view, modifiers: .shift))
        XCTAssertTrue(view.isLineMenuPresentedForTesting)
        XCTAssertEqual(view.targetSpan(forClickedLine: 3), 3...3)
        view.dismissContextMenuForTesting()
    }

    // MARK: - A selection with gaps

    /// ⌘-clicking plates builds a selection with gaps, one line at a time, without opening a
    /// menu; ⌘-clicking a selected line takes it out again; a ⌘-drag adds a run, and runs that
    /// touch merge into one.
    func testCommandClickingPlatesBuildsASelectionWithGaps() throws {
        let (view, _) = hostedDiffView()
        try commandClick(view, line: 1)
        XCTAssertFalse(view.isLineMenuPresentedForTesting, "building the set opens no menu")
        try commandClick(view, line: 4)
        XCTAssertEqual(view.selectedLineRuns(), [1...1, 4...4])
        XCTAssertEqual(view.selectedSourceText(), "old line\nnewer")

        try commandClick(view, line: 1)
        XCTAssertEqual(view.selectedLineRuns(), [4...4], "a ⌘-click on a selected line removes it")

        let press = try plateCentre(of: view, line: 6)
        let target = try XCTUnwrap(view.lineHoverRectForTesting(atDisplayedLine: 7))
        view.mouseMoved(with: mouse(.mouseMoved, at: press, in: view))
        view.mouseDown(with: mouse(.leftMouseDown, at: press, in: view, modifiers: .command))
        view.mouseDragged(with: mouse(
            .leftMouseDragged, at: NSPoint(x: press.x, y: target.midY), in: view, modifiers: .command
        ))
        view.mouseUp(with: mouse(
            .leftMouseUp, at: NSPoint(x: press.x, y: target.midY), in: view, modifiers: .command
        ))
        XCTAssertEqual(view.selectedLineRuns(), [4...4, 6...7], "a ⌘-drag adds its run")
        XCTAssertFalse(view.isLineMenuPresentedForTesting)

        try commandClick(view, line: 5)
        XCTAssertEqual(view.selectedLineRuns(), [4...7], "runs that touch merge")
    }

    /// A plain press inside the set speaks for all of it: one receipt per run for the chat,
    /// the same batch for the comment sheet, and a preview that shows every run.
    func testTheMenuSpeaksForEveryRunWithOneReceiptEach() throws {
        let (view, _) = hostedDiffView()
        var staged: [ConversationContextAttachment] = []
        var commented: [ConversationContextAttachment] = []
        var preview: CodeContextPreview?
        view.onAddContextAttachment = { staged.append($0) }
        view.onRequestComment = { commented = $0; preview = $1 }
        try commandClick(view, line: 1)
        try commandClick(view, line: 4)

        let press = try plateCentre(of: view, line: 4)
        view.mouseMoved(with: mouse(.mouseMoved, at: press, in: view))
        view.mouseDown(with: mouse(.leftMouseDown, at: press, in: view))
        view.mouseUp(with: mouse(.leftMouseUp, at: press, in: view))
        XCTAssertTrue(view.isLineMenuPresentedForTesting)
        XCTAssertEqual(view.targetRuns(forClickedLine: 4), [1...1, 4...4])
        XCTAssertEqual(view.targetSpan(forClickedLine: 4), 1...4, "the hull, for callers without gaps")

        let items = view.lineMenuEntriesForTesting.compactMap { entry -> ThemedMenuItem? in
            guard case .item(let item) = entry else { return nil }
            return item
        }
        XCTAssertEqual(items.map(\.title), ["Add lines to chat", "Comment on lines…"])
        items[0].onChoose?()
        XCTAssertEqual(staged.map(\.title), ["Sources/Foo.swift:2", "Sources/Foo.swift:3"])
        XCTAssertEqual(staged.map(\.excerpt), ["old line", "newer"])
        items[1].onChoose?()
        XCTAssertEqual(commented.map(\.title), ["Sources/Foo.swift:2", "Sources/Foo.swift:3"])

        let rows = try XCTUnwrap(preview).rows.compactMap { row -> (String, Bool)? in
            guard case .line(let line, let isTarget) = row else { return nil }
            return (line.text, isTarget)
        }
        XCTAssertEqual(rows.map(\.0), [
            "context", "old line", "new line", "older", "newer", "tail", "more",
        ])
        XCTAssertEqual(rows.map(\.1), [false, true, false, false, true, false, false])
        view.dismissContextMenuForTesting()
    }

    /// A cancelled menu gives a selection with gaps back whole, every range of it.
    func testCancellingTheMenuRestoresASelectionWithGaps() throws {
        let (view, _) = hostedDiffView()
        try commandClick(view, line: 1)
        try commandClick(view, line: 4)
        let outside = try XCTUnwrap(view.lineHoverRectForTesting(atDisplayedLine: 6))
        view.rightMouseDown(with: mouse(
            .rightMouseDown, at: NSPoint(x: 200, y: outside.midY), in: view
        ))
        XCTAssertEqual(view.selectedLineRuns(), [6...6], "outside the set, the menu is about its line")

        view.dismissContextMenuForTesting()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(view.selectedLineRuns(), [1...1, 4...4])
    }

    /// The sheet's preview over several runs keeps each run's neighbours while ten rows can
    /// hold them, sheds the neighbours first, then keeps the first and last rows around one
    /// omission — and every skip between rows is counted.
    func testAPreviewOverRunsStatesEveryGap() throws {
        let lineAt = { (index: Int) in
            CodeContextPreview.SourceLine(number: index + 1, change: .context, text: "line \(index + 1)")
        }
        func shape(_ preview: CodeContextPreview) -> (lines: Int, omissions: [Int], targets: Int) {
            var lines = 0, targets = 0
            var omissions: [Int] = []
            for row in preview.rows {
                switch row {
                case .line(_, let isTarget):
                    lines += 1
                    if isTarget { targets += 1 }
                case .omission(let count):
                    omissions.append(count)
                }
            }
            return (lines, omissions, targets)
        }

        let near = try XCTUnwrap(CodeContextPreview.make(
            totalLineCount: 100, targets: [10...10, 50...50], lineAt: lineAt
        ))
        XCTAssertEqual(shape(near).lines, 10, "two neighbours each side of both runs fit")
        XCTAssertEqual(shape(near).omissions, [35])
        XCTAssertEqual(shape(near).targets, 2)

        let crowded = try XCTUnwrap(CodeContextPreview.make(
            totalLineCount: 100, targets: [10...12, 50...52, 90...90], lineAt: lineAt
        ))
        XCTAssertEqual(shape(crowded).lines, 7, "the neighbours go before any target does")
        XCTAssertEqual(shape(crowded).omissions, [37, 37])
        XCTAssertEqual(shape(crowded).targets, 7)

        let huge = try XCTUnwrap(CodeContextPreview.make(
            totalLineCount: 100, targets: [0...7, 20...27], lineAt: lineAt
        ))
        XCTAssertEqual(shape(huge).lines, 10)
        XCTAssertEqual(shape(huge).omissions, [18], "first five and last five around one omission")
        XCTAssertEqual(shape(huge).targets, 10)

        let touching = try XCTUnwrap(CodeContextPreview.make(
            totalLineCount: 20, targets: [5...6, 7...8, 2...3], lineAt: lineAt
        ))
        XCTAssertEqual(CodeContextPreview.mergedRuns([5...6, 7...8, 2...3]), [2...3, 5...8])
        XCTAssertEqual(shape(touching).lines, 6, "the neighbours would have made eleven")
        XCTAssertEqual(
            shape(touching).omissions, [1],
            "5-6 and 7-8 are one run; the one line between 3 and 5 is counted"
        )
    }

    /// One sheet, one answer, staged on every run. Sent rather than held, all but the last are
    /// staged and the last submits, so the runs travel as one turn.
    func testACommentAcrossRunsIsStagedOnEveryRun() {
        let receiver = RecordingReceiver()
        let destinations = Destinations(receiver: receiver)
        let session = SessionID()
        let first = ConversationContextAttachment(
            kind: .reference, source: .code, title: "Sources/Foo.swift:2",
            excerpt: "old line", locator: "Sources/Foo.swift", lineStart: 2, lineEnd: 2
        )
        let second = ConversationContextAttachment(
            kind: .reference, source: .code, title: "Sources/Foo.swift:5-6",
            excerpt: "tail\nmore", locator: "Sources/Foo.swift", lineStart: 5, lineEnd: 6
        )

        ContextCommentAlert.apply(
            .text("rename these"), to: [first, second], for: session, querying: destinations
        )
        XCTAssertEqual(receiver.staged.map(\.title), [first.title, second.title])
        XCTAssertEqual(receiver.staged.map(\.comment), ["rename these", "rename these"])
        XCTAssertEqual(receiver.staged.map(\.kind), [.comment, .comment])
        XCTAssertTrue(receiver.sent.isEmpty)

        ContextCommentAlert.apply(
            .immediate("now"), to: [first, second], for: session, querying: destinations
        )
        XCTAssertEqual(receiver.staged.map(\.title), [first.title, second.title, first.title])
        XCTAssertEqual(receiver.sent.map(\.title), [second.title], "the last receipt submits the turn")
        XCTAssertEqual(receiver.sent.map(\.comment), ["now"])

        XCTAssertEqual(ContextCommentAlert.headline(for: [first, second]), "Sources/Foo.swift:2, 5-6")
        XCTAssertEqual(ContextCommentAlert.headline(for: [first]), "Sources/Foo.swift:2")
        XCTAssertEqual(
            ContextCommentAlert.makeRequest(for: [first, second]).title,
            "Comment on Sources/Foo.swift:2, 5-6"
        )
    }

    private final class RecordingReceiver: SessionContextReceiving {
        var staged: [ConversationContextAttachment] = []
        var sent: [ConversationContextAttachment] = []

        func stageContextAttachment(_ attachment: ConversationContextAttachment) {
            staged.append(attachment)
        }

        func sendContextAttachment(_ attachment: ConversationContextAttachment) {
            sent.append(attachment)
        }
    }

    private final class Destinations: SessionContextDestinationQuerying {
        let receiver: RecordingReceiver

        init(receiver: RecordingReceiver) {
            self.receiver = receiver
        }

        func contextReceiver(for sessionID: SessionID) -> (any SessionContextReceiving)? {
            receiver
        }

        func runningTerminalInputSurface(
            for sessionID: SessionID
        ) -> (any AgentTerminalInputSurface)? {
            nil
        }
    }

    // MARK: - What the plate paints

    /// The plate's edges sit on device pixels. TextKit's fragment centre is fractional, and a
    /// plate placed straight from it had every edge — and the plus inside it — straddling two
    /// pixel rows, which is what "the + looks blurry" was.
    func testThePlateSitsOnTheDevicePixelGrid() throws {
        let (view, window) = hostedDiffView()
        let scale = window.backingScaleFactor
        for line in lines.indices {
            let plate = try XCTUnwrap(view.lineActionRectForTesting(atDisplayedLine: line))
            for (name, edge) in [
                ("minX", plate.minX), ("minY", plate.minY),
                ("width", plate.width), ("height", plate.height),
            ] {
                let pixels = edge * scale
                XCTAssertEqual(
                    pixels, pixels.rounded(), accuracy: 0.001,
                    "line \(line)'s plate \(name) is \(edge)pt, off the pixel grid at \(scale)×"
                )
            }
        }
    }

    /// Moving the hover repaints only the old and new line rectangles, so anything the plate
    /// painted outside its own rect stays on screen: a border stroked centred on the plate's
    /// edge left a hairline in the gutter behind every line the pointer had crossed.
    func testMovingTheHoverLeavesNothingBehindInTheGutter() throws {
        let (view, window) = hostedDiffView()
        window.appearance = NSAppearance(named: .aqua)
        let scale = 2
        let plate = try XCTUnwrap(view.lineActionRectForTesting(atDisplayedLine: 1))
        let watched = plate.insetBy(dx: -3, dy: -3)

        let clean = try rendered(view, scale: scale)
        view.mouseMoved(with: mouse(.mouseMoved, at: try plateCentre(of: view, line: 1), in: view))
        XCTAssertEqual(view.hoveredLineIndex, 1)
        let painted = try rendered(view, scale: scale)
        XCTAssertNotEqual(
            pixels(of: painted, in: watched, scale: scale),
            pixels(of: clean, in: watched, scale: scale),
            "the plate did not paint where the test is looking"
        )

        // The pointer moves on, and the window repaints exactly what the view invalidated —
        // the old line's rect and the new one's, widened to whole device pixels — while every
        // pixel outside keeps what it already showed.
        let old = try XCTUnwrap(view.lineHoverRectForTesting(atDisplayedLine: 1))
        view.mouseMoved(with: mouse(.mouseMoved, at: try plateCentre(of: view, line: 4), in: view))
        XCTAssertEqual(view.hoveredLineIndex, 4)
        let new = try XCTUnwrap(view.lineHoverRectForTesting(atDisplayedLine: 4))
        let fresh = try rendered(view, scale: scale)
        let screen = pixels(in: watched, scale: scale) { x, y in
            [old, new].contains { covers($0, pixelX: x, pixelY: y, scale: scale) } ? fresh : painted
        }

        XCTAssertEqual(
            screen,
            pixels(of: clean, in: watched, scale: scale),
            "the plate left ink in the gutter after the hover moved on"
        )
    }

    // MARK: - Fixture

    private func hostedDiffView() -> (view: GitReviewDiffTextView, window: NSWindow) {
        let view = GitReviewDiffTextView(gitLines: lines, displayCap: 100, path: "Sources/Foo.swift")
        view.onAddContextAttachment = { _ in }
        view.onRequestComment = { _, _ in }
        // Built, never shown — see the fixture-window rule in CLAUDE.md.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = window.contentView!
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        window.makeFirstResponder(view)
        return (view, window)
    }

    private func commandClick(_ view: GitReviewDiffTextView, line: Int) throws {
        let plate = try plateCentre(of: view, line: line)
        view.mouseMoved(with: mouse(.mouseMoved, at: plate, in: view))
        view.mouseDown(with: mouse(.leftMouseDown, at: plate, in: view, modifiers: .command))
        view.mouseUp(with: mouse(.leftMouseUp, at: plate, in: view, modifiers: .command))
    }

    private func plateCentre(of view: GitReviewDiffTextView, line: Int) throws -> NSPoint {
        let plate = try XCTUnwrap(view.lineActionRectForTesting(atDisplayedLine: line))
        return NSPoint(x: plate.midX, y: plate.midY)
    }

    private func mouse(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        in view: NSView,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    /// The whole view drawn at a magnification, in a rep the test can paint into again.
    private func rendered(_ view: NSView, scale: Int) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width) * scale,
            pixelsHigh: Int(view.bounds.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = view.bounds.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        view.displayIgnoringOpacity(view.bounds, in: context)
        return rep
    }


    /// The rep's pixels under a rect of the (flipped) view, row by row.
    private func pixels(of rep: NSBitmapImageRep, in rect: NSRect, scale: Int) -> [[Int]] {
        pixels(in: rect, scale: scale) { _, _ in rep }
    }

    /// Whether a device pixel lies inside a view rect widened outward to whole pixels — the
    /// region a window repaints for an invalidated rect.
    private func covers(_ rect: NSRect, pixelX x: Int, pixelY y: Int, scale: Int) -> Bool {
        let scale = CGFloat(scale)
        return CGFloat(x) >= (rect.minX * scale).rounded(.down)
            && CGFloat(x) < (rect.maxX * scale).rounded(.up)
            && CGFloat(y) >= (rect.minY * scale).rounded(.down)
            && CGFloat(y) < (rect.maxY * scale).rounded(.up)
    }

    /// The pixels under a rect of the (flipped) view, row by row, each read from whichever
    /// rep `source` names for it.
    private func pixels(
        in rect: NSRect,
        scale: Int,
        source: (Int, Int) -> NSBitmapImageRep
    ) -> [[Int]] {
        let minX = max(Int(rect.minX.rounded(.down)) * scale, 0)
        let maxX = Int(rect.maxX.rounded(.up)) * scale
        let minY = max(Int(rect.minY.rounded(.down)) * scale, 0)
        let maxY = Int(rect.maxY.rounded(.up)) * scale
        var rows: [[Int]] = []
        for y in minY...maxY {
            var row: [Int] = []
            for x in minX...maxX {
                let rep = source(x, y)
                guard x < rep.pixelsWide, y < rep.pixelsHigh else { continue }
                let color = rep.colorAt(x: x, y: y) ?? .clear
                row.append(contentsOf: [
                    Int(color.redComponent * 255), Int(color.greenComponent * 255),
                    Int(color.blueComponent * 255), Int(color.alphaComponent * 255),
                ])
            }
            rows.append(row)
        }
        return rows
    }
}
