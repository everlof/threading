import XCTest

@testable import Threading

/// On 2026-10-03 a scheduled automation failed because its Claude login had stopped signing in.
/// Threading recorded "The automation ended without reporting a result." and showed an in-app
/// toast, and the person found out by looking. A failed or needs-attention run now reaches the
/// Mac and the paired iPhone once, with the typed reason; a successful one reaches neither.
@MainActor
final class TriggerRunAlertTests: XCTestCase {

    @MainActor private final class Recorder {
        var mac: [TriggerRunAlerts.Alert] = []
        var phone: [(TriggerRunAlerts.Alert, SessionID)] = []
        var phoneEnabled = true

        var sinks: TriggerRunAlerts.Sinks {
            TriggerRunAlerts.Sinks(
                mac: { self.mac.append($0) },
                phone: { self.phone.append(($0, $1)) },
                phoneEnabled: { self.phoneEnabled }
            )
        }
    }

    private func run(
        _ state: TriggerRunState,
        sessionID: SessionID? = SessionID(),
        diagnostic: String? = nil,
        result: TriggerRunResult? = nil
    ) -> TriggerRun {
        TriggerRun(
            id: TriggerRunID(),
            triggerID: TriggerID(),
            triggerRevisionID: TriggerRevisionID(),
            eventKey: "manual",
            state: state,
            queuedAt: Date(),
            startedAt: Date(),
            settledAt: Date(),
            sessionID: sessionID,
            managedWorkspaceID: nil,
            holdReason: nil,
            result: result,
            boundedDiagnostic: diagnostic
        )
    }

    // MARK: - One alert per failed run, none for success

    func testAFailedRunAlertsTheMacAndThePhoneOnce() {
        let recorder = Recorder()
        let alerts = TriggerRunAlerts(sinks: recorder.sinks)
        let failed = run(.needsAttention, diagnostic: "The automation ended without reporting a result.")

        // Settlement can be observed from more than one edge; the run still alerts once.
        alerts.announce(failed, automationName: "Bevakning daglig genomgång")
        alerts.announce(failed, automationName: "Bevakning daglig genomgång")

        XCTAssertEqual(recorder.mac.count, 1)
        XCTAssertEqual(recorder.phone.count, 1)
        XCTAssertEqual(recorder.phone.first?.1, failed.sessionID)
        XCTAssertEqual(recorder.mac.first?.title,
                       L10n.format("“%@” needs attention", "Bevakning daglig genomgång"))
        XCTAssertEqual(recorder.mac.first?.body, "The automation ended without reporting a result.")
    }

    func testAReportedFailureAlertsWithItsOwnSummary() {
        let recorder = Recorder()
        let alerts = TriggerRunAlerts(sinks: recorder.sinks)
        let failed = run(.failed, result: TriggerRunResult(
            disposition: .failed, summary: "SSH to the VPS was refused", changedPaths: [], tests: []
        ))

        alerts.announce(failed, automationName: nil)

        XCTAssertEqual(recorder.mac.map(\.title), [L10n.string("Automation failed")])
        XCTAssertEqual(recorder.mac.first?.body, "SSH to the VPS was refused")
        XCTAssertEqual(recorder.phone.count, 1)
    }

    func testASuccessfulRunAlertsNowhere() {
        let recorder = Recorder()
        let alerts = TriggerRunAlerts(sinks: recorder.sinks)

        for state in TriggerRunState.allCases where state != .failed && state != .needsAttention {
            XCTAssertNil(alerts.announce(run(state), automationName: "Report"), "\(state) alerted")
        }

        XCTAssertTrue(recorder.mac.isEmpty)
        XCTAssertTrue(recorder.phone.isEmpty)
    }

    func testARunRefusedBeforeItsSessionStartedAlertsTheMacOnly() {
        let recorder = Recorder()
        let alerts = TriggerRunAlerts(sinks: recorder.sinks)

        alerts.announce(run(.needsAttention, sessionID: nil, diagnostic: "The existing checkout is not clean."),
                        automationName: "Report")

        XCTAssertEqual(recorder.mac.count, 1)
        XCTAssertNil(recorder.mac.first?.sessionID)
        XCTAssertTrue(recorder.phone.isEmpty, "the remote contract scopes every event to a session")
    }

