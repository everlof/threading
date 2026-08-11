import XCTest
@testable import ThreadingScenarioKit

final class AgentScenarioTapeTests: XCTestCase {
    func testCanonicalRoundTripPreservesTypedActions() throws {
        let tape = fixture()
        let data = try tape.canonicalData()

        let decoded = try JSONDecoder.scenario.decode(AgentScenarioTape.self, from: data)

        XCTAssertEqual(decoded, tape)
        XCTAssertNoThrow(try decoded.validate())
    }

    func testFutureFormatFailsClosed() {
        let tape = AgentScenarioTape(
            version: AgentScenarioTape.currentVersion + 1,
            id: "future-format",
            title: "Future format",
            provider: .codex,
            transport: .codexAppServer,
            provenance: provenance,
            steps: [.exit(status: 0, afterMilliseconds: 0)]
        )

        XCTAssertThrowsError(try tape.validate()) { error in
            XCTAssertEqual(
                error as? AgentScenarioValidationError,
                .unsupportedVersion(found: 2, current: 1)
            )
        }
    }

    func testExitMustBeFinal() {
        let tape = AgentScenarioTape(
            id: "early-exit",
            title: "Early exit",
            provider: .codex,
            transport: .codexAppServer,
            provenance: provenance,
            steps: [
                .exit(status: 0, afterMilliseconds: 0),
                .checkpoint(name: "unreachable"),
            ]
        )

        XCTAssertThrowsError(try tape.validate()) { error in
            XCTAssertEqual(error as? AgentScenarioValidationError, .exitNotLast(step: 0))
        }
    }

    func testUnknownPlaceholderIsRejected() {
        let tape = AgentScenarioTape(
            id: "unknown-placeholder",
            title: "Unknown placeholder",
            provider: .claude,
            transport: .claudeStreamJSON,
            provenance: provenance,
            steps: [
                .emitAgent(
                    channel: .standardOutput,
                    payload: "{\"path\":\"${PERSONAL_HOME}/secret\"}\n",
                    afterMilliseconds: 0
                ),
                .exit(status: 0, afterMilliseconds: 0),
            ]
        )

        XCTAssertThrowsError(try tape.validate()) { error in
            XCTAssertEqual(
                error as? AgentScenarioValidationError,
                .unknownPlaceholder(step: 0, name: "PERSONAL_HOME")
            )
        }
    }

    func testPrivacyAuditRejectsCredentialsAndHomePaths() {
        let tape = AgentScenarioTape(
            id: "unsafe-recording",
            title: "Unsafe recording",
            provider: .codex,
            transport: .codexAppServer,
            provenance: provenance,
            steps: [
                .emitAgent(
                    channel: .standardOutput,
                    payload: "Bearer abcdefghijklmnopqrstuvwxyz",
                    afterMilliseconds: 0
                ),
                .expectHost(channel: .standardInput, payload: "/Users/alice/project/file.swift"),
                .exit(status: 0, afterMilliseconds: 0),
            ]
        )

        XCTAssertEqual(
            AgentScenarioPrivacyAudit.findings(in: tape),
            [
                .init(step: 0, kind: .credentialLikeValue),
                .init(step: 1, kind: .unnormalizedHomePath),
            ]
        )
    }

    func testProviderMustMatchStructuredTransport() {
        let tape = AgentScenarioTape(
            id: "mismatched-transport",
            title: "Mismatched transport",
            provider: .claude,
            transport: .codexAppServer,
            provenance: provenance,
            steps: [.exit(status: 0, afterMilliseconds: 0)]
        )

        XCTAssertThrowsError(try tape.validate()) { error in
            XCTAssertEqual(
                error as? AgentScenarioValidationError,
                .incompatibleProviderTransport(provider: "claude", transport: "codex-app-server")
            )
        }
    }

    func testPTYTransportRejectsStructuredOutputChannel() {
        let tape = AgentScenarioTape(
            id: "mismatched-channel",
            title: "Mismatched channel",
            provider: .codex,
            transport: .terminalPTY,
            provenance: provenance,
            steps: [
                .emitAgent(
                    channel: .standardOutput,
                    payload: "unexpected structured output",
                    afterMilliseconds: 0
                ),
                .exit(status: 0, afterMilliseconds: 0),
            ]
        )

        XCTAssertThrowsError(try tape.validate()) { error in
            XCTAssertEqual(
                error as? AgentScenarioValidationError,
                .incompatibleAgentChannel(
                    step: 0,
                    channel: "stdout",
                    transport: "terminal-pty"
                )
            )
        }
    }

    func testFixtureWriteRejectsTraversal() {
        let tape = AgentScenarioTape(
            id: "unsafe-write",
            title: "Unsafe write",
            provider: .codex,
            transport: .codexAppServer,
            provenance: provenance,
            steps: [
                .writeFixtureFile(path: "project/../outside.txt", contents: "no"),
                .exit(status: 0, afterMilliseconds: 0),
            ]
        )

        XCTAssertThrowsError(try tape.validate()) { error in
            XCTAssertEqual(
                error as? AgentScenarioValidationError,
                .invalidFixturePath(step: 0, path: "project/../outside.txt")
            )
        }
    }

