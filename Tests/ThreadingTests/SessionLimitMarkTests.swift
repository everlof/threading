import AppKit
import XCTest
@testable import Threading

/// The third mark a session row can wear: the triangle that says the agent stopped because its
/// account's usage limit is spent.
///
/// The bug behind it is the whole specification. A refused turn raises no lifecycle hook, so the
/// row went on drawing the spinner it had — "working", for nineteen minutes, for a conversation
/// that had already stopped. What replaces it has to be *distinguishable from the two dots*
/// without colour, has to survive a theme that squares its corners, and must not quietly go away
/// when the user looks at the row, since looking does not lift a limit.
@MainActor
final class SessionLimitMarkTests: XCTestCase {

    // MARK: - Configuration

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    // MARK: - The indicator's states

    /// The state the spinner used to keep. Nothing else on the row says why a session went
    /// quiet, so this is the assertion the whole change exists for.
    func testALimitedSessionShowsTheTriangleAndStopsTheSpinner() {
        let indicator = SessionStatusIndicator()
        indicator.update(for: .working)
        XCTAssertTrue(spinner(in: indicator).isAnimating)

        indicator.update(for: .limitReached)

        XCTAssertFalse(spinner(in: indicator).isAnimating)
        XCTAssertFalse(mark(in: indicator).isHidden)
        XCTAssertEqual(mark(in: indicator).severity, .negative)
    }

    /// Each of the four other states leaves the triangle away — including the two dots, which it
    /// must never be shown beside.
    func testNoOtherStateShowsTheTriangle() {
        for activity in [SessionActivity.working, .idle, .dormant, .awaitingUser, .needsAttention] {
            let indicator = SessionStatusIndicator()
            indicator.update(for: activity)

            XCTAssertTrue(
                mark(in: indicator).isHidden,
                "\(activity) should not draw the usage-limit mark"
            )
        }
    }

    /// A session already limited when the row is built, then loading something of its own — the
    /// loading spinner outranks it, as it does every other state.
    func testLoadingOutranksTheMark() {
        let indicator = SessionStatusIndicator()
        indicator.update(for: .limitReached)
        XCTAssertFalse(mark(in: indicator).isHidden)

        indicator.update(for: .limitReached, isLoading: true)

        XCTAssertTrue(mark(in: indicator).isHidden)
        XCTAssertTrue(spinner(in: indicator).isAnimating)
    }

    /// Status must be identifiable without colour (`THEME_BOUNDARY.md` rule 11). The two dots
    /// separate by fill; this separates from both by silhouette, and that is only true if it is
    /// genuinely a different shape rather than a red dot.
    func testTheMarkIsATriangleRatherThanAThirdDot() {
        let path = ThemedWarningMark.trianglePath(in: NSRect(x: 0, y: 0, width: 12, height: 12))

        XCTAssertGreaterThanOrEqual(path.elementCount, 4)
        XCTAssertTrue(
            NSRect(x: 0, y: 0, width: 12, height: 12).contains(path.bounds),
            "the mark must stay inside the slot the dot and the spinner share"
        )

        // A triangle covers about half of its bounding box; a disc covers ~0.79 of it. Measured
        // rather than asserted about the path, because the question is what the eye sees.
        let filled = coverage(of: path, in: NSRect(x: 0, y: 0, width: 12, height: 12))
        XCTAssertLessThan(filled, 0.62, "a shape this full is a dot, not a triangle")
        XCTAssertGreaterThan(filled, 0.25, "the mark has to be visible at 12pt")
    }

    /// The corners come from the theme, capped so three arcs cannot meet and eat the edges. A
    /// style that squares its panels draws this sharp; System rounds it.
    func testTheCornersFollowTheThemeAndStayCorners() {
        let bounds = NSRect(x: 0, y: 0, width: 12, height: 12)
        let path = ThemedWarningMark.trianglePath(in: bounds)

        if Design.Radius.control > 0 {
            XCTAssertGreaterThan(
                path.elementCount, 4,
                "a rounded theme should produce arcs rather than three straight joins"
            )
        } else {
            XCTAssertEqual(path.elementCount, 4, "a square theme draws three lines and a close")
        }
    }

