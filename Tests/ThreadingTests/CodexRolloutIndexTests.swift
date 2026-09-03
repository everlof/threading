import XCTest
@testable import Threading

/// A retained catalogue is mostly conversations whose rollout is gone, and every one of them
/// used to cost a walk of the account's whole sessions tree — 311 walks of 672 entries in one
/// projection, on the main actor. These cases pin the rule that replaced that: however many
/// conversations ask, a pass reads the tree once, and the answer is then dictionary reads.
final class CodexRolloutIndexTests: XCTestCase {

    private var root: URL!
    private var account: AgentAccount!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingRolloutIndex-\(UUID().uuidString)", isDirectory: true)
        account = AgentAccount(
            provider: .codex,
            handle: .named("rollout-index"),
            configPath: root.path
        )
        CodexTranscript.invalidateCache()
    }

    override func tearDownWithError() throws {
        CodexTranscript.invalidateCache()
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testABurstOfMissesSharesOneWalkOfTheSessionsTree() throws {
        let present = (0..<5).map { _ in newID() }
        for (index, id) in present.enumerated() {
            try writeRollout(id: id, day: "2026/09/0\(index % 3 + 1)")
        }
        let missing = (0..<300).map { _ in newID() }
        let now = Date()
        let walksBefore = CodexTranscript.rolloutWalkCount

        for id in missing {
            XCTAssertNil(CodexTranscript.url(sessionID: id, account: account, now: now))
        }
        for id in present {
            XCTAssertNotNil(CodexTranscript.url(sessionID: id, account: account, now: now))
        }

        XCTAssertEqual(CodexTranscript.rolloutWalkCount - walksBefore, 1)
    }

    func testAMissIsAskedAgainOnceTheWalkHasAged() throws {
        let id = newID()
        let start = Date()
        let walksBefore = CodexTranscript.rolloutWalkCount
        let bound = CodexTranscriptDefaults.rolloutIndexMaximumAge

        XCTAssertNil(CodexTranscript.url(sessionID: id, account: account, now: start))
        let rollout = try writeRollout(id: id)

        // Within the bound the last walk still answers; nothing on disk is asked.
        XCTAssertNil(CodexTranscript.url(
            sessionID: id,
            account: account,
            now: start.addingTimeInterval(bound / 2)
        ))
        XCTAssertEqual(CodexTranscript.rolloutWalkCount - walksBefore, 1)

        // Past it, the next miss walks again and finds the conversation that has appeared.
        XCTAssertEqual(
            CodexTranscript.url(
                sessionID: id,
                account: account,
                now: start.addingTimeInterval(bound)
            )?.resolvingSymlinksInPath(),
            rollout.resolvingSymlinksInPath()
        )
        XCTAssertEqual(CodexTranscript.rolloutWalkCount - walksBefore, 2)
    }

    func testKnownURLReadsNothingAndAnswersFromTheLastWalk() throws {
        let id = newID()
        let other = newID()
        let rollout = try writeRollout(id: id)
        let walksBefore = CodexTranscript.rolloutWalkCount

        XCTAssertNil(CodexTranscript.knownURL(sessionID: id, account: account))
        XCTAssertEqual(CodexTranscript.rolloutWalkCount, walksBefore)

        CodexTranscript.rolloutIndex(account: account)

        XCTAssertEqual(
            CodexTranscript.knownURL(sessionID: id, account: account)?.resolvingSymlinksInPath(),
            rollout.resolvingSymlinksInPath()
        )
        XCTAssertNil(CodexTranscript.knownURL(sessionID: other, account: account))
        XCTAssertEqual(CodexTranscript.rolloutWalkCount - walksBefore, 1)
    }

    func testAReportedRolloutJoinsTheIndexWithoutAWalk() throws {
        CodexTranscript.rolloutIndex(account: account)
        let id = newID()
        let rollout = try writeRollout(id: id)
        let walksBefore = CodexTranscript.rolloutWalkCount

        XCTAssertNotNil(CodexTranscript.url(
            reportedPath: rollout.path,
            sessionID: id,
            account: account
        ))
        XCTAssertEqual(
            CodexTranscript.knownURL(sessionID: id, account: account)?.resolvingSymlinksInPath(),
            rollout.resolvingSymlinksInPath()
        )
        XCTAssertEqual(CodexTranscript.rolloutWalkCount, walksBefore)
    }

    func testAnIDThatIsNotAUUIDStillMatchesByNameSuffix() throws {
        let id = TranscriptID("legacy-42")
        let rollout = try writeRollout(id: id)

        XCTAssertEqual(
            CodexTranscript.url(sessionID: id, account: account)?.resolvingSymlinksInPath(),
            rollout.resolvingSymlinksInPath()
        )
    }

    // MARK: - Helpers

    private func newID() -> TranscriptID {
        TranscriptID(UUID().uuidString.lowercased())
    }

    @discardableResult
    private func writeRollout(id: TranscriptID, day: String = "2026/09/03") throws -> URL {
        let directory = root
            .appendingPathComponent(AgentAccountDefaults.sessionsSubdirectory)
            .appendingPathComponent(day)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rollout-2026-09-03T10-00-00-\(id.rawValue).jsonl")
        try Data("{}\n".utf8).write(to: url)
        return url
    }
}
