import AppKit
import XCTest
@testable import Threading

/// The two places an existing session says what its curfew is doing: the footer chip on a
/// rendered conversation, and the pane ribbon over either surface.
///
/// Both read `CurfewResolution` against `ProjectStore.shared`, so these are hosted-store cases:
/// the resolution takes the store as a parameter precisely so it can be asserted without one,
/// but the *controllers* do not, and a component tested outside the container it ships in can
/// pass while being unusable.
///
/// Nothing here starts `SessionCurfewCenter`. It refuses under a hosted bundle anyway — it is the
/// class that types into terminals — and the surfaces under test read records rather than the
/// engine, which is the whole reason a hold is `now >= deadline` and not a stored flag.

// MARK: - The Chat Chip

@MainActor
final class ConversationCurfewChipTests: HostedStoreTestCase {

    // MARK: - Fixture

    /// 04:00 on a day far enough out that "tonight" is never behind us — the deadline moves in
    /// two directions in these tests and both have to be unambiguous.
    private let deadline = Date(timeIntervalSince1970: 2_000_000_000)

    /// The standing preferences, put back in teardown. `CurfewSettings` is `PreferenceStore`-
    /// backed, so a hosted test writes to a scratch suite rather than to the copy of Threading the
    /// developer is running — but a class that left quiet hours switched on in this *process*
    /// would still be deciding what the next class in the run resolves.
    private var standingPreferences: CurfewPreferences!

    override func setUpWithError() throws {
        try super.setUpWithError()
        standingPreferences = CurfewSettings.shared.preferences
        // Quiet hours off, so the only thing that can answer is the record under test. With them
        // on, every session in the fixture would resolve and the absent-chip case could not be
        // told from a broken one.
        var preferences = CurfewPreferences.default
        preferences.quietHours = QuietHours(isEnabled: false)
        CurfewSettings.shared.preferences = preferences
    }

    override func tearDownWithError() throws {
        CurfewSettings.shared.preferences = standingPreferences
        standingPreferences = nil
        try super.tearDownWithError()
    }

