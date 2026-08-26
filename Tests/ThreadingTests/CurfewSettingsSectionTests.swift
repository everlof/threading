import AppKit
import XCTest
@testable import Threading

/// The standing half of the curfew, as the Usage Windows page states it.
///
/// Two different things are checked here, and they fail for different reasons. The section is a
/// form, so its rows either exist and carry the stored answer or they do not — ordinary
/// assertions. The line under "Tonight" is prose derived from four controls across a midnight,
/// which is the part that can be *wrong* rather than merely ugly, so it is asserted whole,
/// against times derived from the same calendar rather than from a hardcoded clock.
@MainActor
final class CurfewSettingsSectionTests: XCTestCase {

    private enum Render {
        /// The width the pane gives a settings page, and a squeezed pane.
        static let widths: [CGFloat] = [420, SettingsUIDefaults.pageWidth]
        /// Tall enough that the curfew card — the sixth section down — is inside the picture.
        static let height: CGFloat = 2600

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    /// What the developer running the suite had set. The store redirects to a scratch suite under
    /// a test bundle, but this page writes a *behavioural* record the engine reads, so the value
    /// goes back exactly as it was found.
    private var storedPreferences = CurfewPreferences.default

    override func setUp() {
        super.setUp()
        storedPreferences = CurfewSettings.shared.preferences
    }

    override func tearDown() {
        CurfewSettings.shared.preferences = storedPreferences
        super.tearDown()
    }

    // MARK: - The Section

    /// The caption and the paragraph that says what a curfew is.
    ///
    /// The explanation is load-bearing copy rather than decoration: everything below it is a
    /// margin around a deadline the reader has not met yet, and a page of margins for an unnamed
    /// thing explains nothing. The two sentences asserted are the two that name where a curfew is
    /// chosen and what the standing window does.
    func testTheSectionExplainsWhatACurfewIsBeforeOfferingMargins() {
        let controller = UsageWindowPreferencesViewController()
        laidOut(controller.view)

        let text = Self.labels(in: controller.view).joined(separator: "\n")

        XCTAssertTrue(
            text.contains(L10n.string("Quiet Hours & Curfews").localizedUppercase),
            "the section has no caption on the page"
        )
        XCTAssertTrue(
            text.contains("from the composer when you start a session, or from a session's menu"),
            "the page has to say where a curfew is chosen"
        )
        XCTAssertTrue(
            text.contains("Quiet hours are a curfew every session follows daily"),
            "the page has to say what the standing window is"
        )
    }

    /// Every control the section is made of reaches the page, under the title the copy promises.
    func testEveryCurfewRowIsOnThePage() {
        let controller = UsageWindowPreferencesViewController()
        laidOut(controller.view)

        for title in Self.rowTitles {
            XCTAssertNotNil(
                SettingsRowAnchor.find(title: title, in: controller.view),
                "\(title) has no row on the page"
            )
        }
    }

    /// The four choices show what is stored rather than what is default.
    func testThePopUpsStandOnTheStoredChoices() throws {
        CurfewSettings.shared.preferences = CurfewPreferences(
            windDownMargin: 15 * 60,
            grace: nil,
            quietHours: QuietHours(isEnabled: true, startMinute: 23 * 60, endMinute: 7 * 60),
            stopsAgentOnGiveUp: true
        )

        let controller = UsageWindowPreferencesViewController()
        laidOut(controller.view)

        XCTAssertEqual(
            try popUp(Self.windDownTitle, in: controller.view).selectedItem?.title,
            L10n.format("%lld minutes before", Int64(15))
        )
        XCTAssertEqual(
            try popUp(Self.graceTitle, in: controller.view).selectedItem?.title,
            L10n.string("Never")
        )
        XCTAssertEqual(
            try popUp(Self.giveUpTitle, in: controller.view).selectedItem?.title,
            L10n.string("Stop the agent")
        )
        XCTAssertEqual(
            try popUp(Self.fromTitle, in: controller.view).selectedItem?.representedValue as? Int,
            23 * 60
        )
        XCTAssertEqual(
            try popUp(Self.toTitle, in: controller.view).selectedItem?.representedValue as? Int,
            7 * 60
        )
        XCTAssertEqual(
            try toggle(Self.quietHoursTitle, in: controller.view).state,
            .on,
            "the switch has to show the stored window"
        )
        XCTAssertEqual(
            try field(in: controller.view).stringValue,
            CurfewDefaults.windDownText,
            "the wrap-up field has to show the stored message"
        )
    }