    func testThePhoneStaysQuietWithoutRemoteAccess() {
        let recorder = Recorder()
        recorder.phoneEnabled = false
        let alerts = TriggerRunAlerts(sinks: recorder.sinks)

        alerts.announce(run(.needsAttention), automationName: "Report")

        XCTAssertEqual(recorder.mac.count, 1)
        XCTAssertTrue(recorder.phone.isEmpty)
    }

    func testTheLedgerStaysBounded() {
        let recorder = Recorder()
        let alerts = TriggerRunAlerts(sinks: recorder.sinks)
        let first = run(.failed)
        alerts.announce(first, automationName: nil)
        for _ in 0..<TriggerRunAlerts.ledgerLimit { alerts.announce(run(.failed), automationName: nil) }

        XCTAssertEqual(recorder.mac.count, TriggerRunAlerts.ledgerLimit + 1)
    }

    // MARK: - The typed reason

    func testClaudesAuthenticationFailureNamesTheLoginAndTheWayBack() {
        let words = TriggerRunDiagnostic.unreported(
            state: .running,
            failure: .authenticationFailed,
            login: .init(provider: .claude, name: "claude-sonda-02")
        )

        XCTAssertEqual(words, L10n.format(
            "The %@ login “%@” is no longer signed in. Sign in again, or give it a one-year token in Settings ▸ Agents & Accounts.",
            AgentKind.claude.displayName,
            "claude-sonda-02"
        ))
        XCTAssertNotEqual(words, L10n.string("The automation ended without reporting a result."))
    }

    func testTheOneYearTokenIsOfferedOnlyWhereTheRuntimeTakesOne() {
        let words = TriggerRunDiagnostic.unreported(
            state: .running,
            failure: .authenticationFailed,
            login: .init(provider: .codex, name: "codex-work")
        )

        XCTAssertEqual(AgentKind.codex.supports(.longLivedAccountToken), false)
        XCTAssertEqual(words, L10n.format(
            "The %@ login “%@” is no longer signed in. Sign in again in Settings ▸ Agents & Accounts.",
            AgentKind.codex.displayName,
            "codex-work"
        ))
    }

    func testAnUnexplainedExitKeepsItsWords() {
        XCTAssertEqual(
            TriggerRunDiagnostic.unreported(state: .running, failure: nil, login: nil),
            L10n.string("The automation ended without reporting a result.")
        )
        XCTAssertEqual(
            TriggerRunDiagnostic.unreported(state: .fixing, failure: nil, login: nil),
            L10n.string("The fix agent ended without reporting a final result.")
        )
    }

    // MARK: - The wire

    /// The line CLI 2.1.288 writes when the provider rejects a login, measured 2026-10-03.
    static let measuredAuthenticationLine = """
    {"type":"assistant","error":"authentication_failed","is_api_error_message":true,\
    "parent_tool_use_id":null,"session_id":"s","uuid":"u","message":{"model":"<synthetic>",\
    "content":[{"type":"text","text":"Failed to authenticate. API Error: 401 OAuth access token is invalid."}]}}
    """

    func testTheClaudeStreamsTypedFieldIsRead() {
        XCTAssertEqual(AgentTurnFailure.claudeStreamLine(Self.measuredAuthenticationLine), .authenticationFailed)
    }

    func testTheWordsAloneDecideNothing() {
        // The same sentence without the typed flag is ordinary assistant text.
        let prose = """
        {"type":"assistant","message":{"content":[{"type":"text",\
        "text":"Failed to authenticate. API Error: 401 OAuth access token is invalid."}]}}
        """
        XCTAssertNil(AgentTurnFailure.claudeStreamLine(prose))
        // A different typed class is not a login failure.
        XCTAssertNil(AgentTurnFailure.claudeStreamLine(
            Self.measuredAuthenticationLine.replacingOccurrences(of: "authentication_failed", with: "rate_limit")
        ))
        // The result line carries no class at all.
        XCTAssertNil(AgentTurnFailure.claudeStreamLine("""
        {"type":"result","subtype":"success","is_error":true,"api_error_status":401,"terminal_reason":"api_error"}
        """))
    }
}
