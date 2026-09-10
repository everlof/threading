import AppKit
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// The shortcut model: how a chord is written, what counts as a legal one, and how an override
/// resolves over a default. All of it is pure, and none of it is visible in a screenshot.
@MainActor
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

    func testAChordMatchesAnEventByKeyAndExactShortcutModifiers() throws {
        let shortcut = KeyboardShortcut(key: "n", modifiers: [.command, .shift])

        XCTAssertTrue(shortcut.matches(try keyEvent("N", modifiers: [.command, .shift])))
        XCTAssertFalse(shortcut.matches(try keyEvent("n", modifiers: .command)))
        XCTAssertFalse(shortcut.matches(try keyEvent("m", modifiers: [.command, .shift])))
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

    private func keyEvent(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ))
    }
}

// MARK: - Override Store

@MainActor
final class ShortcutOverrideStoreTests: XCTestCase {

    private var store: ShortcutOverrideStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ThreadingShortcutTests-\(UUID().uuidString)"
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

@MainActor
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

    func testJumpToReviewFileShipsAsAnEditableSessionCommandJ() throws {
        let command = try XCTUnwrap(
            AppCommands.all.first { $0.id == AppCommands.ID.jumpToReviewFile }
        )
        XCTAssertEqual(command.defaultShortcut, KeyboardShortcut(key: "j", modifiers: .command))
        XCTAssertEqual(command.scope, .session)
        XCTAssertTrue(command.isEditable)
    }

    func testRenameSessionShipsAsAnEditableCurrentSessionCommandR() throws {
        let command = try XCTUnwrap(AppCommands.command(id: AppCommands.ID.renameSession))
        XCTAssertEqual(command.title, "Rename Session…")
        XCTAssertEqual(command.defaultShortcut, KeyboardShortcut(key: "r", modifiers: .command))
        XCTAssertEqual(command.scope, .session)
        XCTAssertTrue(command.isEditable)
    }

    func testAttachmentsShipsAsAnEditableSessionCommand() throws {
        let command = try XCTUnwrap(AppCommands.command(id: AppCommands.ID.attachments))

        XCTAssertEqual(command.title, "Attachments")
        XCTAssertEqual(command.scope, .session)
        XCTAssertNil(command.defaultShortcut)
        XCTAssertTrue(command.isEditable)

        let descriptor = command.hostDescriptor(
            shortcut: nil,
            availability: .available
        )
        XCTAssertEqual(
            HostCommandSearch.results(in: [descriptor], matching: "Attachment").map(\.id),
            [AppCommands.ID.attachments]
        )
    }

    func testManagerCommandsDeclareTheirScopeAndRisk() throws {
        let newManager = try XCTUnwrap(AppCommands.command(id: AppCommands.ID.newManager))
        XCTAssertEqual(newManager.scope, .project)
        XCTAssertEqual(newManager.risk, .ordinary)

        for id in [AppCommands.ID.makeManager, AppCommands.ID.revokeManager] {
            let command = try XCTUnwrap(AppCommands.command(id: id))
            XCTAssertEqual(command.scope, .session)
            XCTAssertEqual(command.risk, .destructive)
            XCTAssertTrue(command.isEditable)
        }
    }
}

// MARK: - Dynamic Registry

@MainActor
final class CommandRegistryTests: XCTestCase {
    func testExtensionCommandsJoinTheSameNamespaceAsBuiltIns() throws {
        let builtIn = AppCommand(
            id: "app.refresh",
            group: .view,
            title: "Refresh",
            defaultShortcut: .init(key: "r", modifiers: .command),
            isEditable: true
        )
        let registry = CommandRegistry(builtInCommands: [builtIn])
        registry.replaceExtensionCommands(
            extensionIdentifier: "com.example.ci",
            extensionName: "CI",
            commands: [
                .init(
                    id: "open-build",
                    title: "Open Build",
                    scope: .project,
                    risk: .destructive,
                    defaultShortcut: .init(
                        key: "b",
                        modifiers: [.option, .command]
                    )
                )
            ]
        )

        let command = try XCTUnwrap(
            registry.command(id: "extension.com.example.ci.open-build")
        )
        XCTAssertEqual(command.group, .extensions)
        XCTAssertEqual(command.scope, .project)
        XCTAssertEqual(command.risk, .destructive)
        XCTAssertEqual(command.origin.extensionName, "CI")
        XCTAssertEqual(command.defaultShortcut?.displayString, "⌥⌘B")
    }

