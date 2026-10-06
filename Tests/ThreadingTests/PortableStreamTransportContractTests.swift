import XCTest
@testable import Threading

/// Runs the transport contract the Linux core harness runs, against the same production file.
@MainActor
final class PortableStreamTransportContractTests: XCTestCase {
    func testSharedLinuxAndMacStreamTransportContracts() async throws {
        try await runStreamTransportContracts()
    }
}
