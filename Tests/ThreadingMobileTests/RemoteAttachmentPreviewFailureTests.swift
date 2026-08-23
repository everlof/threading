import Foundation
import XCTest
@testable import ThreadingMobile

final class RemoteAttachmentPreviewFailureTests: XCTestCase {
    func testTaskCancellationIsNotPresentedAsAPreviewFailure() {
        XCTAssertNil(RemoteAttachmentPreviewFailure.message(for: CancellationError()))
        XCTAssertNil(RemoteAttachmentPreviewFailure.message(for: URLError(.cancelled)))
    }

    func testRealFailureKeepsItsLocalizedReason() {
        let error = URLError(.notConnectedToInternet)

        XCTAssertEqual(
            RemoteAttachmentPreviewFailure.message(for: error),
            error.localizedDescription
        )
    }
}