    @MainActor
    func testDestructiveExtensionCommandUsesHostWordingAndRequiresApproval() throws {
        let destructive = AppCommand(
            id: "extension.com.example.ci.reset",
            group: .extensions,
            title: "Reset status",
            detail: "Extension-authored detail must not become confirmation copy.",
            defaultShortcut: nil,
            isEditable: true,
            origin: .extensionCommand(
                identifier: "com.example.ci",
                name: "CI Status",
                localID: "reset"
            ),
            risk: .destructive
        )

        var presentations: [ExtensionCommandConfirmationPresentation] = []
        var invocations = 0
        var decision: (@MainActor (Bool) -> Void)?
        ExtensionCommandExecutionGate.execute(
            destructive,
            present: { presentation, completion in
                presentations.append(presentation)
                decision = completion
            },
            invoke: { invocations += 1 }
        )

        XCTAssertEqual(
            presentations,
            [
                .init(command: destructive)
            ]
        )
        XCTAssertEqual(presentations.first?.title, "Run “Reset status”?")
        XCTAssertEqual(
            presentations.first?.message,
            "“CI Status” marked this command as destructive. "
                + "It may make changes that cannot be undone."
        )
        XCTAssertFalse(
            presentations.first?.message.contains("Extension-authored detail") ?? true
        )
        XCTAssertEqual(presentations.first?.acceptTitle, "Run Destructive Command")
        XCTAssertEqual(presentations.first?.cancelTitle, "Cancel")
        XCTAssertEqual(invocations, 0)

        decision?(false)
        XCTAssertEqual(invocations, 0)

        ExtensionCommandExecutionGate.execute(
            destructive,
            present: { _, completion in completion(true) },
            invoke: { invocations += 1 }
        )
        XCTAssertEqual(invocations, 1)

        let ordinary = AppCommand(
            id: "extension.com.example.ci.refresh",
            group: .extensions,
            title: "Refresh",
            defaultShortcut: nil,
            isEditable: true,
            origin: .extensionCommand(
                identifier: "com.example.ci",
                name: "CI Status",
                localID: "refresh"
            )
        )
        var ordinaryPresented = false
        ExtensionCommandExecutionGate.execute(
            ordinary,
            present: { _, _ in ordinaryPresented = true },
            invoke: { invocations += 1 }
        )
        XCTAssertFalse(ordinaryPresented)
        XCTAssertEqual(invocations, 2)
    }

    func testCollidingExtensionDefaultIsUnboundUntilTheOwnerMoves() throws {
        let suiteName = "ThreadingCommandRegistryTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let builtIn = AppCommand(
            id: "app.refresh",
            group: .view,
            title: "Refresh",
            defaultShortcut: .init(key: "r", modifiers: .command),
            isEditable: true
        )
        let registry = CommandRegistry(builtInCommands: [builtIn])
        registry.replaceExtensionCommands(
            extensionIdentifier: "com.example.ci",
            extensionName: "CI",
            commands: [
                .init(
                    id: "refresh",
                    title: "Refresh CI",
                    defaultShortcut: .init(
                        key: "r",
                        modifiers: [.command]
                    )
                )
            ]
        )
        let store = ShortcutOverrideStore(
            defaults: UserDefaults(suiteName: suiteName)!,
            registry: registry
        )
        let extensionCommand = try XCTUnwrap(
            registry.command(id: "extension.com.example.ci.refresh")
        )

        XCTAssertNil(store.shortcut(for: extensionCommand))
        XCTAssertEqual(store.defaultConflict(for: extensionCommand)?.id, builtIn.id)

