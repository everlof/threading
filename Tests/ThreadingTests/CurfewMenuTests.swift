import AppKit
import XCTest

@testable import Threading

/// The rows behind "end this session at", and which of them the checkmark lands on.
///
/// The checkmark is the subject. It reads the **resolved** answer rather than the record, so a
/// chat that says nothing while its checkout or the standing window says plenty still shows what
/// will happen to it tonight — and a chat that named its own moment marks neither standing rule,
/// because it is under neither.
@MainActor
final class CurfewMenuTests: XCTestCase {

    // MARK: - Fixture

    /// Friday 15 August 2025, 08:00 GMT — a morning, so "Tonight" is still ahead and the
    /// standing 04:00 window's next opening is tomorrow's.
    private let now = Date(timeIntervalSince1970: 1_755_244_800)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    private var locale: Locale { Locale(identifier: "en_GB") }

    private var quietHours: QuietHours {
        QuietHours(
            isEnabled: true,
            startMinute: CurfewDefaults.quietHoursStartMinute,
            endMinute: CurfewDefaults.quietHoursEndMinute
        )
    }

    /// Tomorrow's 04:00 — what the standing window resolves to from this morning.
    private var nextWindow: DateInterval {
        guard let window = quietHours.nextWindow(after: now, calendar: calendar) else {
            preconditionFailure("the fixture window has to exist")
        }
        return window
    }

    private func curfew(at deadline: Date, origin: CurfewOrigin) -> ResolvedCurfew {
        ResolvedCurfew(
            deadline: deadline,
            origin: origin,
            windDownMargin: CurfewDefaults.windDownMargin,
            grace: CurfewDefaults.grace,
            windDownText: CurfewDefaults.windDownText
        )
    }

    /// Nothing of its own: the standing window answered.
    private var followingQuietHours: CurfewResolution.Answer {
        CurfewResolution.Answer(
            scope: .app,
            curfew: curfew(at: nextWindow.start, origin: .quietHours(endsAt: nextWindow.end))
        )
    }

    /// This session said `.exempt`.
    private var exempt: CurfewResolution.Answer {
        CurfewResolution.Answer(scope: .session, curfew: nil)
    }

    /// This session named a moment of its own.
    private var ownMoment: CurfewResolution.Answer {
        CurfewResolution.Answer(
            scope: .session,
            curfew: curfew(at: now.addingTimeInterval(4 * 3_600), origin: .session)
        )
    }

    /// No window configured, nothing chosen — the app scope answering "no curfew at all".
    private var nothing: CurfewResolution.Answer {
        CurfewResolution.Answer(scope: .app, curfew: nil)
    }

