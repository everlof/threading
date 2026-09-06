import ThreadingRemoteKit
import XCTest

@testable import ThreadingMobile

/// What one refresh request costs, decided from what the phone already knows.
///
/// The audit of 4–5 Sep 2026 counted 384 full refreshes in a day, 158 within ten seconds of the
/// previous one, against an event socket that was delivering every row change. These pin the
/// two callers that produced most of them — a dashboard coming on screen and the scene
/// activating — to the answers that stop that, and everything that must still be paid in full.
final class MobileRefreshPolicyTests: XCTestCase {
    func testADashboardComingOnScreenAsksNothingWhileTheSocketDelivers() {
        XCTAssertEqual(
            MobileRefreshPolicy.decide(
                reason: .dashboardAppeared,
                hasCatalogue: true,
                eventSocketHealthy: true,
                canRefreshConditionally: true
            ),
            .skip
        )
    }

    func testADashboardWithoutItsSocketAsksCheaplyThenFully() {
        XCTAssertEqual(
            MobileRefreshPolicy.decide(
                reason: .dashboardAppeared,
                hasCatalogue: true,
                eventSocketHealthy: false,
                canRefreshConditionally: true
            ),
            .conditional
        )
        XCTAssertEqual(
            MobileRefreshPolicy.decide(
                reason: .dashboardAppeared,
                hasCatalogue: true,
                eventSocketHealthy: false,
                canRefreshConditionally: false
            ),
            .full
        )
    }

    /// A resume or a socket recovery re-validates the known route with one request rather than
    /// a race, even while a socket is healthy: the connectivity lanes wait for a refresh success
    /// after a resume, and a `304` records one.
    func testAForegroundOrRecoveryRevalidatesTheKnownRoute() {
        for reason in [MobileRefreshReason.foreground, .socketRecovery, .openTarget, .notificationOpen] {
            XCTAssertEqual(
                MobileRefreshPolicy.decide(
                    reason: reason,
                    hasCatalogue: true,
                    eventSocketHealthy: true,
                    canRefreshConditionally: true
                ),
                .conditional,
                reason.rawValue
            )
            XCTAssertEqual(
                MobileRefreshPolicy.decide(
                    reason: reason,
                    hasCatalogue: true,
                    eventSocketHealthy: false,
                    canRefreshConditionally: false
                ),
                .full,
                reason.rawValue
            )
        }
    }

    func testAnythingWithoutACatalogueIsAFullRefresh() {
        for reason in [
            MobileRefreshReason.dashboardAppeared, .foreground, .launch, .hostChanged, .pullToRefresh,
            .socketRecovery, .structuralChange, .revisionGap, .notificationOpen, .openTarget,
            .mutationFollowUp, .userCheck,
        ] {
            XCTAssertEqual(
                MobileRefreshPolicy.decide(
                    reason: reason,
                    hasCatalogue: false,
                    eventSocketHealthy: true,
                    canRefreshConditionally: true
                ),
                .full,
                reason.rawValue
            )
        }
    }

    /// A person asking, a structural change, a gap, and a host change are never cheapened.
    func testTheReasonsThatAlwaysEarnTheRace() {
        for reason in [
            MobileRefreshReason.launch, .hostChanged, .pullToRefresh, .structuralChange,
            .revisionGap, .mutationFollowUp, .userCheck,
        ] {
            XCTAssertEqual(
                MobileRefreshPolicy.decide(
                    reason: reason,
                    hasCatalogue: true,
                    eventSocketHealthy: true,
                    canRefreshConditionally: true
                ),
                .full,
                reason.rawValue
            )
        }
    }

    // MARK: - The edition a merged catalogue is at

    func testApplyingDeltasAdoptsTheNewestEditionOfTheSameEpoch() {
        let current = RemoteCatalogueRevisionDTO(epoch: "e1", revision: 4)
        let deltas = [
            RemoteSessionsChangedDTO(removedSessionID: "a", revision: .init(epoch: "e1", revision: 6)),
            RemoteSessionsChangedDTO(removedSessionID: "b", revision: .init(epoch: "e1", revision: 5)),
        ]

        XCTAssertEqual(
            RemoteMeDTO.editionAfterApplying(deltas, to: current),
            RemoteCatalogueRevisionDTO(epoch: "e1", revision: 6)
        )
        XCTAssertEqual(
            catalogue(revision: current).applying(deltas).revision?.revision,
            6
        )
    }

