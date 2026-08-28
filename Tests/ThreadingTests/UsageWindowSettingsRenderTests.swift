import AppKit
import XCTest
@testable import Threading

/// Draws the Usage Windows page and the diagram on it, light and dark.
///
/// This page carries an argument rather than a list of switches, and an argument can be correct
/// and still not land. Whether the two rows read as the *same day* twice, whether the faint block
/// before the working day reads as "already open" rather than as a rendering fault, whether the
/// hour it gains is legible beside the row that gained it: none of that is assertable, and all of
/// it decides whether anyone believes the feature enough to turn it on.
///
/// The assertions cover what a picture cannot: that the honest sentences are present, that the
/// diagram says the same thing to a screen reader, and that its two lanes actually differ.
final class UsageWindowSettingsRenderTests: XCTestCase {

    private enum Render {
        /// The width the pane gives a settings page, and a squeezed pane — the explanation and
        /// the footnote are the longest prose on the page and wrap first.
        static let widths: [CGFloat] = [420, SettingsUIDefaults.pageWidth]
        static let height: CGFloat = 1400

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    private let windowLength = UsageDefaults.fiveHourSeconds
    private let burn: TimeInterval = 3 * 3600

    private var workday: DateInterval {
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        return DateInterval(start: start, duration: 9 * 3600)
    }

    // MARK: - Content

    /// The page states what the feature does not do, in the place someone deciding whether to
    /// switch it on will read it.
    ///
    /// This is a settings page for something that spends money, so the caveats are load-bearing
    /// copy rather than a disclaimer: it raises no limit, it draws on the weekly cap, and it is
    /// offered on one runtime for a stated reason. A future edit that trims the footnote for
    /// length would quietly turn an honest page into a sales pitch.
    @MainActor
    func testThePageSaysWhatThePokeDoesNotDo() {
        let controller = UsageWindowPreferencesViewController()
        laidOut(controller.view, width: SettingsUIDefaults.pageWidth)

        let text = Self.labels(in: controller.view).joined(separator: "\n")

        XCTAssertTrue(text.contains(L10n.string("Usage Windows")))
        XCTAssertTrue(
            text.contains("raises no limit"),
            "the page has to say the poke raises nothing"
        )
        XCTAssertTrue(
            text.contains("weekly cap"),
            "the page has to say where the extra window is paid from"
        )
        XCTAssertTrue(
            text.contains("Claude only"),
            "the page has to say which runtimes this is offered on"
        )
    }

    /// Every control the schedule is made of reaches the page. The plan row matters most: it is
    /// the one that turns a derived lead into a time the reader can check against their own day.
    @MainActor
    func testTheScheduleAndItsDerivedPlanAreOnThePage() {
        let controller = UsageWindowPreferencesViewController()
        laidOut(controller.view, width: SettingsUIDefaults.pageWidth)

        let labels = Self.labels(in: controller.view)

        for title in [
            L10n.string("Open a window before I start"),
            L10n.string("I start at"),
            L10n.string("I stop at"),
            L10n.string("Days"),
            L10n.string("Today's plan")
        ] {
            XCTAssertTrue(labels.contains(title), "\(title) has no row on the page")
        }
    }

    /// Account discovery is an unbounded provider input, while the Settings viewport is not.
    /// A reading names one account, so it must materialize neither the fleet nor its neighbours.
    @MainActor
    func testAChangedAccountRefreshesOnlyItsVirtualRow() {
        let accounts = (0..<120).map { index in
            AgentAccount(
                provider: .claude,
                handle: AccountHandle(storedName: "usage-window-\(index)"),
                configPath: "/tmp/usage-window-\(index)",
                displayName: "Account \(index)"
            )
        }
        var evaluated: [AccountID] = []
        let controller = UsageWindowPreferencesViewController(
            accountsProvider: { accounts },
            decisionProvider: { account in
                evaluated.append(account.id)
                return .hold(.disabled)
            }
        )
        let host = laidOut(controller.view, width: 440, height: 700)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        controller.scrollAccountToVisibleForTesting(accounts[73].id)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(controller.virtualRowCountForTesting, accounts.count)
        XCTAssertGreaterThan(controller.materializedRowCountForTesting, 0)
        XCTAssertLessThan(
            controller.materializedRowCountForTesting,
            controller.virtualRowCountForTesting / 2
        )

        evaluated.removeAll()
        NotificationCenter.default.post(AccountUsageDidChange(accountID: accounts[73].id))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(evaluated, [accounts[73].id])

        controller.scrollAccountToVisibleForTesting(accounts[42].id)
        host.layoutSubtreeIfNeeded()
        evaluated.removeAll()
        NotificationCenter.default.post(UsageWindowPokeDidChange(accountIDs: [accounts[42].id]))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(evaluated, [accounts[42].id])
    }

