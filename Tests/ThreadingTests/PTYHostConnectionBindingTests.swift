import Foundation
import ThreadingPTYHostKit
import XCTest
@testable import Threading

final class PTYHostConnectionBindingTests: XCTestCase {
    func testInputRequiresBindingAndASecondStreamIsRefused() throws {
        var binding = PTYHostConnectionBinding()
        XCTAssertThrowsError(try binding.requireInputBinding()) {
            XCTAssertEqual($0 as? PTYHostClientError, .notBound)
        }
        let id = PTYHostSessionIdentity.agentSession(SessionID())
        try binding.prepare(.attach(PTYHostAttach(id: id)))
        XCTAssertNoThrow(try binding.requireInputBinding())
        XCTAssertThrowsError(try binding.prepare(.attach(PTYHostAttach(id: id)))) {
            XCTAssertEqual($0 as? PTYHostClientError, .alreadyBound(id))
        }
        binding.reset()
        XCTAssertThrowsError(try binding.requireInputBinding())
    }

    func testMatchingUUIDDoesNotAdmitAnotherDomainOfSession() throws {
        var binding = PTYHostConnectionBinding()
        let uuid = UUID()
        let agent = PTYHostSessionIdentity.agentSession(SessionID(uuid))
        let terminal = PTYHostSessionIdentity(.projectTerminal(TerminalID(uuid)))
        try binding.prepare(.attach(PTYHostAttach(id: agent)))
        let frames: [PTYHostFrame] = [
            .resize(PTYHostResize(id: terminal, grid: PTYHostGrid(cols: 80, rows: 24))),
            .detach(PTYHostDetach(id: terminal, screenSeed: Data(), modeSeed: Data(), ringOffset: 0)),
            .closeInput(PTYHostCloseInput(id: terminal)),
            .kill(PTYHostKill(id: terminal, escalate: false))
        ]
        for frame in frames {
            XCTAssertThrowsError(try binding.prepare(frame)) {
                XCTAssertEqual($0 as? PTYHostClientError, .sessionMismatch(bound: agent, frame: terminal))
            }
        }
        XCTAssertNoThrow(try binding.prepare(.resize(PTYHostResize(id: agent, grid: PTYHostGrid(cols: 80, rows: 24)))))
        XCTAssertEqual(binding.session, agent)
    }

    func testOldFailureCannotReleaseANewerBinding() throws {
        var binding = PTYHostConnectionBinding()
        let first = PTYHostSessionIdentity.agentSession(SessionID())
        let second = PTYHostSessionIdentity.agentSession(SessionID())
        let original = PTYHostFrame.attach(PTYHostAttach(id: first))
        let originalReservation = try binding.prepare(original)
        binding.received(.spawnRefused(PTYHostSpawnRefused(id: second, reason: .capacity)))
        XCTAssertEqual(binding.session, first)
        binding.received(.spawnRefused(PTYHostSpawnRefused(id: first, reason: .capacity)))
        XCTAssertNil(binding.session)
        let next = PTYHostFrame.attach(PTYHostAttach(id: second))
        let nextReservation = try binding.prepare(next)
        binding.sendingFailed(originalReservation)
        XCTAssertEqual(binding.session, second)
        binding.sendingFailed(nextReservation)
        XCTAssertNil(binding.session)
    }
    func testOldFailureCannotReleaseARetryForTheSameSession() throws {
        var binding = PTYHostConnectionBinding()
        let id = PTYHostSessionIdentity.agentSession(SessionID())
        let request = PTYHostFrame.attach(PTYHostAttach(id: id))
        let first = try binding.prepare(request)
        binding.received(.spawnRefused(PTYHostSpawnRefused(id: id, reason: .capacity)))
        let retry = try binding.prepare(request)
        binding.sendingFailed(first)
        XCTAssertEqual(binding.session, id)
        binding.sendingFailed(retry)
        XCTAssertNil(binding.session)
    }

}