    /// A real conversation controller over a real record, because the chip's whole subject is
    /// what the store answers for this session.
    private func conversation(
        curfew: CurfewRule?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (controller: ConversationViewController, sessionID: SessionID) {
        let store = ProjectStore.shared
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-chip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let project = try XCTUnwrap(store.addProject(folderURL: folder), file: file, line: line)
        let session = try XCTUnwrap(
            store.addSession(to: project.id, kind: .codex, usesNativeUI: true, title: "Curfew"),
            file: file,
            line: line
        )
        if let curfew {
            // Written straight to the store rather than through `SessionCurfewCenter`: the engine
            // would evaluate the record on the spot and arm a process timer, and none of that is
            // what these surfaces read.
            XCTAssertEqual(
                store.setCurfewRule(curfew, forSessionID: session.id),
                .applied,
                file: file,
                line: line
            )
        }

        let controller = requireConversationViewController(
            agentSession: try XCTUnwrap(store.session(withID: session.id)),
            project: try XCTUnwrap(store.project(withID: project.id)),
            customizationLookup: { _ in .empty },
            file: file,
            line: line
        )
        _ = controller.view
        controller.refreshCurfewChip()
        return (controller, session.id)
    }

    private func rowIDs(of chip: ChipView) -> [CurfewMenu.RowID] {
        (chip.preparedPresentation()?.entries ?? []).compactMap { entry in
            guard case .item(let item) = entry else { return nil }
            return item.representedValue as? CurfewMenu.RowID
        }
    }

    private func item(_ id: CurfewMenu.RowID, in chip: ChipView) throws -> ThemedMenuItem {
        let items: [ThemedMenuItem] = (chip.preparedPresentation()?.entries ?? []).compactMap {
            guard case .item(let item) = $0 else { return nil }
            return item
        }
        return try XCTUnwrap(
            items.first { $0.representedValue as? CurfewMenu.RowID == id },
            "the menu has no \(id) row: \(rowIDs(of: chip))"
        )
    }

    // MARK: - Presence

    /// **The ordinary case is no chip.** A conversation with nothing ending it would otherwise
    /// spend a permanent footer slot saying "No curfew" on every chat forever, which is a rule
    /// nobody set being announced beside four controls that are all about the next reply.
    func testAConversationWithNoCurfewCarriesNoChip() throws {
        let fixture = try conversation(curfew: nil)
        XCTAssertTrue(fixture.controller.curfewChip.isHidden)
    }

    /// An armed curfew is a plan, and reads as one: what it is *until*, at a glance, while
    /// somebody is typing.
    func testAnArmedCurfewNamesTheMomentItEnds() throws {
        let fixture = try conversation(curfew: .until(deadline))
        let chip = fixture.controller.curfewChip

        XCTAssertFalse(chip.isHidden)
        XCTAssertEqual(
            chip.accessibilityTitle(),
            L10n.format("Until %@", ScheduledTimePresets.time(deadline))
        )
    }

    /// Past the deadline the tense changes, because a fence that has closed is different news
    /// from one that has not — and a chip still promising "Until 04:00" at 06:00 would be reading
    /// as a plan while the session is being held.
    func testAHeldCurfewSaysItIsHoldingRatherThanThatItIsComing() throws {
        let since = Date(timeIntervalSinceNow: -3_600)
        let fixture = try conversation(curfew: .until(since))
        let chip = fixture.controller.curfewChip

        XCTAssertFalse(chip.isHidden)
        XCTAssertEqual(
            chip.accessibilityTitle(),
            L10n.format("Curfew since %@", ScheduledTimePresets.time(since))
        )
    }

    /// The glance and the ledger are different lengths, and the chip has room for one. The other
    /// is the same sentence the pane's own ribbon carries, from the same writer.
    func testTheChipsTooltipCarriesTheWholeLadderRatherThanRepeatingItsTitle() throws {
        let fixture = try conversation(curfew: .until(deadline))
        let chip = fixture.controller.curfewChip

        let tooltip = try XCTUnwrap(chip.toolTip)
        XCTAssertNotEqual(tooltip, chip.accessibilityTitle())
        XCTAssertTrue(
            tooltip.contains(ScheduledTimePresets.time(deadline)),
            tooltip
        )
    }

    // MARK: - The Menu

    /// The same rows the sidebar fold and the draft view open — asserted by identity rather than
    /// by title, because the titles carry formatted times.
    func testTheChipOpensTheSharedCurfewMenu() throws {
        let fixture = try conversation(curfew: .until(deadline))
        let ids = rowIDs(of: fixture.controller.curfewChip)

        XCTAssertTrue(ids.contains(.endsAt), "\(ids)")
        XCTAssertTrue(ids.contains(.inherit), "\(ids)")
        XCTAssertTrue(ids.contains(.custom), "\(ids)")
        XCTAssertFalse(
            ids.contains(.lift),
            "Lift was offered on a curfew that has not arrived yet"
        )
        XCTAssertFalse(
            ids.contains(.atQuietHours),
            "a quiet-hours row was offered with no quiet hours configured"
        )
    }

    /// Lift is offered exactly while something is being held — it is the answer to a state, not a
    /// standing option, and on an armed curfew there is nothing yet to lift.
    func testLiftIsOfferedOnlyWhileTheSessionIsActuallyHeld() throws {
        let fixture = try conversation(curfew: .until(Date(timeIntervalSinceNow: -60)))
        XCTAssertTrue(rowIDs(of: fixture.controller.curfewChip).contains(.lift))
    }

    /// Choosing to follow the scope above **writes nil**, so the chat keeps following its
    /// checkout and Settings and a change there still reaches it — `chooseLimitRecovery`'s rule,
    /// and the reason the field is optional rather than a plain flag.
    func testFollowingTheScopeAboveClearsTheRecordRatherThanWritingAnAnswer() throws {
        let fixture = try conversation(curfew: .until(deadline))
        XCTAssertEqual(
            ProjectStore.shared.session(withID: fixture.sessionID)?.curfewRule,
            .until(deadline)
        )

        try item(.inherit, in: fixture.controller.curfewChip).onChoose?()

        XCTAssertNil(ProjectStore.shared.session(withID: fixture.sessionID)?.curfewRule)
        fixture.controller.refreshCurfewChip()
        XCTAssertTrue(fixture.controller.curfewChip.isHidden)
    }

    /// The other half of the same rule. An exemption is written **only** where a standing window
    /// would otherwise hold this chat — with quiet hours off there is nothing to be exempt from,
    /// and the menu does not even offer the row.
    ///
    /// The chip is also the standing window's own surface here: a chat that answered for nothing
    /// still resolves, because quiet hours reach every session that never said otherwise.
    func testAnExemptionIsWrittenOnlyWhereAStandingWindowWouldOtherwiseHold() throws {
        var preferences = CurfewPreferences.default
        preferences.quietHours = QuietHours(isEnabled: true)
        CurfewSettings.shared.preferences = preferences

        let fixture = try conversation(curfew: nil)
        XCTAssertFalse(
            fixture.controller.curfewChip.isHidden,
            "the standing quiet hours did not reach a chat that never answered for itself"
        )

        let ids = rowIDs(of: fixture.controller.curfewChip)
        XCTAssertTrue(ids.contains(.exempt), "\(ids)")
        XCTAssertTrue(ids.contains(.atQuietHours), "\(ids)")

        try item(.exempt, in: fixture.controller.curfewChip).onChoose?()

        XCTAssertEqual(
            ProjectStore.shared.session(withID: fixture.sessionID)?.curfewRule,
            .exempt
        )
        fixture.controller.refreshCurfewChip()
        XCTAssertTrue(fixture.controller.curfewChip.isHidden)
    }
}

// MARK: - The Ribbon, Drawn

/// The three curfew states the gallery carries, as pictures in both appearances.
///
/// The claim this strip rests on is a visual one — *a line the user drew is not the provider's
/// triangle* — and no assertion about a symbol name can review it. The stack is the same three
/// offers the gallery story shows, so what a reviewer sees here is what ships.
@MainActor
final class CurfewStripRenderTests: XCTestCase {

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

