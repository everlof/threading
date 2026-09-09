import XCTest
@testable import ThreadingRemoteKit

final class RemoteUsageCapacityTests: XCTestCase {
    func testObservationSurvivesRoundTripAndEqualLabelsKeepDistinctIdentity() throws {
        let accounts = ["claude", "codex"].map { runtime in
            RemoteUsageCapacityAccountDTO(runtimeID: runtime, runtimeName: "Agent",
                accountID: "default", accountName: "Personal", observedAt: 1_780_000_000,
                state: .stale, windows: [.init(id: "week", name: "Week", fraction: 0.5)])
        }
        let value = RemoteUsageCapacityDTO(epoch: UUID().uuidString, revision: 42, accounts: accounts)
        let restored = try RemoteUsageCapacityDTO.decode(JSONEncoder().encode(value))
        XCTAssertEqual(restored, value)
        XCTAssertNotEqual(accounts[0].id, accounts[1].id)
    }

    func testUntrustedCapacityIsBoundedAndValidated() throws {
        XCTAssertThrowsError(try RemoteUsageCapacityDTO.decode(Data(repeating: 32, count: 128 * 1024 + 1)))
        let bad = RemoteUsageCapacityAccountDTO(runtimeID: "codex", runtimeName: "Codex",
            accountID: "default", accountName: "Personal", observedAt: nil, state: .current,
            windows: [.init(id: "week", name: "Week", fraction: 1.1)])
        XCTAssertThrowsError(try bad.validate())
        let duplicate = RemoteUsageCapacityDTO(epoch: UUID().uuidString, revision: 1, accounts: [bad, bad])
        XCTAssertThrowsError(try duplicate.validate())
        XCTAssertLessThanOrEqual(RemoteUsageCapacityLimits.label(String(repeating: "🧑🏽‍💻", count: 500)).utf8.count, 120)
    }
}
