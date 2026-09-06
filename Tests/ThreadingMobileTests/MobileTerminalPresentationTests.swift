import SwiftUI
import ThreadingRemoteKit
import UIKit
import XCTest
@testable import ThreadingMobile

/// The three rules of what a terminal shows while its content is not yet the truth, and the
/// keyboard's memory. They were once right by accident and lost in a view change; here they
/// are a table.
final class MobileTerminalPresentationTests: XCTestCase {
    func testAnOpeningWithAPictureShowsItSoftenedAndTheLoaderOnlyAfterABeat() {
        XCTAssertEqual(
            TerminalSurfacePresentation.resolve(
                isLoading: true, keepsLiveScreen: false, hasSnapshot: true, waitedLongEnough: false
            ),
            .snapshot(showsLoader: false)
        )
        XCTAssertEqual(
            TerminalSurfacePresentation.resolve(
                isLoading: true, keepsLiveScreen: false, hasSnapshot: true, waitedLongEnough: true
            ),
            .snapshot(showsLoader: true)
        )
    }

    func testAnOpeningWithNoPictureShowsTheLoaderAtOnce() {
        let presentation = TerminalSurfacePresentation.resolve(
            isLoading: true, keepsLiveScreen: false, hasSnapshot: false, waitedLongEnough: false
        )
        XCTAssertEqual(presentation, .loader)
        XCTAssertTrue(presentation.showsLoader)
        XCTAssertFalse(presentation.delaysLoader)
    }

    func testAReturnToALiveScreenKeepsItSoftenedWithTheLoaderOnlyAfterABeat() {
        XCTAssertEqual(
            TerminalSurfacePresentation.resolve(
                isLoading: true, keepsLiveScreen: true, hasSnapshot: true, waitedLongEnough: false
            ),
            .lockedLive(showsLoader: false),
            "A live screen outranks a stale picture"
        )
        XCTAssertEqual(
            TerminalSurfacePresentation.resolve(
                isLoading: true, keepsLiveScreen: true, hasSnapshot: false, waitedLongEnough: true
            ),
            .lockedLive(showsLoader: true)
        )
    }

    func testNothingIsShownOverAScreenThatIsNotLoading() {
        for keeps in [false, true] {
            for snapshot in [false, true] {
                XCTAssertEqual(
                    TerminalSurfacePresentation.resolve(
                        isLoading: false, keepsLiveScreen: keeps, hasSnapshot: snapshot, waitedLongEnough: true
                    ),
                    .live
                )
            }
        }
    }

    func testTheKeyboardComesBackOnlyWhenLeftUpRecently() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let justNow = now.timeIntervalSince1970 - 60
        let anHourAgo = now.timeIntervalSince1970 - 3_600
        XCTAssertTrue(MobileTerminalKeyboardMemory.opensKeyboard(wasUp: true, leftAt: justNow, now: now))
        XCTAssertFalse(MobileTerminalKeyboardMemory.opensKeyboard(wasUp: true, leftAt: anHourAgo, now: now))
        XCTAssertFalse(MobileTerminalKeyboardMemory.opensKeyboard(wasUp: false, leftAt: justNow, now: now))
        XCTAssertFalse(MobileTerminalKeyboardMemory.opensKeyboard(wasUp: nil, leftAt: nil, now: now))
        XCTAssertFalse(
            MobileTerminalKeyboardMemory.opensKeyboard(wasUp: true, leftAt: nil, now: now),
            "A memory with no time on it has expired by definition"
        )
    }

    @MainActor
    func testTheSnapshotCacheKeepsAPictureOfAViewPerChat() {
        let cache = MobileTerminalSnapshotCache()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        view.backgroundColor = .red
        cache.keep(view, for: "chat-a")
        let image = cache.image(for: "chat-a")
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.scale, MobileTerminalSnapshotCache.captureScale)
        XCTAssertNil(cache.image(for: "chat-b"))
        cache.forget("chat-a")
        XCTAssertNil(cache.image(for: "chat-a"))
    }

    @MainActor
    func testTheSnapshotCacheIgnoresAViewWithNoSize() {
        let cache = MobileTerminalSnapshotCache()
        cache.keep(UIView(frame: .zero), for: "chat-a")
        XCTAssertNil(cache.image(for: "chat-a"))
    }
}