    /// A delta from another Mac process is a restart the phone slept through. Neither its rows
    /// nor this process's edition can be trusted; only a full scoped snapshot may cross epochs.
    func testADeltaFromAnotherEpochLosesTheEdition() {
        let current = RemoteCatalogueRevisionDTO(epoch: "e1", revision: 4)
        let deltas = [
            RemoteSessionsChangedDTO(
                session: session(id: "a", state: .needsAttention),
                revision: .init(epoch: "e2", revision: 1)
            ),
        ]
        let original = catalogue(revision: current, sessions: [session(id: "a", state: .idle)])
        let changed = original.applying(deltas)

        XCTAssertNil(RemoteMeDTO.editionAfterApplying(deltas, to: current))
        XCTAssertNil(changed.revision)
        XCTAssertEqual(changed.sessions, original.sessions)
    }

    /// An older Mac's deltas carry no edition and never answer `304`; nothing is lost by
    /// keeping whatever edition the catalogue had, and nothing is gained by advancing it.
    func testADeltaWithoutAnEditionKeepsTheCurrentOne() {
        let current = RemoteCatalogueRevisionDTO(epoch: "e1", revision: 4)
        let deltas = [RemoteSessionsChangedDTO(removedSessionID: "a")]

        XCTAssertEqual(RemoteMeDTO.editionAfterApplying(deltas, to: current), current)
        XCTAssertNil(catalogue(revision: nil).applying(deltas).revision)
    }

    @MainActor
    func testLocalThemeEditsKeepTheEdition() {
        let current = RemoteCatalogueRevisionDTO(epoch: "e1", revision: 4)
        let theme = RemoteAppModel.demoTheme

        XCTAssertEqual(catalogue(revision: current).replacing(theme: theme).revision, current)
    }

    func testAnAlreadyAppliedDeltaCannotOverwriteANewerSnapshot() {
        let current = RemoteCatalogueRevisionDTO(epoch: "e1", revision: 6)
        let original = catalogue(
            revision: current,
            sessions: [session(id: "a", state: .idle)]
        )
        let stale = RemoteSessionsChangedDTO(
            session: session(id: "a", state: .needsAttention),
            revision: .init(epoch: "e1", revision: 6)
        )

        XCTAssertEqual(original.applying([stale]), original)
    }

    func testACommittedCanonicalVisitCanHealAnEqualEditionRow() {
        let revision = RemoteCatalogueRevisionDTO(epoch: "e1", revision: 6)
        let original = catalogue(
            revision: revision,
            sessions: [session(id: "a", state: .needsAttention)]
        )
        let visit = RemoteSessionVisitedDTO(
            session: session(id: "a", state: .idle),
            revision: revision,
            receiptCommitted: true
        )

        let healed = original.applyingCanonicalVisit(visit)

        XCTAssertEqual(healed.sessions.first?.state, .idle)
        XCTAssertEqual(healed.revision, revision)
    }

    func testAnUncommittedVisitCannotClearAttention() {
        let revision = RemoteCatalogueRevisionDTO(epoch: "e1", revision: 6)
        let original = catalogue(
            revision: revision,
            sessions: [session(id: "a", state: .needsAttention)]
        )
        let visit = RemoteSessionVisitedDTO(
            session: session(id: "a", state: .idle),
            revision: revision,
            receiptCommitted: false
        )

        XCTAssertEqual(original.applyingCanonicalVisit(visit), original)
    }

    func testCoalescedDeltasApplyInEditionOrder() {
        let original = catalogue(
            revision: .init(epoch: "e1", revision: 4),
            sessions: [session(id: "a", state: .working)]
        )
        let updates = [
            RemoteSessionsChangedDTO(
                session: session(id: "a", state: .needsAttention),
                revision: .init(epoch: "e1", revision: 6)
            ),
            RemoteSessionsChangedDTO(
                session: session(id: "a", state: .idle),
                revision: .init(epoch: "e1", revision: 5)
            ),
        ]

        let changed = original.applying(updates)
        XCTAssertEqual(changed.sessions.count, 1)
        XCTAssertEqual(changed.sessions.first?.state, .needsAttention)
        XCTAssertEqual(changed.revision?.revision, 6)
    }

    // MARK: - Snapshot/stream continuity

