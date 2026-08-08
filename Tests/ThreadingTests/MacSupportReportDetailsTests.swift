import Foundation
import ThreadingRemoteKit
import XCTest
@testable import Threading

/// A support report is meant to be handed to someone else without being read first. That is only
/// true if its shape guarantees it, so what is pinned here is mostly what must *not* appear.
@MainActor
final class MacSupportReportDetailsTests: XCTestCase {

    private func details(
        privacyStatuses: [SystemPrivacyPermission: SystemPrivacyStatus] = [:],
        remoteAccessEnabled: Bool = false,
        automaticUpdateChecksEnabled: Bool = true,
        appThemeID: String = "system",
        projectCount: Int = 0,
        sessionCount: Int = 0,
        extensionCount: Int = 0,
        companionCount: Int = 0,
        agentAccounts: [String: Int] = [:],
        previousLaunchWasClean: Bool? = nil,
        crashLoopDecision: CrashLoopDecision? = nil,
        launchLedgerRead: LaunchLedgerRead? = nil,
        metricKitDiagnostics: MetricKitDiagnosticReading? = nil
    ) -> [RemoteDiagnosticExtraField: String] {
        MacSupportReportDetails(
            privacyStatuses: privacyStatuses,
            remoteAccessEnabled: remoteAccessEnabled,
            automaticUpdateChecksEnabled: automaticUpdateChecksEnabled,
            appThemeID: appThemeID,
            projectCount: projectCount,
            sessionCount: sessionCount,
            extensionCount: extensionCount,
            companionCount: companionCount,
            agentAccounts: agentAccounts,
            previousLaunchWasClean: previousLaunchWasClean,
            crashLoopDecision: crashLoopDecision,
            launchLedgerRead: launchLedgerRead,
            metricKitDiagnostics: metricKitDiagnostics
        ).fields
    }

    private func summary(
        payloadCount: Int = 1,
        unreadablePayloadCount: Int = 0,
        skippedPayloadCount: Int = 0,
        crashCount: Int = 0,
        hangCount: Int = 0,
        cpuExceptionCount: Int = 0,
        diskWriteExceptionCount: Int = 0,
        coveredFrom: Date? = nil,
        coveredTo: Date? = nil,
        mostRecentCrash: MetricKitCrashFacts? = nil
    ) -> MetricKitDiagnosticSummary {
        MetricKitDiagnosticSummary(
            payloadCount: payloadCount,
            unreadablePayloadCount: unreadablePayloadCount,
            skippedPayloadCount: skippedPayloadCount,
            crashCount: crashCount,
            hangCount: hangCount,
            cpuExceptionCount: cpuExceptionCount,
            diskWriteExceptionCount: diskWriteExceptionCount,
            coveredFrom: coveredFrom,
            coveredTo: coveredTo,
            mostRecentCrash: mostRecentCrash
        )
    }

