#if os(Linux)
import Foundation
@testable import CoreSlice

/// Linux's lifecycle adapter for the same bounded policy used by the Mac host. The SDL loop
/// calls this at each wake; candidate collection happens only after a relevant edge or deadline.
@MainActor
final class LinuxNativeProcessRetention {
    private var lastVersion: UInt64?
    private var lastVisibleID: SessionID?
    private var nextEvaluationAt: Date?

    func retirementsIfNeeded(
        version: UInt64,
        visibleID: SessionID?,
        candidates: () -> [SessionProcessRetentionCandidate]
    ) -> Set<SessionID> {
        let now = Date()
        guard lastVersion != version || lastVisibleID != visibleID
                || nextEvaluationAt.map({ $0 <= now }) == true else { return [] }
        lastVersion = version
        lastVisibleID = visibleID
        let plan = SessionProcessRetentionPolicy.plan(
            candidates: candidates(),
            windowDays: LinuxGeneralSettings.sessionRestoreWindowDays,
            limit: LinuxGeneralSettings.sessionRestoreLimit,
            now: now)
        nextEvaluationAt = plan.nextEvaluationAt
        return plan.retire
    }

    var waitMilliseconds: Int32? {
        guard let nextEvaluationAt else { return nil }
        let milliseconds = max(1, ceil(nextEvaluationAt.timeIntervalSinceNow * 1_000))
        return Int32(min(milliseconds, Double(Int32.max)))
    }
}
#endif
