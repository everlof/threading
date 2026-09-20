import AppKit
import XCTest
import ThreadingRemoteKit
@testable import Threading

@MainActor
final class BrowserPermissionRequestsTests: HostedStoreTestCase {
    func testRealOriginPromptCanBeAnsweredByPhoneWithoutShowingAWindow() throws {
        let session = SessionID()
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.animationBehavior = .none
        let coordinator = AgentToolCoordinator(
            displayPaneController: DisplayPaneController(), visibleSessionID: { session },
            setPaneVisible: { _ in }, windowProvider: { window }, activateApp: {}
        )
        let url = try XCTUnwrap(URL(string: "https://user:secret@example.com/account"))
        var answers: [Bool] = []
        coordinator.authorizeBrowserAccess(to: url, for: session, purpose: "open and interact with") {
            answers.append($0)
        }
        defer { BrowserPermissionRequests.shared.cancel(sessionID: session) }
        let request = try XCTUnwrap(BrowserPermissionRequests.shared.pending(for: session))
        XCTAssertTrue(request.message.contains("https://example.com/account"))
        XCTAssertFalse(request.message.contains("secret"))
        XCTAssertTrue(BrowserPermissionRequests.shared.resolve(
            sessionID: session, id: request.id, decision: .allowOnce
        ))
        XCTAssertEqual(answers, [true])
        XCTAssertTrue(coordinator.hasBrowserAccess(to: url, for: session))
        XCTAssertFalse(BrowserPermissionRequests.shared.resolve(
            sessionID: session, id: request.id, decision: .deny
        ))
        window.orderOut(nil)
    }

    func testPhoneAnswerRetiresIdentityBeforeMacDismissalAndSettlesExactlyOnce() throws {
        let store = BrowserPermissionRequests()
        let session = SessionID()
        var results: [RemoteBrowserPermissionDecision] = []
        var id = ""
        id = try XCTUnwrap(store.enqueue(sessionID: session, title: "Host", message: "URL", dismiss: {
            XCTAssertFalse(store.resolve(sessionID: session, id: id, decision: .deny))
        }, settle: { results.append($0) }))
        XCTAssertFalse(store.resolve(sessionID: SessionID(), id: id, decision: .allowOnce))
        XCTAssertTrue(store.resolve(sessionID: session, id: id, decision: .allowRemembered))
        XCTAssertEqual(results, [.allowRemembered])
        XCTAssertNil(store.pending(for: session))
        XCTAssertFalse(store.resolve(sessionID: session, id: id, decision: .allowOnce))
    }

    func testNoRememberedDecisionForOneTimeActionAndCancellationDoesNotAnnounceSuccessors() throws {
        var announcements = 0
        let store = BrowserPermissionRequests(changed: { _, announce in
            if announce { announcements += 1 }
        })
        let session = SessionID()
        var decisions: [RemoteBrowserPermissionDecision] = []
        let first = try XCTUnwrap(store.enqueue(
            sessionID: session, title: "Clear data", message: "Destructive", rememberTitle: nil,
            dismiss: {}, settle: { decisions.append($0) }
        ))
        XCTAssertFalse(store.resolve(sessionID: session, id: first, decision: .allowRemembered))
        XCTAssertEqual(store.pending(for: session)?.id, first)
        store.enqueue(sessionID: session, title: "Next", message: "Next", dismiss: {}, settle: { decisions.append($0) })
        XCTAssertEqual(announcements, 1)
        store.cancel(sessionID: session)
        XCTAssertEqual(decisions, [.deny, .deny])
        XCTAssertEqual(announcements, 1)
        XCTAssertNil(store.pending(for: session))
    }

    func testQueuesAreBoundedAndNextRequestIsPromoted() throws {
        let store = BrowserPermissionRequests()
        let session = SessionID()
        var denied = 0
        for _ in 0..<BrowserPermissionRequests.maximumPerSession {
            XCTAssertNotNil(store.enqueue(sessionID: session, title: "Host", message: "Page", dismiss: {}, settle: {
                if $0 == .deny { denied += 1 }
            }))
        }
        XCTAssertNil(store.enqueue(sessionID: session, title: "Overflow", message: "Page", dismiss: {}, settle: {
            XCTAssertEqual($0, .deny)
        }))
        let first = try XCTUnwrap(store.pending(for: session)?.id)
        XCTAssertTrue(store.resolve(sessionID: session, id: first, decision: .allowOnce))
        XCTAssertNotEqual(store.pending(for: session)?.id, first)
        store.cancel(sessionID: session)
        XCTAssertEqual(denied, BrowserPermissionRequests.maximumPerSession - 1)
    }

    func testExpiredRequestCannotGrantEvenBeforeItsTimerRuns() throws {
        var now = ContinuousClock.now
        let store = BrowserPermissionRequests(now: { now })
        let session = SessionID()
        var answer: RemoteBrowserPermissionDecision?
        let id = try XCTUnwrap(store.enqueue(
            sessionID: session, title: "Host", message: "Page", dismiss: {}, settle: { answer = $0 }
        ))
        now = now.advanced(by: BrowserPermissionRequests.lifetime)
        XCTAssertFalse(store.resolve(sessionID: session, id: id, decision: .allowRemembered))
        XCTAssertEqual(answer, .deny)
        XCTAssertNil(store.pending(for: session))
    }

    func testGlobalStressBoundRefusesOverflowWithoutEvictingPendingRequests() {
        let store = BrowserPermissionRequests()
        let sessions = (0..<BrowserPermissionRequests.maximumPending).map { _ in SessionID() }
        for session in sessions {
            XCTAssertNotNil(store.enqueue(sessionID: session, title: "Host", message: "Page", dismiss: {}, settle: { _ in }))
        }
        for _ in 0..<1_000 {
            XCTAssertNil(store.enqueue(sessionID: SessionID(), title: "Host", message: "Page", dismiss: {}, settle: {
                XCTAssertEqual($0, .deny)
            }))
        }
        for session in sessions {
            XCTAssertNotNil(store.pending(for: session))
            store.cancel(sessionID: session)
        }
    }

    func testOlderWorkspaceWithoutPermissionStillDecodes() throws {
        let workspace = try JSONDecoder().decode(RemoteWorkspaceDTO.self, from: Data(#"{"browserTabs":[]}"#.utf8))
        XCTAssertNil(workspace.browserPermission)
    }
}
