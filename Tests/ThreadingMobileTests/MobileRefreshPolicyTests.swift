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

    /// A delta from another Mac process is a restart the phone slept through. The rows apply,
    /// but the catalogue no longer knows its edition, so the next refresh is a full one.
    func testADeltaFromAnotherEpochLosesTheEdition() {
        let current = RemoteCatalogueRevisionDTO(epoch: "e1", revision: 4)
        let deltas = [
            RemoteSessionsChangedDTO(removedSessionID: "a", revision: .init(epoch: "e2", revision: 1)),
        ]

        XCTAssertNil(RemoteMeDTO.editionAfterApplying(deltas, to: current))
        XCTAssertNil(catalogue(revision: current).applying(deltas).revision)
    }

    /// An older Mac's deltas carry no edition and never answer `304`; nothing is lost by
    /// keeping whatever edition the catalogue had, and nothing is gained by advancing it.
    func testADeltaWithoutAnEditionKeepsTheCurrentOne() {
        let current = RemoteCatalogueRevisionDTO(epoch: "e1", revision: 4)
        let deltas = [RemoteSessionsChangedDTO(removedSessionID: "a")]

        XCTAssertEqual(RemoteMeDTO.editionAfterApplying(deltas, to: current), current)
        XCTAssertNil(catalogue(revision: nil).applying(deltas).revision)
    }

    func testLocalThemeEditsKeepTheEdition() {
        let current = RemoteCatalogueRevisionDTO(epoch: "e1", revision: 4)
        let theme = RemoteAppModel.demoTheme

        XCTAssertEqual(catalogue(revision: current).replacing(theme: theme).revision, current)
    }

    private func catalogue(revision: RemoteCatalogueRevisionDTO?) -> RemoteMeDTO {
        RemoteMeDTO(
            serverProtocol: RemoteProtocolInfo(),
            share: .init(label: "owner", scope: .all, capability: .interact, expiresAt: nil),
            sessions: [],
            revision: revision
        )
    }
}
