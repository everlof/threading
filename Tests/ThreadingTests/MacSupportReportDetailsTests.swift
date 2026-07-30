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
        previousLaunchWasClean: Bool? = nil
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
            previousLaunchWasClean: previousLaunchWasClean
        ).fields
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
            previousLaunchWasClean: true
        )

        let allowed: Set<String> = [
            "yes", "no", "none", "allowed", "not-allowed", "not-determined", "ocean"
        ]

        for (field, value) in fields {
            let isCount = !value.isEmpty && value.allSatisfy(\.isNumber)
            let isSummary = field == .agentAccountSummary
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
            previousLaunchWasClean: false
        )

        for (field, value) in fields {
            XCTAssertFalse(value.contains("/"), "\(field.rawValue) looks like a path: \(value)")
            XCTAssertFalse(value.contains("~"), "\(field.rawValue) names a home directory")
            XCTAssertFalse(value.contains("@"), "\(field.rawValue) may contain an address")
        }
    }
}
