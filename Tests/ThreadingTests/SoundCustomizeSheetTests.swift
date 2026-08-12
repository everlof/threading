import AppKit
import XCTest
@testable import Threading

/// The Customize sheet — the per-event tier, one sheet at every scope.
///
/// Most of this file is about **one function**. `SoundResolution.inherited` decides what every
/// *Inherit (…)* parenthetical says and, through the writer, whether a row stores anything at
/// all; it is also the part of this feature that will go wrong without anything looking wrong,
/// because a parenthetical naming the sound one level too far out is still a plausible sentence.
/// So it is pinned here from five directions: under a base coat, at the kind level, on an event
/// nothing has ever voiced, at the app scope where the word changes, and across a scope holding
/// two levels at once.
@MainActor
final class SoundCustomizeSheetTests: XCTestCase {

    // MARK: - Fixtures

    /// The app scope's keys, snapshotted and put back. The bundle is hosted in the app, so
    /// `AppSettings.shared` is the developer's own defaults domain — the same treatment
    /// `SoundMenuTests` gives the same keys, and for the same reason.
    private enum Key {
        static let all = ["silencesAllSounds", "terminalBellSound", "attentionAlertSound",
                          "soundEventChoices"]
    }

    override func setUp() {
        super.setUp()
        let previous = Key.all.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        addTeardownBlock {
            for (key, value) in previous {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        AppSettings.shared.silencesAllSounds = false
        AppSettings.shared.resetSoundChoices()
    }

    private struct Fixture {
        let project: Project
        let session: AgentSession
        let terminal: ProjectTerminal
    }

    private func makeFixture() throws -> Fixture {
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(
            folderURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("sound-sheet-\(UUID().uuidString)", isDirectory: true)
        ))
        addTeardownBlock { MainActor.assumeIsolated { _ = store.removeProject(id: project.id) } }

        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let terminal = try XCTUnwrap(store.addTerminal(to: project.id))
        return Fixture(project: project, session: session, terminal: terminal)
    }

    /// Loads the view, which is what builds the eleven pickers.
    private func sheet(for scope: SoundScope) -> SoundCustomizeViewController {
        let controller = SoundCustomizeViewController(scope: scope)
        _ = controller.view
        return controller
    }

    // MARK: - The Parenthetical

    /// An event row over a scope whose base coat is Submarine reads *Inherit (Submarine)* — the
    /// row is asking what it would resolve to with only *its own* entry gone, not with the whole
    /// scope gone.
    func testAnEventRowInheritsTheBaseCoatOfItsOwnScope() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(
            ProjectStore.shared.setSoundOverrides(
                ["all": SoundChoice.named("Submarine.aiff").storedValue],
                forProjectID: fixture.project.id
            ),
            .applied
        )

        let sheet = sheet(for: .project(fixture.project.id))
        XCTAssertEqual(
            sheet.selectedTitle(for: .event(.bellAgentAsking)),
            "Inherit (Submarine)"
        )
    }

    /// A kind row inherits past itself: its own entry is what the row *is*, so the base coat
    /// beneath it is what it would read without one.
    func testAKindRowInheritsPastItsOwnEntry() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(
            ProjectStore.shared.setSoundOverrides(
                [
                    "all": SoundChoice.named("Submarine.aiff").storedValue,
                    "bell": SoundChoice.named("Glass.aiff").storedValue
                ],
                forProjectID: fixture.project.id
            ),
            .applied
        )

