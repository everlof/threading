import Darwin
import ThreadingPTYHostKit
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

    func testSameSessionHostedAncestorIsNotTreatedAsExternalOwnership() {
        let sessionID = SessionID()
        let rootPID: pid_t = 40
        let wrapperPID: pid_t = 41
        let codexPID: pid_t = 42

        XCTAssertNil(matchingProcess(
            summaries: [
                rootPID: summary(pid: rootPID, parentPID: 1, command: "node"),
                wrapperPID: summary(pid: wrapperPID, parentPID: rootPID, command: "node"),
                codexPID: summary(pid: codexPID, parentPID: wrapperPID, command: "codex")
            ],
            commandLines: [
                codexPID: commandLine("codex", "resume", wantedID)
            ],
            sessionID: sessionID,
            hostedSessions: [hostedSession(sessionID: sessionID, pid: rootPID)]
        ))
    }

    func testHostedAncestorForAnotherSessionStillRefusesTheOwner() {
        let currentSessionID = SessionID()
        let otherSessionID = SessionID()
        let rootPID: pid_t = 40
        let codexPID: pid_t = 42

        XCTAssertEqual(
            matchingProcess(
                summaries: [
                    rootPID: summary(pid: rootPID, parentPID: 1, command: "node"),
                    codexPID: summary(pid: codexPID, parentPID: rootPID, command: "codex")
                ],
                commandLines: [
                    codexPID: commandLine("codex", "resume", wantedID)
                ],
                sessionID: currentSessionID,
                hostedSessions: [hostedSession(sessionID: otherSessionID, pid: rootPID)]
            ),
            codexPID
        )
    }

    func testExternalOwnerAfterSameSessionHostedOwnerStillRefuses() {
        let sessionID = SessionID()
        let rootPID: pid_t = 40
        let hostedCodexPID: pid_t = 42
        let externalCodexPID: pid_t = 43

        XCTAssertEqual(
            matchingProcess(
                summaries: [
                    rootPID: summary(pid: rootPID, parentPID: 1, command: "node"),
                    hostedCodexPID: summary(
                        pid: hostedCodexPID,
                        parentPID: rootPID,
                        command: "codex"
                    ),
                    externalCodexPID: summary(
                        pid: externalCodexPID,
                        parentPID: 1,
                        command: "codex"
                    )
                ],
                commandLines: [
                    hostedCodexPID: commandLine("codex", "resume", wantedID),
                    externalCodexPID: commandLine("codex", "resume", wantedID)
                ],
                sessionID: sessionID,
                hostedSessions: [hostedSession(sessionID: sessionID, pid: rootPID)]
            ),
            externalCodexPID
        )
    }

    func testHostedSessionSurveyIsLazyWithoutAMatchingResume() {
        var surveyCount = 0

        let owner = ExternalConversationPreflight.runningProcessID(
            executableName: "codex",
            transcriptID: wantedID,
            sessionID: SessionID(),
            hostedSessions: {
                surveyCount += 1
                return []
            },
            processTable: { [42: self.summary(pid: 42, command: "other")] },
            commandLine: { _ in self.commandLine("other", "resume", self.wantedID) }
        )

        XCTAssertNil(owner)
        XCTAssertEqual(surveyCount, 0)
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
        commandLines: [pid_t: ProcessCommandLine],
        sessionID: SessionID? = nil,
        hostedSessions: [PTYHostSessionSummary] = []
    ) -> pid_t? {
        ExternalConversationPreflight.runningProcessID(
            executableName: "codex",
            transcriptID: wantedID,
            sessionID: sessionID,
            hostedSessions: { hostedSessions },
            processTable: { summaries },
            commandLine: { commandLines[$0] }
        )
    }

    private func summary(
        pid: pid_t,
        parentPID: pid_t = 1,
        command: String
    ) -> ProcessSummary {
        ProcessSummary(
            pid: pid,
            parentPid: parentPID,
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

    private func hostedSession(
        sessionID: SessionID,
        pid: pid_t
    ) -> PTYHostSessionSummary {
        PTYHostSessionSummary(
            id: .agentSession(sessionID),
            pid: pid,
            startedAt: Date(),
            executable: "/usr/local/bin/codex",
            grid: PTYHostGrid(cols: 80, rows: 24),
            isAttached: false
        )
    }
}