    private func usage() -> AccountUsage {
        AccountUsage(
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
    }

    private func entries(
        usage: AccountUsage? = nil,
        quietHours: QuietHours? = nil,
        resolved: CurfewResolution.Answer? = nil,
        holds: Bool = false,
        offersExempt: Bool = true,
        onChoose: @escaping (CurfewMenu.Choice) -> Void = { _ in }
    ) -> [ThemedMenuEntry] {
        CurfewMenu.entries(
            now: now,
            calendar: calendar,
            locale: locale,
            usage: usage,
            quietHours: quietHours ?? self.quietHours,
            resolved: resolved ?? followingQuietHours,
            holds: holds,
            offersExempt: offersExempt,
            onChoose: onChoose
        )
    }

    private func item(
        _ id: CurfewMenu.RowID,
        in entries: [ThemedMenuEntry]
    ) -> ThemedMenuItem? {
        entries.compactMap(\.item).first { ($0.representedValue as? CurfewMenu.RowID) == id }
    }

    private func presetIDs(in entries: [ThemedMenuEntry]) -> [String] {
        entries.compactMap { $0.item?.representedValue as? String }
    }

    // MARK: - Order

    func testTheOffersRunFromMomentsThroughRulesToTheCustomSheet() {
        let entries = self.entries(usage: usage(), holds: true)

        let wallClock = [
            PresetDefaults.curfewInAnHourID,
            PresetDefaults.curfewInThreeHoursID,
            PresetDefaults.curfewTonightID,
        ]
        XCTAssertEqual(
            Array(presetIDs(in: entries).prefix(wallClock.count)),
            wallClock,
            "the short leashes lead, before anything that is a rule"
        )
        XCTAssertEqual(
            presetIDs(in: entries).filter { $0.hasPrefix(PresetDefaults.curfewResetIDPrefix) }.count,
            2,
            "both windows with a reset ahead are offerable as ends"
        )

        // Everything after the offers, in the order somebody reads it.
        let named = entries.compactMap { $0.item?.representedValue as? CurfewMenu.RowID }
        XCTAssertEqual(named, [.atQuietHours, .inherit, .exempt, .lift, .custom])

        // Each run stands behind a rule of its own: moments, resets, the window, the rules.
        XCTAssertEqual(
            entries.filter { !$0.isItem }.count,
            4,
            "the runs would read as one list of interchangeable answers"
        )
    }

    func testAWallClockOfferKeepsItsTimeOnTheTitleLineAndAResetOfferDoesNot() {
        let entries = self.entries(usage: usage())

        let wallClockRows = entries
            .compactMap(\.item)
            .filter { ($0.representedValue as? String)?.hasPrefix("curfew.in") == true }
        XCTAssertEqual(wallClockRows.count, 2)
        for row in wallClockRows {
            XCTAssertNil(row.subtitle, "“\(row.title)” took a second line and stretched the run")
            XCTAssertEqual(row.titleDetail?.isEmpty, false)
        }

        guard let reset = entries.compactMap(\.item).first(where: {
            ($0.representedValue as? String)?.hasPrefix(PresetDefaults.curfewResetIDPrefix) == true
        }) else {
            return XCTFail("the reset offer was not built")
        }
        XCTAssertEqual(reset.subtitle?.isEmpty, false, "two facts are a sentence, not a qualifier")
        XCTAssertNil(reset.titleDetail)
    }

    func testTheQuietHoursOfferNamesTheNextOpeningAndHandsItBack() {
        var chosen: Date?
        let entries = self.entries(onChoose: { choice in
            if case .atQuietHours(let start) = choice { chosen = start }
        })

        guard let row = item(.atQuietHours, in: entries) else {
            return XCTFail("the standing window was not offered")
        }
        XCTAssertTrue(row.title.contains(ScheduledTimePresets.time(nextWindow.start, locale: locale)))
        XCTAssertEqual(row.help?.isEmpty, false)

        row.onChoose?()
        XCTAssertEqual(chosen, nextWindow.start)
    }

    // MARK: - Without A Standing Window

    /// "Follow quiet hours" beside a window nobody has configured names a rule that does not
    /// exist, so the whole vocabulary collapses to one answer.
    func testAnUnconfiguredWindowOffersNoCurfewInsteadOfTwoRulesAboutIt() {
        let entries = self.entries(
            quietHours: QuietHours(isEnabled: false),
            resolved: nothing
        )

        XCTAssertNil(item(.atQuietHours, in: entries))
        XCTAssertNil(item(.exempt, in: entries))
        guard let row = item(.inherit, in: entries) else {
            return XCTFail("there is always a standing answer")
        }
        XCTAssertEqual(row.title, L10n.string("No curfew"))
        XCTAssertTrue(row.isSelected, "nothing resolves, which is what this row says")
        XCTAssertEqual(row.help?.isEmpty, false)
    }

    func testANilWindowIsTheSameAsASwitchedOffOne() {
        let entries = CurfewMenu.entries(
            now: now,
            calendar: calendar,
            locale: locale,
            quietHours: nil,
            resolved: nothing,
            holds: false,
            onChoose: { _ in }
        )

        XCTAssertNil(item(.atQuietHours, in: entries))
        XCTAssertEqual(item(.inherit, in: entries)?.title, L10n.string("No curfew"))
    }

    // MARK: - The Checkmark

    func testFollowingTheStandingWindowIsWhatAnAppScopeAnswerLooksLike() {
        let entries = self.entries(resolved: followingQuietHours)

        XCTAssertEqual(item(.inherit, in: entries)?.title, L10n.string("Follow quiet hours"))
        XCTAssertEqual(item(.inherit, in: entries)?.isSelected, true)
        XCTAssertEqual(item(.exempt, in: entries)?.isSelected, false)
    }

    func testASessionThatSaidExemptIsTheOneThatIsChecked() {
        let entries = self.entries(resolved: exempt)

        XCTAssertEqual(item(.exempt, in: entries)?.isSelected, true)
        XCTAssertEqual(item(.inherit, in: entries)?.isSelected, false)
    }

    /// The standing window answering "nothing" is a window that is simply off — not somebody
    /// exempting this session from it.
    func testAnUnconfiguredWindowDoesNotReadAsAnExemption() {
        let entries = self.entries(resolved: nothing)

        XCTAssertEqual(item(.exempt, in: entries)?.isSelected, false)
        XCTAssertEqual(item(.inherit, in: entries)?.isSelected, false)
    }

    func testTheDraftIsNotOfferedAnExemptionForARecordItDoesNotHaveYet() {
        let entries = self.entries(offersExempt: false)

        XCTAssertNil(item(.exempt, in: entries))
        XCTAssertNotNil(item(.inherit, in: entries), "it can still follow the standing window")
    }

    /// A moment is not one of the two rules, so it marks neither: it is stated instead, in a row
    /// that says it and cannot be chosen.
    func testASessionsOwnMomentIsStatedRatherThanCheckedAsARule() {
        let entries = self.entries(resolved: ownMoment)

        guard let row = item(.endsAt, in: entries) else {
            return XCTFail("the chosen moment went unsaid")
        }
        XCTAssertFalse(row.isEnabled)
        XCTAssertTrue(row.isSelected, "the checkmark still has to read the resolved answer")
        XCTAssertNil(row.onChoose)
        XCTAssertTrue(row.title.contains(
            ScheduledTimePresets.time(ownMoment.curfew?.deadline ?? now, locale: locale)
        ))

        XCTAssertEqual(item(.inherit, in: entries)?.isSelected, false)
        XCTAssertEqual(item(.exempt, in: entries)?.isSelected, false)
    }

    func testTheStatementLeadsTheRulesItIsNotOneOf() {
        let entries = self.entries(resolved: ownMoment)
        let named = entries.compactMap { $0.item?.representedValue as? CurfewMenu.RowID }

        XCTAssertEqual(named, [.atQuietHours, .endsAt, .inherit, .exempt, .custom])
    }

    // MARK: - Lift

    func testLiftIsOfferedOnlyWhileTheCurfewHolds() {
        XCTAssertNil(item(.lift, in: entries(holds: false)))

        var lifted = false
        let held = entries(holds: true, onChoose: { choice in
            if case .lift = choice { lifted = true }
        })
        guard let row = item(.lift, in: held) else {
            return XCTFail("a held session has nothing to press")
        }
        XCTAssertEqual(row.title, L10n.string("Lift Curfew"))
        XCTAssertEqual(row.help?.isEmpty, false)
        row.onChoose?()
        XCTAssertTrue(lifted)
    }

    // MARK: - Choices

    func testAWallClockOfferHandsBackTheMomentItNamed() {
        var chosen: Date?
        let entries = self.entries(onChoose: { choice in
            if case .at(let date) = choice { chosen = date }
        })

        let expected = ScheduledTimePresets.curfewWallClock(
            now: now,
            calendar: calendar,
            locale: locale
        ).first
        entries.compactMap(\.item)
            .first { ($0.representedValue as? String) == PresetDefaults.curfewInAnHourID }?
            .onChoose?()

        XCTAssertNotNil(expected?.date)
        XCTAssertEqual(chosen, expected?.date)
    }

    func testTheCustomSheetIsAlwaysTheLastWayOut() {
        var custom = false
        let entries = self.entries(onChoose: { choice in
            if case .custom = choice { custom = true }
        })

        XCTAssertEqual(
            entries.last?.item?.representedValue as? CurfewMenu.RowID,
            .custom
        )
        item(.custom, in: entries)?.onChoose?()
        XCTAssertTrue(custom)
    }

    // MARK: - Chip Title

    func testTheChipNamesAMomentAMovingWindowOrNothing() {
        XCTAssertNil(CurfewMenu.title(
            for: nil,
            quietHours: quietHours,
            now: now,
            calendar: calendar,
            locale: locale
        ))

        let deadline = now.addingTimeInterval(4 * 3_600)
        XCTAssertEqual(
            CurfewMenu.title(
                for: .at(deadline),
                quietHours: quietHours,
                now: now,
                calendar: calendar,
                locale: locale
            ),
            L10n.format("Until %@", ScheduledTimePresets.time(deadline, locale: locale))
        )

        XCTAssertEqual(
            CurfewMenu.title(
                for: .atQuietHours,
                quietHours: quietHours,
                now: now,
                calendar: calendar,
                locale: locale
            ),
            L10n.format(
                "Until quiet hours (%@)",
                ScheduledTimePresets.time(nextWindow.start, locale: locale)
            )
        )
    }

    /// The window can be switched off between choosing the plan and reading it back. The choice
    /// still stands — it resolves at fire time — so the chip drops the time rather than itself.
    func testTheChipStillSpeaksWhenTheWindowWasSwitchedOff() {
        XCTAssertEqual(
            CurfewMenu.title(
                for: .atQuietHours,
                quietHours: QuietHours(isEnabled: false),
                now: now,
                calendar: calendar,
                locale: locale
            ),
            L10n.string("Until quiet hours")
        )
    }

    // MARK: - Rendered

    /// The whole menu, drawn. A statement row that reads as a disabled choice, or a run of
    /// offers padded to a second line's height, is the sort of defect that is obvious in a
    /// picture and invisible in every assertion anyone would think to write.
    func testRendersTheOffersToImages() throws {
        let entries = self.entries(usage: usage(), holds: true)

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
            try data.write(to: directory.appendingPathComponent("curfew-menu-\(name).png"))
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
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.appearance = appearance
            let root = ThemedSurfaceView()
            root.translatesAutoresizingMaskIntoConstraints = true
            root.frame = NSRect(x: 0, y: 0, width: 380, height: 520)
            root.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            let source = NSView(frame: NSRect(x: 12, y: 488, width: 1, height: 1))
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
