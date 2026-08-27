import Foundation
import ThreadingDomain
import ThreadingPTYHostKit
import XCTest
@testable import Threading

@MainActor
final class PTYHostArchiveStopTests: XCTestCase {

    func testArchiveStopsTheMatchingLiveDaemonChildBeforeCompleting() async {
        let target = SessionID()
        let other = SessionID()
        let socket = "/tmp/threading-archive-stop-tests.sock"
        let targetIdentity = PTYHostSessionIdentity(.agentSession(target))
        let recorder = ArchiveStopRecorder()
        let completed = expectation(description: "archive stop completed")

        PTYHostArchiveStop.run(
            sessionID: target,
            decision: decision(enabled: true, socket: socket),
            survey: .answering(PTYHostHoldings(
                socketPath: socket,
                sessions: [summary(other), summary(target), summary(target, exit: 0)]
            )),
            stopper: { identity, socketPath, build in
                recorder.record(identity: identity, socketPath: socketPath, build: build)
                return true
            },
            completion: { completed.fulfill() }
        )

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(recorder.identities, [targetIdentity])
        XCTAssertEqual(recorder.socketPaths, [socket])
        XCTAssertEqual(recorder.builds, ["archive-stop-tests"])
    }

    func testArchiveStillStopsAChildAfterTheHostSettingWasTurnedOff() async {
        let target = SessionID()
        let targetIdentity = PTYHostSessionIdentity(.agentSession(target))
        let socket = "/tmp/threading-disabled-archive-stop-tests.sock"
        let heldSummary = summary(target)
        let recorder = ArchiveStopRecorder()
        let completed = expectation(description: "disabled archive stop completed")

        PTYHostArchiveStop.run(
            sessionID: target,
            decision: decision(enabled: false, socket: socket),
            survey: PTYHostHoldingsSurvey { decision in
                recorder.recordSurveyDecision(decision)
                return PTYHostHoldings(socketPath: socket, sessions: [heldSummary])
            },
            stopper: { identity, socketPath, build in
                recorder.record(identity: identity, socketPath: socketPath, build: build)
                return true
            },
            completion: { completed.fulfill() }
        )

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(recorder.identities, [targetIdentity])
        XCTAssertEqual(recorder.surveyDecisions.map(\.isEnabled), [true])
    }

    private func decision(enabled: Bool, socket: String) -> PTYHostDecision {
        PTYHostDecision(
            isEnabled: enabled,
            helperURL: URL(fileURLWithPath: "/unused/threading-ptyd"),
            socketPath: socket,
            socketPathBytes: socket.utf8.count,
            build: "archive-stop-tests"
        )
    }

    private func summary(_ sessionID: SessionID, exit: Int32? = nil) -> PTYHostSessionSummary {
        PTYHostSessionSummary(
            id: .agentSession(sessionID),
            pid: 4_242,
            startedAt: Date(timeIntervalSince1970: 1_000),
            executable: "/usr/local/bin/codex",
            grid: PTYHostGrid(cols: 100, rows: 40),
            isAttached: false,
            exit: exit
        )
    }
}

private final class ArchiveStopRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var identityStorage: [PTYHostSessionIdentity] = []
    private var socketStorage: [String] = []
    private var buildStorage: [String] = []
    private var surveyDecisionStorage: [PTYHostDecision] = []

    func record(identity: PTYHostSessionIdentity, socketPath: String, build: String) {
        lock.lock()
        identityStorage.append(identity)
        socketStorage.append(socketPath)
        buildStorage.append(build)
        lock.unlock()
    }

    func recordSurveyDecision(_ decision: PTYHostDecision) {
        lock.lock()
        surveyDecisionStorage.append(decision)
        lock.unlock()
    }

    var identities: [PTYHostSessionIdentity] {
        lock.lock()
        defer { lock.unlock() }
        return identityStorage
    }

    var socketPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return socketStorage
    }

    var builds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return buildStorage
    }

    var surveyDecisions: [PTYHostDecision] {
        lock.lock()
        defer { lock.unlock() }
        return surveyDecisionStorage
    }
}
