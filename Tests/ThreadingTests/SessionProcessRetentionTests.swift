@testable import Threading
import XCTest

@MainActor
final class SessionProcessRetentionTests: XCTestCase {
    func testKeepsFourMostRecentEligibleProcessesAndRetiresTheRest() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let candidates = (0 ..< 6).map { offset in
            candidate(
                lastUsedAt: now.addingTimeInterval(-TimeInterval(offset * 60)),
                id: SessionID()
            )
        }

        let plan = SessionProcessRetentionPolicy.plan(
            candidates: candidates,
            windowDays: 1,
            limit: 4,
            now: now
        )

        XCTAssertEqual(plan.warmIdleExpirations.count, 4)
        XCTAssertEqual(plan.retire, Set(candidates.suffix(2).map(\.sessionID)))
        XCTAssertEqual(
            plan.nextEvaluationAt,
            candidates[3].lastWarmUseAt.addingTimeInterval(
                SessionRestoreDefaults.secondsPerDay
            )
        )
    }

    func testLocalViewRefreshesWarmAgeAndRankingWithoutChangingConversationRecency() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let viewedID = SessionID()
        let oldConversationUse = now.addingTimeInterval(
            -2 * SessionRestoreDefaults.secondsPerDay
        )
        var recency = SessionProcessResidencyRecency()
        recency.noteLocalView(of: viewedID, at: now.addingTimeInterval(-30))

        let viewed = candidate(
            lastUsedAt: recency.lastWarmUseAt(
                for: viewedID,
                conversationUseAt: oldConversationUse
            ),
            id: viewedID
        )
        let other = (1 ... 4).map { offset in
            candidate(
                lastUsedAt: now.addingTimeInterval(-TimeInterval(offset * 60)),
                id: SessionID()
            )
        }

        let plan = SessionProcessRetentionPolicy.plan(
            candidates: [viewed] + other,
            windowDays: 1,
            limit: 4,
            now: now
        )

        XCTAssertEqual(
            viewed.lastWarmUseAt,
            now.addingTimeInterval(-30),
            "viewing affects process residency without mutating the durable work timestamp"
        )
        XCTAssertEqual(plan.retire, Set([other[3].sessionID]))
        XCTAssertEqual(
            plan.warmIdleExpirations[viewedID],
            now.addingTimeInterval(-30 + SessionRestoreDefaults.secondsPerDay)
        )

        recency.forget(viewedID)
        XCTAssertEqual(
            recency.lastWarmUseAt(for: viewedID, conversationUseAt: oldConversationUse),
            oldConversationUse
        )
    }

    func testAgeRetiresEligibleProcessEvenWhenWarmCapHasRoom() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let expired = candidate(
            lastUsedAt: now.addingTimeInterval(-SessionRestoreDefaults.secondsPerDay),
            id: SessionID()
        )

        let plan = SessionProcessRetentionPolicy.plan(
            candidates: [expired],
            windowDays: 1,
            limit: 4,
            now: now
        )

        XCTAssertEqual(plan.retire, Set([expired.sessionID]))
        XCTAssertTrue(plan.warmIdleExpirations.isEmpty)
    }

    func testSafetyGateProtectsEveryUncertainOrOutstandingState() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let old = now.addingTimeInterval(-2 * SessionRestoreDefaults.secondsPerDay)
        let protected = [
            candidate(lastUsedAt: old, isResumable: false),
            candidate(lastUsedAt: old, runtime: Self.snapshot(process: .starting)),
            candidate(lastUsedAt: old, runtime: Self.snapshot(reportsOwnTurns: false)),
            candidate(lastUsedAt: old, runtime: Self.snapshot(turn: .inFlight(.reported))),
            candidate(lastUsedAt: old, runtime: Self.snapshot(continuation: .delegated)),
            candidate(lastUsedAt: old, runtime: Self.snapshot(blocker: .awaitingUser)),
            candidate(lastUsedAt: old, isLocallyVisible: true),
            candidate(lastUsedAt: old, hasRemoteViewers: true),
            candidate(lastUsedAt: old, hasPendingInput: true),
            candidate(lastUsedAt: old, hasPendingCheckoutMove: true),
        ]

        let plan = SessionProcessRetentionPolicy.plan(
            candidates: protected,
            windowDays: 1,
            limit: 4,
            now: now
        )

        XCTAssertTrue(plan.retire.isEmpty)
        XCTAssertTrue(plan.warmIdleExpirations.isEmpty)
    }

    func testUnreadCompletionAndUsageLimitAreSafeToRetire() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let old = now.addingTimeInterval(-2 * SessionRestoreDefaults.secondsPerDay)
        let unread = candidate(
            lastUsedAt: old,
            runtime: Self.snapshot(activity: .needsAttention)
        )
        let limited = candidate(
            lastUsedAt: old,
            runtime: Self.snapshot(blocker: .usageLimit, activity: .limitReached)
        )

        let plan = SessionProcessRetentionPolicy.plan(
            candidates: [unread, limited],
            windowDays: 1,
            limit: 4,
            now: now
        )

        XCTAssertEqual(plan.retire, Set([unread.sessionID, limited.sessionID]))
    }

    func testQuitIgnoresLocalVisibilityButStillProtectsRemoteViewer() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let old = now.addingTimeInterval(-2 * SessionRestoreDefaults.secondsPerDay)
        let local = candidate(lastUsedAt: old, isLocallyVisible: true)
        let remote = candidate(lastUsedAt: old, hasRemoteViewers: true)

        let plan = SessionProcessRetentionPolicy.plan(
            candidates: [local, remote],
            windowDays: 1,
            limit: 4,
            now: now,
            protectsLocalVisibility: false
        )

        XCTAssertEqual(plan.retire, Set([local.sessionID]))
        XCTAssertFalse(plan.retire.contains(remote.sessionID))
    }

    func testCoordinatorReevaluatesWhenRetentionSettingChanges() {
        let center = NotificationCenter()
        let now = Date(timeIntervalSince1970: 2_000_000)
        var configuration = SessionProcessRetentionCoordinator.Configuration(
            windowDays: 2,
            limit: 4
        )
        let session = candidate(
            lastUsedAt: now.addingTimeInterval(-1.5 * SessionRestoreDefaults.secondsPerDay)
        )
        var retired: [SessionID] = []
        let coordinator = SessionProcessRetentionCoordinator(
            center: center,
            candidates: { [session] },
            configuration: { configuration },
            retire: { retired.append($0) },
            hasRemoteViewers: { _ in false },
            now: { now }
        )

        coordinator.start()
        XCTAssertTrue(retired.isEmpty)

        configuration = .init(windowDays: 1, limit: 4)
        center.post(AppSettingsDidChange(
            changedSetting: AppSettingIdentity.sessionRestoreWindowDays.rawValue
        ))

        XCTAssertEqual(retired, [session.sessionID])
        coordinator.stop()
    }

    func testQuitHandsOnlyWarmHostedIdleSessionsAnExpiry() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let warm = candidate(
            lastUsedAt: now.addingTimeInterval(-60),
            isHostBacked: true,
            isLocallyVisible: true
        )
        let stale = candidate(
            lastUsedAt: now.addingTimeInterval(-2 * SessionRestoreDefaults.secondsPerDay),
            isHostBacked: true
        )
        let remotelyViewed = candidate(
            lastUsedAt: now.addingTimeInterval(-60),
            isHostBacked: true,
            hasRemoteViewers: true
        )
        var live = [warm, stale, remotelyViewed]
        var retired: [SessionID] = []
        let coordinator = SessionProcessRetentionCoordinator(
            candidates: { live },
            configuration: { .init(windowDays: 1, limit: 4) },
            retire: { sessionID in
                retired.append(sessionID)
                live.removeAll { $0.sessionID == sessionID }
            },
            hasRemoteViewers: { $0 == remotelyViewed.sessionID },
            now: { now }
        )
        coordinator.start()

        let disposition = coordinator.prepareForQuit()

        XCTAssertEqual(retired, [stale.sessionID])
        XCTAssertEqual(disposition.warmHostSessionIDs, Set([warm.sessionID]))
        XCTAssertEqual(
            disposition.hostIdleExpirations[warm.sessionID],
            warm.lastWarmUseAt.addingTimeInterval(SessionRestoreDefaults.secondsPerDay)
        )
        XCTAssertNil(disposition.hostIdleExpirations[remotelyViewed.sessionID])
    }

    private func candidate(
        lastUsedAt: Date,
        id: SessionID = SessionID(),
        isResumable: Bool = true,
        isHostBacked: Bool = false,
        runtime: SessionRuntimeSnapshot? = nil,
        isLocallyVisible: Bool = false,
        hasRemoteViewers: Bool = false,
        hasPendingInput: Bool = false,
        hasPendingCheckoutMove: Bool = false
    ) -> SessionProcessRetentionCandidate {
        SessionProcessRetentionCandidate(
            sessionID: id,
            lastWarmUseAt: lastUsedAt,
            isResumable: isResumable,
            isHostBacked: isHostBacked,
            runtime: runtime ?? Self.snapshot(),
            isLocallyVisible: isLocallyVisible,
            hasRemoteViewers: hasRemoteViewers,
            hasPendingInput: hasPendingInput,
            hasPendingCheckoutMove: hasPendingCheckoutMove
        )
    }

    private static func snapshot(
        process: SessionProcessState = .ready,
        turn: SessionTurnState = .none,
        continuation: SessionContinuationState = .none,
        blocker: SessionRuntimeBlocker = .none,
        activity: SessionActivity = .idle,
        reportsOwnTurns: Bool = true
    ) -> SessionRuntimeSnapshot {
        SessionRuntimeSnapshot(
            process: process,
            turn: turn,
            continuation: continuation,
            blocker: blocker,
            activity: activity,
            reportsOwnTurns: reportsOwnTurns
        )
    }
}
