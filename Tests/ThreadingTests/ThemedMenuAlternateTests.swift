import AppKit
import XCTest
@testable import Threading

/// The act a menu row offers instead while a modifier is held — Option's "Remove Project Without
/// Asking" under "Remove Project".
///
/// One sentence carries all of it: **the name a person reads is the action they get.** A row that
/// drew the alternate and ran its own action, or the reverse, would look right to anyone who only
/// looked at it, so every path that can choose — the key, the pointer's row, VoiceOver — is held
/// to what the row is showing at that moment.
@MainActor
final class ThemedMenuAlternateTests: XCTestCase {

    private enum Title {
        static let row = "Remove Project"
        static let alternate = "Remove Project Without Asking"
        static let other = "Rename Project…"
    }

    /// What ran, in order — "row" for the authored action, "alternate" for the held one.
    private var ran: [String] = []

    private func alternateRow() -> ThemedMenuItem {
        var item = ThemedMenuItem(title: Title.row) { [unowned self] in ran.append("row") }
        item.alternate = ThemedMenuAlternate(title: Title.alternate) { [unowned self] in
            ran.append("alternate")
        }
        return item
    }

    // MARK: - The Chord

    /// Exactly Option. A larger chord is a different alternate, and Caps Lock or Fn riding along
    /// in the flags was never meant by anyone.
    func testTheAlternateAnswersItsExactChordOnly() {
        let alternate = ThemedMenuAlternate(title: Title.alternate) {}

        XCTAssertTrue(alternate.isTriggered(by: .option))
        XCTAssertTrue(alternate.isTriggered(by: [.option, .capsLock, .function, .numericPad]))
        XCTAssertFalse(alternate.isTriggered(by: []))
        XCTAssertFalse(alternate.isTriggered(by: [.option, .shift]), "⌥⇧ also showed ⌥'s alternate")
        XCTAssertFalse(alternate.isTriggered(by: .command))
    }

    /// An alternate with no chord would replace its row for good — a different title, not an
    /// alternate — so it is never shown.
    func testAnAlternateWithNoChordIsNeverShown() {
        let alternate = ThemedMenuAlternate(title: Title.alternate, modifiers: []) {}
        XCTAssertFalse(alternate.isTriggered(by: []))
        XCTAssertFalse(alternate.isTriggered(by: .option))
    }

    // MARK: - The Resolved Row

    func testHoldingTheChordSwapsTheNameAndTheActionTogether() throws {
        var item = alternateRow()
        item.shortcut = KeyboardShortcut(key: "r", modifiers: .command)
        item.image = ThemedMenuIcon.symbol("minus.circle")

        let shown = item.resolved(holding: .option)
        XCTAssertEqual(shown.title, Title.alternate)
        XCTAssertNil(shown.resolvedShortcut, "the row's own chord was printed beside the alternate")
        XCTAssertNotNil(shown.image, "an alternate with no mark of its own dropped the row's")
        try XCTUnwrap(shown.onChoose)()
        XCTAssertEqual(ran, ["alternate"])

        let released = item.resolved(holding: [])
        XCTAssertEqual(released.title, Title.row)
        try XCTUnwrap(released.onChoose)()
        XCTAssertEqual(ran, ["alternate", "row"])
    }

    /// A parent row turning into an action under its own open panel would strand that panel.
    func testASubmenuRowKeepsItsSubmenuWhateverIsHeld() {
        var parent = ThemedMenuItem(title: "Theme", submenu: [.item(ThemedMenuItem(title: "Ink"))])
        parent.alternate = ThemedMenuAlternate(title: "Reset Theme") {}

        XCTAssertFalse(parent.showsAlternate(holding: .option))
        XCTAssertEqual(parent.resolved(holding: .option).title, "Theme")
        XCTAssertNotNil(parent.resolved(holding: .option).submenu)
    }