    func testAStreamHelloIsHealthyOnlyWhenTheSnapshotMeetsItsFence() {
        var fence = MobileCatalogueStreamFence()
        fence.begin(
            RemoteCatalogueStreamHelloDTO(
                streamID: "stream-a",
                revision: .init(epoch: "e1", revision: 5)
            ),
            currentRevision: .init(epoch: "e1", revision: 4)
        )
        XCTAssertTrue(fence.requiresRefresh)

        fence.reconcile(currentRevision: .init(epoch: "e1", revision: 5))
        XCTAssertFalse(fence.requiresRefresh)
        XCTAssertEqual(fence.sequence, 0)
    }

    func testOneMissingFrameLatchesRefreshThroughTheFollowingTail() {
        var fence = MobileCatalogueStreamFence()
        fence.begin(
            RemoteCatalogueStreamHelloDTO(
                streamID: "stream-a",
                revision: .init(epoch: "e1", revision: 4)
            ),
            currentRevision: .init(epoch: "e1", revision: 4)
        )
        XCTAssertTrue(fence.accepts(RemoteSessionsChangedDTO(
            revision: .init(epoch: "e1", revision: 5),
            streamID: "stream-a",
            sequence: 1
        )))
        XCTAssertFalse(fence.accepts(RemoteSessionsChangedDTO(
            revision: .init(epoch: "e1", revision: 7),
            streamID: "stream-a",
            sequence: 3
        )))
        XCTAssertTrue(fence.requiresRefresh)
        XCTAssertEqual(fence.sequence, 3)
        XCTAssertFalse(fence.accepts(RemoteSessionsChangedDTO(
            revision: .init(epoch: "e1", revision: 8),
            streamID: "stream-a",
            sequence: 4
        )))

        fence.reconcile(currentRevision: .init(epoch: "e1", revision: 7))
        XCTAssertTrue(fence.requiresRefresh, "the later discarded tail is part of the fence")
        fence.reconcile(currentRevision: .init(epoch: "e1", revision: 8))
        XCTAssertFalse(fence.requiresRefresh)
    }

    func testAnotherStreamAndAFramedUpdateWithoutAHelloAreRefused() {
        var current = MobileCatalogueStreamFence()
        current.begin(
            RemoteCatalogueStreamHelloDTO(
                streamID: "stream-a",
                revision: .init(epoch: "e1", revision: 4)
            ),
            currentRevision: .init(epoch: "e1", revision: 4)
        )
        XCTAssertFalse(current.accepts(RemoteSessionsChangedDTO(
            revision: .init(epoch: "e1", revision: 5),
            streamID: "stream-b",
            sequence: 1
        )))
        XCTAssertTrue(current.requiresRefresh)

        var noHello = MobileCatalogueStreamFence()
        XCTAssertFalse(noHello.accepts(RemoteSessionsChangedDTO(
            revision: .init(epoch: "e1", revision: 5),
            streamID: "stream-a",
            sequence: 1
        )))
        XCTAssertTrue(noHello.requiresRefresh)
    }

    func testAFramedDeltaWithoutAnEditionIsARefreshGap() {
        var fence = MobileCatalogueStreamFence()
        fence.begin(
            RemoteCatalogueStreamHelloDTO(
                streamID: "stream-a",
                revision: .init(epoch: "e1", revision: 4)
            ),
            currentRevision: .init(epoch: "e1", revision: 4)
        )

        XCTAssertFalse(fence.accepts(RemoteSessionsChangedDTO(
            streamID: "stream-a",
            sequence: 1
        )))
        XCTAssertTrue(fence.requiresRefresh)
    }

    func testAnOlderUnframedHostKeepsItsCompatibilityLane() {
        var fence = MobileCatalogueStreamFence()
        XCTAssertTrue(fence.accepts(RemoteSessionsChangedDTO(removedSessionID: "a")))
        XCTAssertFalse(fence.requiresRefresh)
    }

    private func catalogue(
        revision: RemoteCatalogueRevisionDTO?,
        sessions: [RemoteSessionSummaryDTO] = []
    ) -> RemoteMeDTO {
        RemoteMeDTO(
            serverProtocol: RemoteProtocolInfo(),
            share: .init(label: "owner", scope: .all, capability: .interact, expiresAt: nil),
            sessions: sessions,
            revision: revision
        )
    }

    private func session(
        id: String,
        state: RemoteSessionActivity
    ) -> RemoteSessionSummaryDTO {
        RemoteSessionSummaryDTO(
            id: id,
            title: id,
            agentKind: "codex",
            surface: .conversation,
            state: state,
            projectName: "Threading"
        )
    }
}
