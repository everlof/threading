import Foundation
import ThreadingDomain
import XCTest
@testable import Threading

/// A remote session's transcript, copied to this Mac by byte offset: only whole lines, only forward,
/// in bounded rounds — and read by every transcript reader here while no transcript writer will
/// touch it.
final class RemoteTranscriptMirrorTests: XCTestCase {

    private var root: URL!
    private let destination = RemoteHostDestination(alias: "pi", configFile: nil)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/threading-mirror-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func location(_ mirror: RemoteTranscriptMirror) -> RemoteTranscriptLocation {
        RemoteTranscriptLocation(
            destination: destination,
            remotePath: "/home/me/.claude/projects/-home-me-app/abc.jsonl",
            localURL: mirror.localURL(destination: destination, transcriptID: TranscriptID("abc"))
        )
    }

    private func mirrored(_ mirror: RemoteTranscriptMirror) throws -> String {
        String(decoding: try Data(contentsOf: location(mirror).localURL), as: UTF8.self)
    }

    // MARK: - Whole lines, forward

    /// A line the agent is still writing is never half-copied; the next refresh finishes it.
    func testOnlyWholeLinesArriveAndTheRestFollowsNextTime() throws {
        let host = FakeTranscriptHost()
        let mirror = RemoteTranscriptMirror(root: root, fetcher: host)
        host.content = "{\"a\":1}\n{\"b\":2}\n{\"c\":"

        XCTAssertEqual(mirror.synchronize(location(mirror)), .advanced(16))
        XCTAssertEqual(try mirrored(mirror), "{\"a\":1}\n{\"b\":2}\n")

        host.content = (host.content ?? "") + "3}\n{\"d\":4}\n"
        XCTAssertEqual(mirror.synchronize(location(mirror)), .advanced(16))
        XCTAssertEqual(try mirrored(mirror), host.content)
        XCTAssertEqual(host.requestedOffsets.last, 16, "the second refresh fetched from where the first stopped")

        XCTAssertEqual(mirror.synchronize(location(mirror)), .unchanged)
    }

    /// A line longer than one read — a big tool result, an inlined image — is carried across reads
    /// until its newline arrives. The first version stopped at such a line for good.
    func testALineLongerThanAChunkIsCarriedUntilItEnds() throws {
        let host = FakeTranscriptHost()
        let mirror = RemoteTranscriptMirror(root: root, fetcher: host, chunkBytes: 64, maximumRounds: 4)
        let long = "{\"result\":\"" + String(repeating: "y", count: 500) + "\"}\n"
        host.content = "{\"a\":1}\n" + long + "{\"b\":2}\n"

        _ = mirror.synchronize(location(mirror))
        _ = mirror.synchronize(location(mirror))
        XCTAssertEqual(try mirrored(mirror), host.content, "the mirror stopped at a line longer than a read")

        // Still being written: a long line with no end yet is not copied, and nothing is lost.
        host.content = (host.content ?? "") + "{\"c\":\"" + String(repeating: "z", count: 300)
        _ = mirror.synchronize(location(mirror))
        XCTAssertFalse(try mirrored(mirror).contains("zzz"), "half a line was copied")
        host.content = (host.content ?? "") + "\"}\n"
        _ = mirror.synchronize(location(mirror))
        XCTAssertEqual(try mirrored(mirror), host.content)
    }

    /// A host file shorter than the mirror was rewritten; the copy starts again rather than
    /// appending onto a prefix that is no longer the host's.
    func testARewrittenTranscriptIsCopiedAgainFromTheStart() throws {
        let host = FakeTranscriptHost()
        let mirror = RemoteTranscriptMirror(root: root, fetcher: host)
        host.content = "{\"old\":1}\n{\"old\":2}\n"
        _ = mirror.synchronize(location(mirror))

        host.content = "{\"new\":1}\n"
        XCTAssertEqual(mirror.synchronize(location(mirror)), .advanced(10))
        XCTAssertEqual(try mirrored(mirror), "{\"new\":1}\n")
    }

