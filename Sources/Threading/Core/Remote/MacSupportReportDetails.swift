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
    private let automaticUpdateChecksEnabled: Bool
    private let appThemeID: String
    private let projectCount: Int
    private let sessionCount: Int
    private let extensionCount: Int
    private let companionCount: Int
    private let agentAccounts: [String: Int]
    private let previousLaunchWasClean: Bool?
    private let crashLoopDecision: CrashLoopDecision?
    private let launchLedgerRead: LaunchLedgerRead?
    private let metricKitDiagnostics: MetricKitDiagnosticReading?
    private let mainThreadStallIncidents: MainThreadStallIncidentReading?

    init(
        privacyStatuses: [SystemPrivacyPermission: SystemPrivacyStatus],
        remoteAccessEnabled: Bool,
        automaticUpdateChecksEnabled: Bool,
        appThemeID: String,
        projectCount: Int,
        sessionCount: Int,
        extensionCount: Int,
        companionCount: Int,
        agentAccounts: [String: Int],
        previousLaunchWasClean: Bool?,
        crashLoopDecision: CrashLoopDecision? = nil,
        launchLedgerRead: LaunchLedgerRead? = nil,
        metricKitDiagnostics: MetricKitDiagnosticReading? = nil,
        mainThreadStallIncidents: MainThreadStallIncidentReading? = nil
    ) {
        self.privacyStatuses = privacyStatuses
        self.remoteAccessEnabled = remoteAccessEnabled
        self.automaticUpdateChecksEnabled = automaticUpdateChecksEnabled
        self.appThemeID = appThemeID
        self.projectCount = projectCount
        self.sessionCount = sessionCount
        self.extensionCount = extensionCount
        self.companionCount = companionCount
        self.agentAccounts = agentAccounts
        self.previousLaunchWasClean = previousLaunchWasClean
        self.crashLoopDecision = crashLoopDecision
        self.launchLedgerRead = launchLedgerRead
        self.metricKitDiagnostics = metricKitDiagnostics
        self.mainThreadStallIncidents = mainThreadStallIncidents
    }

    // MARK: - Output

    var fields: [RemoteDiagnosticExtraField: String] {
        var fields: [RemoteDiagnosticExtraField: String] = [
            .remoteAccessEnabled: Self.flag(remoteAccessEnabled),
            .automaticUpdateChecks: Self.flag(automaticUpdateChecksEnabled),
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

        // The run of launches rather than the one before this. Absent on a machine with no ledger
        // at all, for the reason above: with nothing recorded, "normal" is not a finding, and a
        // field claiming one would be answering a question nobody could have asked yet.
        if let launchLedgerRead {
            fields[.launchLedger] = launchLedgerRead.token
            if let crashLoopDecision, launchLedgerRead != .missing {
                fields[.crashLoopDecision] = crashLoopDecision.token
                if let checkpoint = crashLoopDecision.lastReachedCheckpoint {
                    fields[.lastStartupCheckpoint] = checkpoint.rawValue
                }
            }
        }

        // The other half of that question, from Apple's side. `previousLaunchClean` says whether
        // *this* app came back; MetricKit says whether the system recorded a crash or a hang for
        // it, over a longer window than one launch. Absent when the payloads were not read at all,
        // for the same reason as above: a field is a claim, and there is nothing to claim yet.
        if let metricKitDiagnostics {
            fields[.metricKitDiagnostics] = Self.summary(of: metricKitDiagnostics)

            if case .read(let summary) = metricKitDiagnostics {
                if let window = Self.window(of: summary) {
                    fields[.metricKitWindow] = window
                }
                if let crash = summary.mostRecentCrash, let facts = Self.facts(of: crash) {
                    fields[.metricKitLastCrash] = facts
                }
            }
        }

        if let mainThreadStallIncidents {
            fields[.mainThreadStalls] = Self.summary(of: mainThreadStallIncidents)
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

    // MARK: - MetricKit
    //
    // Counts and a window, never the payloads. A crash's call tree is what makes those files
    // large and what makes them unsafe to hand over; what a support conversation needs is whether
    // MetricKit saw the crash at all, how many, and which build it hit.

    /// Every state is a distinct token, because "no payloads have ever arrived", "payloads arrived
    /// and recorded nothing" and "payloads arrived and could not be read" are three different
    /// facts, and only the first two are good news.
    private static func summary(of reading: MetricKitDiagnosticReading) -> String {
        switch reading {
        case .noDirectory:
            return "absent"
        case .empty:
            return "none"
        case .unreadable(let payloadFiles):
            return "unreadable payloads=\(payloadFiles)"
        case .read(let summary):
            return [
                "payloads=\(summary.payloadCount)",
                "crash=\(summary.crashCount)",
                "hang=\(summary.hangCount)",
                "cpu=\(summary.cpuExceptionCount)",
                "diskWrite=\(summary.diskWriteExceptionCount)",
                "unreadable=\(summary.unreadablePayloadCount)",
                "skipped=\(summary.skippedPayloadCount)"
            ].joined(separator: " ")
        }
    }

    /// The span the payloads cover, to the day and in UTC. MetricKit aggregates a prior period,
    /// so "crash=0" only means anything alongside the window it is a count over.
    private static func window(of summary: MetricKitDiagnosticSummary) -> String? {
        guard let from = summary.coveredFrom, let to = summary.coveredTo else { return nil }
        return "\(dayFormatter.string(from: from))..\(dayFormatter.string(from: to))"
    }

    /// The identifying facts of the newest crash, each already reduced to one token by the reader.
    private static func facts(of crash: MetricKitCrashFacts) -> String? {
        var parts: [String] = []
        if let value = crash.appVersion { parts.append("version=\(value)") }
        if let value = crash.appBuildVersion { parts.append("build=\(value)") }
        if let value = crash.exceptionType { parts.append("exception=\(value)") }
        if let value = crash.exceptionCode { parts.append("code=\(value)") }
        if let value = crash.signal { parts.append("signal=\(value)") }
        if let value = crash.terminationReason { parts.append("reason=\(value)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Immediate app watchdog findings. Operation names come from `StaticString` trace schema;
    /// the store re-validates their machine-token alphabet before they reach this boundary.
    private static func summary(of reading: MainThreadStallIncidentReading) -> String {
        switch reading {
        case .noDirectory:
            return "absent"
        case .empty:
            return "none"
        case .unreadable(let files):
            return "unreadable files=\(files)"
        case .read(let summary):
            var parts = [
                "incidents=\(summary.incidentCount)",
                "incomplete=\(summary.incompleteCount)",
                "longest_ms=\(summary.longestObservedMilliseconds)",
                "unreadable=\(summary.unreadableCount)",
                "skipped=\(summary.skippedCount)"
            ]
            if !summary.operationNames.isEmpty {
                parts.append("operations=\(summary.operationNames.joined(separator: ","))")
            }
            return parts.joined(separator: " ")
        }
    }

    /// Days rather than instants, and UTC rather than the reporter's zone: neither the hour a Mac
    /// crashed nor where in the world it is doing so belongs in a support field.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