    /// Held, held after the ladder has run, and the honest one.
    private var lines: [String] {
        [
            "Curfew since 04:00 · wrap-up sent 03:50",
            "Curfew since 04:00 · wrap-up sent 03:50 · interrupted 04:05 ×2",
            "Curfew since 04:00 · Threading cannot tell whether this session is working, so it "
                + "only stops delivering messages."
        ]
    }

    func testRendersTheCurfewStripInBothAppearances() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let strips = lines.map { line -> LimitEscapeStripView in
                let strip = LimitEscapeStripView()
                strip.setOffer(.curfew(line: line))
                return strip
            }

            let column = NSStackView(views: strips)
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = Design.Spacing.medium
            column.translatesAutoresizingMaskIntoConstraints = false

            let host = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 170))
            host.wantsLayer = true
            host.appearance = appearance
            column.appearance = appearance
            host.addSubview(column)
            NSLayoutConstraint.activate(
                [
                    column.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    column.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    column.centerYAnchor.constraint(equalTo: host.centerYAnchor)
                ] + strips.map { $0.widthAnchor.constraint(equalTo: column.widthAnchor) }
            )

            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                // A `ThemedComponent` takes its ink from the sweep rather than from its
                // initializer; a fixture that skips this draws a correctly laid-out ribbon in no
                // colour at all.
                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()
                if let representation = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: representation)
                    data = representation.representation(using: .png, properties: [:])
                }
            }

            try XCTUnwrap(data, "the curfew strip drew nothing in \(suffix)")
                .write(to: directory.appendingPathComponent("curfew-strip-\(suffix).png"))
        }
    }
}

// MARK: - The Terminal Pane's Ribbon

@MainActor
final class TerminalPaneCurfewStripTests: HostedStoreTestCase {

    private var standingPreferences: CurfewPreferences!

