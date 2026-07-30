import Foundation
import ThreadingRemoteKit

/// The Mac host's contribution to a support report.
///
/// `RemoteDiagnosticJournal` already writes app version, build, OS and protocol versions, and
/// bounds every value it is handed. What it could not know is the state that actually explains
/// most reports: which OS grants Threading holds, how much is installed, and whether the last
/// launch ended cleanly. Those were the questions being asked by hand over a support thread.
///
/// **Everything here is a count, an enum case, or a version string.** No project or session
/// names, no paths, no prompts, no extension identifiers. That is not a scrubbing pass that
/// could miss something — it is the shape of the data. It is what lets someone send this file
/// without reading it first, and it is the same rule `MacRemoteDiagnostics` states for the
/// journal it sits beside.
@MainActor
struct MacSupportReportDetails {

    // MARK: - Inputs
    //
    // Injected for the same reason `SystemPrivacyStatusReader` injects its probes: a test must
    // assert on stated inputs, not on whatever this particular Mac has approved and installed.

    private let privacyStatuses: [SystemPrivacyPermission: SystemPrivacyStatus]
    private let remoteAccessEnabled: Bool
    private let appThemeID: String
    private let projectCount: Int
    private let sessionCount: Int
    private let extensionCount: Int
    private let companionCount: Int
    private let agentAccounts: [String: Int]
    private let previousLaunchWasClean: Bool?

    init(
        privacyStatuses: [SystemPrivacyPermission: SystemPrivacyStatus],
        remoteAccessEnabled: Bool,
        appThemeID: String,
        projectCount: Int,
        sessionCount: Int,
        extensionCount: Int,
        companionCount: Int,
        agentAccounts: [String: Int],
        previousLaunchWasClean: Bool?
    ) {
        self.privacyStatuses = privacyStatuses
        self.remoteAccessEnabled = remoteAccessEnabled
        self.appThemeID = appThemeID
        self.projectCount = projectCount
        self.sessionCount = sessionCount
        self.extensionCount = extensionCount
        self.companionCount = companionCount
        self.agentAccounts = agentAccounts
        self.previousLaunchWasClean = previousLaunchWasClean
    }

    // MARK: - Output

    var fields: [RemoteDiagnosticExtraField: String] {
        var fields: [RemoteDiagnosticExtraField: String] = [
            .remoteAccessEnabled: Self.flag(remoteAccessEnabled),
            .appThemeID: appThemeID,
            .projectCount: String(projectCount),
            .sessionCount: String(sessionCount),
            .extensionCount: String(extensionCount),
            .extensionCompanionCount: String(companionCount),
            .agentAccountSummary: Self.summary(of: agentAccounts)
        ]

        // The grant rows are the point of the exercise: "the companion cannot capture the
        // screen" and "no notifications arrive" are both answered here rather than by asking.
        if let notifications = privacyStatuses[.notifications] {
            fields[.notificationAuthorization] = Self.token(for: notifications)
        }
        if let accessibility = privacyStatuses[.accessibility] {
            fields[.accessibilityAuthorization] = Self.token(for: accessibility)
        }
        if let screenRecording = privacyStatuses[.screenRecording] {
            fields[.screenRecordingAuthorization] = Self.token(for: screenRecording)
        }

        // Absent rather than "unknown": a first launch has no previous launch to judge, and a
        // field claiming otherwise would read as a crash that never happened.
        if let previousLaunchWasClean {
            fields[.previousLaunchClean] = Self.flag(previousLaunchWasClean)
        }

        return fields
    }

    // MARK: - Formatting

    /// Machine-stable tokens, not the localized labels. A support report is read by whoever is
    /// helping, whose language need not match the reporter's.
    private static func token(for status: SystemPrivacyStatus) -> String {
        switch status {
        case .allowed: return "allowed"
        case .notAllowed: return "not-allowed"
        case .askedWhenNeeded: return "not-determined"
        }
    }

    private static func flag(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    /// Agent kinds and how many logins each has — never which logins. "claude=2 codex=1" says
    /// enough to explain a routing problem without naming an account.
    private static func summary(of accounts: [String: Int]) -> String {
        guard !accounts.isEmpty else { return "none" }
        return accounts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }
}
