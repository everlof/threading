import XCTest
import ThreadingRemoteKit
@testable import Threading

@MainActor
final class RemoteUsageCapacityServiceTests: XCTestCase {
    private func account(_ index: Int) -> AgentAccount {
        AgentAccount(provider: .codex, handle: .named("account-\(index)"),
                     configPath: "/unused/account-\(index)", displayName: "Account \(index)")
    }

    func testCapacityDoesNotRescanForEachReadingAndPreservesObservationTime() async throws {
        let source = account(1)
        let observation = Date(timeIntervalSince1970: 1_780_000_000)
        var reading: AccountUsageReading = .notFetched
        var discoveries = 0
        var changes: [RemoteUsageCapacityChangedDTO] = []
        let service = RemoteUsageCapacityService(discover: {
            discoveries += 1
            return ([source], 0)
        }, reading: { _ in reading }, refresh: { _ in })
        service.didChange = { changes.append($0) }
        let initial = try await service.snapshot()
        XCTAssertEqual(initial.accounts.first?.state, .unavailable)
        reading = .current(AccountUsage(windows: [.init(id: "week", label: "Week", fraction: 0.4,
            resetsAt: nil, windowDuration: 604800)], planLabel: "Pro", observedAt: observation, source: .api))
        NotificationCenter.default.post(AccountUsageDidChange(accountID: source.id))
        let updated = try await service.snapshot()
        XCTAssertEqual(discoveries, 1)
        XCTAssertEqual(updated.accounts.first?.observedAt, observation.timeIntervalSince1970)
        XCTAssertEqual(updated.accounts.first?.windows.first?.fraction, 0.4)
        XCTAssertGreaterThan(updated.revision, initial.revision)
        XCTAssertEqual(changes.last?.revision, updated.revision)
        XCTAssertEqual(updated.epoch, initial.epoch)
    }

    func testProjectionBoundsBeforeBuildingWindowsAndReportsOmissions() async throws {
        let candidates = (0..<129).map(account)
        let usage = AccountUsage(windows: (0..<300).map {
            .init(id: "window-\($0)", label: "Window", fraction: 0.5, resetsAt: nil, windowDuration: 3600)
        }, planLabel: "Pro", observedAt: Date(), source: .api)
        let service = RemoteUsageCapacityService(discover: { (candidates, 4) },
            reading: { _ in .current(usage) }, refresh: { _ in })
        let value = try await service.snapshot()
        XCTAssertEqual(value.accounts.count, 128)
        XCTAssertEqual(value.omittedAccountCount, 5)
        XCTAssertEqual(value.accounts.reduce(0) { $0 + $1.windows.count }, 256)
        XCTAssertEqual(value.omittedWindowCount, 128 * 300 - 256)
        try value.validate()
    }
}