    /// The two times stay on the page while the window is off, and say so by being inoperable.
    ///
    /// Removing them instead would leave a switch whose consequences are invisible until it is
    /// on, which is exactly backwards for a switch that holds every session in the app.
    func testTheQuietHoursTimesAreInoperableUntilTheWindowIsOn() throws {
        CurfewSettings.shared.preferences = CurfewPreferences(
            quietHours: QuietHours(isEnabled: false)
        )

        let off = UsageWindowPreferencesViewController()
        laidOut(off.view)
        XCTAssertFalse(try popUp(Self.fromTitle, in: off.view).isEnabled)
        XCTAssertFalse(try popUp(Self.toTitle, in: off.view).isEnabled)
        XCTAssertTrue(
            try toggle(Self.quietHoursTitle, in: off.view).isEnabled,
            "the switch itself is always operable"
        )

        CurfewSettings.shared.preferences = CurfewPreferences(
            quietHours: QuietHours(isEnabled: true)
        )

        let on = UsageWindowPreferencesViewController()
        laidOut(on.view)
        XCTAssertTrue(try popUp(Self.fromTitle, in: on.view).isEnabled)
        XCTAssertTrue(try popUp(Self.toTitle, in: on.view).isEnabled)
    }

    // MARK: - Writing

    /// A choice writes the one field it is about, and announces it once.
    ///
    /// Once matters: every writer here is a read-modify-write of a five-field record, and the
    /// engine, the menu and this page all rebuild on the announcement.
    func testChoosingAMarginWritesThatFieldAndAnnouncesItOnce() throws {
        CurfewSettings.shared.preferences = CurfewPreferences(
            windDownMargin: CurfewDefaults.windDownMargin,
            grace: CurfewDefaults.grace,
            windDownText: CurfewDefaults.windDownText
        )

        let controller = UsageWindowPreferencesViewController()
        laidOut(controller.view)

        let announced = expectation(description: "CurfewSettingsDidChange")
        announced.assertForOverFulfill = true
        let observations = AppEventObservations()
        observations.observe(CurfewSettingsDidChange.self) { _ in announced.fulfill() }

        let chosen = try XCTUnwrap(CurfewDefaults.windDownMarginChoices.firstIndex(of: 30 * 60))
        try popUp(Self.windDownTitle, in: controller.view).chooseItem(at: chosen)

        wait(for: [announced], timeout: 1)
        XCTAssertEqual(CurfewSettings.shared.preferences.windDownMargin, 30 * 60)
        XCTAssertEqual(
            CurfewSettings.shared.preferences.grace,
            CurfewDefaults.grace,
            "the other fields of the record must survive the write"
        )
        XCTAssertEqual(
            CurfewSettings.shared.preferences.windDownText,
            CurfewDefaults.windDownText
        )
    }

    /// The grace's "never" is a stored answer rather than an unset one.
    func testChoosingNeverStoresNoGraceAtAll() throws {
        CurfewSettings.shared.preferences = CurfewPreferences(grace: CurfewDefaults.grace)

        let controller = UsageWindowPreferencesViewController()
        laidOut(controller.view)

        let chosen = try XCTUnwrap(CurfewDefaults.graceChoices.firstIndex(of: TimeInterval?.none))
        try popUp(Self.graceTitle, in: controller.view).chooseItem(at: chosen)

        XCTAssertNil(CurfewSettings.shared.preferences.grace)
    }

    /// The escalation is stored from the row that arms it.
    func testChoosingStopTheAgentArmsTheEscalation() throws {
        CurfewSettings.shared.preferences = CurfewPreferences(stopsAgentOnGiveUp: false)

        let controller = UsageWindowPreferencesViewController()
        laidOut(controller.view)

        try popUp(Self.giveUpTitle, in: controller.view)
            .chooseItem(at: CurfewSettingsDefaults.stopsAgentIndex)

        XCTAssertTrue(CurfewSettings.shared.preferences.stopsAgentOnGiveUp)
    }