    override func setUpWithError() throws {
        try super.setUpWithError()
        standingPreferences = CurfewSettings.shared.preferences
        var preferences = CurfewPreferences.default
        preferences.quietHours = QuietHours(isEnabled: false)
        CurfewSettings.shared.preferences = preferences
    }

    override func tearDownWithError() throws {
        CurfewSettings.shared.preferences = standingPreferences
        standingPreferences = nil
        try super.tearDownWithError()
    }

    /// A terminal pane over a real record. The strip is private to the controller, so it is found
    /// where the user finds it — in the pane.
    private func pane(
        curfew: CurfewRule?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (controller: AgentSessionViewController, strip: LimitEscapeStripView) {
        let store = ProjectStore.shared
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-pane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let project = try XCTUnwrap(store.addProject(folderURL: folder), file: file, line: line)
        let session = try XCTUnwrap(
            store.addSession(to: project.id, kind: .claude, title: "Curfew"),
            file: file,
            line: line
        )
        if let curfew {
            XCTAssertEqual(
                store.setCurfewRule(curfew, forSessionID: session.id),
                .applied,
                file: file,
                line: line
            )
        }

        let controller = AgentSessionViewController(agentSession: session)
        _ = controller.view
        let strip = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? LimitEscapeStripView }.first,
            "the terminal pane carries no limit ribbon",
            file: file,
            line: line
        )
        return (controller, strip)
    }

    /// The ribbon costs the terminal real rows, so it stands only for a curfew that is actually
    /// holding the session — never for one that is merely coming.
    func testTheRibbonStandsOnlyWhileTheCurfewIsHoldingTheSession() throws {
        let none = try pane(curfew: nil).strip
        XCTAssertTrue(none.isHidden)

        let armed = try pane(curfew: .until(Date(timeIntervalSinceNow: 3_600))).strip
        XCTAssertTrue(
            armed.isHidden,
            "an armed curfew took rows off the terminal hours before it does anything"
        )

        let held = try pane(curfew: .until(Date(timeIntervalSinceNow: -60))).strip
        XCTAssertFalse(held.isHidden)
    }

    /// **The honest clause, and this is where it lands.** A terminal session whose CLI does not
    /// read Escape as *stop* — or whose runtime reports no turns, which is every session with no
    /// PTY running — still gets the hold and never gets a keystroke, and the ribbon says so
    /// rather than implying a fence that is not there.
    func testATerminalSessionThreadingCannotReadSaysSoOnTheRibbon() throws {
        let fixture = try pane(curfew: .until(Date(timeIntervalSinceNow: -60)))
        let offer = try XCTUnwrap(fixture.strip.offer)

        XCTAssertEqual(offer.source, .curfew)
        let line = try XCTUnwrap(offer.curfewLine)
        XCTAssertTrue(
            line.contains(
                L10n.string(
                    "Threading cannot tell whether this session is working, so it only stops delivering messages."
                )
            ),
            line
        )
        XCTAssertEqual(fixture.strip.continueControl.title, L10n.string("Lift Curfew"))
        XCTAssertTrue(fixture.strip.dismissControl.isHidden)
    }

    /// A provider refusal outranks it: that is the one the user cannot answer, and naming their
    /// own bedtime over it would be the smaller fact on top of the larger one.
    func testAProviderRefusalOutranksTheCurfewOnTheSamePane() throws {
        let fixture = try pane(curfew: .until(Date(timeIntervalSinceNow: -60)))
        XCTAssertEqual(fixture.strip.offer?.source, .curfew)

        // The store the pane draws from, fed the way the terminal path feeds it.
        let sessionID = fixture.controller.sessionID
        LimitEscapeSuggestionStore.shared.record(
            LimitEscapeSuggestion(
                sessionID: sessionID,
                accountName: "Daniel Block",
                reading: "5h 12% · 7d 40%",
                resetHint: "9:40pm (Europe/Rome)",
                model: nil
            )
        )
        defer { LimitEscapeSuggestionStore.shared.clear(sessionID) }

        XCTAssertEqual(fixture.strip.offer?.source, .provider)
    }
}
