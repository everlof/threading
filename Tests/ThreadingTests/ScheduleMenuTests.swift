import AppKit
import XCTest

@testable import Threading

/// The offers behind the chevron beside a send, and how tall each of them ends up.
///
/// Height is the subject here because it is decided a level away from where the rows are built.
/// `ThemedMenuMetrics.heights` gives every row in a run the height of the tallest kind in it —
/// deliberately, so a group of logins where some carry a scoped window does not read as a spacing
/// defect. That rule turns one row's second line into three tall rows, which is what happened
/// here: "In an hour" is the only wall-clock offer whose title does not already say the time, and
/// its subtitle stretched "Tomorrow at 09:00" and "Monday at 09:00" into 46pt rows holding one
/// line of text each.
@MainActor
final class ScheduleMenuTests: XCTestCase {

    // MARK: - Fixture

    /// A Friday morning: both Tomorrow and Monday are offered, and they name different days —
    /// on a Sunday the menu suppresses Monday rather than naming one moment twice.
    private let now = Date(timeIntervalSince1970: 1_755_244_800)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    private var locale: Locale { Locale(identifier: "en_GB") }

    private func entries(usage: AccountUsage? = nil) -> [ThemedMenuEntry] {
        ScheduleMenu.entries(
            now: now,
            calendar: calendar,
            locale: locale,
            usage: usage,
            onChoose: { _ in }
        )
    }

    /// The rows before the first rule — the wall-clock offers, which is the run in question.
    private func leadingRun(of entries: [ThemedMenuEntry]) -> [ThemedMenuItem] {
        var run: [ThemedMenuItem] = []
        for entry in entries {
            guard let item = entry.item else { break }
            run.append(item)
        }
        return run
    }

    // MARK: - Row Height

    func testAWallClockOfferStatesItsTimeOnTheTitleLine() {
        let run = leadingRun(of: entries())

        XCTAssertGreaterThanOrEqual(run.count, 2, "the wall-clock offers went missing")
        for item in run {
            XCTAssertNil(
                item.subtitle,
                "“\(item.title)” took a second line, which makes every offer beside it 46pt tall"
            )
        }
        // The one whose title does not already say when: its reading is still on screen, beside
        // the title rather than under it.
        XCTAssertEqual(run.first?.title, L10n.string("In an hour"))
        XCTAssertEqual(run.first?.titleDetail?.isEmpty, false)
        XCTAssertNil(
            run.dropFirst().first?.titleDetail,
            "“Tomorrow at 09:00” already says the time; repeating it is a second reading"
        )
    }

    func testTheWallClockOffersAreShortRows() {
        let entries = self.entries()
        let heights = ThemedMenuMetrics.heights(for: entries)
        let run = leadingRun(of: entries)

        XCTAssertEqual(
            Set(heights.prefix(run.count)),
            [ThemedMenuMetrics.rowHeight],
            "an offer with nothing on a second line was given a second line's height"
        )
    }

    /// The reset offers keep their subtitle: "14:30 · resets in 4h 37m" is two facts and a
    /// sentence's worth of them, not a qualifier that fits beside a title. They sit behind a
    /// separator, which is what makes the change of height legible rather than accidental.
    func testAResetOfferKeepsItsReadingOnASecondLine() {
        let usage = AccountUsage(
            windows: [
                AccountUsage.Window(
                    id: UsageDefaults.fiveHourWindowID,
                    label: "5h",
                    fraction: 0.9,
                    resetsAt: now.addingTimeInterval(3_600),
                    windowDuration: 5 * 3_600,
                    scopeName: nil
                )
            ],
            planLabel: "Max",
            observedAt: now,
            source: .api
        )

        let entries = self.entries(usage: usage)
        let heights = ThemedMenuMetrics.heights(for: entries)
        guard let index = entries.firstIndex(where: {
            $0.item?.representedValue as? String == "\(PresetDefaults.resetIDPrefix)\(UsageDefaults.fiveHourWindowID)"
        }) else {
            return XCTFail("the reset offer was not built")
        }

        XCTAssertEqual(entries[index].item?.subtitle?.isEmpty, false)
        XCTAssertNil(entries[index].item?.titleDetail)
        XCTAssertEqual(heights[index], ThemedMenuMetrics.subtitleRowHeight)
        XCTAssertGreaterThan(
            heights[index],
            ThemedMenuMetrics.rowHeight,
            "the two kinds of offer would be indistinguishable in height"
        )
    }

    // MARK: - Rendered

    /// The whole menu, drawn. Row height is the sort of defect that is obvious in a picture and
    /// invisible in every assertion anyone would think to write — this one shipped as two offers
    /// padded to a two-line height with one line of text in the middle of each.
    func testRendersTheOffersToImages() throws {
        let usage = AccountUsage(
            windows: [
                AccountUsage.Window(
                    id: UsageDefaults.fiveHourWindowID,
                    label: "5h",
                    fraction: 0.9,
                    resetsAt: now.addingTimeInterval(3_600),
                    windowDuration: 5 * 3_600,
                    scopeName: nil
                ),
                AccountUsage.Window(
                    id: UsageDefaults.weeklyWindowID,
                    label: "7d",
                    fraction: 0.6,
                    resetsAt: now.addingTimeInterval(4 * 24 * 3_600),
                    windowDuration: 7 * 24 * 3_600,
                    scopeName: nil
                )
            ],
            planLabel: "Max",
            observedAt: now,
            source: .api
        )
        let entries = self.entries(usage: usage)

        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map {
            URL(fileURLWithPath: $0)
        } ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var renders = Set<Data>()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let data = try XCTUnwrap(
                menuImage(entries: entries, appearance: appearance),
                "\(name): the menu drew nothing"
            )
            renders.insert(data)
            try data.write(to: directory.appendingPathComponent("schedule-menu-\(name).png"))
        }
        XCTAssertEqual(renders.count, 2, "the menu ignored the appearance it was drawn in")
    }

    /// The panel presented in a window that is built and never shown — `ThemedMenuPresenter`
    /// draws inside the window's content view rather than in a second window, so `cacheDisplay`
    /// sees the whole panel without anything reaching the screen.
    private func menuImage(
        entries: [ThemedMenuEntry],
        appearance name: NSAppearance.Name
    ) -> Data? {
        guard let appearance = NSAppearance(named: name) else { return nil }

        var data: Data?
        let render: @MainActor () -> Void = {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.appearance = appearance
            let root = ThemedSurfaceView()
            root.translatesAutoresizingMaskIntoConstraints = true
            root.frame = NSRect(x: 0, y: 0, width: 380, height: 460)
            root.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            let source = NSView(frame: NSRect(x: 12, y: 428, width: 1, height: 1))
            root.addSubview(source)
            window.contentView = root

            let token = ThemedMenuPresenter.present(
                ThemedMenuPresentation(entries: entries, minimumWidth: 0),
                from: source,
                selectedEntryIndex: nil,
                onChoose: { _, _ in },
                onDismiss: {}
            )
            defer { ThemedMenuPresenter.dismiss(token) }

            AppThemeRefresh.repaint(root)
            root.layoutSubtreeIfNeeded()

            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }

        appearance.performAsCurrentDrawingAppearance {
            MainActor.assumeIsolated(render)
        }
        return data
    }
}