        store.setShortcut(nil, for: builtIn)
        XCTAssertEqual(
            store.shortcut(for: extensionCommand),
            extensionCommand.defaultShortcut
        )
    }

    func testRowPlacementsNeverOwnTheShortcutButKeepItsCarrier() throws {
        let registry = CommandRegistry(builtInCommands: [])
        registry.replaceExtensionCommands(
            extensionIdentifier: "com.example.rows",
            extensionName: "Rows",
            commands: [
                .init(
                    id: "both",
                    title: "Both",
                    menuPlacements: [.sessionRow, .extensions]
                ),
                .init(
                    id: "row-only",
                    title: "Row only",
                    scope: .project,
                    menuPlacements: [.projectRow]
                )
            ]
        )

        // The first *menu-bar* placement owns the visible shortcut; a row placement declared
        // ahead of it changes nothing, because row menus never display key equivalents.
        let both = try XCTUnwrap(registry.command(id: "extension.com.example.rows.both"))
        XCTAssertEqual(ExtensionCommandMenuLayout.canonicalPlacement(for: both), .extensions)
        XCTAssertFalse(ExtensionCommandMenuLayout.needsHiddenShortcutCarrier(both))

        // A row-only command still dispatches a user-assigned shortcut through the hidden
        // menu-bar carrier, exactly like a command with no placements at all.
        let rowOnly = try XCTUnwrap(
            registry.command(id: "extension.com.example.rows.row-only")
        )
        XCTAssertNil(ExtensionCommandMenuLayout.canonicalPlacement(for: rowOnly))
        XCTAssertTrue(ExtensionCommandMenuLayout.needsHiddenShortcutCarrier(rowOnly))

        // The row-context filter: a project row answers for project and application scope,
        // never for session scope — omission, not a disabled item.
        let projectContext = ExtensionCommandContext(projectID: "p-1")
        XCTAssertTrue(ExtensionCommandMenuLayout.context(projectContext, satisfies: .application))
        XCTAssertTrue(ExtensionCommandMenuLayout.context(projectContext, satisfies: .project))
        XCTAssertFalse(ExtensionCommandMenuLayout.context(projectContext, satisfies: .session))
    }

    func testExtensionMenuLayoutUsesStablePlacementsAndCanonicalShortcutOwner() throws {
        let registry = CommandRegistry(builtInCommands: [])
        registry.replaceExtensionCommands(
            extensionIdentifier: "com.example.zebra",
            extensionName: "Zebra",
            commands: [
                .init(
                    id: "shared",
                    title: "Shared",
                    menuPlacements: [.project, .view]
                ),
                .init(
                    id: "shortcut-only",
                    title: "Shortcut only",
                    menuPlacements: []
                )
            ]
        )
        registry.replaceExtensionCommands(
            extensionIdentifier: "com.example.alpha",
            extensionName: "Alpha",
            commands: [
                .init(
                    id: "refresh",
                    title: "Refresh",
                    menuPlacements: [.project]
                )
            ]
        )

        let projectGroups = ExtensionCommandMenuLayout.groups(
            commands: registry.extensionCommands,
            placement: .project
        )
        XCTAssertEqual(projectGroups.map(\.extensionName), ["Alpha", "Zebra"])
        XCTAssertEqual(projectGroups[1].commands.map(\.title), ["Shared"])

        let shared = try XCTUnwrap(
            registry.command(id: "extension.com.example.zebra.shared")
        )
        XCTAssertEqual(
            ExtensionCommandMenuLayout.canonicalPlacement(for: shared),
            .project
        )
        XCTAssertEqual(
            ExtensionCommandMenuLayout.groups(
                commands: registry.extensionCommands,
                placement: .view
            ).flatMap(\.commands).map(\.id),
            [shared.id]
        )

        let shortcutOnly = try XCTUnwrap(
            registry.command(id: "extension.com.example.zebra.shortcut-only")
        )
        XCTAssertNil(
            ExtensionCommandMenuLayout.canonicalPlacement(for: shortcutOnly)
        )
        XCTAssertTrue(
            ExtensionMenuPlacement.allCases.allSatisfy { placement in
                ExtensionCommandMenuLayout.groups(
                    commands: registry.extensionCommands,
                    placement: placement
                ).flatMap(\.commands).allSatisfy { $0.id != shortcutOnly.id }
            }
        )
    }
}
