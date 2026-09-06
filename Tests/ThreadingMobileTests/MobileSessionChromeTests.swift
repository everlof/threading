import SwiftTerm
import SwiftUI
import ThreadingRemoteKit
import UIKit
import UniformTypeIdentifiers
import XCTest
import os
@testable import ThreadingMobile

final class MobileSessionChromeTests: XCTestCase {
    func testChangingASessionSurfacePreservesIndependentRuntimeAndRoutingFacts() throws {
        let session = RemoteSessionSummaryDTO(
            id: Fixture.sessionID,
            title: "Background review",
            agentKind: "claude",
            surface: .terminal,
            state: .idle,
            attention: .init(
                knowledge: .read,
                completionGeneration: 3,
                seenGeneration: 3
            ),
            continuation: .delegated,
            projectName: "AnotherTerminal",
            projectID: "project-id",
            accountID: "work",
            limitRecovery: .resumeOnBestAccount,
            model: "claude-fable-5"
        )
        let response = RemoteMeDTO(
            serverProtocol: RemoteProtocolInfo(),
            share: Fixture.share,
            sessions: [session],
            revision: .init(epoch: "fixture", revision: 7)
        )

        let changed = try XCTUnwrap(
            response.replacingSessionSurface(
                sessionID: Fixture.sessionID,
                surface: .conversation
            ).sessions.first
        )

        XCTAssertEqual(changed.surface, .conversation)
        XCTAssertEqual(changed.attention?.knowledge, .read)
        XCTAssertEqual(changed.continuation, .delegated)
        XCTAssertEqual(changed.projectID, "project-id")
        XCTAssertEqual(changed.accountID, "work")
        XCTAssertEqual(changed.limitRecovery, .resumeOnBestAccount)
        XCTAssertEqual(changed.model, "claude-fable-5")
        XCTAssertEqual(
            response.replacingSessionSurface(
                sessionID: Fixture.sessionID,
                surface: .conversation
            ).revision,
            response.revision
        )
    }

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
            TerminalRemoteView(
                connection: connection,
                openingLoaderOwner: .terminalSurface
            )
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

