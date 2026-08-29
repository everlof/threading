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
