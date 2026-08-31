import Darwin
import XCTest
@testable import Threading

final class ExternalConversationPreflightTests: XCTestCase {
    private let wantedID = "01a05114-40e3-70c2-b583-cb86a01603c0"

    func testExactResumeOperandFindsTheOwningProcess() {
        let pid: pid_t = 42

        XCTAssertEqual(
            matchingProcess(
                summaries: [pid: summary(pid: pid, command: "codex")],
                commandLines: [
                    pid: commandLine("codex", "--no-alt-screen", "resume", wantedID)
                ]
            ),
            pid
        )
    }

    func testAnIdentifierElsewhereInTheArgumentsIsNotTreatedAsOwnership() {
        let promptPID: pid_t = 42
        let otherConversationPID: pid_t = 43
        let otherExecutablePID: pid_t = 44

        XCTAssertNil(matchingProcess(
            summaries: [
                promptPID: summary(pid: promptPID, command: "codex"),
                otherConversationPID: summary(pid: otherConversationPID, command: "codex"),
                otherExecutablePID: summary(pid: otherExecutablePID, command: "other")
            ],
            commandLines: [
                promptPID: commandLine("codex", "exec", "please inspect", wantedID),
                otherConversationPID: commandLine("codex", "resume", "different-id"),
                otherExecutablePID: commandLine("other", "resume", wantedID)
            ]
        ))
    }

    func testPreflightFailureIsDurableAndActionableWithoutProcessOutput() {
        let failure = ExternalConversationPreflight.launchFailure(
            kind: .codex,
            transcriptPath: "/tmp/rollout.jsonl"
        )

        XCTAssertEqual(failure.origin, .preflight)
        XCTAssertEqual(failure.knownCause, SessionLaunchDiagnosis.Cause.identifierInUse)
        XCTAssertEqual(failure.transcriptPath, "/tmp/rollout.jsonl")
        XCTAssertTrue(failure.detail.isEmpty)
        XCTAssertTrue(failure.summary.contains("Close it there"))
    }

    private func matchingProcess(
        summaries: [pid_t: ProcessSummary],
        commandLines: [pid_t: ProcessCommandLine]
    ) -> pid_t? {
        ExternalConversationPreflight.runningProcessID(
            executableName: "codex",
            transcriptID: wantedID,
            processTable: { summaries },
            commandLine: { commandLines[$0] }
        )
    }

    private func summary(pid: pid_t, command: String) -> ProcessSummary {
        ProcessSummary(
            pid: pid,
            parentPid: 1,
            command: command,
            state: .running,
            startTime: nil
        )
    }

    private func commandLine(_ arguments: String...) -> ProcessCommandLine {
        ProcessCommandLine(
            executablePath: "/usr/local/bin/\(arguments[0])",
            arguments: arguments
        )
    }
}
