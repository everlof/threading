import XCTest
@testable import Threading

/// The tab-traversal rows in the command table: listed, spelled as every tabbed mac app spells
/// them, and colliding with nothing — the table is the single place a chord is decided, so the
/// table is where a collision would land.
final class TabCyclingCommandTests: XCTestCase {

    func testTraversalCommandsAreListedAndEditable() throws {
        let previous = try XCTUnwrap(AppCommands.command(id: AppCommands.ID.previousTab))
        let next = try XCTUnwrap(AppCommands.command(id: AppCommands.ID.nextTab))

        XCTAssertTrue(previous.isEditable)
        XCTAssertTrue(next.isEditable)
        XCTAssertEqual(
            previous.defaultShortcut,
            KeyboardShortcut(key: "[", modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            next.defaultShortcut,
            KeyboardShortcut(key: "]", modifiers: [.command, .shift])
        )
    }

    func testTabByNumberCommandsCoverTheDigitsAndStayFixed() throws {
        for number in AppCommands.ID.selectTabNumbers {
            let command = try XCTUnwrap(
                AppCommands.command(id: AppCommands.ID.selectTab(number)),
                "tab.select.\(number) missing from the table"
            )
            XCTAssertFalse(
                command.isEditable,
                "⌘\(number) is listed so the page can answer for it, not rebind it"
            )
            XCTAssertEqual(
                command.defaultShortcut,
                KeyboardShortcut(key: "\(number)", modifiers: .command)
            )
        }
    }

    /// One chord, one command — across the whole table, because a duplicate default is a
    /// collision every user gets before any override exists.
    func testDefaultChordsAreUniqueAcrossTheTable() {
        var owners: [KeyboardShortcut: String] = [:]
        for command in AppCommands.all {
            guard let shortcut = command.defaultShortcut else { continue }
            if let owner = owners[shortcut] {
                XCTFail("\(command.id) and \(owner) both default to \(shortcut.displayString)")
            }
            owners[shortcut] = command.id
        }
    }
}
