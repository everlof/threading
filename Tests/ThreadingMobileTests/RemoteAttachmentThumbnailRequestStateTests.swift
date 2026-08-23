import XCTest
@testable import ThreadingMobile

final class RemoteAttachmentThumbnailRequestStateTests: XCTestCase {
    func testSuccessfulThumbnailCanLoadAgainAfterCacheEviction() {
        var state = RemoteAttachmentThumbnailRequestState()

        XCTAssertTrue(state.begin(id: "attachment", isCached: false))
        state.finish(id: "attachment", outcome: .success)
        XCTAssertFalse(state.begin(id: "attachment", isCached: true))
        XCTAssertTrue(state.begin(id: "attachment", isCached: false))
    }

    func testFailedThumbnailRemainsSuppressedAfterItLeavesTheCache() {
        var state = RemoteAttachmentThumbnailRequestState()

        XCTAssertTrue(state.begin(id: "attachment", isCached: false))
        state.finish(id: "attachment", outcome: .failure)

        XCTAssertFalse(state.begin(id: "attachment", isCached: false))
    }

    func testCancelledThumbnailCanBeRetried() {
        var state = RemoteAttachmentThumbnailRequestState()

        XCTAssertTrue(state.begin(id: "attachment", isCached: false))
        state.finish(id: "attachment", outcome: .cancelled)

        XCTAssertTrue(state.begin(id: "attachment", isCached: false))
    }
}