    /// The toolbar dot opens a menu with several unrelated actions. Its state survives that hop
    /// as the same badge on Workspace, without lengthening the destination's visible title.
    func testUnseenBrowserActivityKeepsAStableWorkspaceTitle() {
        XCTAssertEqual(
            MobileSessionChrome.workspaceMenuTitle(),
            MobileL10n.string("Workspace")
        )
        XCTAssertEqual(
            MobileSessionChrome.workspaceMenuSystemImage(),
            "square.grid.2x2"
        )
        XCTAssertEqual(
            MobileSessionChrome.workspaceMenuAccessibilityLabel(hasUnseenBrowser: true),
            MobileL10n.string("Workspace · New browser activity")
        )
        XCTAssertEqual(
            MobileSessionChrome.workspaceMenuAccessibilityLabel(hasUnseenBrowser: false),
            MobileL10n.string("Workspace")
        )
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
            uploadScopeID: "session"
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
            uploadScopeID: "session"
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

/// The workspace drawer's arithmetic, asked the way the gestures ask it: where the panel is for
/// a finger that has travelled so far, where it settles when the finger lets go, and which
/// touches are its at all.
final class SessionWorkspaceDrawerTests: XCTestCase {
    func testThePanelIsThePhoneLessARevealAndNeverWiderThanAPhone() {
        XCTAssertEqual(SessionWorkspaceDrawer.width(in: 402), 402 - SessionWorkspaceDrawer.reveal)
        XCTAssertEqual(SessionWorkspaceDrawer.width(in: 1_024), SessionWorkspaceDrawer.maximumWidth)
        XCTAssertEqual(SessionWorkspaceDrawer.width(in: 20), 0, "a sliver cannot hold a drawer")
    }

    func testOpeningFollowsTheFingerLeftwardAndStopsAtTheEdges() {
        XCTAssertEqual(SessionWorkspaceDrawer.openingProgress(translation: -179, width: 358), 0.5)
        XCTAssertEqual(SessionWorkspaceDrawer.openingProgress(translation: 40, width: 358), 0)
        XCTAssertEqual(SessionWorkspaceDrawer.openingProgress(translation: -900, width: 358), 1)
        XCTAssertEqual(SessionWorkspaceDrawer.closingProgress(translation: 179, width: 358), 0.5)
        XCTAssertEqual(SessionWorkspaceDrawer.closingProgress(translation: -30, width: 358), 0)
    }

    /// Half way is the rule, and a throw is read a fifth of a second ahead of the finger.
    func testAReleaseSettlesByPositionAndAFlickDecidesShortOfHalfWay() {
        XCTAssertTrue(SessionWorkspaceDrawer.settlesOpen(openness: 0.6, velocity: 0, width: 358))
        XCTAssertFalse(SessionWorkspaceDrawer.settlesOpen(openness: 0.4, velocity: 0, width: 358))
        // A quarter open, flicked inward at 1,000 pt/s: 0.25 + 200/358 lands past half.
        XCTAssertTrue(SessionWorkspaceDrawer.settlesOpen(openness: 0.25, velocity: -1_000, width: 358))
        // Three quarters open, flicked outward: it goes.
        XCTAssertFalse(SessionWorkspaceDrawer.settlesOpen(openness: 0.75, velocity: 1_000, width: 358))
        XCTAssertFalse(SessionWorkspaceDrawer.settlesOpen(openness: 1, velocity: 0, width: 0))
    }

    /// A touch is the drawer's when it began at the right bezel and has headed left since; the
    /// same drag begun a thumb's width in is the list's, and a scroll that happens to start at
    /// the bezel is the list's too.
    func testOnlyALeftwardTouchFromTheRightBezelOpens() {
        // Ten points in from a touch-down at 398: the recogniser's own hysteresis.
        XCTAssertTrue(SessionWorkspaceDrawer.isOpeningEdgeTouch(
            location: CGPoint(x: 388, y: 451), translation: CGPoint(x: -10, y: 1),
            velocity: CGPoint(x: -400, y: 30), width: 402
        ))
        XCTAssertFalse(SessionWorkspaceDrawer.isOpeningEdgeTouch(
            location: CGPoint(x: 350, y: 451), translation: CGPoint(x: -10, y: 1),
            velocity: CGPoint(x: -400, y: 30), width: 402
        ), "a thumb's width in is the list's")
        XCTAssertFalse(SessionWorkspaceDrawer.isOpeningEdgeTouch(
            location: CGPoint(x: 397, y: 440), translation: CGPoint(x: -1, y: -10),
            velocity: CGPoint(x: -60, y: -900), width: 402
        ), "a scroll begun at the bezel is the list's")
        XCTAssertFalse(SessionWorkspaceDrawer.isOpeningEdgeTouch(
            location: CGPoint(x: 402, y: 450), translation: CGPoint(x: 10, y: 0),
            velocity: CGPoint(x: 300, y: 0), width: 402
        ), "rightward is nobody's")
    }

    /// The edge is where the touch began, not where the finger is when the pan is asked. A
    /// quick swipe has travelled well past the edge zone by then — further still on a frame the
    /// terminal was busy drawing — and used to be declined for it.
    func testTheEdgeIsJudgedAtTheTouchDownNotWhereTheFingerHasGot() {
        XCTAssertTrue(SessionWorkspaceDrawer.isOpeningEdgeTouch(
            location: CGPoint(x: 340, y: 455), translation: CGPoint(x: -58, y: 5),
            velocity: CGPoint(x: -2_400, y: 120), width: 402
        ), "a swipe begun at 398 is the drawer's however far it got before it was asked")
        XCTAssertFalse(SessionWorkspaceDrawer.isOpeningEdgeTouch(
            location: CGPoint(x: 340, y: 455), translation: CGPoint(x: -30, y: 5),
            velocity: CGPoint(x: -2_400, y: 120), width: 402
        ), "the same finger, begun at 370, is the list's")
    }

    /// The direction is the path since touch-down, which is steadier than the last two
    /// samples' velocity; a pan that reports no travel is judged on velocity.
    func testTheDirectionIsThePathNotTheLastSample() {
        XCTAssertTrue(SessionWorkspaceDrawer.isOpeningEdgeTouch(
            location: CGPoint(x: 386, y: 453), translation: CGPoint(x: -12, y: 3),
            velocity: CGPoint(x: -60, y: -900), width: 402
        ), "a leftward path with a vertical last sample still opens")
        XCTAssertFalse(SessionWorkspaceDrawer.isOpeningEdgeTouch(
            location: CGPoint(x: 395, y: 462), translation: CGPoint(x: -3, y: 12),
            velocity: CGPoint(x: -900, y: 60), width: 402
        ), "a downward path with a sideways last sample still scrolls")
        XCTAssertTrue(SessionWorkspaceDrawer.isOpeningEdgeTouch(
            location: CGPoint(x: 398, y: 450), translation: .zero,
            velocity: CGPoint(x: -400, y: 30), width: 402
        ))
        XCTAssertFalse(SessionWorkspaceDrawer.isOpeningEdgeTouch(
            location: CGPoint(x: 398, y: 450), translation: .zero,
            velocity: CGPoint(x: -60, y: -900), width: 402
        ))
    }

    /// Only a scroll view's pan waits for the drawer's. The terminal's long press on the same
    /// scroll view does not: a pan under a resting finger never fails, and a wait on it held
    /// the press until touch-up.
    @MainActor
    func testOnlyAScrollViewsPanWaitsForTheDrawer() {
        let scroller = UIScrollView()
        let scrollerPan = UIPanGestureRecognizer()
        scroller.addGestureRecognizer(scrollerPan)
        let longPress = UILongPressGestureRecognizer()
        scroller.addGestureRecognizer(longPress)
        let pinch = UIPinchGestureRecognizer()
        scroller.addGestureRecognizer(pinch)
        let plain = UIView()
        let plainPan = UIPanGestureRecognizer()
        plain.addGestureRecognizer(plainPan)

        XCTAssertTrue(SessionWorkspaceDrawer.isCompetingPan(scroller.panGestureRecognizer))
        XCTAssertTrue(SessionWorkspaceDrawer.isCompetingPan(scrollerPan))
        XCTAssertFalse(SessionWorkspaceDrawer.isCompetingPan(longPress))
        XCTAssertFalse(SessionWorkspaceDrawer.isCompetingPan(pinch))
        XCTAssertFalse(SessionWorkspaceDrawer.isCompetingPan(plainPan))
    }

    /// A release hands the spring the throw — the finger's speed toward where the panel is
    /// going, in remaining distances per second, capped so a flick released short of home does
    /// not overshoot — and a short remainder is slowed to the least settle rather than snapped.
    func testTheSettleCarriesTheThrowAndNeverSnaps() {
        // A quarter open, flicked inward at 1,000 pt/s: opens at full pace, carrying the throw
        // over the three quarters left.
        let flicked = SessionWorkspaceDrawer.settle(openness: 0.25, velocity: -1_000, width: 358)
        XCTAssertTrue(flicked.opens)
        XCTAssertEqual(flicked.completionSpeed, 1)
        XCTAssertEqual(flicked.initialVelocity, 1_000 / (0.75 * 358), accuracy: 0.001)

        // Nearly open and flicked hard: the throw is capped, and the last few points take the
        // least settle instead of two frames.
        let hard = SessionWorkspaceDrawer.settle(openness: 0.95, velocity: -3_000, width: 358)
        XCTAssertTrue(hard.opens)
        XCTAssertEqual(hard.initialVelocity, SessionWorkspaceDrawer.maximumSettleVelocity)
        XCTAssertEqual(
            0.05 * SessionWorkspaceDrawer.settleDuration / Double(hard.completionSpeed),
            SessionWorkspaceDrawer.minimumSettleDuration,
            accuracy: 0.001
        )

        // Pushed back from four tenths: closes, carrying the throw toward closed.
        let pushed = SessionWorkspaceDrawer.settle(openness: 0.4, velocity: 200, width: 358)
        XCTAssertFalse(pushed.opens)
        XCTAssertEqual(pushed.initialVelocity, 200 / (0.4 * 358), accuracy: 0.001)

        // Let go past half while drifting the other way: it opens, and the spring is told the
        // finger was leaving.
        let drifting = SessionWorkspaceDrawer.settle(openness: 0.6, velocity: 100, width: 358)
        XCTAssertTrue(drifting.opens)
        XCTAssertEqual(drifting.initialVelocity, -100 / (0.4 * 358), accuracy: 0.001)

        // A gesture the system cancelled goes back where it came from, whatever the position
        // says, at the slide's own pace.
        let cancelled = SessionWorkspaceDrawer.settle(
            opens: false, openness: 0.8, velocity: 0, width: 358
        )
        XCTAssertEqual(
            cancelled,
            SessionWorkspaceDrawer.Settle(opens: false, completionSpeed: 1, initialVelocity: 0)
        )
        XCTAssertEqual(
            SessionWorkspaceDrawer.settle(openness: 1, velocity: -500, width: 0).initialVelocity,
            0,
            "a sliver has no throw"
        )
    }

    func testOnlyARightwardSidewaysPanOnThePanelCloses() {
        XCTAssertTrue(SessionWorkspaceDrawer.isDismissDirection(velocity: CGPoint(x: 420, y: 60)))
        XCTAssertFalse(SessionWorkspaceDrawer.isDismissDirection(velocity: CGPoint(x: -420, y: 60)))
        XCTAssertFalse(SessionWorkspaceDrawer.isDismissDirection(velocity: CGPoint(x: 60, y: 900)))
        // Exactly diagonal is the list's: scrolling is the commoner intent.
        XCTAssertFalse(SessionWorkspaceDrawer.isDismissDirection(velocity: CGPoint(x: 300, y: 300)))
    }
}

/// The gallery's detail line and the ledger's bounds, without a window.
final class RemoteAttachmentGalleryTests: XCTestCase {
    func testTheDetailLineIsPositionThenPixelsThenSizeInTheMacsOrder() {
        XCTAssertEqual(
            RemoteAttachmentGalleryDetail.text(
                index: 0, count: 27, pixelSize: CGSize(width: 1_219, height: 874), byteCount: 188_000
            ),
            "1 of 27 · 1219 × 874 · 188 KB"
        )
        XCTAssertEqual(
            RemoteAttachmentGalleryDetail.text(index: 3, count: 7, pixelSize: nil, byteCount: 1_284),
            "4 of 7 · 1 KB",
            "pixels are named only once the image has been decoded"
        )
        XCTAssertEqual(
            RemoteAttachmentGalleryDetail.text(index: 0, count: 1, pixelSize: nil, byteCount: 2_048),
            "2 KB",
            "one attachment has no position to state"
        )
    }

    func testImagesPDFsAndMoviesAreAskedForAThumbnail() {
        XCTAssertTrue(RemoteAttachmentGalleryDetail.hasThumbnail(kind: .image))
        XCTAssertTrue(RemoteAttachmentGalleryDetail.hasThumbnail(kind: .pdf))
        XCTAssertTrue(RemoteAttachmentGalleryDetail.hasThumbnail(kind: .video))
        let others: [RemoteAttachmentKind] = [
            .html, .text, .archive, .document, .diagram, .media, .unknown("hologram"),
        ]
        for kind in others {
            XCTAssertFalse(RemoteAttachmentGalleryDetail.hasThumbnail(kind: kind), "\(kind)")
        }
    }

    @MainActor
    func testTheThumbnailStoreKeepsABoundedNumber() throws {
        let image = try XCTUnwrap(UIImage(systemName: "photo"))
        let seed = Dictionary(uniqueKeysWithValues: (0..<(RemoteAttachmentThumbnailStore.capacity + 5))
            .map { ("attachment-\($0)", image) })
        let store = RemoteAttachmentThumbnailStore(isOffered: true, seed: seed) { _, _ in Data() }

        // A dictionary seed has no first; the bound is the invariant, not which one went.
        XCTAssertEqual(store.images.count, RemoteAttachmentThumbnailStore.capacity)
    }

    /// A Mac that did not advertise thumbnails is never asked: the cell keeps its glyph and the
    /// link carries nothing for it.
    @MainActor
    func testAMacWithoutThumbnailsIsNeverAsked() async throws {
        let fetches = OSAllocatedUnfairLock(initialState: 0)
        let store = RemoteAttachmentThumbnailStore(isOffered: false) { _, _ in
            fetches.withLock { $0 += 1 }
            return Data()
        }

        await store.load(id: "attachment-1", hasThumbnail: true)

        XCTAssertNil(store.image(for: "attachment-1"))
        XCTAssertEqual(fetches.withLock { $0 }, 0)
    }
}

/// The chat menu's usage row keeps exact values beside the glanceable gauge and follows them with
/// the first reset from the same model-relevant window set.
final class MobileSessionUsageMenuRowTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var ringed: MobileAccountUsageReading {
        MobileAccountUsageReading(
            rings: [.init(id: "7d", fraction: 0.34)],
            summary: "7d 34%",
            nextReset: now.addingTimeInterval(5 * 60 * 60)
        )
    }

    func testTheWordsKeepExactUsageAndTheRelevantReset() {
        let detail = MobileSessionChrome.usageMenuDetail(reading: ringed, now: now)

        XCTAssertTrue(detail.contains("7d 34%"))
        XCTAssertTrue(detail.contains("5"), "when the window comes back is also stated")
    }

    /// A host that reports no reset time still states the exact reading.
    func testAHostThatNamesNoResetKeepsTheReadingInWords() {
        let noReset = MobileAccountUsageReading(
            rings: ringed.rings,
            summary: ringed.summary
        )
        XCTAssertEqual(
            MobileSessionChrome.usageMenuDetail(reading: noReset, now: now),
            "7d 34%"
        )
    }

    /// An older host sends a summary and no per-window reset metadata.
    func testAReadingWithNothingToRingKeepsItsPercentagesInTheWords() {
        let wordsOnly = MobileAccountUsageReading(rings: [], summary: "5h 43% · 7d 73%")

        XCTAssertEqual(
            MobileSessionChrome.usageMenuDetail(reading: wordsOnly, now: now),
            "5h 43% · 7d 73%"
        )
    }

    /// A fraction with no words behind it still draws; the row shows the dash the rest of the
    /// app uses rather than an empty second line.
    func testAGaugeWithNoWordsBehindItSaysSoRatherThanNothing() {
        let mute = MobileAccountUsageReading(
            rings: [.init(id: "binding", fraction: 0.2)],
            summary: nil
        )

        XCTAssertEqual(
            MobileSessionChrome.usageMenuDetail(reading: mute, now: now),
            MobileUsageDefaults.unknownValue
        )
    }

    /// `AccountName` derives the person from the address, and falls back to the address itself
    /// when two logins derive the same person. A row handed both must not print it twice.
    func testAnAddressThatIsAlreadyTheNameIsNotSaidAgain() {
        func account(name: String, email: String?) -> RemoteAccountChoiceDTO {
            RemoteAccountChoiceDTO(
                id: "default",
                name: name,
                email: email,
                models: [],
                defaultModelID: nil
            )
        }

        XCTAssertEqual(
            MobileSessionChrome.usageMenuAddress(
                for: account(name: "Everlof", email: "everlof@gmail.com")
            ),
            "everlof@gmail.com"
        )
        XCTAssertNil(MobileSessionChrome.usageMenuAddress(
            for: account(name: "everlof@gmail.com", email: "everlof@gmail.com")
        ))
        XCTAssertNil(MobileSessionChrome.usageMenuAddress(
            for: account(name: "Everlof@Gmail.com", email: "everlof@gmail.com")
        ))
        XCTAssertNil(MobileSessionChrome.usageMenuAddress(
            for: account(name: "Everlof", email: "   ")
        ))
        XCTAssertNil(MobileSessionChrome.usageMenuAddress(
            for: account(name: "Everlof", email: nil)
        ))
    }

    func testTheRowAppearsForAnythingItCanDrawOrSayAndForNothingElse() {
        XCTAssertTrue(MobileSessionChrome.showsUsageMenuRow(reading: ringed))
        XCTAssertTrue(MobileSessionChrome.showsUsageMenuRow(
            reading: MobileAccountUsageReading(rings: [], summary: "7d 34%")
        ))
        XCTAssertTrue(MobileSessionChrome.showsUsageMenuRow(
            reading: MobileAccountUsageReading(rings: [.init(id: "7d", fraction: nil)], summary: nil)
        ))
        XCTAssertFalse(MobileSessionChrome.showsUsageMenuRow(
            reading: MobileAccountUsageReading(rings: [], summary: nil)
        ))
        XCTAssertFalse(MobileSessionChrome.showsUsageMenuRow(reading: nil))
    }
}
