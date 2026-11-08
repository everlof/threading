import XCTest
@testable import ThreadingAndroidKit

final class GRPCChannelLifecycleTests: XCTestCase {
    func testClosedChannelRefusesConnectionWithoutWaitingForItsDeadline() async {
        let channel = GRPCChannel(port: 1)
        channel.close()
        do {
            try await channel.connect(timeout: 0.05)
            XCTFail("A closed channel must not open a new connection")
        } catch {
            XCTAssertEqual(error as? GRPCChannel.Failure, .connectionLost("closed by Threading"))
        }
    }
}
