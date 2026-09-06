import Foundation
import XCTest
@testable import Threading

@MainActor
final class AgentStreamTransportTests: XCTestCase {
    func testFragmentedLinesAreParsedOffPipeAndDeliveredInOrderOnMain() throws {
        let pipes = TransportPipes()
        let delivered = expectation(description: "two lines")
        delivered.expectedFulfillmentCount = 2
        var lines: [String] = []
        let transport = makeTransport(pipes: pipes) { line in
            XCTAssertTrue(Thread.isMainThread)
            lines.append(line)
            delivered.fulfill()
        }

        transport.start()
        try pipes.output.fileHandleForWriting.write(contentsOf: Data("fir".utf8))
        try pipes.output.fileHandleForWriting.write(contentsOf: Data("st\nsecond\n".utf8))

        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(lines, ["first", "second"])
        transport.detach()
    }

    func testNewlineFreeOutputIsBounded() throws {
        let pipes = TransportPipes()
        let failed = expectation(description: "bounded output failure")
        var receivedFailure: AgentStreamTransportFailure?
        let transport = makeTransport(
            pipes: pipes,
            maximumLineBytes: 8,
            onFailure: { failure in
                receivedFailure = failure
                failed.fulfill()
            }
        )

        transport.start()
        try pipes.output.fileHandleForWriting.write(contentsOf: Data("123456789".utf8))

        wait(for: [failed], timeout: 1)
        XCTAssertEqual(receivedFailure, .outputLineTooLarge(9))
        transport.detach()
    }

    func testErrorFloodIsDrainedPastTheCaptureLimit() throws {
        let pipes = TransportPipes()
        let writeFinished = expectation(description: "error flood drained")
        let finishReturned = expectation(description: "transport finished")
        var diagnostic = ""
        let transport = makeTransport(pipes: pipes, maximumErrorBytes: 8)
        let writer = pipes.error.fileHandleForWriting

        transport.start()
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: Data(repeating: 0x78, count: 256 * 1_024))
            try? writer.close()
            writeFinished.fulfill()
        }

        wait(for: [writeFinished], timeout: 2)
        try pipes.output.fileHandleForWriting.close()
        transport.finish { captured in
            diagnostic = captured
            finishReturned.fulfill()
        }
        wait(for: [finishReturned], timeout: 1)
        XCTAssertEqual(diagnostic, "xxxxxxxx")
        transport.detach()
    }

    func testOutboundJSONIsSerializedByWriterLane() throws {
        let pipes = TransportPipes()
        let written = expectation(description: "json line")
        let data = LockedTransportData()
        pipes.input.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            if data.appendAndEndsInNewline(chunk) { written.fulfill() }
        }
        let transport = makeTransport(pipes: pipes)

        XCTAssertTrue(transport.writeJSONObject(["method": "test", "value": 7]))

        wait(for: [written], timeout: 1)
        pipes.input.fileHandleForReading.readabilityHandler = nil
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(data.snapshot.dropLast())) as? [String: Any]
        )
        XCTAssertEqual(object["method"] as? String, "test")
        XCTAssertEqual(object["value"] as? Int, 7)
        transport.detach()
    }

    func testDetachSuppressesAlreadyQueuedMainActorDelivery() throws {
        let pipes = TransportPipes()
        let delivered = expectation(description: "no line after detach")
        delivered.isInverted = true
        let transport = makeTransport(
            pipes: pipes,
            onLine: { _ in delivered.fulfill() }
        )

        transport.start()
        try pipes.output.fileHandleForWriting.write(contentsOf: Data("late\n".utf8))
        transport.detach()

        wait(for: [delivered], timeout: 0.1)
    }

    private func makeTransport(
        pipes: TransportPipes,
        maximumLineBytes: Int = 1_024,
        maximumErrorBytes: Int = 1_024,
        onLine: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onFailure: @escaping @MainActor @Sendable (AgentStreamTransportFailure) -> Void = { _ in }
    ) -> AgentStreamTransport<String> {
        AgentStreamTransport(
            label: "codes.threading.tests.agent-stream",
            input: pipes.input.fileHandleForWriting,
            output: pipes.output.fileHandleForReading,
            error: pipes.error.fileHandleForReading,
            maximumLineBytes: maximumLineBytes,
            maximumErrorBytes: maximumErrorBytes,
            parser: { String(data: $0, encoding: .utf8) },
            onLine: onLine,
            onMalformedLine: {},
            onFailure: onFailure
        )
    }
}

private final class TransportPipes {
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
}

private final class LockedTransportData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func appendAndEndsInNewline(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        return data.last == 0x0A
    }

    var snapshot: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
