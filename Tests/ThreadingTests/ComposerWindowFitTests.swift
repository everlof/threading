import AppKit
import XCTest
@testable import Threading

/// The composer's height is the *window's* business.
///
/// A pane's content states a required minimum on the window it hangs in, so a column taller than
/// the pane does not overflow — it makes the window taller. The composer's usage panel used to
/// draw one bar per rate-limit window and one per metered model, which is a list the provider
/// lengthens: five bars grew a 420pt window to 561pt and twelve grew it to 932. Past the screen's
/// height that window hangs off the bottom, and AppKit pins it back to the top every time it is
/// moved — which is how the bug was reported.
///
/// The panel is gone; the account's reading is one line inside the prompt box. So the column is
/// bounded by construction — a chip row, a box capped at `Design.Size.inputMaxHeight`, and a
/// one-line import offer — and what is asserted here is that boundedness rather than a fitting
/// pass. The platform half stays, because it is the whole reason the rule exists.
@MainActor
final class ComposerWindowFitTests: XCTestCase {

    private enum Fixture {
        /// Short enough to be tight, tall enough that the composer itself is comfortable — the
        /// window a session is usually started in.
        static let size = NSSize(width: 900, height: 420)

        /// A prompt long enough to drive the box to its own cap, which is the only part of the
        /// composer whose height answers to content at all.
        static let longDraft = Array(repeating: "en rad text", count: 40).joined(separator: "\n")
    }

    private enum Render {
        /// Tall, tall enough to lose the hero, the working size, and the shortest the app allows.
        static let heights: [(String, CGFloat)] = [
            ("tall", 900), ("mid", 620), ("short", 420), ("tiny", WindowDefaults.minHeight)
        ]

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    // MARK: - The Window Keeps Its Height

    /// The composer leaves the window the size the user gave it, with a reading in it and with a
    /// draft long enough to push the box to its cap.
    func testTheComposerLeavesTheWindowTheHeightItWasGiven() throws {
        let composer = SessionComposerViewController()
        let window = window(for: composer)

        composer.show(projectID: nil)
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame.height, Fixture.size.height, accuracy: 1)

        let prompt = try XCTUnwrap(promptView(in: composer.view))
        prompt.stringValue = Fixture.longDraft
        window.layoutIfNeeded()
        XCTAssertEqual(
            window.frame.height,
            Fixture.size.height,
            accuracy: 1,
            "a long draft pushed the window taller than the user sized it"
        )
    }

    /// The whole point of the panel's removal: nothing in the composer grows with what a
    /// provider chooses to report.
    ///
    /// Measured at the column's **top edge**, since the column hangs from the pane's bottom: a
    /// column that grew would push its first row upward, which is exactly what twelve usage bars
    /// used to do before they ran out of pane and took the window with them.
    func testTheColumnIsTheSameHeightWhateverTheAccountReports() throws {
        let composer = SessionComposerViewController()
        let host = host(composer, height: Fixture.size.height)
        composer.show(projectID: nil)
        host.layoutSubtreeIfNeeded()

        let label = try XCTUnwrap(usageLabel(in: composer.view))
        let bare = try columnTop(of: composer)

        label.isHidden = false
        label.readings = [reading("5h", "43%"), reading("7d", "73%")]
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            try columnTop(of: composer),
            bare,
            accuracy: 1,
            "showing a reading changed the column's height"
        )