    /// The window's switch and its two times each write their own field.
    func testTheQuietHoursRowsWriteTheWindow() throws {
        CurfewSettings.shared.preferences = CurfewPreferences(
            quietHours: QuietHours(isEnabled: false)
        )

        let controller = UsageWindowPreferencesViewController()
        laidOut(controller.view)

        let toggle = try toggle(Self.quietHoursTitle, in: controller.view)
        XCTAssertTrue(toggle.accessibilityPerformPress())
        XCTAssertTrue(CurfewSettings.shared.preferences.quietHours.isEnabled)

        // 23:00 to 07:00 — the case the record calls a midnight crossing, and the one the two
        // popups must not try to correct for each other the way a working day's ends do.
        let rebuilt = UsageWindowPreferencesViewController()
        laidOut(rebuilt.view)
        let from = try popUp(Self.fromTitle, in: rebuilt.view)
        try from.chooseItem(at: XCTUnwrap(index(ofMinute: 23 * 60, in: from)))
        let to = try popUp(Self.toTitle, in: rebuilt.view)
        try to.chooseItem(at: XCTUnwrap(index(ofMinute: 7 * 60, in: to)))

        XCTAssertEqual(CurfewSettings.shared.preferences.quietHours.startMinute, 23 * 60)
        XCTAssertEqual(CurfewSettings.shared.preferences.quietHours.endMinute, 7 * 60)
    }

    /// The wrap-up template settles when the field is left, and a refused one leaves the stored
    /// message standing rather than a message nothing will ever send.
    func testTheWrapUpMessageSettlesOnLeavingTheFieldAndRefusesAnEmptyOne() throws {
        CurfewSettings.shared.preferences = CurfewPreferences(
            windDownText: CurfewDefaults.windDownText
        )

        let controller = UsageWindowPreferencesViewController()
        laidOut(controller.view)

        let written = "Stop at \(CurfewDefaults.timePlaceholder)."
        let field = try field(in: controller.view)
        field.stringValue = written
        controller.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: field
        ))
        XCTAssertEqual(CurfewSettings.shared.preferences.windDownText, written)