    /// Pressing the key must not resize the panel under the pointer, so the panel is measured
    /// for the longer of the two names before either is shown.
    func testThePanelIsMeasuredForTheAlternateBeforeItIsShown() {
        let plain = ThemedMenuMetrics.width(
            for: [.item(ThemedMenuItem(title: Title.row))],
            minimum: 0
        )
        let withAlternate = ThemedMenuMetrics.width(for: [.item(alternateRow())], minimum: 0)

        XCTAssertGreaterThan(withAlternate, plain)
        XCTAssertEqual(
            withAlternate,
            ThemedMenuMetrics.width(
                for: [.item(ThemedMenuItem(title: Title.alternate))],
                minimum: 0
            ),
            "the panel was not sized for the alternate's own name"
        )
    }

    // MARK: - The Presented Menu

    private func presentedMenu() throws -> (window: NSWindow, root: NSView, token: AnyObject) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        let source = ThemedButton(frame: NSRect(x: 24, y: 180, width: 140, height: 26))
        root.addSubview(source)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root

        let token = try XCTUnwrap(ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: [
                    .item(alternateRow()),
                    .item(ThemedMenuItem(title: Title.other) { [unowned self] in
                        ran.append("other")
                    })
                ],
                minimumWidth: source.bounds.width
            ),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: {}
        ))
        return (window, root, token)
    }

    private func rowTitles(in root: NSView) -> [String] {
        descendants(in: root)
            .filter { $0.accessibilityRole() == .menuItem }
            .compactMap { $0.accessibilityTitle() }
    }

    private func flagsChanged(_ flags: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 58
        ))
    }

    private func returnKey(_ flags: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
    }

    /// The shipping route end to end: the window's modifier change reaches the open menu through
    /// its own monitor, the row says the other act, and Return — still held — does that act.
    func testHoldingOptionRenamesTheRowAndReturnChoosesTheAlternate() throws {
        let (window, root, token) = try presentedMenu()
        defer {
            ThemedMenuPresenter.dismiss(token)
            window.close()
        }
        XCTAssertEqual(rowTitles(in: root), [Title.row, Title.other])

        NSApp.sendEvent(try flagsChanged(.option, in: window))
        XCTAssertEqual(
            rowTitles(in: root),
            [Title.alternate, Title.other],
            "holding Option left the row naming its own act"
        )

        NSApp.sendEvent(try returnKey(.option, in: window))
        XCTAssertEqual(ran, ["alternate"])
        XCTAssertFalse(ThemedMenuPresenter.isMenuOpen(in: window))
    }

    /// Letting go puts the row back, and what it then chooses is its own act again.
    func testReleasingOptionRestoresTheRowAndItsAction() throws {
        let (window, root, token) = try presentedMenu()
        defer {
            ThemedMenuPresenter.dismiss(token)
            window.close()
        }

        NSApp.sendEvent(try flagsChanged(.option, in: window))
        NSApp.sendEvent(try flagsChanged([], in: window))
        XCTAssertEqual(rowTitles(in: root), [Title.row, Title.other])

        NSApp.sendEvent(try returnKey([], in: window))
        XCTAssertEqual(ran, ["row"])
    }

    /// VoiceOver's keys are already chorded with modifiers, so the alternate is offered as an
    /// action on the row — and taking it runs the alternate whatever is held.
    func testVoiceOverIsOfferedTheAlternateAsAnAction() throws {
        let (window, root, token) = try presentedMenu()
        defer {
            ThemedMenuPresenter.dismiss(token)
            window.close()
        }
        let row = try XCTUnwrap(descendants(in: root).first {
            $0.accessibilityRole() == .menuItem && $0.accessibilityTitle() == Title.row
        })
        // Asked before the action runs: choosing closes the menu and retires its rows.
        let plain = try XCTUnwrap(descendants(in: root).first {
            $0.accessibilityRole() == .menuItem && $0.accessibilityTitle() == Title.other
        })
        XCTAssertNil(plain.accessibilityCustomActions(), "a row with no alternate offered one")
        let action = try XCTUnwrap(
            row.accessibilityCustomActions()?.first { $0.name == Title.alternate },
            "the row offers VoiceOver no route to its alternate"
        )

        XCTAssertTrue(try XCTUnwrap(action.handler)())
        XCTAssertEqual(ran, ["alternate"])
    }

    // MARK: - Helpers

    private func descendants(in view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(in:))
    }
}
