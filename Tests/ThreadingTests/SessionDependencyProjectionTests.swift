import XCTest
import ThreadingRemoteKit
@testable import Threading

final class SessionDependencyProjectionTests: XCTestCase {
    func testRemoteRowRetainsHostDependencyWhenProviderReportsNoBackgroundTask() throws {
        let runtime = SessionRuntimeSnapshot.test(activity: .idle)
            .awaiting(.awaitingSessionResult)
        let continuation = try XCTUnwrap(RemoteSessionContinuation(runtime))
        XCTAssertEqual(continuation, .sessionDependency)
        let encoded = try JSONEncoder().encode(continuation)
        XCTAssertEqual(try JSONDecoder().decode(RemoteSessionContinuation.self, from: encoded),
                       .sessionDependency)
        XCTAssertNil(RemoteSessionContinuation(.test(activity: .idle)))
    }

    func testProviderContinuationAndFutureWireKindsKeepTheirMeaning() throws {
        let runtime = SessionRuntimeSnapshot.test(activity: .idle, continuation: .delegated)
            .awaiting(.awaitingSessionResult)
        XCTAssertEqual(RemoteSessionContinuation(runtime), .delegated)
        let future = RemoteSessionContinuation.unknown("future-dependency")
        let encoded = try JSONEncoder().encode(future)
        XCTAssertEqual(try JSONDecoder().decode(RemoteSessionContinuation.self, from: encoded), future)
    }
}