    /// A mark that says nothing is decoration. VoiceOver has to reach the same sentence the
    /// popover shows.
    func testTheMarkStatesWhatItMeans() {
        let indicator = SessionStatusIndicator()
        indicator.update(for: .limitReached)

        let mark = mark(in: indicator)
        XCTAssertTrue(mark.isAccessibilityElement())
        XCTAssertEqual(mark.accessibilityRole(), .staticText)
        XCTAssertEqual(mark.accessibilityLabel(), L10n.string("Session stopped at its usage limit"))
    }

    /// The row's own popover is where the reason is spelt out, since the mark is 12pt of red.
    func testTheRowsPopoverNamesTheLimitRatherThanCallingItAttention() {
        let session = AgentSession(kind: .claude, title: "Plan the scheduler")
        let info = SessionInfoPopoverViewController.Info(session: session, activity: .limitReached)

        XCTAssertEqual(info.stateText, SessionPopoverDefaults.limitState)
        XCTAssertEqual(info.stateSymbol, SessionPopoverDefaults.limitSymbol)
    }

    // MARK: - Rendered

    /// The three marks together, in both appearances: the only way to check that the triangle
    /// reads as a different *kind* of thing beside the dots rather than as a third one of them.
    func testRendersTheMarksBesideEachOther() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let session = AgentSession(kind: .claude, title: "Plan the scheduler")
        let states: [SessionActivity] = [.working, .awaitingUser, .needsAttention, .limitReached]

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)
            var data: Data?

            let render = {
                let host = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 28 * 4))
                host.appearance = appearance

                let rows: [NSView] = states.map { activity in
                    let row = SessionRowView(customizationLookup: { _ in .empty })
                    row.translatesAutoresizingMaskIntoConstraints = false
                    row.configure(with: session, activity: activity)
                    return row
                }

                let stack = NSStackView(views: rows)
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 0
                stack.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    stack.topAnchor.constraint(equalTo: host.topAnchor)
                ])
                for row in rows {
                    NSLayoutConstraint.activate([
                        row.widthAnchor.constraint(equalTo: host.widthAnchor),
                        row.heightAnchor.constraint(equalToConstant: 28)
                    ])
                }

                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()
                host.wantsLayer = true
                host.layer?.backgroundColor = Design.Surface.background.cgColor

                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    return
                }
                host.cacheDisplay(in: host.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }

            if #available(macOS 11.0, *) {
                appearance?.performAsCurrentDrawingAppearance(render)
            } else {
                render()
            }

            let image = try XCTUnwrap(data, "Failed to render the session marks in \(name)")
            try image.write(to: directory.appendingPathComponent("session-marks-\(name).png"))
        }
        print("Rendered session marks to \(Render.directory.path)")
    }

    /// The same rows with a rule drawn through the *ink* of each title, so the icon, the text
    /// and the trailing mark can be checked against one line rather than against each other's
    /// frames. Every element's ink centre is measured off the rendered pixels and printed
    /// beside it — a frame that is centred says nothing about a glyph that sits high in it.
    func testRendersTheCenteringGuides() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let session = AgentSession(kind: .claude, title: "Plan the scheduler")
        let states: [SessionActivity] = [.working, .awaitingUser, .needsAttention, .limitReached]
        let rowHeight: CGFloat = 28
        let width: CGFloat = 240

        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: rowHeight * 4))
        host.appearance = NSAppearance(named: .aqua)

        let rows: [SessionRowView] = states.map { activity in
            let row = SessionRowView(customizationLookup: { _ in .empty })
            row.translatesAutoresizingMaskIntoConstraints = false
            row.configure(with: session, activity: activity)
            return row
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        for row in rows {
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: host.widthAnchor),
                row.heightAnchor.constraint(equalToConstant: rowHeight)
            ])
        }

        var rendered: NSBitmapImageRep?
        let render = {
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            host.wantsLayer = true
            host.layer?.backgroundColor = Design.Surface.background.cgColor
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            rendered = rep
        }
        if #available(macOS 11.0, *) {
            host.appearance?.performAsCurrentDrawingAppearance(render)
        } else {
            render()
        }

        let rep = try XCTUnwrap(rendered)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        /// The ink's vertical centre inside one element's column, in host points.
        ///
        /// Two things this got wrong first, both of which read as "everything is perfectly
        /// centred": scanning the whole bitmap rather than the element's own row — every row
        /// shares these columns — and comparing against `Design.Surface.background` when the
        /// row draws its own surface over it, which made every pixel count as ink. The ground
        /// is therefore taken from the region itself: whatever colour most of it is.
        func inkCentre(of view: NSView, within band: NSRect) -> CGFloat? {
            let frame = view.convert(view.bounds, to: host)
            let x0 = max(0, Int(frame.minX * scale))
            let x1 = min(rep.pixelsWide - 1, Int(frame.maxX * scale))
            let bandTop = max(0, Int((host.bounds.height - band.maxY) * scale))
            let bandBottom = min(rep.pixelsHigh - 1, Int((host.bounds.height - band.minY) * scale) - 1)
            guard x0 <= x1, bandTop <= bandBottom else { return nil }

            var pixels: [[NSColor]] = []
            var counts: [Int: Int] = [:]
            for pixelY in bandTop...bandBottom {
                var row: [NSColor] = []
                for pixelX in x0...x1 {
                    let colour = rep.colorAt(x: pixelX, y: pixelY)?
                        .usingColorSpace(.deviceRGB) ?? .clear
                    row.append(colour)
                    counts[self.quantised(colour), default: 0] += 1
                }
                pixels.append(row)
            }
            guard let groundKey = counts.max(by: { $0.value < $1.value })?.key else { return nil }

            var top: Int?
            var bottom: Int?
            for (offset, row) in pixels.enumerated() {
                let hasInk = row.contains { colour in
                    guard self.quantised(colour) != groundKey else { return false }
                    return self.distance(colour, from: self.ground(groundKey)) > 0.10
                }
                guard hasInk else { continue }
                if top == nil { top = bandTop + offset }
                bottom = bandTop + offset
            }

            guard let top, let bottom else { return nil }
            let centrePixel = (CGFloat(top) + CGFloat(bottom) + 1) / 2
            return host.bounds.height - centrePixel / scale
        }

        var guides: [(y: CGFloat, colour: NSColor)] = []
        for (index, row) in rows.enumerated() {
            let icon = try XCTUnwrap(Self.view("sidebar.session.identity", in: row))
            let title = try XCTUnwrap(Self.view("sidebar.session.title", in: row))
            let status = try XCTUnwrap(Self.view("sidebar.session.status", in: row))

            let rowFrame = row.convert(row.bounds, to: host)
            let textCentre = inkCentre(of: title, within: rowFrame)
            let iconCentre = inkCentre(of: icon, within: rowFrame)
            let markCentre = inkCentre(of: status, within: rowFrame)

            func point(_ value: CGFloat?) -> String {
                value.map { String(format: "%.2f", $0) } ?? "—"
            }
            func delta(_ value: CGFloat?) -> String {
                guard let value, let textCentre else { return "—" }
                return String(format: "%+.2f", value - textCentre)
            }

            print(
                "row \(index) (\(states[index]))"
                    + "  box \(point(rowFrame.midY))"
                    + "  text \(point(textCentre))"
                    + "  icon \(point(iconCentre)) (Δ \(delta(iconCentre)))"
                    + "  mark \(point(markCentre)) (Δ \(delta(markCentre)))"
            )

            // The measurement is the assertion, not just the caption: the triangle's ink sat
            // 1.25pt under the title's while the dots sat 0.25 under, because rounding takes a
            // point off the apex and nothing off the base. One point on a 28pt row is visible,
            // and no other test in the suite could see it.
            for (name, centre) in [("icon", iconCentre), ("mark", markCentre)] {
                let centre = try XCTUnwrap(centre, "\(name) drew no ink in row \(index)")
                let text = try XCTUnwrap(textCentre, "the title drew no ink in row \(index)")
                XCTAssertEqual(
                    centre,
                    text,
                    accuracy: 0.75,
                    "row \(index) (\(states[index])): the \(name)'s ink is off the title's line"
                )
            }

            if let textCentre { guides.append((textCentre, .systemPink)) }
            guides.append((rowFrame.midY, NSColor.systemBlue.withAlphaComponent(0.55)))
        }

        // Guides are drawn *over* the render rather than into the view tree, so nothing about
        // measuring the layout can move it.
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        let annotated = NSImage(size: host.bounds.size)
        annotated.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: host.bounds.size))
        for guide in guides {
            guide.colour.setFill()
            NSRect(x: 0, y: guide.y - 0.25, width: host.bounds.width, height: 0.5).fill()
        }
        annotated.unlockFocus()

        let data = try XCTUnwrap(
            annotated.tiffRepresentation
                .flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:])
        )
        try data.write(to: directory.appendingPathComponent("session-marks-guides.png"))

        // The trailing column at 8×, nearest-neighbour: a point of misalignment on a 28pt row
        // is one pixel, and one pixel is not something to decide by eye at 1×.
        let crop = NSRect(x: host.bounds.width - 40, y: 0, width: 40, height: host.bounds.height)
        let zoomFactor: CGFloat = 8
        let zoomed = NSImage(
            size: NSSize(width: crop.width * zoomFactor, height: crop.height * zoomFactor)
        )
        zoomed.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        annotated.draw(
            in: NSRect(origin: .zero, size: zoomed.size),
            from: crop,
            operation: .copy,
            fraction: 1
        )
        zoomed.unlockFocus()
        let zoomData = try XCTUnwrap(
            zoomed.tiffRepresentation
                .flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:])
        )
        try zoomData.write(to: directory.appendingPathComponent("session-marks-guides-zoom.png"))
        print("Rendered centering guides to \(directory.path)")
    }

    // MARK: - Helpers

    /// A colour bucketed coarsely enough that antialiasing does not invent new grounds.
    private func quantised(_ colour: NSColor) -> Int {
        let red = Int(colour.redComponent * 31)
        let green = Int(colour.greenComponent * 31)
        let blue = Int(colour.blueComponent * 31)
        return red << 10 | green << 5 | blue
    }

    private func ground(_ key: Int) -> NSColor {
        NSColor(
            deviceRed: CGFloat(key >> 10 & 31) / 31,
            green: CGFloat(key >> 5 & 31) / 31,
            blue: CGFloat(key & 31) / 31,
            alpha: 1
        )
    }

    private func distance(_ colour: NSColor, from other: NSColor) -> CGFloat {
        abs(colour.redComponent - other.redComponent)
            + abs(colour.greenComponent - other.greenComponent)
            + abs(colour.blueComponent - other.blueComponent)
    }

    /// The first descendant carrying an accessibility identifier. Local rather than shared:
    /// the sibling render tests keep their own, and a helper crossing files is how a fixture
    /// starts depending on another test's setup.
    private static func view(_ identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for subview in root.subviews {
            if let found = view(identifier, in: subview) { return found }
        }
        return nil
    }

    private func spinner(in indicator: SessionStatusIndicator) -> ThemedSpinner {
        indicator.subviews.compactMap { $0 as? ThemedSpinner }.first!
    }

    private func mark(in indicator: SessionStatusIndicator) -> ThemedWarningMark {
        indicator.subviews.compactMap { $0 as? ThemedWarningMark }.first!
    }

    /// What fraction of `bounds` the filled path actually covers, sampled on a grid.
    private func coverage(of path: NSBezierPath, in bounds: NSRect) -> CGFloat {
        let steps = 60
        var inside = 0
        for row in 0..<steps {
            for column in 0..<steps {
                let point = NSPoint(
                    x: bounds.minX + (CGFloat(column) + 0.5) / CGFloat(steps) * bounds.width,
                    y: bounds.minY + (CGFloat(row) + 0.5) / CGFloat(steps) * bounds.height
                )
                if path.contains(point) { inside += 1 }
            }
        }
        return CGFloat(inside) / CGFloat(steps * steps)
    }
}