        field.stringValue = ""
        controller.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: field
        ))
        XCTAssertEqual(
            CurfewSettings.shared.preferences.windDownText,
            written,
            "an empty template is refused by the store"
        )
        XCTAssertEqual(
            field.stringValue,
            written,
            "and the field goes back to saying what is stored"
        )
    }

    // MARK: - Tonight

    /// The whole ladder in times, in the order it happens.
    func testTonightStatesTheWholeLadder() throws {
        let preferences = CurfewPreferences(
            windDownMargin: 10 * 60,
            grace: 5 * 60,
            quietHours: Self.overnightWindow
        )
        let window = try nextWindow(preferences)

        XCTAssertEqual(
            tonight(preferences),
            clauses([
                "Wrap-up at \(time(window.start.addingTimeInterval(-10 * 60)))",
                "held from \(time(window.start))",
                "a turn still running at \(time(window.start.addingTimeInterval(5 * 60))) "
                    + "is interrupted",
                "lifts \(time(window.end))"
            ])
        )
    }

    /// No wrap-up: the clause is gone, and the hold leads the sentence instead of trailing a
    /// clause that is not there.
    func testTonightOmitsTheWrapUpWhenItIsOff() throws {
        let preferences = CurfewPreferences(
            windDownMargin: nil,
            grace: 5 * 60,
            quietHours: Self.overnightWindow
        )
        let window = try nextWindow(preferences)

        XCTAssertEqual(
            tonight(preferences),
            clauses([
                "Held from \(time(window.start))",
                "a turn still running at \(time(window.start.addingTimeInterval(5 * 60))) "
                    + "is interrupted",
                "lifts \(time(window.end))"
            ])
        )
    }

    /// No grace: the hold still applies and nothing is typed, which the line says outright.
    func testTonightSaysNothingIsInterruptedWhenThereIsNoGrace() throws {
        let preferences = CurfewPreferences(
            windDownMargin: 10 * 60,
            grace: nil,
            quietHours: Self.overnightWindow
        )
        let window = try nextWindow(preferences)

        XCTAssertEqual(
            tonight(preferences),
            clauses([
                "Wrap-up at \(time(window.start.addingTimeInterval(-10 * 60)))",
                "held from \(time(window.start))",
                "nothing is interrupted",
                "lifts \(time(window.end))"
            ])
        )
    }

    /// A zero grace interrupts at the deadline itself rather than at some later minute.
    func testTonightInterruptsAtTheCurfewWhenTheGraceIsZero() throws {
        let preferences = CurfewPreferences(
            windDownMargin: 10 * 60,
            grace: 0,
            quietHours: Self.overnightWindow
        )
        let window = try nextWindow(preferences)

        XCTAssertEqual(
            tonight(preferences),
            clauses([
                "Wrap-up at \(time(window.start.addingTimeInterval(-10 * 60)))",
                "held from \(time(window.start))",
                "a turn still running at \(time(window.start)) is interrupted",
                "lifts \(time(window.end))"
            ])
        )
    }

    /// The escalation is stated where it happens, not as a footnote.
    func testTonightNamesTheStopWhenTheEscalationIsArmed() throws {
        let preferences = CurfewPreferences(
            windDownMargin: 10 * 60,
            grace: 5 * 60,
            quietHours: Self.overnightWindow,
            stopsAgentOnGiveUp: true
        )
        let window = try nextWindow(preferences)

        XCTAssertEqual(
            tonight(preferences),
            clauses([
                "Wrap-up at \(time(window.start.addingTimeInterval(-10 * 60)))",
                "held from \(time(window.start))",
                "a turn still running at \(time(window.start.addingTimeInterval(5 * 60))) "
                    + "is interrupted, then the agent is stopped",
                "lifts \(time(window.end))"
            ])
        )
    }

    /// Asked from inside a window, "Tonight" means the hold the reader is standing in.
    func testTonightDescribesTheWindowInProgressRatherThanTheNextOne() throws {
        let preferences = CurfewPreferences(
            windDownMargin: 10 * 60,
            grace: 5 * 60,
            quietHours: Self.overnightWindow
        )
        let inside = try XCTUnwrap(Self.calendar.date(
            byAdding: .hour,
            value: 1,
            to: nextWindow(preferences).start
        ))
        let window = try XCTUnwrap(
            preferences.quietHours.window(containing: inside, calendar: Self.calendar)
        )

        XCTAssertEqual(
            tonight(preferences, now: inside),
            clauses([
                "Wrap-up at \(time(window.start.addingTimeInterval(-10 * 60)))",
                "held from \(time(window.start))",
                "a turn still running at \(time(window.start.addingTimeInterval(5 * 60))) "
                    + "is interrupted",
                "lifts \(time(window.end))"
            ])
        )
    }

    /// With no standing window there is no deadline to name, so the line says what the same
    /// margins would do to a curfew set on one session — which is still switched on.
    func testTonightDescribesAPerSessionCurfewWhenQuietHoursAreOff() {
        XCTAssertEqual(
            tonight(CurfewPreferences(
                windDownMargin: 10 * 60,
                grace: 5 * 60,
                quietHours: QuietHours(isEnabled: false)
            )),
            "Quiet hours are off. A curfew you set on a session sends a wrap-up 10 minutes "
                + "before and interrupts a turn still running 5 minutes after."
        )

        XCTAssertEqual(
            tonight(CurfewPreferences(
                windDownMargin: nil,
                grace: nil,
                quietHours: QuietHours(isEnabled: false)
            )),
            "Quiet hours are off. A curfew you set on a session sends no wrap-up and never "
                + "interrupts a turn still running."
        )

        XCTAssertEqual(
            tonight(CurfewPreferences(
                windDownMargin: 30 * 60,
                grace: 0,
                quietHours: QuietHours(isEnabled: false),
                stopsAgentOnGiveUp: true
            )),
            "Quiet hours are off. A curfew you set on a session sends a wrap-up 30 minutes "
                + "before and interrupts a turn still running at the curfew, then stops the agent."
        )
    }

    // MARK: - Rendering

    /// The section as somebody reading it sees it, in both appearances and at both widths.
    ///
    /// Everything above asserts that a control exists and carries a value. Whether the card spans
    /// the pane, whether the wrap-up field reads as one editable line rather than as a plate, and
    /// whether the "Tonight" sentence still fits at 420pt are all questions a picture answers and
    /// no assertion here does.
    func testRendersTheCurfewSectionToImages() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        CurfewSettings.shared.preferences = CurfewPreferences(
            windDownMargin: CurfewDefaults.windDownMargin,
            grace: CurfewDefaults.grace,
            windDownText: CurfewDefaults.windDownText,
            quietHours: QuietHours(isEnabled: true)
        )

        var written: [String] = []
        for width in Render.widths {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = directory.appendingPathComponent(
                    "curfew-settings-\(Int(width))-\(name).png"
                )
                let data = try XCTUnwrap(
                    pageImage(width: width, appearance: appearance),
                    "Failed to render the curfew section at \(width)pt in \(name)"
                )
                try data.write(to: url)
                written.append(url.lastPathComponent)
            }
        }

        print("Rendered \(written.count) curfew settings pages to \(directory.path)")
        XCTAssertEqual(written.count, Render.widths.count * 2)
    }

    // MARK: - Fixture

    /// The window the feature was written for: a five-hour window resetting at 04:00 while its
    /// owner is asleep.
    private static let overnightWindow = QuietHours(
        isEnabled: true,
        startMinute: CurfewDefaults.quietHoursStartMinute,
        endMinute: CurfewDefaults.quietHoursEndMinute
    )

    /// The machine's own zone, with the calendar pinned: the sentence formats times in the
    /// zone the reader is in, so the fixture has to compute its window in that zone too.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    private static let locale = Locale(identifier: "en_GB")

    /// The evening before the 2026 spring-forward night in Europe. The window it names is on the
    /// far side of a day that is not 24 hours long in many zones, which is what makes this a
    /// fixture rather than "some Tuesday".
    private static let evening: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 28
        components.hour = 22
        return calendar.date(from: components) ?? Date()
    }()

    private func tonight(
        _ preferences: CurfewPreferences,
        now: Date = CurfewSettingsSectionTests.evening
    ) -> String {
        CurfewSettingsSentence.tonight(
            preferences: preferences,
            now: now,
            calendar: Self.calendar,
            locale: Self.locale
        )
    }

    private func nextWindow(_ preferences: CurfewPreferences) throws -> DateInterval {
        try XCTUnwrap(preferences.quietHours.nextWindow(
            after: Self.evening,
            calendar: Self.calendar
        ))
    }

    private func time(_ date: Date) -> String {
        ScheduledTimePresets.time(date, locale: Self.locale)
    }

    private func clauses(_ clauses: [String]) -> String {
        clauses.joined(separator: CurfewDefaults.receiptSeparator)
            + CurfewSettingsDefaults.sentenceTerminator
    }

    // MARK: - Helpers

    private static var windDownTitle: String { L10n.string("Send a wrap-up before the curfew") }
    private static var graceTitle: String { L10n.string("Interrupt a turn still running") }
    private static var giveUpTitle: String {
        L10n.format(
            "If it keeps working after %lld interrupts",
            Int64(CurfewDefaults.maximumInterrupts)
        )
    }
    private static var quietHoursTitle: String { L10n.string("Quiet hours") }
    private static var fromTitle: String { L10n.string("From") }
    private static var toTitle: String { L10n.string("To") }

    private static var rowTitles: [String] {
        [
            windDownTitle,
            graceTitle,
            L10n.string("Wrap-up message"),
            giveUpTitle,
            quietHoursTitle,
            fromTitle,
            toTitle,
            L10n.string("Tonight")
        ]
    }

    private func popUp(_ title: String, in root: NSView) throws -> ThemedPopUp {
        try control(title, in: root)
    }

    private func toggle(_ title: String, in root: NSView) throws -> ThemedToggle {
        try control(title, in: root)
    }

    private func control<Control: NSView>(_ title: String, in root: NSView) throws -> Control {
        let row = try XCTUnwrap(
            SettingsRowAnchor.find(title: title, in: root),
            "no row on the page carries the title “\(title)”"
        )
        return try XCTUnwrap(
            Self.descendants(of: row).compactMap { $0 as? Control }.first,
            "the row “\(title)” carries no \(Control.self)"
        )
    }

    private func field(in root: NSView) throws -> ThemedTextField {
        try XCTUnwrap(
            Self.descendants(of: root).compactMap { $0 as? ThemedTextField }.first {
                $0.accessibilityIdentifier() == CurfewSettingsDefaults.wrapUpFieldIdentifier
            },
            "the wrap-up field is not on the page"
        )
    }

    private func index(ofMinute minute: Int, in popUp: ThemedPopUp) -> Int? {
        (0 ..< popUp.numberOfItems).first {
            popUp.item(at: $0)?.representedValue as? Int == minute
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private static func labels(in view: NSView) -> Set<String> {
        var found: Set<String> = []
        if let field = view as? NSTextField { found.insert(field.stringValue) }
        for subview in view.subviews {
            found.formUnion(labels(in: subview))
        }
        return found
    }

    @discardableResult
    private func laidOut(
        _ view: NSView,
        width: CGFloat = SettingsUIDefaults.pageWidth,
        height: CGFloat = Render.height
    ) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)

        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])

        host.layoutSubtreeIfNeeded()
        return host
    }

    private func pageImage(width: CGFloat, appearance name: NSAppearance.Name) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        appearance?.performAsCurrentDrawingAppearance {
            let controller = UsageWindowPreferencesViewController()
            let host = self.laidOut(controller.view, width: width)
            host.appearance = appearance
            controller.view.appearance = appearance
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            data = self.png(of: host)
        }
        return data
    }

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
