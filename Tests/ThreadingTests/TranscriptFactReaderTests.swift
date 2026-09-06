import XCTest
@testable import Threading

@MainActor
final class TranscriptFactReaderTests: XCTestCase {
    private func file(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptFactReaderTests-\(UUID().uuidString).jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCopyRevokesAnInflightRefusalAndPreCopyWaitersButKeepsPostCopyRequests() async throws {
        let url = try file("old refusal")
        let gate = FactScanGate()
        let reader = TranscriptFactReader<String> { gate.read($0) }
        defer { gate.release.signal() }
        reader.revalidate(at: url) { _ in XCTFail("Pre-copy result must not be delivered") }
        await fulfillment(of: [gate.started], timeout: 3)
        reader.revalidate(at: url) { _ in XCTFail("Pre-copy waiter must not be delivered") }

        reader.seedCopiedTranscript(at: url, byteCount: "old refusal".utf8.count, value: nil)
        XCTAssertNil(reader.known(at: url))
        try "new account output".write(to: url, atomically: true, encoding: .utf8)
        let current = expectation(description: "new output after copy")
        reader.revalidate(at: url) { value in
            XCTAssertEqual(value, "new account output")
            current.fulfill()
        }
        gate.release.signal()
        await fulfillment(of: [current], timeout: 3)
        XCTAssertEqual(reader.known(at: url), "new account output")
        XCTAssertEqual(gate.maximumConcurrentScans, 1)
    }

    func testResetRevokesInflightWorkWithoutStartingOverlappingScans() async throws {
        let url = try file("before reset")
        let gate = FactScanGate()
        let reader = TranscriptFactReader<String> { gate.read($0) }
        defer { gate.release.signal() }
        reader.revalidate(at: url) { _ in XCTFail("Discarded result must not be delivered") }
        await fulfillment(of: [gate.started], timeout: 3)
        reader.revalidate(at: url) { _ in XCTFail("Discarded waiter must not be delivered") }
        reader.forgetAll()
        try "after reset".write(to: url, atomically: true, encoding: .utf8)

        let current = expectation(description: "read after reset")
        reader.revalidate(at: url) { value in
            XCTAssertEqual(value, "after reset")
            current.fulfill()
        }
        gate.release.signal()
        await fulfillment(of: [current], timeout: 3)
        XCTAssertEqual(reader.known(at: url), "after reset")
        XCTAssertEqual(gate.maximumConcurrentScans, 1)
    }

    func testSameSizeAtomicReplacementInvalidatesTheFact() async throws {
        let url = try file("limited")
        let reader = TranscriptFactReader<String> { try? String(contentsOf: $0, encoding: .utf8) }
        let first = expectation(description: "original refusal")
        reader.revalidate(at: url) { value in
            XCTAssertEqual(value, "limited")
            first.fulfill()
        }
        await fulfillment(of: [first], timeout: 3)

        try "working".write(to: url, atomically: true, encoding: .utf8)
        let next = expectation(description: "same-size replacement")
        reader.revalidate(at: url) { value in
            XCTAssertEqual(value, "working")
            next.fulfill()
        }
        await fulfillment(of: [next], timeout: 3)
    }

    func testSameSizeInPlaceRewriteInvalidatesTheFact() async throws {
        let url = try file("limited")
        let reader = TranscriptFactReader<String> { try? String(contentsOf: $0, encoding: .utf8) }
        let first = expectation(description: "original refusal")
        reader.revalidate(at: url) { _ in first.fulfill() }
        await fulfillment(of: [first], timeout: 3)

        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data("working".utf8))
        try handle.close()
        // Make the modification boundary deterministic even on coarse timestamp filesystems.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path
        )
        let next = expectation(description: "same inode and size, changed contents")
        reader.revalidate(at: url) { value in
            XCTAssertEqual(value, "working")
            next.fulfill()
        }
        await fulfillment(of: [next], timeout: 3)
    }
}

/// The first scan reads old bytes and waits while the main actor changes ownership. No timing
/// sleeps: the test controls the exact point at which the stale worker is allowed to return.
private final class FactScanGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "old bytes captured")
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    private var active = 0
    private var maximum = 0

    var maximumConcurrentScans: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }

    func read(_ url: URL) -> String? {
        lock.lock()
        count += 1
        active += 1
        maximum = max(maximum, active)
        let first = count == 1
        lock.unlock()
        defer {
            lock.lock()
            active -= 1
            lock.unlock()
        }
        let value = try? String(contentsOf: url, encoding: .utf8)
        if first {
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        return value
    }
}
