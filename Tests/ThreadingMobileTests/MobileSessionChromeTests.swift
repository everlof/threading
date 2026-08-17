import SwiftTerm
import UIKit
import XCTest
@testable import ThreadingMobile

final class MobileSessionChromeTests: XCTestCase {
    func testOwnerSeesWorkspaceInTheMenu() {
        XCTAssertTrue(MobileSessionChrome.canOpenWorkspace(
            canManageSessions: true,
            hasClient: true
        ))
    }

    func testWorkspaceIsAbsentWithoutAnAuthenticatedClient() {
        XCTAssertFalse(MobileSessionChrome.canOpenWorkspace(
            canManageSessions: true,
            hasClient: false
        ))
        XCTAssertFalse(MobileSessionChrome.canOpenWorkspace(
            canManageSessions: false,
            hasClient: true
        ))
    }

    func testPaletteBelongsToATerminalRatherThanANativeConversation() {
        XCTAssertTrue(MobileSessionChrome.canChooseTerminalTheme(
            canManageThemes: true,
            surface: .terminal,
            hasThemeCatalog: true
        ))
        XCTAssertFalse(MobileSessionChrome.canChooseTerminalTheme(
            canManageThemes: true,
            surface: .conversation,
            hasThemeCatalog: true
        ))
        XCTAssertFalse(MobileSessionChrome.canChooseTerminalTheme(
            canManageThemes: true,
            surface: .terminal,
            hasThemeCatalog: false
        ))
    }

    /// The palette used to be its own toolbar button, reachable by a share that may recolour a
    /// terminal without managing the session. Gathering it into the menu must not take it away.
    func testAShareThatMayOnlyThemeStillGetsTheMenu() {
        XCTAssertTrue(MobileSessionChrome.showsSessionMenu(
            canManageSessions: false,
            canChooseTerminalTheme: true
        ))
    }

    func testAViewOnlyShareGetsNoTrailingControlAtAll() {
        XCTAssertFalse(MobileSessionChrome.showsSessionMenu(
            canManageSessions: false,
            canChooseTerminalTheme: false
        ))
    }

    func testAFlickFromTheEdgeOpensTheWorkspaceAndAGrazeDoesNot() {
        XCTAssertTrue(ScreenEdgeSwipeGesture.isDeliberate(travel: CGPoint(x: -120, y: 8)))
        XCTAssertFalse(ScreenEdgeSwipeGesture.isDeliberate(travel: CGPoint(x: -6, y: 0)))
        // A near-vertical drag that happened to begin at the bezel is a scroll.
        XCTAssertFalse(ScreenEdgeSwipeGesture.isDeliberate(travel: CGPoint(x: -60, y: -200)))
    }

    /// SwiftTerm fits its own esc/ctrl/tab/arrow accessory over the keyboard, which stacked a
    /// second row of the same keys under this app's own `TerminalKeyBar`. Both halves are
    /// asserted: that SwiftTerm still installs one, and that the app still takes it away.
    @MainActor
    func testTheTerminalShowsOnlyThisAppsKeyBarOverTheKeyboard() {
        let view = RemoteTerminalView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )

        XCTAssertTrue(
            view.inputAccessoryView is TerminalAccessory,
            "SwiftTerm no longer installs its accessory; the removal below is now a no-op."
        )

        view.dropBuiltInKeyboardAccessory()

        XCTAssertNil(view.inputAccessoryView)
    }
}