    func testAConversationWithNoTranscriptYetIsMissingNotAFailure() {
        let host = FakeTranscriptHost()
        host.content = nil
        let mirror = RemoteTranscriptMirror(root: root, fetcher: host)
        XCTAssertEqual(mirror.synchronize(location(mirror)), .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location(mirror).localURL.path))
    }

    /// A long first copy is bounded per refresh: it catches up across refreshes rather than in one
    /// unbounded transfer, and never loses or repeats a line on the way.
    func testALongTranscriptCatchesUpInBoundedRounds() throws {
        let host = FakeTranscriptHost()
        let chunk = 4_096
        let rounds = 3
        let mirror = RemoteTranscriptMirror(root: root, fetcher: host, chunkBytes: chunk, maximumRounds: rounds)
        let line = "{\"payload\":\"" + String(repeating: "x", count: 300) + "\"}\n"
        host.content = String(repeating: line, count: chunk / line.utf8.count * rounds + 20)

        guard case .advanced = mirror.synchronize(location(mirror)) else { return XCTFail("nothing arrived") }
        let firstPass = try Data(contentsOf: location(mirror).localURL).count
        XCTAssertLessThanOrEqual(host.requestedOffsets.count, rounds)
        XCTAssertLessThan(firstPass, host.content?.utf8.count ?? 0, "one refresh copied more than its bound")

        _ = mirror.synchronize(location(mirror))
        XCTAssertEqual(try mirrored(mirror), host.content, "the copy lost or repeated a line")
    }

    // MARK: - The host's half

    /// The exact command a host runs, run here by a real shell against a file whose path is hostile
    /// to quoting: the size header, then only the bytes asked for.
    func testTheHostCommandReadsExactlyTheBytesAskedFor() throws {
        let folder = root.appendingPathComponent("it's $(a) dir", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("abc.jsonl")
        try Data("0123456789\nabcdefghij\n".utf8).write(to: file)

        func run(_ offset: Int, _ limit: Int, path: String = file.path) throws -> RemoteTranscriptChunk {
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", SSHTranscriptFetcher.command(remotePath: path, offset: offset, limit: limit)]
            let output = Pipe()
            shell.standardOutput = output
            try shell.run()
            shell.waitUntilExit()
            return try SSHTranscriptFetcher.parse(output.fileHandleForReading.readDataToEndOfFile())
        }

        XCTAssertEqual(try run(0, 1_000), RemoteTranscriptChunk(remoteSize: 22, bytes: Data("0123456789\nabcdefghij\n".utf8)))
        XCTAssertEqual(try run(11, 4), RemoteTranscriptChunk(remoteSize: 22, bytes: Data("abcd".utf8)))
        XCTAssertEqual(try run(22, 100), RemoteTranscriptChunk(remoteSize: 22, bytes: Data()))
        XCTAssertEqual(try run(0, 10, path: folder.appendingPathComponent("none.jsonl").path),
                       RemoteTranscriptChunk(remoteSize: nil, bytes: Data()))
        XCTAssertThrowsError(try SSHTranscriptFetcher.parse(Data("garbage".utf8)))
    }

    // MARK: - One refresh at a time

    /// Callers arriving together share refreshes, every one is answered, and each is answered by a
    /// refresh that began after it asked.
    func testConcurrentCallersAreAllAnsweredWithoutOverlappingRefreshes() {
        let host = FakeTranscriptHost()
        host.content = "{\"a\":1}\n"
        host.delay = 0.05
        let mirror = RemoteTranscriptMirror(root: root, fetcher: host)

        let answered = expectation(description: "every caller answered")
        answered.expectedFulfillmentCount = 5
        for _ in 0..<5 {
            mirror.refresh(location(mirror)) { _ in answered.fulfill() }
        }
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(host.maximumConcurrency, 1, "two refreshes of one mirror ran at once")
        XCTAssertLessThan(host.requestedOffsets.count, 5, "every caller cost its own refresh")
    }

    func testTheMirrorKnowsItsOwnFiles() {
        let mirror = RemoteTranscriptMirror(root: root, fetcher: FakeTranscriptHost())
        XCTAssertTrue(mirror.contains(location(mirror).localURL))
        XCTAssertFalse(mirror.contains(URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects/x/abc.jsonl")))
        XCTAssertFalse(mirror.contains(root), "the root itself is not a transcript")
    }
}

/// A host whose transcript is a string in memory, answering exactly as `SSHTranscriptFetcher` does.
private final class FakeTranscriptHost: RemoteTranscriptFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var stored: String? = ""
    private(set) var requestedOffsets: [Int] = []
    private(set) var maximumConcurrency = 0
    var delay: TimeInterval = 0

    var content: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    func fetch(
        destination: RemoteHostDestination,
        remotePath: String,
        offset: Int,
        limit: Int
    ) throws -> RemoteTranscriptChunk {
        lock.lock()
        active += 1
        maximumConcurrency = max(maximumConcurrency, active)
        requestedOffsets.append(offset)
        let snapshot = stored
        lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        guard let snapshot else { return RemoteTranscriptChunk(remoteSize: nil, bytes: Data()) }
        let bytes = Data(snapshot.utf8)
        let start = min(offset, bytes.count)
        return RemoteTranscriptChunk(remoteSize: bytes.count, bytes: Data(bytes[start..<min(bytes.count, start + limit)]))
    }
}