    // MARK: - The Diagram

    /// The picture and the screen reader say the same thing.
    ///
    /// The whole argument is carried by fill and by one extra boundary, neither of which survives
    /// being read aloud, so the label states the counts and the totals outright.
    @MainActor
    func testTheDiagramDescribesBothLanesWithoutColour() throws {
        let grid = UsageWindowGridView()
        grid.show(workday: workday, burn: burn, windowLength: windowLength)

        let description = try XCTUnwrap(grid.accessibilityLabel())

        XCTAssertTrue(description.contains(L10n.string("Without a poke")))
        XCTAssertTrue(
            description.contains("3"),
            "the poked lane uses three windows and the label has to say so: \(description)"
        )
        XCTAssertTrue(
            description.contains("2"),
            "the unpoked lane uses two: \(description)"
        )
    }

    /// Nothing the diagram draws escapes its own bounds.
    ///
    /// The totals column was a fixed width sized to `7h working  +1h`, and a *measured* burn
    /// writes minutes into every figure — `6h 36m working  +1h 24m` — which is wider. AppKit
    /// stopped clipping drawing to a view's bounds in macOS 14, so the difference did not
    /// vanish: it ran out of the view and across the settings card's frame. The columns are
    /// measured from the drawn strings now; this renders the grid inside a transparent margin
    /// and asserts the margin stayed empty, so the next overflow fails here instead of on a
    /// screenshot. The clean three-hour fixture burn cannot catch it — its totals are exactly
    /// the round strings the fixed width was sized for — so this one uses 2h 36m.
    @MainActor
    func testTheDiagramDrawsNothingOutsideItsOwnBounds() throws {
        let margin: CGFloat = 40
        let measuredBurn: TimeInterval = 2 * 3600 + 36 * 60

        let grid = UsageWindowGridView()
        grid.show(workday: workday, burn: measuredBurn, windowLength: windowLength)

        let host = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: SettingsUIDefaults.pageWidth + margin * 2,
            height: UsageWindowGridDefaults.height + margin * 2
        ))
        host.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: margin),
            grid.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -margin),
            grid.topAnchor.constraint(equalTo: host.topAnchor, constant: margin),
            grid.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -margin)
        ])
        host.layoutSubtreeIfNeeded()

        // The host paints nothing itself, so any ink in the margin is the grid's.
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        let scaleX = CGFloat(rep.pixelsWide) / host.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / host.bounds.height
        // A point inside this rectangle is the grid's to draw; the 1pt allowance is for
        // antialiasing at the very edge, not for content.
        let inked = grid.frame.insetBy(dx: -1, dy: -1)

        var spill: [NSPoint] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let point = NSPoint(x: CGFloat(x) / scaleX, y: CGFloat(y) / scaleY)
                guard !inked.contains(point) else { continue }
                if let alpha = rep.colorAt(x: x, y: y)?.alphaComponent, alpha > 0 {
                    spill.append(point)
                }
            }
        }

        XCTAssertTrue(
            spill.isEmpty,
            "the diagram drew outside its bounds at \(spill.prefix(5)) (\(spill.count) pixels)"
        )
    }

    /// A diagram with two identical rows is a diagram making no point. This is the render-side
    /// guard on the claim `UsageWindowPlanTests` proves arithmetically.
    @MainActor
    func testTheTwoLanesActuallyDiffer() {
        let comparison = UsageWindowPlan.comparison(
            workday: workday,
            burn: burn,
            windowLength: windowLength
        )

        XCTAssertGreaterThan(
            comparison.poked.productiveTime,
            comparison.unpoked.productiveTime,
            "the picture would show two identical rows"
        )
    }

    // MARK: - Rendering

    @MainActor
    func testRendersUsageWindowSettingsToImages() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [String] = []

        for width in Render.widths {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = directory.appendingPathComponent(
                    "usage-windows-\(Int(width))-\(name).png"
                )
                let data = try XCTUnwrap(
                    pageImage(width: width, appearance: appearance),
                    "Failed to render the usage windows page at \(width)pt in \(name)"
                )
                try data.write(to: url)
                written.append(url.lastPathComponent)
            }
        }

        print("Rendered \(written.count) usage window pages to \(directory.path)")
        XCTAssertEqual(written.count, Render.widths.count * 2)
    }

    /// The diagram alone, under two deliberately different app themes, because it is the one
    /// surface here that draws its own fills rather than composing themed components — the shape
    /// most likely to keep a previous theme's accent after a live switch.
    @MainActor
    func testRendersTheDiagramUnderSeveralThemes() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let original = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(original) }

        var written = 0
        for theme in Self.renderThemes {
            AppThemeLibrary.apply(theme)

            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                guard let data = diagramImage(appearance: appearance) else {
                    XCTFail("Failed to render the diagram under \(theme.id) in \(name)")
                    continue
                }
                try data.write(
                    to: directory.appendingPathComponent(
                        "usage-window-grid-\(theme.id)-\(name).png"
                    )
                )
                written += 1
            }
        }

        print("Rendered \(written) usage window diagrams to \(directory.path)")
        XCTAssertEqual(written, Self.renderThemes.count * 2)
    }

    /// System, a theme whose accent is nowhere near it (which is what makes a stale colour
    /// visible at all), and the two period materials the blocks have to answer: Platinum bevels
    /// its troughs, and Win98 is the one theme that fills a progress bar with chunks instead of a
    /// smooth bar. The last is the whole reason the blocks are drawn through `ThemedSurface`
    /// rather than with a radius this file picked.
    private static let renderThemes: [AppTheme] = [
        .system,
        AppThemeStyles.cyberpunk,
        AppThemeStyles.platinum,
        AppThemeStyles.win98
    ]

    // MARK: - Helpers

    private static func labels(in view: NSView) -> Set<String> {
        var found: Set<String> = []
        if let field = view as? NSTextField { found.insert(field.stringValue) }
        for subview in view.subviews {
            found.formUnion(labels(in: subview))
        }
        return found
    }

    @MainActor
    private func pageImage(width: CGFloat, appearance name: NSAppearance.Name) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        appearance?.performAsCurrentDrawingAppearance {
            let controller = UsageWindowPreferencesViewController()
            let host = self.laidOut(controller.view, width: width, height: Render.height)
            host.appearance = appearance
            controller.view.appearance = appearance
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            data = self.png(of: host)
        }
        return data
    }

    @MainActor
    private func diagramImage(appearance name: NSAppearance.Name) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        appearance?.performAsCurrentDrawingAppearance {
            let grid = UsageWindowGridView()
            grid.show(workday: self.workday, burn: self.burn, windowLength: self.windowLength)

            let host = self.laidOut(
                grid,
                width: SettingsUIDefaults.pageWidth,
                height: UsageWindowGridDefaults.height
            )
            host.appearance = appearance
            grid.appearance = appearance
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            data = self.png(of: host)
        }
        return data
    }

    @MainActor
    @discardableResult
    private func laidOut(
        _ view: NSView,
        width: CGFloat,
        height: CGFloat = Render.height
    ) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)

        NSLayoutConstraint.activate([
            // A detached fixture's frame is only an initial size. Constrain the capture itself,
            // or the squeezed evidence can grow back to the page's preferred width while the PNG
            // still records the old 420-point bounds.
            host.widthAnchor.constraint(equalToConstant: width),
            host.heightAnchor.constraint(equalToConstant: height),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])

        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.width, width, accuracy: 0.5, "the fixture widened its capture")
        XCTAssertEqual(
            host.bounds.height,
            height,
            accuracy: 0.5,
            "the fixture changed its capture height"
        )
        return host
    }

    @MainActor
    private func png(of host: NSView) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }

        // The page paints no ground of its own, so one is painted here or every label draws
        // onto transparency.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
