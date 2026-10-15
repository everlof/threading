import AppKit
import XCTest
@testable import Threading

/// ⌘X, ⌘C, ⌘V and ⌘A have to reach a text field inside a modal prompt — Rename Session, a
/// branch name, a comment — not only the window behind it.
///
/// They did not. The Edit items were routed through the app delegate's
/// `performHostMenuCommand(_:)`, and during `NSApp.runModal(for:)` AppKit disables a menu item
/// whose target lies outside the modal window. The delegate always does, so every chord beeped at
/// a field holding a perfectly good field editor while the same chords kept working in the main
/// window. A test outside a modal session cannot see that, which is why this one runs one.
@MainActor
final class EditMenuModalRoutingTests: XCTestCase {

    private enum Fixture {
        static let text = "ANDROIDNETWORK"
        /// Borderless and parked off every display, so the modal session orders a real window
        /// front without anything appearing on screen and the class stays in `fast`.
        static let parkedFrame = NSRect(x: -10_000, y: -10_000, width: 320, height: 80)
        static let fieldFrame = NSRect(x: 10, y: 10, width: 240, height: 24)
        /// Long enough for a loaded machine, short enough that a stuck session fails promptly
        /// instead of hanging the suite.
        static let modalDeadline: TimeInterval = 5
    }

    // MARK: - Helpers

    private func installShippingMenu() throws -> NSMenu {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let previousMenu = NSApp.mainMenu
        addTeardownBlock { @MainActor in NSApp.mainMenu = previousMenu }
        delegate.setupMenuBar()
        return try XCTUnwrap(NSApp.mainMenu)
    }

    private func editItem(_ commandID: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(
            menu.items.lazy.compactMap(\.submenu).flatMap(\.items).first {
                ($0.representedObject as? String) == commandID
            },
            "the Edit menu has no item for \(commandID)"
        )
    }

    private func keyEquivalentEvent(for item: NSMenuItem, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: item.keyEquivalentModifierMask,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: item.keyEquivalent,
            charactersIgnoringModifiers: item.keyEquivalent,
            isARepeat: false,
            keyCode: 0
        ))
    }

    // MARK: - Tests

    /// The structural half: each clipboard and selection item is an AppKit action with no
    /// target, so the responder chain of whichever window is key — modal or not — answers it.
    func testEditItemsSendAppKitActionsToTheResponderChain() throws {
        let menu = try installShippingMenu()
        let expected: [(String, Selector)] = [
            ("system.undo", AppKitEditActions.undo),
            ("system.cut", AppKitEditActions.cut),
            ("system.copy", AppKitEditActions.copy),
            ("system.paste", AppKitEditActions.paste),
            ("system.selectAll", AppKitEditActions.selectAll)
        ]
        for (commandID, action) in expected {
            let item = try editItem(commandID, in: menu)
            XCTAssertNil(item.target, "\(commandID) must resolve through the responder chain")
            XCTAssertEqual(item.action, action, "\(commandID) is routed through the host")
        }
    }

    /// The behavioural half, in the container the bug lived in: a real modal session whose key
    /// window holds a themed field, driven by the shipping menu's own ⌘A key equivalent.
    func testSelectAllReachesAFieldInsideAModalSession() throws {
        let menu = try installShippingMenu()
        let panel = NSPanel(
            contentRect: Fixture.parkedFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let field = ThemedTextField(frame: Fixture.fieldFrame)
        field.stringValue = Fixture.text
        panel.contentView?.addSubview(field)

        modal = ModalProbe(
            menu: menu,
            selectAll: try editItem("system.selectAll", in: menu),
            panel: panel,
            field: field
        )
        defer {
            NSObject.cancelPreviousPerformRequests(withTarget: self)
            panel.orderOut(nil)
            modal = nil
        }

        // Both are queued for the modal run-loop mode only, so neither can fire before the
        // session starts; the deadline ends a session the probe somehow never reached.
        perform(#selector(probeModalSession), with: nil, afterDelay: 0, inModes: [.modalPanel])
        perform(
            #selector(endModalSession),
            with: nil,
            afterDelay: Fixture.modalDeadline,
            inModes: [.modalPanel]
        )
        NSApp.runModal(for: panel)

        let probe = try XCTUnwrap(modal)
        XCTAssertEqual(probe.itemEnabled, true, "Select All is disabled inside a modal session")
        XCTAssertEqual(
            probe.selectedRange,
            NSRange(location: 0, length: (Fixture.text as NSString).length),
            "⌘A did not reach the modal field's editor"
        )
    }

    // MARK: - Modal Probe

    /// What the probe needs inside the session and what it found there. Held on the test case
    /// because the run-loop callbacks below are selectors, not closures.
    private final class ModalProbe {
        let menu: NSMenu
        let selectAll: NSMenuItem
        let panel: NSPanel
        let field: ThemedTextField
        var itemEnabled: Bool?
        var selectedRange: NSRange?

        init(menu: NSMenu, selectAll: NSMenuItem, panel: NSPanel, field: ThemedTextField) {
            self.menu = menu
            self.selectAll = selectAll
            self.panel = panel
            self.field = field
        }
    }

    private var modal: ModalProbe?

    @objc private func probeModalSession() {
        defer { endModalSession() }
        guard let modal,
              modal.panel.makeFirstResponder(modal.field),
              let editor = modal.field.currentEditor(),
              let event = try? keyEquivalentEvent(for: modal.selectAll, in: modal.panel)
        else { return }
        editor.selectedRange = NSRange(location: 0, length: 0)

        modal.menu.update()
        modal.itemEnabled = modal.selectAll.isEnabled
        _ = modal.menu.performKeyEquivalent(with: event)
        modal.selectedRange = editor.selectedRange
    }

    @objc private func endModalSession() {
        NSApp.stopModal()
    }
}
