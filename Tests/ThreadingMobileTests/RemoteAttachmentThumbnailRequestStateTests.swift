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

    /// A refusal is the Mac's answer about the attachment, and the Mac has not changed.
    func testFailedThumbnailRemainsSuppressedAfterItLeavesTheCacheAndAcrossRouteMoves() {
        var state = RemoteAttachmentThumbnailRequestState()

        XCTAssertTrue(state.begin(id: "attachment", isCached: false))
        state.finish(id: "attachment", outcome: .failure)

        XCTAssertFalse(state.begin(id: "attachment", isCached: false))
        state.forgetTransientFailures()
        XCTAssertFalse(state.begin(id: "attachment", isCached: false))
    }

    /// A lost connection is an answer about the moment, not the attachment. It is not asked
    /// again on the same route in the same breath, and it is asked again once the route moves.
    func testATransientFailureIsAskedAgainAfterTheRouteMoves() {
        var state = RemoteAttachmentThumbnailRequestState()

        XCTAssertTrue(state.begin(id: "attachment", isCached: false))
        state.finish(id: "attachment", outcome: .transientFailure)
        XCTAssertFalse(state.begin(id: "attachment", isCached: false))

        state.forgetTransientFailures()
        XCTAssertTrue(state.begin(id: "attachment", isCached: false))
    }

    func testCancelledThumbnailCanBeRetried() {
        var state = RemoteAttachmentThumbnailRequestState()

        XCTAssertTrue(state.begin(id: "attachment", isCached: false))
        state.finish(id: "attachment", outcome: .cancelled)

        XCTAssertTrue(state.begin(id: "attachment", isCached: false))
    }
}
