import Darwin
import XCTest
import os

@testable import Threading

final class SimulatorSocketIOTests: XCTestCase {
    private struct SocketFailure: Error {
        let detail: String
    }

    func testFullDuplexSocketWritesWhileDuplicateDescriptorIsBlockedReading() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        let parentRead = sockets[0]
        let parentWrite = dup(parentRead)
        let peer = sockets[1]
        XCTAssertGreaterThanOrEqual(parentWrite, 0)
        defer {
            close(parentRead)
            if parentWrite >= 0 { close(parentWrite) }
            close(peer)
        }

        let request = Data("hello".utf8)
        let reply = Data("ready".utf8)
        let parentReaderStarted = DispatchSemaphore(value: 0)
        let parentAnswered = expectation(description: "parent read the helper reply")
        let peerAnswered = expectation(description: "helper read and answered the request")
        let outcomes = OSAllocatedUnfairLock(initialState: (
            parent: Result<Data, SocketFailure>?.none,
            peer: Result<Data, SocketFailure>?.none
        ))

        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 32)
            parentReaderStarted.signal()
            do {
                let data = try SimulatorSocketIO.read(
                    upToCount: buffer.count,
                    from: parentRead,
                    reusing: &buffer
                ) ?? Data()
                outcomes.withLock { $0.parent = .success(data) }
            } catch {
                outcomes.withLock {
                    $0.parent = .failure(SocketFailure(detail: String(describing: error)))
                }
            }
            parentAnswered.fulfill()
        }

        XCTAssertEqual(parentReaderStarted.wait(timeout: .now() + 1), .success)
        Thread.sleep(forTimeInterval: 0.02)

        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 32)
            do {
                let data = try SimulatorSocketIO.read(
                    upToCount: buffer.count,
                    from: peer,
                    reusing: &buffer
                ) ?? Data()
                outcomes.withLock { $0.peer = .success(data) }
                try SimulatorSocketIO.writeAll(reply, to: peer)
            } catch {
                outcomes.withLock {
                    $0.peer = .failure(SocketFailure(detail: String(describing: error)))
                }
            }
            peerAnswered.fulfill()
        }

        try SimulatorSocketIO.writeAll(request, to: parentWrite)
        wait(for: [parentAnswered, peerAnswered], timeout: 2)

        let result = outcomes.withLock { $0 }
        XCTAssertEqual(try result.peer?.get(), request)
        XCTAssertEqual(try result.parent?.get(), reply)
    }
}
