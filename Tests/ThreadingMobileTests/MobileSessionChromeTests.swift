import SwiftTerm
import SwiftUI
import ThreadingRemoteKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ThreadingMobile

final class MobileSessionChromeTests: XCTestCase {
    func testRenamedCatalogueTitleReplacesTheStaleLiveDetailTitle() {
        XCTAssertEqual(
            MobileSessionChrome.navigationTitle(
                catalogTitle: "Renamed session",
                liveTitle: "Original session"
            ),
            "Renamed session"
        )
    }

    func testLiveTitleBootstrapsChromeWhenTheCatalogueHasNoTitleYet() {
        XCTAssertEqual(
            MobileSessionChrome.navigationTitle(
                catalogTitle: "",
                liveTitle: "Connecting session"
            ),
            "Connecting session"
        )
    }

    // MARK: - One name, wherever it is drawn

    /// The list draws the catalogue's name and the screen it opens drew the socket's caption, so
    /// the same chat answered to two names: "Licensing strategy" in the list, "\u{2733} Claude
    /// Code" once it was open. A caption is the mirrored surface talking about itself — the Mac
    /// strips its decoration, ignores the ones that name the product or the working directory,
    /// and applies the user's choice about agent titles before a row is named, and none of that
    /// has happened to the string on the wire.
    func testTheCatalogueNamesTheChatEvenWhileTheMirroredSurfaceCallsItSomethingElse() {
        let catalogue = catalogue(
            named: "Licensing strategy",
            forSessionID: Fixture.sessionID
        )

        XCTAssertEqual(
            MobileSessionChrome.navigationTitle(
                for: Fixture.session(titled: "Claude Code"),
                in: catalogue,
                liveTitle: "\u{2733} Claude Code"
            ),
            "Licensing strategy"
        )
    }

    /// The summary a screen was opened with is a photograph of one row; a rename lands in the
    /// catalogue. Reading the opened copy is how the list and the screen disagree even when
    /// both read a catalogue title.
    func testARenameReachesAScreenThatWasOpenedBeforeIt() {
        XCTAssertEqual(
            MobileSessionChrome.navigationTitle(
                for: Fixture.session(titled: "Untitled"),
                in: catalogue(named: "Ship the iPhone client", forSessionID: Fixture.sessionID),
                liveTitle: nil
            ),
            "Ship the iPhone client"
        )
    }

    /// The archive list opens the same screen, so its rows are looked up too.
    func testAnArchivedRowIsFoundInTheCatalogueAsWell() {
        let archived = RemoteMeDTO(
            serverProtocol: RemoteProtocolInfo(),
            share: Fixture.share,
            sessions: [],
            archivedSessions: [Fixture.session(titled: "Finished migration")]
        )

        XCTAssertEqual(
            MobileSessionChrome.navigationTitle(
                for: Fixture.session(titled: "stale"),
                in: archived,
                liveTitle: "\u{2733} claude"
            ),
            "Finished migration"
        )
    }

    /// Nothing to read yet — a first launch, or a row the Mac no longer lists — falls back to
    /// the summary the screen was opened with rather than to the caption.
    func testAnAbsentCatalogueFallsBackToTheSummaryTheScreenWasOpenedWith() {
        XCTAssertEqual(
            MobileSessionChrome.navigationTitle(
                for: Fixture.session(titled: "Licensing strategy"),
                in: nil,
                liveTitle: "\u{2733} Claude Code"
            ),
            "Licensing strategy"
        )
        XCTAssertEqual(
            MobileSessionChrome.currentSession(
                Fixture.session(titled: "Licensing strategy"),
                in: catalogue(named: "Someone else", forSessionID: "another-session")
            ).title,
            "Licensing strategy"
        )
    }

    private enum Fixture {
        static let sessionID = "5de80220-2172-4fbe-8ed7-a707572fc922"

        static let share = RemoteMeDTO.Share(
            label: "preview",
            scope: .all,
            capability: .interact,
            expiresAt: nil
        )

        static func session(titled title: String) -> RemoteSessionSummaryDTO {
            RemoteSessionSummaryDTO(
                id: sessionID,
                title: title,
                agentKind: "claude",
                surface: .conversation,
                state: .idle,
                projectName: "AnotherTerminal"
            )
        }
    }

