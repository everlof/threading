import Foundation
import XCTest
@testable import ThreadingMobile

final class RemoteWireEncodingLaneTests: XCTestCase {
    func testEncodingRunsOffMainAndPreservesAdmissionOrder() throws {
        let recorder = EncodingRecorder()
        let lane = RemoteWireEncodingLane(label: "test.remote-wire-order", generation: 7)
        let completed = expectation(description: "all messages encoded")
        completed.expectedFulfillmentCount = 3

        for identifier in 0..<3 {
            try lane.enqueue(
                ProbeMessage(identifier: identifier, recorder: recorder),
                generation: 7
            ) { result in
                recorder.recordCompletion(result)
                completed.fulfill()
            }
        }

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(recorder.encodedIdentifiers, [0, 1, 2])
        XCTAssertEqual(recorder.completedIdentifiers, [0, 1, 2])
        XCTAssertEqual(recorder.mainThreadEncodingCount, 0)
    }

    func testAdvancingGenerationDropsQueuedWorkBeforeEncoding() throws {
        let recorder = EncodingRecorder(blocksFirstMessage: true)
        let lane = RemoteWireEncodingLane(label: "test.remote-wire-generation", generation: 1)
        let currentCompleted = expectation(description: "current generation encoded")

        try lane.enqueue(
            ProbeMessage(identifier: 0, recorder: recorder),
            generation: 1
        ) { result in
            recorder.recordCompletion(result)
        }
        XCTAssertEqual(recorder.firstMessageStarted.wait(timeout: .now() + 2), .success)

        try lane.enqueue(
            ProbeMessage(identifier: 1, recorder: recorder),
            generation: 1
        ) { result in
            recorder.recordCompletion(result)
        }
        lane.advance(to: 2)
        try lane.enqueue(
            ProbeMessage(identifier: 2, recorder: recorder),
            generation: 2
        ) { result in
            recorder.recordCompletion(result)
            currentCompleted.fulfill()
        }
        recorder.releaseFirstMessage.signal()

        wait(for: [currentCompleted], timeout: 2)
        XCTAssertEqual(recorder.encodedIdentifiers, [0, 2])
        XCTAssertEqual(recorder.completedIdentifiers, [2])
    }

    func testPendingWorkIsBounded() throws {
        let recorder = EncodingRecorder(blocksFirstMessage: true)
        let lane = RemoteWireEncodingLane(
            label: "test.remote-wire-backpressure",
            generation: 3,
            maximumPendingMessages: 2
        )
        let admittedCompleted = expectation(description: "admitted messages encoded")
        admittedCompleted.expectedFulfillmentCount = 2

        for identifier in 0..<2 {
            try lane.enqueue(
                ProbeMessage(identifier: identifier, recorder: recorder),
                generation: 3
            ) { result in
                recorder.recordCompletion(result)
                admittedCompleted.fulfill()
            }
        }
        XCTAssertEqual(recorder.firstMessageStarted.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(
            try lane.enqueue(
                ProbeMessage(identifier: 2, recorder: recorder),
                generation: 3
            ) { _ in }
        ) { error in
            XCTAssertEqual(error as? RemoteWireEncodingFailure, .backpressure)
        }
        recorder.releaseFirstMessage.signal()

        wait(for: [admittedCompleted], timeout: 2)
        XCTAssertEqual(recorder.encodedIdentifiers, [0, 1])
    }

    func testPreparedBinaryFrameCannotOvertakeEncodedTextFrames() throws {
        let recorder = EncodingRecorder()
        let lane = RemoteWireEncodingLane(label: "test.remote-wire-mixed-order", generation: 9)
        let completed = expectation(description: "mixed frames delivered")
        completed.expectedFulfillmentCount = 3

        try lane.enqueue(ProbeMessage(identifier: 0, recorder: recorder), generation: 9) { _ in
            recorder.recordDelivery("hello")
            completed.fulfill()
        }
        try lane.enqueuePrepared(generation: 9) {
            recorder.recordDelivery("terminal")
            completed.fulfill()
        }
        try lane.enqueue(ProbeMessage(identifier: 1, recorder: recorder), generation: 9) { _ in
            recorder.recordDelivery("ready")
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(recorder.deliveryLabels, ["hello", "terminal", "ready"])
    }
}

private struct ProbeMessage: Encodable, Sendable {
    let identifier: Int
    let recorder: EncodingRecorder

    private enum CodingKeys: String, CodingKey {
        case identifier
    }

    func encode(to encoder: Encoder) throws {
        recorder.recordEncoding(identifier)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identifier, forKey: .identifier)
    }
}

private final class EncodingRecorder: @unchecked Sendable {
    let firstMessageStarted = DispatchSemaphore(value: 0)
    let releaseFirstMessage = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private let blocksFirstMessage: Bool
    private var encoded: [Int] = []
    private var completed: [Int] = []
    private var deliveries: [String] = []
    private var mainThreadEncodings = 0

    init(blocksFirstMessage: Bool = false) {
        self.blocksFirstMessage = blocksFirstMessage
    }

    var encodedIdentifiers: [Int] {
        lock.withLock { encoded }
    }

    var completedIdentifiers: [Int] {
        lock.withLock { completed }
    }

    var mainThreadEncodingCount: Int {
        lock.withLock { mainThreadEncodings }
    }

    var deliveryLabels: [String] {
        lock.withLock { deliveries }
    }

    func recordEncoding(_ identifier: Int) {
        lock.withLock {
            encoded.append(identifier)
            if Thread.isMainThread { mainThreadEncodings += 1 }
        }
        if blocksFirstMessage, identifier == 0 {
            firstMessageStarted.signal()
            releaseFirstMessage.wait()
        }
    }

    func recordCompletion(_ result: Result<String, RemoteWireEncodingFailure>) {
        guard case .success(let text) = result,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
              let identifier = object["identifier"] else { return }
        lock.withLock { completed.append(identifier) }
    }

    func recordDelivery(_ label: String) {
        lock.withLock { deliveries.append(label) }
    }
}
