import XCTest
@testable import Threading

/// The preflight that decides whether a conversation file is worth launching for.
///
/// The rule under test is narrow and was arrived at by measuring, not by reading the error
/// message: the fatal shape is a rollout that *started* being numbered and stopped, not one
/// that was never numbered. On the machine this was written against, 1,818 of 1,842 rollouts
/// carried no ordinals at all and resumed perfectly well under the same CLI that refused the
/// mixed one. A check that only looked at the last record would have condemned all of them,
/// which is the failure this class exists to prevent anyone reintroducing.
final class TranscriptResumeHealthTests: XCTestCase {

    // MARK: - Fixtures

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rollout-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func rollout(_ lines: [String]) throws -> URL {
        let url = directory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        return url
    }

    private func record(ordinal: Int?, type: String = "event_msg") -> String {
        let number = ordinal.map { "\"ordinal\":\($0)," } ?? ""
        return "{\"timestamp\":\"2026-08-20T21:07:05.717Z\",\(number)\"type\":\"\(type)\","
            + "\"payload\":{\"type\":\"task_complete\"}}"
    }

    // MARK: - The Three Shapes

    func testARolloutWithNoOrdinalsAnywhereIsUsable() throws {
        // The older format, and the overwhelming majority of what is on disk. Condemning this
        // shape would take nearly every conversation the user has.
        let url = try rollout([
            record(ordinal: nil, type: "session_meta"),
            record(ordinal: nil),
            record(ordinal: nil, type: "turn_context"),
        ])

        XCTAssertEqual(TranscriptResumeHealth.verdict(for: url, kind: .codex), .usable)
    }

    func testARolloutWhoseFinalRecordIsNumberedIsUsable() throws {
        let url = try rollout([
            record(ordinal: 0, type: "session_meta"),
            record(ordinal: 1),
            record(ordinal: 2, type: "turn_context"),
        ])

        XCTAssertEqual(TranscriptResumeHealth.verdict(for: url, kind: .codex), .usable)
    }

    func testARolloutThatStartedBeingNumberedAndStoppedIsUnusable() throws {
        // The specimen: ordinals through 3116, then nine records written the next morning
        // without them. `codex resume` fails outright on this and prints its reason to a
        // terminal Threading was, until this check existed, about to tear down.
        let url = try rollout([
            record(ordinal: 0, type: "session_meta"),
            record(ordinal: 1),
            record(ordinal: 2),
            record(ordinal: nil, type: "response_item"),
            record(ordinal: nil, type: "turn_context"),
        ])

        guard case .unusable(let reason, let cause) = TranscriptResumeHealth.verdict(
            for: url,
            kind: .codex
        ) else {
            return XCTFail("a mixed-ordinal rollout must be refused before launching")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(cause, SessionLaunchDiagnosis.Cause.transcriptUnreadable)
    }

    // MARK: - Bounds And Edges

    func testTheVerdictIsReachedWithoutReadingTheWholeFile() throws {
        // A real rollout was 38.9 MB. This runs on the way to a launch, so it must not depend on
        // file size: a healthy tail after megabytes of padding still answers, and answers fast.
        let padding = String(repeating: "x", count: 200_000)
        let url = try rollout(
            [record(ordinal: 0, type: "session_meta")]
                + (1...40).map { i in
                    "{\"timestamp\":\"t\",\"ordinal\":\(i),\"type\":\"event_msg\","
                        + "\"payload\":{\"text\":\"\(padding)\"}}"
                }
                + [record(ordinal: 41)]
        )

        let started = Date()
        XCTAssertEqual(TranscriptResumeHealth.verdict(for: url, kind: .codex), .usable)
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            1,
            "the preflight must stay a tail read rather than a full parse"
        )
    }

    func testAnOrdinalDeepInsideAPayloadDoesNotCountAsTheRecordsOwn() throws {
        // Rollout lines carry tool output, and tool output can contain anything — including the
        // word this check looks for. Only the record's own envelope may answer.
        let url = try rollout([
            record(ordinal: 0, type: "session_meta"),
            record(ordinal: 1),
            "{\"timestamp\":\"t\",\"type\":\"response_item\",\"payload\":{\"text\":\""
                + String(repeating: " ", count: 600) + "\\\"ordinal\\\":7\"}}",
        ])

        guard case .unusable = TranscriptResumeHealth.verdict(for: url, kind: .codex) else {
            return XCTFail("an ordinal inside a payload must not pass for the record's own")
        }
    }

    func testAMissingFileIsNotThisChecksQuestion() {
        // "There is no transcript" is the launcher's existing question and has its own answer.
        let url = directory.appendingPathComponent("absent.jsonl")

        XCTAssertEqual(TranscriptResumeHealth.verdict(for: url, kind: .codex), .usable)
    }

    func testRuntimesWithNoSuchCheckAreNeverRefused() throws {
        // Provider-neutral by construction: a rule written for one runtime's file format must
        // not become a refusal for a runtime whose files it has never seen.
        let url = try rollout([
            record(ordinal: 0, type: "session_meta"),
            record(ordinal: nil),
        ])

        for kind in [AgentKind.claude, .grok, .openCode, .cursor] {
            XCTAssertEqual(
                TranscriptResumeHealth.verdict(for: url, kind: kind),
                .usable,
                "\(kind) has no ordinal rule and must not inherit Codex's"
            )
        }
    }
}