    private func catalogue(named title: String, forSessionID id: String) -> RemoteMeDTO {
        RemoteMeDTO(
            serverProtocol: RemoteProtocolInfo(),
            share: Fixture.share,
            sessions: [
                RemoteSessionSummaryDTO(
                    id: id,
                    title: title,
                    agentKind: "claude",
                    surface: .conversation,
                    state: .idle,
                    projectName: "AnotherTerminal"
                ),
            ]
        )
    }

    /// The rule above existed and the screen still drew the caption, because nothing on a
    /// session screen draws SwiftUI's `navigationTitle`: a conversation installs its own
    /// `titleView` and a terminal supplies a principal toolbar item, and both read the socket
    /// directly. So this asks the shipping controller, inside the navigation controller it
    /// ships in, what its title view actually says.
    @MainActor
    func testTheConversationScreensOwnTitleViewSaysWhatTheListSaid() throws {
        let model = RemoteAppModel()
        model.startDemo()
        let row = try XCTUnwrap(model.me?.sessions.first(where: { $0.surface == .conversation }))

        // Opened from a row that has since been renamed, mirroring a surface that calls itself
        // something else again — the two ways the screen and the list used to disagree.
        let connection = RemoteSessionConnection(
            session: RemoteSessionSummaryDTO(
                id: row.id,
                title: "Claude Code",
                agentKind: row.agentKind,
                surface: row.surface,
                state: row.state,
                projectName: row.projectName
            ),
            client: RemoteClient(
                link: try XCTUnwrap(RemoteConnectionLink(string: "https://demo.invalid/#preview"))
            )
        )
        let controller = RemoteConversationViewController(
            connection: connection,
            model: model,
            continuity: MobileSessionContinuityStore(),
            notifications: RemoteNotificationManager(),
            inheritedTheme: RemoteThemePalette(nil)
        )

        let window = hostedWindow(rootViewController: UINavigationController(
            rootViewController: controller
        ))
        defer { window.isHidden = true }

        let titleView = try XCTUnwrap(
            controller.navigationItem.titleView,
            "the conversation screen installed no title view of its own"
        )
        let label = try XCTUnwrap(
            first(MobileMorphingTitleLabel.self, in: titleView),
            "no morphing title in the conversation screen's title view"
        )

        XCTAssertEqual(label.stringValue, row.title)
    }

    /// The terminal half of the same question, asked of the principal toolbar item the shipping
    /// screen supplies.
    @MainActor
    func testTheTerminalScreensToolbarTitleSaysWhatTheListSaid() throws {
        let model = RemoteAppModel()
        model.startDemo()
        let row = try XCTUnwrap(model.me?.sessions.first(where: { $0.surface == .terminal }))

        let connection = RemoteSessionConnection(
            session: RemoteSessionSummaryDTO(
                id: row.id,
                title: "\u{2733} Claude Code",
                agentKind: row.agentKind,
                surface: row.surface,
                state: row.state,
                projectName: row.projectName
            ),
            client: RemoteClient(
                link: try XCTUnwrap(RemoteConnectionLink(string: "https://demo.invalid/#terminal"))
            )
        )

        let screen = NavigationStack {
            TerminalRemoteView(connection: connection)
                .navigationBarTitleDisplayMode(.inline)
        }
            .environmentObject(model)
            .environmentObject(MobileSessionContinuityStore())
            .environmentObject(MobileTerminalKeyboardStore())
            .environmentObject(RemoteNotificationManager())

        let window = hostedWindow(rootViewController: UIHostingController(rootView: screen))
        defer { window.isHidden = true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()

        let bar = try XCTUnwrap(
            first(UINavigationBar.self, in: window),
            "no navigation bar in the hosted terminal screen"
        )
        let label = try XCTUnwrap(
            first(MobileMorphingTitleLabel.self, in: bar),
            "no morphing title in the terminal screen's navigation bar"
        )

        XCTAssertEqual(label.stringValue, row.title)
    }

    @MainActor
    private func hostedWindow(rootViewController: UIViewController) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
        return window
    }