        let sheet = sheet(for: .project(fixture.project.id))
        XCTAssertEqual(sheet.selectedTitle(for: .kind(.bell)), "Glass", "its own entry is shown")
        XCTAssertEqual(
            SoundScope.project(fixture.project.id).inherited(.kind(.bell)),
            .named("Submarine.aiff"),
            "and what it would read without one is the base coat under it"
        )
    }

    /// The opt-in rule surfaces itself: an event nothing has ever voiced reads *Inherit
    /// (Silent)*, and a base coat over the scope does not change that.
    func testAnOptInRowWithNothingAboveReadsSilent() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(
            ProjectStore.shared.setSoundOverrides(
                ["all": SoundChoice.named("Submarine.aiff").storedValue],
                forProjectID: fixture.project.id
            ),
            .applied
        )

        let sheet = sheet(for: .session(fixture.session.id))
        XCTAssertEqual(sheet.selectedTitle(for: .event(.alertUnread)), "Inherit (Silent)")
        XCTAssertEqual(
            sheet.selectedTitle(for: .event(.alertBlocked)),
            "Inherit (Submarine)",
            "while a voiced event does follow the base coat"
        )
    }

    /// Two levels at one scope: the alert rows follow this scope's own kind entry, the bell rows
    /// fall past it to the project's base coat.
    func testMixedLevelsAtOneScopeResolveIndependently() throws {
        let fixture = try makeFixture()
        let store = ProjectStore.shared
        XCTAssertEqual(
            store.setSoundOverrides(
                ["all": SoundChoice.named("Submarine.aiff").storedValue],
                forProjectID: fixture.project.id
            ),
            .applied
        )
        XCTAssertEqual(
            store.setSoundOverrides(
                ["alert": SoundChoice.named("Glass.aiff").storedValue],
                forSessionID: fixture.session.id
            ),
            .applied
        )

        let sheet = sheet(for: .session(fixture.session.id))
        XCTAssertEqual(sheet.selectedTitle(for: .event(.alertBlocked)), "Inherit (Glass)")
        XCTAssertEqual(sheet.selectedTitle(for: .event(.bellLaunch)), "Inherit (Submarine)")
    }

    // MARK: - The App Scope

    /// The outermost word is *Default* there, which is what the theme scope already calls the
    /// same position — and the two kind rows have no outermost item at all, because they are the
    /// General page's own pickers and there is nothing beyond them.
    func testTheAppScopeSaysDefaultAndItsKindRowsOfferNoOutermostItem() {
        AppSettings.shared.terminalBellSound = .named("Glass.aiff")

        let sheet = sheet(for: .app)
        XCTAssertEqual(sheet.selectedTitle(for: .event(.bellLaunch)), "Default (Glass)")
        XCTAssertEqual(
            sheet.selectedTitle(for: .kind(.bell)),
            "Glass",
            "the kind row shows the stored sound rather than a Default item above it"
        )
    }

    /// One storage, two surfaces: the sheet's kind row *is* the preference the General page's
    /// pop-up writes, so the two cannot disagree.
    func testTheAppScopesKindRowWritesThePagesOwnPreference() {
        let sheet = sheet(for: .app)

        sheet.choose(.silent, for: .kind(.bell))
        XCTAssertEqual(AppSettings.shared.terminalBellSound, .silent)

        sheet.choose(.silent, for: .kind(.alert))
        XCTAssertEqual(AppSettings.shared.attentionAlertSound, .silent)
    }

    // MARK: - The Writer

    /// A row set to exactly what it inherits stores **nothing**, so a later change above still
    /// reaches it. The mute writer's rule, at the event level.
    func testARowSetToItsInheritedAnswerStoresNothing() throws {
        let fixture = try makeFixture()
        let store = ProjectStore.shared
        XCTAssertEqual(
            store.setSoundOverrides(
                ["all": SoundChoice.system.storedValue],
                forProjectID: fixture.project.id
            ),
            .applied
        )

        let sheet = sheet(for: .session(fixture.session.id))
        sheet.choose(.system, for: .event(.bellLaunch))
        XCTAssertNil(store.session(withID: fixture.session.id)?.soundOverrides)

        // …and it really still follows.
        XCTAssertEqual(
            store.setSoundOverrides(
                ["all": SoundChoice.silent.storedValue],
                forProjectID: fixture.project.id
            ),
            .applied
        )
        XCTAssertEqual(
            SoundResolution.resolve(
                .bellLaunch,
                through: SoundResolution.scopes(for: .session(fixture.session.id))
            ),
            .silent
        )
    }

    /// A row set to something else stores that one key — and every other key in the map, known
    /// or not, comes back out untouched. The whole of the round-trip constraint, on the surface
    /// that writes one level at a time.
    func testWritingOneRowKeepsEveryOtherEntryIncludingUnknownOnes() throws {
        let fixture = try makeFixture()
        let store = ProjectStore.shared
        XCTAssertEqual(
            store.setSoundOverrides(
                [
                    "all": SoundChoice.silent.storedValue,
                    "alert.somethingLater": "file:Hero.aiff"
                ],
                forSessionID: fixture.session.id
            ),
            .applied
        )

        let sheet = sheet(for: .session(fixture.session.id))
        sheet.choose(.system, for: .event(.bellLaunch))

        XCTAssertEqual(
            store.session(withID: fixture.session.id)?.soundOverrides,
            [
                "all": SoundChoice.silent.storedValue,
                "alert.somethingLater": "file:Hero.aiff",
                "bell.launch": SoundChoice.system.storedValue
            ]
        )
    }

    /// Choosing *Inherit* clears the row by the same expression that stores nothing for a
    /// matching value — nil equals nil.
    func testChoosingInheritClearsTheRow() throws {
        let fixture = try makeFixture()
        let sheet = sheet(for: .session(fixture.session.id))

        sheet.choose(.silent, for: .event(.bellLaunch))
        XCTAssertEqual(
            ProjectStore.shared.session(withID: fixture.session.id)?.soundOverrides,
            ["bell.launch": SoundChoice.silent.storedValue]
        )

        sheet.choose(nil, for: .event(.bellLaunch))
        XCTAssertNil(ProjectStore.shared.session(withID: fixture.session.id)?.soundOverrides)
    }

    // MARK: - Reset

    /// *Reset All* leaves the record without the field at all — a scope with nothing left to say
    /// must be indistinguishable from one that never said anything — and the sheet stays open
    /// showing the result.
    func testResetAllLeavesTheRecordWithoutTheField() throws {
        let fixture = try makeFixture()
        let store = ProjectStore.shared
        XCTAssertEqual(
            store.setSoundOverrides(
                [
                    "all": SoundChoice.named("Glass.aiff").storedValue,
                    "bell.launch": SoundChoice.silent.storedValue,
                    "alert.somethingLater": "file:Hero.aiff"
                ],
                forSessionID: fixture.session.id
            ),
            .applied
        )

        let sheet = sheet(for: .session(fixture.session.id))
        sheet.resetAll()

        XCTAssertNil(store.session(withID: fixture.session.id)?.soundOverrides)
        XCTAssertEqual(
            sheet.selectedTitle(for: .event(.bellLaunch)),
            "Inherit (macOS Alert Sound)",
            "and the sheet is showing the result rather than the state it was reset from"
        )
    }

    /// At the app scope there is no record to drop, so the three keys go instead — both pickers
    /// and the per-event map.
    func testResetAllAtTheAppScopeClearsBothPickersAndTheEventMap() {
        AppSettings.shared.terminalBellSound = .named("Glass.aiff")
        AppSettings.shared.attentionAlertSound = .silent
        AppSettings.shared.setSoundChoice(.named("Purr.aiff"), for: .alertUnread)

        let sheet = sheet(for: .app)
        sheet.resetAll()

        XCTAssertEqual(AppSettings.shared.terminalBellSound, TerminalBellDefaults.sound)
        XCTAssertEqual(AppSettings.shared.attentionAlertSound, AttentionAlertDefaults.sound)
        XCTAssertTrue(AppSettings.shared.soundEventChoices.isEmpty)
    }

    // MARK: - The Door From the Submenu

    /// The count on *Customize…* is the only indicator that event-level exceptions exist, since
    /// they never move the submenu's checkmark.
    func testTheSubmenuNamesHowManyEventsAreCustomized() throws {
        let fixture = try makeFixture()
        let builder = SoundMenuBuilder()

        XCTAssertEqual(try customizeTitle(in: builder.sessionSoundEntry(for: fixture.session.id)),
                       "Customize…")

        XCTAssertEqual(
            ProjectStore.shared.setSoundOverrides(
                [
                    "all": SoundChoice.silent.storedValue,
                    "bell": SoundChoice.silent.storedValue,
                    "bell.launch": SoundChoice.silent.storedValue,
                    "bell.agentVisible": SoundChoice.silent.storedValue,
                    "alert.blocked": SoundChoice.silent.storedValue
                ],
                forSessionID: fixture.session.id
            ),
            .applied
        )

        XCTAssertEqual(
            try customizeTitle(in: builder.sessionSoundEntry(for: fixture.session.id)),
            "Customize (3 Events)…",
            "the kind and base-coat entries are what the checkmark reports, not exceptions"
        )
    }

    /// A standalone terminal has no cause to scope, so its submenu offers no door to the sheet.
    func testATerminalRowOffersNoCustomizeItem() throws {
        let fixture = try makeFixture()
        let entry = SoundMenuBuilder().terminalSoundEntry(for: fixture.terminal.id)
        let titles = try submenu(of: entry).compactMap(\.item).map(\.title)
        XCTAssertFalse(titles.contains { $0.hasPrefix("Customize") })
        XCTAssertEqual(titles.last, "Add a Sound…")
    }

    /// The item is a door and nothing else: opening it must not clear the exceptions it counts.
    func testTheCustomizeItemOpensTheSheetWithoutClearingAnything() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(
            ProjectStore.shared.setSoundOverrides(
                ["bell.launch": SoundChoice.silent.storedValue],
                forSessionID: fixture.session.id
            ),
            .applied
        )

        var opened: SoundScope?
        let builder = SoundMenuBuilder()
        builder.onCustomize = { opened = $0 }

        let entry = builder.sessionSoundEntry(for: fixture.session.id)
        let item = try XCTUnwrap(
            submenu(of: entry).compactMap(\.item).first { $0.title.hasPrefix("Customize") }
        )
        try XCTUnwrap(item.onChoose)()

        XCTAssertEqual(opened, .session(fixture.session.id))
        XCTAssertEqual(
            ProjectStore.shared.session(withID: fixture.session.id)?.soundOverrides,
            ["bell.launch": SoundChoice.silent.storedValue]
        )
    }

    // MARK: - Private Methods

    private func submenu(of entry: ThemedMenuEntry) throws -> [ThemedMenuEntry] {
        let item = try XCTUnwrap(entry.item, "the Sounds entry is not an item")
        return try XCTUnwrap(item.submenu, "the Sounds item has no submenu")
    }

    private func customizeTitle(in entry: ThemedMenuEntry) throws -> String {
        let titles = try submenu(of: entry).compactMap(\.item).map(\.title)
        return try XCTUnwrap(
            titles.first { $0.hasPrefix("Customize") },
            "the submenu offers no Customize item"
        )
    }
}