@MainActor
final class ProjectTerminalOpeningTests: XCTestCase {
    func testAvailabilitySelectsTheExplicitOpeningPhase() {
        XCTAssertEqual(
            ProjectTerminalOpeningPhase(isAvailable: false),
            .startingOnMac
        )
        XCTAssertEqual(
            ProjectTerminalOpeningPhase(isAvailable: true),
            .openingTerminal
        )
        XCTAssertEqual(
            ProjectTerminalOpeningPhase.startingOnMac.message,
            MobileL10n.string("Starting terminal on your Mac…")
        )
    }

    func testOnlyTheInstalledAttemptOwnsOpeningWork() throws {
        let installed = try ProjectTerminalOpeningAttemptID(
            rawValue: XCTUnwrap(
                UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
            )
        )
        let stale = try ProjectTerminalOpeningAttemptID(
            rawValue: XCTUnwrap(
                UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
            )
        )
        let state = ProjectTerminalOpeningState.opening(ProjectTerminalOpeningAttempt(
            id: installed,
            phase: .startingOnMac
        ))

        XCTAssertTrue(state.owns(installed))
        XCTAssertFalse(state.owns(stale))
    }

    func testConnectionOpeningSettlesOnlyAfterHydration() {
        XCTAssertEqual(
            ProjectTerminalConnectionOpeningOutcome.resolve(
                phase: .connecting,
                isTerminalHydrating: true
            ),
            .pending
        )
        XCTAssertEqual(
            ProjectTerminalConnectionOpeningOutcome.resolve(
                phase: .connected,
                isTerminalHydrating: true
            ),
            .pending
        )
        XCTAssertEqual(
            ProjectTerminalConnectionOpeningOutcome.resolve(
                phase: .connected,
                isTerminalHydrating: false
            ),
            .ready
        )
    }

    func testConnectionFailureReplacesOpeningProgressWithItsTypedFailure() {
        let failure = RemoteConnectionFailure(
            cause: .transport,
            message: "The connection closed."
        )

        XCTAssertEqual(
            ProjectTerminalConnectionOpeningOutcome.resolve(
                phase: .failed(failure),
                isTerminalHydrating: true
            ),
            .failed(.connection(failure))
        )
        XCTAssertEqual(
            ProjectTerminalConnectionOpeningOutcome.resolve(
                phase: .ended("The terminal ended."),
                isTerminalHydrating: true
            ),
            .failed(.ended("The terminal ended."))
        )
    }

    func testLoadingPlaceholderRetainsOneMorphLabelAndItsFrameWhenPhaseChanges() throws {
        let model = LoadingMessageModel()
        let controller = UIHostingController(rootView: LoadingHarness(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        settle(window)
        let initial = try XCTUnwrap(first(MobileMorphingTitleLabel.self, in: window))
        let initialFrame = initial.convert(initial.bounds, to: window)
        XCTAssertEqual(initial.stringValue, MobileL10n.string("Starting terminal on your Mac…"))
        XCTAssertEqual(all(MobileMorphingTitleLabel.self, in: window).count, 1)

        model.message = MobileL10n.string("Opening terminal…")
        settle(window)

        let changed = try XCTUnwrap(first(MobileMorphingTitleLabel.self, in: window))
        XCTAssertTrue(initial === changed, "a phase change must update the retained MorphLabel")
        XCTAssertEqual(changed.stringValue, MobileL10n.string("Opening terminal…"))
        XCTAssertEqual(changed.convert(changed.bounds, to: window), initialFrame)
        XCTAssertTrue(changed.isAnimatingTitleForTesting)
        XCTAssertEqual(all(MobileMorphingTitleLabel.self, in: window).count, 1)
    }

    private func settle(_ window: UIWindow) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
    }

    private func first<ViewType: UIView>(
        _ type: ViewType.Type,
        in root: UIView
    ) -> ViewType? {
        if let match = root as? ViewType { return match }
        return root.subviews.lazy.compactMap { self.first(type, in: $0) }.first
    }

    private func all<ViewType: UIView>(
        _ type: ViewType.Type,
        in root: UIView
    ) -> [ViewType] {
        let current = (root as? ViewType).map { [$0] } ?? []
        return current + root.subviews.flatMap { self.all(type, in: $0) }
    }
}

@MainActor
private final class LoadingMessageModel: ObservableObject {
    @Published var message = MobileL10n.string("Starting terminal on your Mac…")
}

private struct LoadingHarness: View {
    @ObservedObject var model: LoadingMessageModel

    var body: some View {
        MobileLoadingPlaceholder(model.message)
    }
}
