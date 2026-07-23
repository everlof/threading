import AppKit
import XCTest
@testable import Skalman

/// The shortcut model: how a chord is written, what counts as a legal one, and how an override
/// resolves over a default. All of it is pure, and none of it is visible in a screenshot.
final class KeyboardShortcutTests: XCTestCase {

    // MARK: - Display

    /// ⌃⌥⇧⌘ is the platform's fixed order. Any other order still names the same keys but reads
    /// as a different shortcut beside every other menu in the system.
    func testModifiersAreDrawnInPlatformOrder() {
        let shortcut = KeyboardShortcut(key: "i", modifiers: [.command, .shift, .option, .control])
        XCTAssertEqual(shortcut.displayString, "⌃⌥⇧⌘I")
    }

    func testCommonChordsRead() {
        XCTAssertEqual(KeyboardShortcut(key: "n", modifiers: .command).displayString, "⌘N")
        XCTAssertEqual(KeyboardShortcut(key: "r", modifiers: [.command, .shift]).displayString, "⇧⌘R")
        XCTAssertEqual(KeyboardShortcut(key: "`", modifiers: .control).displayString, "⌃`")
    }

    /// A space or an arrow has no glyph of its own; drawn raw they are blank cells.
    func testNamedKeysAreSpelledOut() {
        XCTAssertEqual(KeyboardShortcut(key: " ", modifiers: .command).displayString, "⌘Space")
        XCTAssertEqual(KeyboardShortcut(key: "\u{F700}", modifiers: .command).displayString, "⌘↑")
    }

    /// The event's flags also say *which* shift key was held. That is not part of the chord, and
    /// keeping it would make two identical-looking shortcuts compare unequal.
    func testDeviceDependentFlagsAreDiscarded() {
        let raw = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x0002)
        XCTAssertEqual(
            KeyboardShortcut(key: "n", modifiers: raw),
            KeyboardShortcut(key: "n", modifiers: .command)
        )
    }

    // MARK: - Validity

    /// A bare letter would fire while the user is typing, and typing is most of what this app is.
    func testAChordNeedsANonShiftModifier() {
        XCTAssertFalse(KeyboardShortcut(key: "n", modifiers: []).isValid)
        XCTAssertFalse(KeyboardShortcut(key: "n", modifiers: .shift).isValid)
        XCTAssertFalse(KeyboardShortcut(key: "", modifiers: .command).isValid)

        XCTAssertTrue(KeyboardShortcut(key: "n", modifiers: .command).isValid)
        XCTAssertTrue(KeyboardShortcut(key: "`", modifiers: .control).isValid)
        XCTAssertTrue(KeyboardShortcut(key: "n", modifiers: .option).isValid)
    }
}

// MARK: - Override Store

final class ShortcutOverrideStoreTests: XCTestCase {

    private var store: ShortcutOverrideStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SkalmanShortcutTests-\(UUID().uuidString)"
        store = ShortcutOverrideStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        store = nil
        super.tearDown()
    }

    private var newSession: AppCommand {
        AppCommands.command(id: AppCommands.ID.newSession)!
    }

    private var quit: AppCommand {
        AppCommands.command(id: "system.quit")!
    }

    func testUnsetCommandResolvesToItsDefault() {
        XCTAssertEqual(store.shortcut(for: newSession), newSession.defaultShortcut)
        XCTAssertFalse(store.isOverridden(newSession))
    }

    func testOverrideWins() {
        let chord = KeyboardShortcut(key: "k", modifiers: [.command, .option])
        store.setShortcut(chord, for: newSession)

        XCTAssertEqual(store.shortcut(for: newSession), chord)
        XCTAssertTrue(store.isOverridden(newSession))
    }

    /// Re-choosing the default is not an override. Storing it would freeze the command against a
    /// later change to that default, for a user who never actually expressed a preference.
    func testSettingTheDefaultBackDropsTheOverride() {
        store.setShortcut(KeyboardShortcut(key: "k", modifiers: .command), for: newSession)
        store.setShortcut(newSession.defaultShortcut, for: newSession)

        XCTAssertFalse(store.isOverridden(newSession))
        XCTAssertEqual(store.shortcut(for: newSession), newSession.defaultShortcut)
    }

    /// The case the whole `cleared` list exists for: without it, "no shortcut" is indistinguishable
    /// from "never touched", and the default would silently come back.
    func testClearingIsRememberedRatherThanRevertingToTheDefault() {
        store.setShortcut(nil, for: newSession)

        XCTAssertNil(store.shortcut(for: newSession))
        XCTAssertTrue(store.isOverridden(newSession))
    }

    func testResetRestoresTheDefault() {
        store.setShortcut(nil, for: newSession)
        store.reset(newSession)

        XCTAssertEqual(store.shortcut(for: newSession), newSession.defaultShortcut)
        XCTAssertFalse(store.hasAnyOverride)
    }

    /// A fixed command is listed but never rebindable — a user who took ⌘Q for something of ours
    /// could not quit.
    func testFixedCommandsRefuseOverrides() {
        store.setShortcut(KeyboardShortcut(key: "j", modifiers: .command), for: quit)

        XCTAssertEqual(store.shortcut(for: quit), quit.defaultShortcut)
        XCTAssertFalse(store.isOverridden(quit))
    }

    func testConflictFindsTheCommandAlreadyHoldingTheChord() throws {
        let taken = try XCTUnwrap(store.shortcut(for: quit))
        XCTAssertEqual(store.conflict(for: taken, excluding: newSession)?.id, quit.id)
    }

    func testNoConflictWithItself() throws {
        let own = try XCTUnwrap(store.shortcut(for: newSession))
        XCTAssertNil(store.conflict(for: own, excluding: newSession))
    }

    /// Bindings outlive the launch that set them.
    func testOverridesSurviveAReload() {
        let chord = KeyboardShortcut(key: "k", modifiers: [.command, .option])
        store.setShortcut(chord, for: newSession)

        let reloaded = ShortcutOverrideStore(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(reloaded.shortcut(for: newSession), chord)
    }
}

// MARK: - Command Table

final class AppCommandTests: XCTestCase {

    /// An id is what an override is stored under, so a duplicate would make two commands share
    /// one binding.
    func testCommandIDsAreUnique() {
        let ids = AppCommands.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "two commands share an id")
    }

    /// The table ships with no collisions. This is the check that fails when a new command is
    /// added on a chord something else already answers to.
    func testDefaultShortcutsDoNotCollide() {
        var seen: [KeyboardShortcut: String] = [:]

        for command in AppCommands.all {
            guard let shortcut = command.defaultShortcut else { continue }
            if let owner = seen[shortcut] {
                XCTFail("\(command.title) and \(owner) both default to \(shortcut.displayString)")
            }
            seen[shortcut] = command.title
        }
    }

    func testEveryDefaultShortcutIsItselfLegal() {
        for command in AppCommands.all {
            guard let shortcut = command.defaultShortcut else { continue }
            XCTAssertTrue(shortcut.isValid, "\(command.title) ships an unusable default")
        }
    }

    func testFixedCommandsAreNotEditable() {
        XCTAssertTrue(AppCommands.fixed.allSatisfy { !$0.isEditable })
        XCTAssertTrue(AppCommands.editable.allSatisfy(\.isEditable))
    }
}