    private func first<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let found = view as? T { return found }
        for child in view.subviews {
            if let found = first(type, in: child) { return found }
        }
        return nil
    }

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

    // MARK: - The dashboard row's trailing swipe

    /// `.swipeActions` is a `List` modifier, and the dashboard's rows are on a `ThemedRowGroup`
    /// plate inside a `LazyVStack`. SwiftUI ignores it there without a warning, so archive by
    /// swipe was in the source and inert for everybody who tried it. These assert the rules the
    /// replacement follows, which is the half a picture cannot check.

    /// The whole gesture turns on this one question, asked before the pan begins: a sideways pan
    /// is the row's, anything else is the list's. Declining is what lets the scroll view start —
    /// a SwiftUI `DragGesture` recognises in every direction and stops the dashboard scrolling
    /// wherever a drag happens to begin on a row.
    func testASidewaysPanIsTheRowsAndAVerticalOneIsTheLists() {
        XCTAssertTrue(MobileRowSwipe.isSwipeDirection(velocity: CGPoint(x: -420, y: 60)))
        XCTAssertFalse(MobileRowSwipe.isSwipeDirection(velocity: CGPoint(x: -60, y: -900)))
        // A drag at exactly 45 degrees belongs to the list: scrolling is the commoner intent,
        // and the one whose loss is felt.
        XCTAssertFalse(MobileRowSwipe.isSwipeDirection(velocity: CGPoint(x: -300, y: 300)))
    }

    /// A throw is read a fifth of a second ahead, so a flick can open a row the finger stopped
    /// short of.
    func testAThrowIsReadAShortWayAhead() {
        XCTAssertEqual(
            MobileRowSwipe.projectedTranslation(-30, velocity: -400),
            -110,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MobileRowSwipe.projectedTranslation(-60, velocity: 0),
            -60,
            accuracy: 0.001
        )
    }

    func testAClosedRowDoesNotFollowAFingerTowardsTheTrailingEdge() {
        XCTAssertEqual(
            MobileRowSwipe.offset(
                translation: 120,
                resting: 0,
                rowWidth: 340,
                allowsFullSwipe: true
            ),
            0
        )
    }

    /// A row that cannot be swiped through still follows the finger past the button, because a
    /// row that stops dead reads as broken rather than as refusing.
    func testARowWithNoFullSwipeResistsPastTheButtonInsteadOfStopping() {
        let offset = MobileRowSwipe.offset(
            translation: -212,
            resting: 0,
            rowWidth: 340,
            allowsFullSwipe: false
        )
        XCTAssertGreaterThan(-offset, MobileRowSwipe.actionWidth)
        XCTAssertLessThan(-offset, 140)
    }

    func testARowThatAllowsAFullSwipeFollowsTheFingerToItsOwnWidth() {
        XCTAssertEqual(
            MobileRowSwipe.offset(
                translation: -1_000,
                resting: 0,
                rowWidth: 340,
                allowsFullSwipe: true
            ),
            -340
        )
    }

    func testLettingGoShortOfTheButtonSnapsShutAndPastItRestsOpen() {
        XCTAssertEqual(
            MobileRowSwipe.release(
                offset: -20,
                projectedOffset: -22,
                rowWidth: 340,
                allowsFullSwipe: true
            ),
            .closed
        )
        XCTAssertEqual(
            MobileRowSwipe.release(
                offset: -70,
                projectedOffset: -80,
                rowWidth: 340,
                allowsFullSwipe: true
            ),
            .open
        )
    }

    /// A flick opens the row. It does not archive a chat the finger never dragged that far:
    /// only travel that actually happened can perform the action.
    func testAFlickOpensTheRowButNeverArchivesThroughIt() {
        XCTAssertEqual(
            MobileRowSwipe.release(
                offset: -30,
                projectedOffset: -900,
                rowWidth: 340,
                allowsFullSwipe: true
            ),
            .open
        )
    }

    func testDraggingPastMostOfTheRowPerformsTheActionOnRelease() {
        XCTAssertEqual(
            MobileRowSwipe.release(
                offset: -260,
                projectedOffset: -300,
                rowWidth: 340,
                allowsFullSwipe: true
            ),
            .performed
        )
    }

    /// Restore is not destructive, so the row rests open and asks for the tap however far it is
    /// dragged.
    func testARowWithNoFullSwipeOnlyEverOpens() {
        XCTAssertEqual(
            MobileRowSwipe.release(
                offset: -400,
                projectedOffset: -400,
                rowWidth: 340,
                allowsFullSwipe: false
            ),
            .open
        )
    }

    /// `rowWidth` is zero until the row has been laid out once. A threshold taken from that
    /// would be zero too, and the first twelve points of any sideways drag would archive a chat.
    func testAnUnmeasuredRowCannotBeSwipedThrough() {
        XCTAssertFalse(
            MobileRowSwipe.isArmed(offset: -30, rowWidth: 0, allowsFullSwipe: true)
        )
        XCTAssertEqual(
            MobileRowSwipe.release(
                offset: -30,
                projectedOffset: -30,
                rowWidth: 0,
                allowsFullSwipe: true
            ),
            .closed
        )
    }

    /// The plate under the row changes when letting go would archive rather than open, which is
    /// the only warning a quiet strip gives before the row goes.
    func testTheStripArmsItselfOnlyOnceTheRowIsMostlyPastTheFinger() {
        XCTAssertFalse(
            MobileRowSwipe.isArmed(offset: -150, rowWidth: 340, allowsFullSwipe: true)
        )
        XCTAssertTrue(
            MobileRowSwipe.isArmed(offset: -200, rowWidth: 340, allowsFullSwipe: true)
        )
        XCTAssertFalse(
            MobileRowSwipe.isArmed(offset: -320, rowWidth: 340, allowsFullSwipe: false)
        )
    }

    /// Dragging an open row back towards its resting place closes it.
    func testDraggingAnOpenRowBackClosesIt() {
        let resting = -MobileRowSwipe.actionWidth
        let offset = MobileRowSwipe.offset(
            translation: 100,
            resting: resting,
            rowWidth: 340,
            allowsFullSwipe: true
        )
        XCTAssertEqual(
            MobileRowSwipe.release(
                offset: offset,
                projectedOffset: offset,
                rowWidth: 340,
                allowsFullSwipe: true
            ),
            .closed
        )
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

    // MARK: - Files staged beside a direct terminal

    /// The tray tells its owner when something changed. Dropping failures is a change only when
    /// there were failures — and the guard is what stops the direct terminal's own handler, which
    /// calls this from inside `onChange`, from re-entering itself once per staged file.
    @MainActor
    func testDroppingFailedUploadsFromATrayWithNoneAnnouncesNothing() throws {
        let tray = ComposerAttachmentTray(
            client: RemoteClient(
                link: try XCTUnwrap(RemoteConnectionLink(string: "https://demo.invalid/#tray"))
            ),
            sessionID: "session"
        )
        var changes = 0
        tray.onChange = { changes += 1 }

        tray.removeFailed()

        XCTAssertEqual(changes, 0)
    }

    /// One file too many is answered with a notice and nothing else. The notice used to be the
    /// trigger for sweeping failed chips out of the tray, so an unrelated refusal like this one
    /// deleted files that had nothing to do with it.
    @MainActor
    func testRefusingAnExtraFileLeavesTheStagedOnesAlone() throws {
        let tray = ComposerAttachmentTray(
            client: RemoteClient(
                link: try XCTUnwrap(RemoteConnectionLink(string: "https://demo.invalid/#tray"))
            ),
            sessionID: "session"
        )
        let bytes = Data("staged".utf8)
        for index in 0..<RemoteAttachmentUploadLimits.maximumPerMessage {
            tray.add(data: bytes, name: "file-\(index).txt", type: .plainText)
        }
        let staged = tray.items.count
        XCTAssertEqual(staged, RemoteAttachmentUploadLimits.maximumPerMessage)
        XCTAssertFalse(tray.canAcceptMore)

        tray.add(data: bytes, name: "one-too-many.txt", type: .plainText)

        XCTAssertNotNil(tray.notice)
        XCTAssertEqual(tray.items.count, staged, "a refusal must not disturb what is staged")
    }
}
