import AppKit
import XCTest
@testable import Threading

/// The Sounds submenu offered on a session row, a project row and a terminal row — the
/// one-click tier.
///
/// It is the only surface this level of the model has, and a contextual menu is not reachable
/// from a script here, so without this the wiring between an item and the entry it writes would
/// be checked by clicking it and listening. Two things are worth pinning hardest: the *Inherit*
/// parenthetical, which is the part that will silently go wrong, and the writer's nil-where-it
/// -matches rule, which is what keeps a chat *following* its project instead of freezing a copy
/// of its answer.
@MainActor
final class SoundMenuTests: XCTestCase {

    // MARK: - Fixtures

    /// The app scope's keys, snapshotted and put back. The bundle is hosted in the app, so
    /// `AppSettings.shared` is the developer's own defaults domain — the same treatment
    /// `SilenceGateTests` gives the same keys, and for the same reason.
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
    }

    private func soundSubmenu(of entry: ThemedMenuEntry) throws -> [ThemedMenuEntry] {
        guard case .item(let item) = entry else { throw SoundMenuTestError.expectedItem }
        XCTAssertEqual(item.title, "Sounds")
        return try XCTUnwrap(item.submenu, "the Sounds item has no submenu")
    }

    private func items(in entries: [ThemedMenuEntry]) -> [ThemedMenuItem] {
        entries.compactMap(\.item)
    }

    /// Paints the app scope with one sound, so every voiced event agrees and the inherited
    /// answer is a value a parenthetical can name.
    private func paintTheAppScope(_ choice: SoundChoice) {
        AppSettings.shared.terminalBellSound = choice
        AppSettings.shared.attentionAlertSound = choice
    }

    // MARK: - Shape

    func testTheMenuOffersInheritThenTheSettingsPickersOwnList() throws {
        let sidebar = ProjectSidebarViewController()
        let submenu = try soundSubmenu(of: sidebar.sessionSoundEntry(for: SessionID()))
        let titles = items(in: submenu).map(\.title)

        XCTAssertTrue(titles.first?.hasPrefix("Inherit") == true)
        XCTAssertEqual(Array(titles.dropFirst().prefix(2)), ["Off", "macOS Alert Sound"])
        // The list of sounds ends at *Add a Sound…*; the door to the per-event sheet sits after
        // it, last, because it is the tier this menu is not.
        XCTAssertEqual(Array(titles.suffix(2)), ["Add a Sound…", "Customize…"])
        for sound in SoundPickerMenu.groups().flatMap({ $0 }) {
            XCTAssertTrue(
                titles.contains(sound.displayName),
                "\(sound.displayName) is missing from the menu"
            )
        }
    }

    /// All three row kinds carry it, and each item targets its own scope rather than reading
    /// whichever row was last clicked — the submenu is built from several places.
    func testEveryRowKindOffersItAndItsItemsCarryTheirOwnTarget() throws {
        let sidebar = ProjectSidebarViewController()
        let sessionID = SessionID()
        let projectID = ProjectID()
        let terminalID = TerminalID()

        let session = try XCTUnwrap(
            items(in: try soundSubmenu(of: sidebar.sessionSoundEntry(for: sessionID)))
                .compactMap { $0.representedValue as? SoundMenuChoice }.first
        )
        let project = try XCTUnwrap(
            items(in: try soundSubmenu(of: sidebar.projectSoundEntry(for: projectID)))
                .compactMap { $0.representedValue as? SoundMenuChoice }.first
        )
        let terminal = try XCTUnwrap(
            items(in: try soundSubmenu(of: sidebar.terminalSoundEntry(for: terminalID)))
                .compactMap { $0.representedValue as? SoundMenuChoice }.first
        )

        guard case .session(let id) = session.target else {
            return XCTFail("the session menu did not target a session")
        }
        guard case .project(let pid) = project.target else {
            return XCTFail("the project menu did not target a project")
        }
        guard case .terminal(let tid) = terminal.target else {
            return XCTFail("the terminal menu did not target a terminal")
        }
        XCTAssertEqual(id, sessionID)
        XCTAssertEqual(pid, projectID)
        XCTAssertEqual(tid, terminalID)
    }

    /// Clearing is the nil choice, which is why the handler needs no sentinel to tell "inherit"
    /// apart from a sound called something.
    func testInheritCarriesNoChoice() throws {
        let sidebar = ProjectSidebarViewController()
        let submenu = try soundSubmenu(of: sidebar.sessionSoundEntry(for: SessionID()))

        let inherit = try XCTUnwrap(items(in: submenu).first?.representedValue as? SoundMenuChoice)
        XCTAssertNil(inherit.choice)
    }

    // MARK: - The Inherited Answer

    /// *Inherit* names what it inherits — otherwise it is the one choice in the list whose
    /// result the user cannot see before picking it.
    func testInheritNamesTheUniformInheritedSound() throws {
        paintTheAppScope(.named("Purr.aiff"))
        let builder = SoundMenuBuilder()

        let submenu = try soundSubmenu(of: builder.projectSoundEntry(for: ProjectID()))
        XCTAssertEqual(items(in: submenu).first?.title, "Inherit (Purr)")

        paintTheAppScope(.silent)
        let silenced = try soundSubmenu(of: builder.projectSoundEntry(for: ProjectID()))
        XCTAssertEqual(items(in: silenced).first?.title, "Inherit (Off)")
    }

    /// Right after migration the app scope usually holds a bell sound and a different
    /// notification tone, so *mixed* is the common inherited state and the item reads plain.
    func testInheritReadsPlainWhenTheAppsTwoSoundsDiffer() throws {
        AppSettings.shared.terminalBellSound = .named("Glass.aiff")
        AppSettings.shared.attentionAlertSound = .named("Submarine.aiff")

        let submenu = try soundSubmenu(of: SoundMenuBuilder().projectSoundEntry(for: ProjectID()))
        XCTAssertEqual(items(in: submenu).first?.title, "Inherit")
    }

    /// The three events that have never sounded take no part in the agreement. With one sound
    /// app-wide they are still silent, and the parenthetical still names the sound.
    func testTheSilentEventsDoNotMakeTheInheritedAnswerMixed() throws {
        paintTheAppScope(.named("Purr.aiff"))
        AppSettings.shared.setSoundChoice(nil, for: .alertUnread)

        let submenu = try soundSubmenu(of: SoundMenuBuilder().projectSoundEntry(for: ProjectID()))
        XCTAssertEqual(items(in: submenu).first?.title, "Inherit (Purr)")
        XCTAssertEqual(
            SoundResolution.resolve(.alertUnread, through: [SoundResolution.appScope()]),
            .silent,
            "and they really are still silent"
        )
    }

    // MARK: - The Checkmark

    /// The checkmark marks the base coat: *Inherit* while the scope stores nothing, the stored
    /// sound once it does. Exactly one item carries it either way.
    func testTheCheckmarkMovesFromInheritToTheStoredSound() throws {
        paintTheAppScope(.named("Purr.aiff"))
        let fixture = try makeFixture()
        let builder = SoundMenuBuilder()

        var checked = items(in: try soundSubmenu(of: builder.sessionSoundEntry(for: fixture.session.id)))
            .filter(\.isSelected)
        XCTAssertEqual(checked.count, 1)
        XCTAssertTrue(checked.first?.title.hasPrefix("Inherit") == true)

        XCTAssertEqual(
            ProjectStore.shared.setSoundOverrides(
                ["all": SoundChoice.named("Glass.aiff").storedValue],
                forSessionID: fixture.session.id
            ),
            .applied
        )

        checked = items(in: try soundSubmenu(of: builder.sessionSoundEntry(for: fixture.session.id)))
            .filter(\.isSelected)
        XCTAssertEqual(checked.count, 1)
        XCTAssertEqual(checked.first?.title, "Glass")
    }

    /// An event-level exception is not the base coat and never moves the checkmark.
    func testAnEventEntryDoesNotMoveTheCheckmark() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(
            ProjectStore.shared.setSoundOverrides(
                ["bell.launch": SoundChoice.named("Tink.aiff").storedValue],
                forSessionID: fixture.session.id
            ),
            .applied
        )

        let submenu = try soundSubmenu(
            of: SoundMenuBuilder().sessionSoundEntry(for: fixture.session.id)
        )
        let checked = items(in: submenu).filter(\.isSelected)
        XCTAssertEqual(checked.count, 1)
        XCTAssertTrue(checked.first?.title.hasPrefix("Inherit") == true)
    }

    // MARK: - The Writer

    /// A chat picking the sound its project already carries stores **nothing**, so a later
    /// change to the project still reaches it. This is the mute writer's rule, and the reason
    /// the field is optional rather than a table of values copied into every record.
    func testAChatPickingItsProjectsSoundStoresNothing() throws {
        let fixture = try makeFixture()
        let store = ProjectStore.shared
        XCTAssertEqual(
            store.setSoundOverrides(["all": SoundChoice.named("Purr.aiff").storedValue],
                                    forProjectID: fixture.project.id),
            .applied
        )

        let builder = SoundMenuBuilder()
        builder.apply(SoundMenuChoice(
            target: .session(fixture.session.id),
            choice: .named("Purr.aiff")
        ))

        XCTAssertNil(store.session(withID: fixture.session.id)?.soundOverrides)

        // …and the chat still follows: repainting the project reaches it.
        XCTAssertEqual(
            store.setSoundOverrides(["all": SoundChoice.silent.storedValue],
                                    forProjectID: fixture.project.id),
            .applied
        )
        XCTAssertEqual(
            SoundResolution.resolve(
                .bellAgentAsking,
                through: SoundResolution.scopes(for: .session(fixture.session.id))
            ),
            .silent
        )
    }

    /// A chat picking something its project does not carry stores it, and clearing it again is
    /// what *Inherit* does.
    func testAChatPickingSomethingElseStoresItAndInheritClearsIt() throws {
        let fixture = try makeFixture()
        let store = ProjectStore.shared
        XCTAssertEqual(
            store.setSoundOverrides(["all": SoundChoice.named("Purr.aiff").storedValue],
                                    forProjectID: fixture.project.id),
            .applied
        )

        let builder = SoundMenuBuilder()
        builder.apply(SoundMenuChoice(target: .session(fixture.session.id), choice: .silent))
        XCTAssertEqual(
            store.session(withID: fixture.session.id)?.soundOverrides,
            ["all": SoundChoice.silent.storedValue]
        )

        builder.apply(SoundMenuChoice(target: .session(fixture.session.id), choice: nil))
        XCTAssertNil(store.session(withID: fixture.session.id)?.soundOverrides)
    }

    /// The same rule at the **project** level, which is where the mute writer has no precedent
    /// to copy: a project picking what the app already says stores nothing.
    func testAProjectPickingTheAppsSoundStoresNothing() throws {
        paintTheAppScope(.named("Purr.aiff"))
        let fixture = try makeFixture()
        let builder = SoundMenuBuilder()

        builder.apply(SoundMenuChoice(
            target: .project(fixture.project.id),
            choice: .named("Purr.aiff")
        ))
        XCTAssertNil(ProjectStore.shared.project(withID: fixture.project.id)?.soundOverrides)

        builder.apply(SoundMenuChoice(target: .project(fixture.project.id), choice: .silent))
        XCTAssertEqual(
            ProjectStore.shared.project(withID: fixture.project.id)?.soundOverrides,
            ["all": SoundChoice.silent.storedValue]
        )
    }

    /// And at the terminal level, against the project that persists it.
    func testATerminalPickingItsProjectsSoundStoresNothing() throws {
        let fixture = try makeFixture()
        let store = ProjectStore.shared
        XCTAssertEqual(
            store.setSoundOverrides(["all": SoundChoice.named("Glass.aiff").storedValue],
                                    forProjectID: fixture.project.id),
            .applied
        )

        let builder = SoundMenuBuilder()
        builder.apply(SoundMenuChoice(
            target: .terminal(fixture.terminal.id),
            choice: .named("Glass.aiff")
        ))
        XCTAssertNil(store.terminal(withID: fixture.terminal.id)?.soundOverrides)

        builder.apply(SoundMenuChoice(target: .terminal(fixture.terminal.id), choice: .system))
        XCTAssertEqual(
            store.terminal(withID: fixture.terminal.id)?.soundOverrides,
            ["all": SoundChoice.system.storedValue]
        )
    }

    /// The menu writes one level and reads the rest back out untouched — including a key this
    /// build has never heard of, which is the whole of the round-trip constraint.
    func testWritingTheBaseCoatKeepsEveryOtherEntry() throws {
        let fixture = try makeFixture()
        let store = ProjectStore.shared
        XCTAssertEqual(
            store.setSoundOverrides(
                ["bell.launch": "file:Tink.aiff", "alert.somethingLater": "file:Hero.aiff"],
                forSessionID: fixture.session.id
            ),
            .applied
        )

        SoundMenuBuilder().apply(SoundMenuChoice(
            target: .session(fixture.session.id),
            choice: .silent
        ))

        XCTAssertEqual(
            store.session(withID: fixture.session.id)?.soundOverrides,
            [
                "bell.launch": "file:Tink.aiff",
                "alert.somethingLater": "file:Hero.aiff",
                "all": "silent"
            ]
        )
    }

    /// End to end through the themed menu action: pressing the row reaches the store.
    func testChoosingAnItemWritesTheRecord() throws {
        let fixture = try makeFixture()
        let builder = SoundMenuBuilder()
        let submenu = try soundSubmenu(of: builder.sessionSoundEntry(for: fixture.session.id))

        let off = try XCTUnwrap(items(in: submenu).first { $0.title == "Off" })
        try XCTUnwrap(off.onChoose)()

        XCTAssertEqual(
            ProjectStore.shared.session(withID: fixture.session.id)?.soundOverrides,
            ["all": SoundChoice.silent.storedValue]
        )
    }

    /// Mute and Sounds are different verbs and neither writes the other's storage.
    func testSoundsAndMuteAreOrthogonal() throws {
        let fixture = try makeFixture()
        let store = ProjectStore.shared

        XCTAssertEqual(store.setNotificationsMuted(true, forSessionID: fixture.session.id), .applied)
        SoundMenuBuilder().apply(SoundMenuChoice(
            target: .session(fixture.session.id),
            choice: .silent
        ))

        let session = try XCTUnwrap(store.session(withID: fixture.session.id))
        XCTAssertEqual(session.notificationsMuted, true, "Sounds did not touch the mute")
        XCTAssertEqual(session.soundOverrides, ["all": SoundChoice.silent.storedValue])

        XCTAssertEqual(store.setNotificationsMuted(nil, forSessionID: fixture.session.id), .applied)
        XCTAssertEqual(
            store.session(withID: fixture.session.id)?.soundOverrides,
            ["all": SoundChoice.silent.storedValue],
            "and unmuting did not touch the sound"
        )
    }

    // MARK: - Private Methods

    private struct Fixture {
        let project: Project
        let session: AgentSession
        let terminal: ProjectTerminal
    }

    private func makeFixture() throws -> Fixture {
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(
            folderURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("sound-menu-\(UUID().uuidString)", isDirectory: true)
        ))
        addTeardownBlock { MainActor.assumeIsolated { _ = store.removeProject(id: project.id) } }

        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let terminal = try XCTUnwrap(store.addTerminal(to: project.id))
        return Fixture(project: project, session: session, terminal: terminal)
    }
}

private enum SoundMenuTestError: Error {
    case expectedItem
}