    func testReplayMatchesJSONSubsetsCapturesIdsAndWritesInsideRoot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = Pipe()
        try input.fileHandleForWriting.write(contentsOf: Data(
            "{\"id\":7,\"method\":\"turn/start\",\"params\":{\"clientUserMessageId\":\"captured-id\",\"cwd\":\"\(project.path)\",\"metadata\":true}}\n".utf8
        ))
        try input.fileHandleForWriting.close()
        let output = Pipe()
        let tape = AgentScenarioTape(
            id: "subset-replay",
            title: "Subset replay",
            provider: .codex,
            transport: .codexAppServer,
            provenance: provenance,
            steps: [
                .expectHost(
                    channel: .standardInput,
                    payload: "{\"method\":\"turn/start\",\"params\":{\"clientUserMessageId\":\"${TURN_ID}\",\"cwd\":\"${SCENARIO_ROOT}/project\"}}"
                ),
                .writeFixtureFile(path: "project/status.txt", contents: "after\n"),
                .emitAgent(
                    channel: .standardOutput,
                    payload: "{\"messageId\":\"${TURN_ID}\"}\n",
                    afterMilliseconds: 0
                ),
                .exit(status: 0, afterMilliseconds: 0),
            ]
        )

        let status = try AgentScenarioReplayer(delay: { _ in }).run(
            tape: tape,
            scenarioRoot: directory,
            input: input.fileHandleForReading,
            standardOutput: output.fileHandleForWriting
        )
        try output.fileHandleForWriting.close()

        XCTAssertEqual(status, 0)
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: project.appendingPathComponent("status.txt")), as: UTF8.self),
            "after\n"
        )
        XCTAssertEqual(
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            "{\"messageId\":\"captured-id\"}\n"
        )
    }

    func testReplayBoundsPayloadAfterPlaceholderExpansion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oversizedBinding = String(
            repeating: "x",
            count: AgentScenarioLimits.maximumPayloadBytes + 1
        )
        let tape = AgentScenarioTape(
            id: "expanded-output-limit",
            title: "Expanded output limit",
            provider: .codex,
            transport: .codexAppServer,
            provenance: provenance,
            steps: [
                .emitAgent(
                    channel: .standardOutput,
                    payload: "${TURN_ID}",
                    afterMilliseconds: 0
                ),
                .exit(status: 0, afterMilliseconds: 0),
            ]
        )

        XCTAssertThrowsError(try AgentScenarioReplayer(delay: { _ in }).run(
            tape: tape,
            scenarioRoot: directory,
            bindings: ["TURN_ID": oversizedBinding],
            standardOutput: Pipe().fileHandleForWriting
        )) { error in
            XCTAssertEqual(
                error as? AgentScenarioReplayError,
                .renderedPayloadTooLarge(
                    step: 0,
                    actual: AgentScenarioLimits.maximumPayloadBytes + 1,
                    maximum: AgentScenarioLimits.maximumPayloadBytes
                )
            )
        }
    }

    func testLoadReadsOneBytePastActualLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("oversize.json")
        let data = Data(repeating: 0x20, count: AgentScenarioLimits.maximumEncodedBytes + 1)
        try data.write(to: url)

        XCTAssertThrowsError(try AgentScenarioTape.load(from: url)) { error in
            XCTAssertEqual(
                error as? AgentScenarioValidationError,
                .fileTooLarge(
                    actual: AgentScenarioLimits.maximumEncodedBytes + 1,
                    maximum: AgentScenarioLimits.maximumEncodedBytes
                )
            )
        }
    }

    func testCanonicalEncodingCannotExceedOpenedFileLimit() {
        let payload = String(
            repeating: "\0",
            count: AgentScenarioLimits.maximumPayloadBytes
        )
        let payloadSteps = AgentScenarioLimits.maximumAggregatePayloadBytes
            / AgentScenarioLimits.maximumPayloadBytes
        let tape = AgentScenarioTape(
            id: "escaped-output-limit",
            title: "Escaped output limit",
            provider: .codex,
            transport: .codexAppServer,
            provenance: provenance,
            steps: (0..<payloadSteps).map { _ in
                .emitAgent(
                    channel: .standardOutput,
                    payload: payload,
                    afterMilliseconds: 0
                )
            } + [.exit(status: 0, afterMilliseconds: 0)]
        )

        XCTAssertThrowsError(try tape.canonicalData()) { error in
            guard let validationError = error as? AgentScenarioValidationError,
                  case .fileTooLarge(let actual, let maximum) = validationError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, AgentScenarioLimits.maximumEncodedBytes)
        }
    }

    private func fixture() -> AgentScenarioTape {
        AgentScenarioTape(
            id: "codex-launch-smoke",
            title: "Codex launch smoke",
            provider: .codex,
            transport: .codexAppServer,
            provenance: provenance,
            steps: [
                .expectHost(
                    channel: .standardInput,
                    payload: "{\"id\":1,\"method\":\"initialize\"}\n"
                ),
                .emitAgent(
                    channel: .standardOutput,
                    payload: "{\"id\":1,\"result\":{}}\n",
                    afterMilliseconds: 5
                ),
                .checkpoint(name: "initialized"),
                .exit(status: 0, afterMilliseconds: 0),
            ]
        )
    }

    private var provenance: RecordingProvenance {
        RecordingProvenance(
            providerVersion: "fixture-1.0",
            protocolVersion: "app-server-1",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private extension JSONDecoder {
    static var scenario: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