    private static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso) ?? .distantPast
    }

    // MARK: - The Grants

    /// The two questions this exists to answer without a round trip: "no notifications arrive"
    /// and "the companion cannot capture the screen".
    func testEachReadableGrantIsReportedAsAStableToken() {
        let fields = details(privacyStatuses: [
            .notifications: .allowed,
            .accessibility: .notAllowed,
            .screenRecording: .askedWhenNeeded
        ])

        XCTAssertEqual(fields[.notificationAuthorization], "allowed")
        XCTAssertEqual(fields[.accessibilityAuthorization], "not-allowed")
        XCTAssertEqual(fields[.screenRecordingAuthorization], "not-determined")
    }

    /// Localized labels would make a report unreadable to whoever is helping, whose language
    /// need not match the reporter's. The tokens above are deliberately not `status.label`.
    func testGrantTokensAreNotTheLocalizedLabels() {
        let fields = details(privacyStatuses: [.notifications: .allowed])
        XCTAssertNotEqual(fields[.notificationAuthorization], SystemPrivacyStatus.allowed.label)
    }

    func testAGrantThatWasNotReadIsAbsentRatherThanGuessed() {
        let fields = details(privacyStatuses: [.notifications: .allowed])
        XCTAssertNil(fields[.accessibilityAuthorization])
        XCTAssertNil(fields[.screenRecordingAuthorization])
    }

    // MARK: - First Launch

    /// A first launch has no previous launch to judge. Reporting "not clean" would read as a
    /// crash that never happened.
    func testAFirstLaunchOmitsThePreviousLaunchVerdict() {
        XCTAssertNil(details(previousLaunchWasClean: nil)[.previousLaunchClean])
        XCTAssertEqual(details(previousLaunchWasClean: true)[.previousLaunchClean], "yes")
        XCTAssertEqual(details(previousLaunchWasClean: false)[.previousLaunchClean], "no")
    }

    // MARK: - The Launch History

    /// `previousLaunchClean` describes the one launch before this one; these describe the run of
    /// them. A machine with no ledger at all reports nothing: with nothing recorded, "normal" is
    /// not a finding, and a field is a claim.
    func testAMachineWithNoLedgerReportsNoLaunchHistoryAtAll() {
        let fields = details(crashLoopDecision: .launchNormally(.available))

        XCTAssertNil(fields[.launchLedger])
        XCTAssertNil(fields[.crashLoopDecision])
        XCTAssertNil(fields[.lastStartupCheckpoint])
    }

    /// The ledger's own state is reported even when there is no verdict to draw from it, because
    /// "nothing has happened" and "this build could not read what happened" are the finding.
    func testAMissingLedgerIsSaidWithoutAVerdictBesideIt() {
        let fields = details(
            crashLoopDecision: .launchNormally(.available),
            launchLedgerRead: .missing
        )

        XCTAssertEqual(fields[.launchLedger], "missing")
        XCTAssertNil(fields[.crashLoopDecision])
    }

    func testACrashLoopIsReportedWithTheCheckpointTheLastLaunchReached() {
        let fields = details(
            crashLoopDecision: .recommendRecoveryMode(
                consecutive: 2,
                lastCheckpoint: .mainWindowConstructed
            ),
            launchLedgerRead: .valid(LaunchLedgerHistory())
        )

        XCTAssertEqual(fields[.crashLoopDecision], "recovery-recommended consecutive=2")
        XCTAssertEqual(fields[.lastStartupCheckpoint], "mainWindowConstructed")
        XCTAssertEqual(fields[.launchLedger], "valid launches=0")
    }

    /// Every value here is a count or an enum word. A quarantine path would be the first user
    /// directory layout in a file that is meant to be sendable without being read.
    func testTheLaunchHistoryFieldsNameNoPath() throws {
        let fields = details(
            crashLoopDecision: .launchNormally(.unreadable),
            launchLedgerRead: .corrupt(
                quarantinedAt: URL(fileURLWithPath: "/Users/someone/Library/launch-ledger.jsonl")
            )
        )

        for value in [fields[.launchLedger], fields[.crashLoopDecision]] {
            XCTAssertFalse(try XCTUnwrap(value).contains("/"))
        }
        XCTAssertEqual(fields[.launchLedger], "corrupt quarantined=yes")
        XCTAssertEqual(fields[.crashLoopDecision], "normal history=unreadable")
    }

    // MARK: - Counts

    func testInventoryIsReportedAsCounts() {
        let fields = details(
            remoteAccessEnabled: true,
            projectCount: 12,
            sessionCount: 340,
            extensionCount: 3,
            companionCount: 1
        )

        XCTAssertEqual(fields[.remoteAccessEnabled], "yes")
        XCTAssertEqual(fields[.automaticUpdateChecks], "yes")
        XCTAssertEqual(fields[.projectCount], "12")
        XCTAssertEqual(fields[.sessionCount], "340")
        XCTAssertEqual(fields[.extensionCount], "3")
        XCTAssertEqual(fields[.extensionCompanionCount], "1")
    }

    /// Agent kinds and how many logins each has — never which logins.
    func testAgentAccountsAreSummarisedByKindAndCount() {
        XCTAssertEqual(
            details(agentAccounts: ["codex": 1, "claude": 2])[.agentAccountSummary],
            "claude=2 codex=1"
        )
        XCTAssertEqual(details(agentAccounts: [:])[.agentAccountSummary], "none")
    }

    // MARK: - MetricKit

    /// Apple's payloads were write-only sediment until the report read them back. The point of
    /// carrying them here is that four different findings must stay four different strings.
    func testEachMetricKitOutcomeIsItsOwnToken() {
        XCTAssertEqual(details(metricKitDiagnostics: .noDirectory)[.metricKitDiagnostics], "absent")
        XCTAssertEqual(details(metricKitDiagnostics: .empty)[.metricKitDiagnostics], "none")
        XCTAssertEqual(
            details(metricKitDiagnostics: .unreadable(payloadFiles: 3))[.metricKitDiagnostics],
            "unreadable payloads=3"
        )
    }

    /// The counts a support conversation actually asks for: did MetricKit see a crash, a hang, or
    /// nothing at all, and did any payload fail to parse while it was answering.
    func testAReadingIsReportedAsCounts() {
        let fields = details(metricKitDiagnostics: .read(summary(
            payloadCount: 4,
            unreadablePayloadCount: 1,
            skippedPayloadCount: 2,
            crashCount: 2,
            hangCount: 3,
            cpuExceptionCount: 1,
            diskWriteExceptionCount: 0
        )))

        XCTAssertEqual(
            fields[.metricKitDiagnostics],
            "payloads=4 crash=2 hang=3 cpu=1 diskWrite=0 unreadable=1 skipped=2"
        )
    }

    /// A count is only meaningful over the window it counts, and MetricKit's window is not the
    /// app's. Days and UTC: neither the hour a Mac crashed nor its time zone is anyone's business.
    func testTheCoveredWindowIsReportedInWholeUTCDays() {
        let fields = details(metricKitDiagnostics: .read(summary(
            coveredFrom: Self.date("2026-07-30T23:30:00Z"),
            coveredTo: Self.date("2026-08-05T01:00:00Z")
        )))

        XCTAssertEqual(fields[.metricKitWindow], "2026-07-30..2026-08-05")
    }

    func testAWindowThatCouldNotBeDatedIsOmittedRatherThanGuessed() {
        XCTAssertNil(details(metricKitDiagnostics: .read(summary()))[.metricKitWindow])
        XCTAssertNil(details(metricKitDiagnostics: .empty)[.metricKitWindow])
    }

    /// Enough to know whether MetricKit saw *this* crash and which build it hit. Not a call tree.
    func testTheMostRecentCrashIsReportedAsIdentifyingFacts() {
        let fields = details(metricKitDiagnostics: .read(summary(
            crashCount: 1,
            mostRecentCrash: MetricKitCrashFacts(
                appVersion: "1.4.2",
                appBuildVersion: "311",
                exceptionType: 1,
                exceptionCode: 0,
                signal: 11,
                terminationReason: "Namespace-SIGNAL-Code-0xb"
            )
        )))

        XCTAssertEqual(
            fields[.metricKitLastCrash],
            "version=1.4.2 build=311 exception=1 code=0 signal=11 reason=Namespace-SIGNAL-Code-0xb"
        )
    }

    func testAReadingWithNoCrashOmitsTheCrashField() {
        XCTAssertNil(
            details(metricKitDiagnostics: .read(summary(hangCount: 2)))[.metricKitLastCrash]
        )
    }

    /// Absent rather than "unknown", the same rule the previous-launch verdict follows: a field is
    /// a claim, and a report that never read the payloads has nothing to claim.
    func testPayloadsThatWereNotReadLeaveEveryMetricKitFieldOut() {
        let fields = details(metricKitDiagnostics: nil)
        XCTAssertNil(fields[.metricKitDiagnostics])
        XCTAssertNil(fields[.metricKitWindow])
        XCTAssertNil(fields[.metricKitLastCrash])
    }

    // MARK: - What Must Not Be There
    //
    // The load-bearing test. Everything above could pass while the report still carried a
    // project name, and nobody would notice until a report had already been sent.

    func testNoFieldCarriesFreeformUserContent() {
        let fields = details(
            privacyStatuses: [
                .notifications: .allowed,
                .accessibility: .allowed,
                .screenRecording: .notAllowed
            ],
            remoteAccessEnabled: true,
            appThemeID: "ocean",
            projectCount: 4,
            sessionCount: 9,
            extensionCount: 2,
            companionCount: 1,
            agentAccounts: ["claude": 1],
            previousLaunchWasClean: true,
            metricKitDiagnostics: .read(summary(
                crashCount: 1,
                coveredFrom: Self.date("2026-07-30T00:00:00Z"),
                coveredTo: Self.date("2026-08-05T00:00:00Z"),
                mostRecentCrash: MetricKitCrashFacts(
                    appVersion: "1.4.2",
                    appBuildVersion: "311",
                    exceptionType: 1,
                    exceptionCode: 0,
                    signal: 11,
                    terminationReason: "Namespace-SIGNAL-Code-0xb"
                )
            ))
        )

        let allowed: Set<String> = [
            "yes", "no", "none", "allowed", "not-allowed", "not-determined", "ocean"
        ]

        // The fields whose shape is `key=value` pairs or a dated window rather than one token.
        // They are named here rather than pattern-matched so a new free-form field cannot join
        // them by accident.
        let structured: Set<RemoteDiagnosticExtraField> = [
            .agentAccountSummary, .metricKitDiagnostics, .metricKitWindow, .metricKitLastCrash
        ]

        for (field, value) in fields {
            let isCount = !value.isEmpty && value.allSatisfy(\.isNumber)
            let isSummary = structured.contains(field)
            XCTAssertTrue(
                allowed.contains(value) || isCount || isSummary,
                "\(field.rawValue) = \"\(value)\" is neither a count nor a known token, so it "
                    + "may be carrying content that should not leave the machine"
            )
        }
    }

    func testNoFieldContainsAPathOrHomeDirectory() {
        let fields = details(
            appThemeID: "system",
            projectCount: 1,
            agentAccounts: ["claude": 1],
            previousLaunchWasClean: false,
            // MetricKit's own strings are the newest way a path could reach this file: a
            // termination reason is written by macOS, not by us, and a later release could put
            // anything in it. The reader reduces it to one token; this is what says so.
            metricKitDiagnostics: .read(summary(
                crashCount: 1,
                coveredFrom: Self.date("2026-07-30T00:00:00Z"),
                coveredTo: Self.date("2026-08-05T00:00:00Z"),
                mostRecentCrash: MetricKitCrashFacts(
                    appVersion: "1.4.2",
                    appBuildVersion: "311",
                    exceptionType: 1,
                    exceptionCode: 0,
                    signal: 11,
                    terminationReason: "Namespace-SIGNAL-Code-0xb"
                )
            ))
        )

        for (field, value) in fields {
            XCTAssertFalse(value.contains("/"), "\(field.rawValue) looks like a path: \(value)")
            XCTAssertFalse(value.contains("~"), "\(field.rawValue) names a home directory")
            XCTAssertFalse(value.contains("@"), "\(field.rawValue) may contain an address")
        }
    }
}