        // Twelve windows on one line rather than twelve lines, which is the difference.
        label.readings = (0..<12).map { reading("7d Model \($0)", "40%") }
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            try columnTop(of: composer),
            bare,
            accuracy: 1,
            "a longer reading grew the column, which is what the panel used to do"
        )
    }

    /// The composer has to fit the shortest window the app can be dragged to.
    func testTheShortestWindowTheAppAllowsStillFitsTheComposer() throws {
        let composer = SessionComposerViewController()
        let window = window(for: composer)
        composer.show(projectID: nil)

        let prompt = try XCTUnwrap(promptView(in: composer.view))
        prompt.stringValue = Fixture.longDraft

        window.setContentSize(NSSize(width: WindowDefaults.minWidth, height: WindowDefaults.minHeight))
        window.layoutIfNeeded()

        XCTAssertEqual(
            window.frame.height,
            WindowDefaults.minHeight,
            accuracy: 1,
            "The composer grew the window past the smallest size it states"
        )
    }

    /// A pane that cannot grow — one already at the screen's height, or any host that simply
    /// holds the composer to a size — draws inside it rather than over the chips above.
    func testAPaneThatCannotGrowKeepsTheColumnInsideIt() throws {
        let composer = SessionComposerViewController()
        let host = host(composer, height: 420)
        composer.show(projectID: nil)
        host.layoutSubtreeIfNeeded()

        let chips = try XCTUnwrap(descendants(of: composer.view).first { $0 is ChipView })
        let chipsFrame = composer.view.convert(chips.bounds, from: chips)
        let box = try XCTUnwrap(promptView(in: composer.view))
        let boxFrame = composer.view.convert(box.bounds, from: box)

        XCTAssertFalse(boxFrame.intersects(chipsFrame), "The box was drawn over the chip row")
        XCTAssertTrue(
            composer.view.bounds.contains(boxFrame),
            "The prompt drew outside the pane"
        )
    }

    /// The four heights the column has to answer for, drawn for review.
    func testRendersEachHeightTheComposerAnswersFor() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, height) in Render.heights {
            let composer = SessionComposerViewController()
            let host = host(composer, height: height)
            composer.show(projectID: nil)

            let label = try XCTUnwrap(usageLabel(in: composer.view))
            label.isHidden = false
            label.readings = [reading("5h", "43%"), reading("7d", "73%")]
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.wantsLayer = true
            host.layer?.backgroundColor = Design.Surface.ground.cgColor
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("composer-fit-\(name).png"))
        }
        print("Rendered \(Render.heights.count) composers to \(directory.path)")
    }

    // MARK: - The Platform Half

    /// Why the growth is worth a test rather than a shrug: AppKit does not leave an over-tall
    /// window where it is put. Dragged down, it is pinned back to the top of the screen and
    /// clipped to its height — the "it jumps to the top when I drag it" half of the report. If
    /// the platform ever stops doing this, the reason for the rule above is gone with it.
    func testAppKitPinsAnOverTallWindowBackToTheTopOfTheScreen() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Fixture.size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )

        // Dragged so its top edge sits well below the top of the screen.
        let dropped: CGFloat = 120
        let overTall = NSRect(
            x: visible.minX,
            y: visible.maxY - dropped - (visible.height + 200),
            width: Fixture.size.width,
            height: visible.height + 200
        )
        let constrained = window.constrainFrameRect(overTall, to: screen)
        XCTAssertEqual(constrained.maxY, visible.maxY, accuracy: 1, "AppKit let it stay where it was put")
        XCTAssertLessThanOrEqual(constrained.height, visible.height + 1)

        // A window that fits is left exactly where it was dragged.
        let fits = NSRect(
            x: visible.minX,
            y: visible.maxY - dropped - Fixture.size.height,
            width: Fixture.size.width,
            height: Fixture.size.height
        )
        XCTAssertEqual(window.constrainFrameRect(fits, to: screen), fits)
    }

    // MARK: - The Column Fills Its Pane

    /// The column takes the width the pane leaves it, up to `ComposerDefaults.contentWidth`.
    ///
    /// It measured itself against the pane at priority 240 and hugged its own content at the
    /// stack view's default 250, because the hugging was set through `setContentHuggingPriority`
    /// — an `NSView` property a stack view does not lay out by. So the measurement never
    /// applied: in a 1454-point pane the box drew 415 points wide, sized by whichever row inside
    /// it happened to be widest, with the choices on its footer crushed against each other and
    /// the pane empty on both sides of them.
    func testTheColumnFillsThePaneUpToItsCap() throws {
        let composer = SessionComposerViewController()
        let widePane = host(composer, size: NSSize(width: 1454, height: 700))
        composer.show(projectID: nil)
        widePane.layoutSubtreeIfNeeded()

        let box = try XCTUnwrap(promptView(in: composer.view))
        XCTAssertEqual(
            box.frame.width,
            ComposerDefaults.contentWidth,
            accuracy: 1,
            "the column hugged its content instead of filling the pane"
        )

        // And it is a cap, not a width: a pane narrower than 720 still gets a column that fills
        // it, or the composer would draw outside the pane it hangs in.
        let narrow = SessionComposerViewController()
        let narrowHost = host(narrow, size: NSSize(width: 560, height: 700))
        narrow.show(projectID: nil)
        narrowHost.layoutSubtreeIfNeeded()

        let narrowBox = try XCTUnwrap(promptView(in: narrow.view))
        XCTAssertEqual(
            narrowBox.frame.width,
            560 - Design.Spacing.pane * 2,
            accuracy: 1,
            "a narrow pane left the column at a width the pane does not have"
        )
    }

    // MARK: - The Scheduled Strip Keeps Its Height

    /// A scheduled row is one line, however much room the pane has to spare.
    ///
    /// The row stated only a floor (`height ≥ 26`), and the column above the composer has a
    /// second free height — the hero region soaks up whatever the pane does not need. Two free
    /// heights is an ambiguous layout, and the engine parked the pane's slack in whichever it
    /// liked: in the app the strip's labels drew over the chip row while its remove button
    /// floated forty points below them; in this fixture the row came out 434 points tall.
    func testAScheduledRowStaysOneLineRatherThanAbsorbingThePanesSlack() throws {
        let composer = SessionComposerViewController()
        let host = host(composer, size: NSSize(width: 1454, height: 700))
        composer.show(projectID: nil)
        host.layoutSubtreeIfNeeded()

        composer.scheduledStrip.setRows([
            ScheduledMessageStripView.Row(
                id: ScheduledMessageID(),
                summary: "Pick the importer back up where we left it.",
                timing: "tomorrow 09:31 · in 2h 26m",
                problem: nil
            )
        ])
        composer.setScheduledStripAttached(true)
        host.layoutSubtreeIfNeeded()

        let root = composer.view
        let row = try XCTUnwrap(descendants(of: root).first { $0 is ScheduledMessageRowView })
        let rowFrame = root.convert(row.bounds, from: row)
        XCTAssertEqual(
            rowFrame.height,
            ScheduledStripDefaults.rowHeight,
            accuracy: 1,
            "the scheduled row absorbed the pane's slack instead of leaving it to the hero"
        )

        // The row's members share its one line — the reported bug drew the labels over the
        // chip row above while the remove button stayed in the strip's own slot.
        let members = descendants(of: row).filter { $0 is NSTextField || $0 is ThemedIconButton }
        XCTAssertFalse(members.isEmpty)
        for member in members {
            let frame = root.convert(member.bounds, from: member)
            XCTAssertEqual(
                frame.midY,
                rowFrame.midY,
                accuracy: rowFrame.height / 2,
                "a row member was drawn outside the row's own line"
            )
        }

        let summary = try XCTUnwrap(
            descendants(of: row).compactMap { $0 as? NSTextField }.first {
                $0.stringValue == "Pick the importer back up where we left it."
            }
        )
        let remove = try XCTUnwrap(
            descendants(of: row).compactMap { $0 as? ThemedIconButton }.first {
                $0.accessibilityTitle() == L10n.string("Unschedule this message")
            }
        )
        let summaryFrame = row.convert(summary.bounds, from: summary)
        let summaryBaseline = summaryFrame.maxY - summary.firstBaselineOffsetFromTop
        let summaryFont = try XCTUnwrap(summary.font)
        let summaryInkCenter = summaryBaseline + summaryFont.capHeight / 2
        XCTAssertEqual(
            row.convert(remove.bounds, from: remove).midY,
            summaryInkCenter,
            accuracy: 0.5,
            "the remove mark is not aligned with the item it removes"
        )

        let chips = try XCTUnwrap(descendants(of: root).first { $0 is ChipView }?.superview)
        let chipsFrame = root.convert(chips.bounds, from: chips)
        XCTAssertFalse(
            rowFrame.intersects(chipsFrame),
            "the scheduled row was drawn over the chip row above it"
        )
    }

    // MARK: - Fixtures

    /// An unshown window holding the composer as its content — the arrangement that grows, since
    /// a window with a content view controller takes its minimum size from that view's fit.
    private func window(for composer: SessionComposerViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Fixture.size),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = composer
        window.setContentSize(Fixture.size)
        return window
    }

    /// A pane the composer cannot resize: the split view holds it to the window's, and this
    /// holds it to a number, which is the same answer arrived at without a window.
    private func host(_ composer: SessionComposerViewController, height: CGFloat) -> NSView {
        host(composer, size: NSSize(width: Fixture.size.width, height: height))
    }

    private func host(_ composer: SessionComposerViewController, size: NSSize) -> NSView {
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        let view = composer.view
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        return host
    }

    /// How far down the pane the composer's first row starts. The column is bottom-flush, so
    /// this is its height read from the other end.
    private func columnTop(of composer: SessionComposerViewController) throws -> CGFloat {
        let chips = try XCTUnwrap(descendants(of: composer.view).first { $0 is ChipView })
        let row = try XCTUnwrap(chips.superview)
        return composer.view.convert(row.bounds, from: row).maxY
    }

    // MARK: - Tree Walking

    private func promptView(in view: NSView) -> PromptView? {
        descendants(of: view).compactMap { $0 as? PromptView }.first
    }

    /// Found through `arrangedSubviews` as well as the hierarchy: a stack with
    /// `detachesHiddenViews` takes a hidden arranged view out of the view tree, and the usage
    /// line is hidden until a reading arrives.
    private func usageLabel(in view: NSView) -> UsageReadingLabel? {
        let subtree = [view] + descendants(of: view)
        let arranged = subtree.compactMap { $0 as? NSStackView }.flatMap(\.arrangedSubviews)
        return (subtree + arranged).first {
            $0.accessibilityIdentifier() == "composer.session-start.usage"
        } as? UsageReadingLabel
    }

    /// A window as the line receives it: named, valued, and comfortable.
    private func reading(_ name: String, _ value: String) -> AccountUsage.Reading {
        AccountUsage.Reading(name: name, value: value, severity: .normal, fraction: 0.4)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
