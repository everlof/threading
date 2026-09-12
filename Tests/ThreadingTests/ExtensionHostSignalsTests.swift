import Foundation
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// The live values a custom surface may bind to, and the promise that the SDK's list and the
/// host's answers cannot drift apart.
@MainActor
final class ExtensionHostSignalsTests: XCTestCase {

    private var previousIntensity: (() -> AgentIntensity)!
    private var previousUptime: (() -> TimeInterval)!
    private var previousNow: (() -> Date)!
    private var previousCalendar: (() -> Calendar)!
    private var previousUsage: (() -> Double?)!

    override func setUp() async throws {
        try await super.setUp()
        previousIntensity = ExtensionHostSignals.intensity
        previousUptime = ExtensionHostSignals.uptime
        previousNow = ExtensionHostSignals.now
        previousCalendar = ExtensionHostSignals.calendar
        previousUsage = ExtensionHostSignals.activeAccountUsageRemaining
    }

    override func tearDown() async throws {
        ExtensionHostSignals.intensity = previousIntensity
        ExtensionHostSignals.uptime = previousUptime
        ExtensionHostSignals.now = previousNow
        ExtensionHostSignals.calendar = previousCalendar
        ExtensionHostSignals.activeAccountUsageRemaining = previousUsage
        try await super.tearDown()
    }

    /// Every signal the SDK names, this host answers — and nothing the SDK does not name.
    func testTheHostAnswersExactlyTheSignalsTheSDKNames() {
        XCTAssertEqual(ExtensionHostSignals.supported, Set(ExtensionHostSignal.all))
    }

    @MainActor
    func testWorkloadSignalsReadTheMonitorsEnvelope() {
        ExtensionHostSignals.intensity = {
            AgentIntensity(
                workload: AgentWorkload(workingCount: 3, anyAtTopEffort: false),
                recentActivity: 0.5,
                measuredAt: 100
            )
        }
        ExtensionHostSignals.uptime = { 100 }

        let intensity = try? XCTUnwrap(ExtensionHostSignals.value(.workloadIntensity))
        XCTAssertNotNil(intensity)
        XCTAssertGreaterThan(intensity ?? 0, 0)
        XCTAssertLessThanOrEqual(intensity ?? 2, 1)
        XCTAssertEqual(ExtensionHostSignals.value(.workloadWorkingCount), 3)

        ExtensionHostSignals.intensity = { .none }
        XCTAssertEqual(ExtensionHostSignals.value(.workloadIntensity), 0)
        XCTAssertEqual(ExtensionHostSignals.value(.workloadWorkingCount), 0)
    }

    @MainActor
    func testTheDayFractionFollowsTheUsersCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        ExtensionHostSignals.calendar = { calendar }

        ExtensionHostSignals.now = { Date(timeIntervalSince1970: 86_400 * 100 + 43_200) }
        XCTAssertEqual(ExtensionHostSignals.value(.timeOfDayFraction) ?? -1, 0.5, accuracy: 0.0001)

        ExtensionHostSignals.now = { Date(timeIntervalSince1970: 86_400 * 100) }
        XCTAssertEqual(ExtensionHostSignals.value(.timeOfDayFraction), 0)

        ExtensionHostSignals.now = { Date(timeIntervalSince1970: 86_400 * 101 - 1) }
        let almostMidnight = try XCTUnwrap(ExtensionHostSignals.value(.timeOfDayFraction))
        XCTAssertLessThan(almostMidnight, 1)
        XCTAssertGreaterThan(almostMidnight, 0.99)
    }

    @MainActor
    func testTheAccountSignalIsWhateverTheWindowInstalled() {
        ExtensionHostSignals.activeAccountUsageRemaining = { nil }
        XCTAssertNil(
            ExtensionHostSignals.value(.activeAccountUsageRemaining),
            "no window, no account: the surface falls back"
        )
        ExtensionHostSignals.activeAccountUsageRemaining = { 0.25 }
        XCTAssertEqual(ExtensionHostSignals.value(.activeAccountUsageRemaining), 0.25)
    }

    @MainActor
    func testAnUnknownSignalIsNilRatherThanAGuess() {
        XCTAssertNil(ExtensionHostSignals.value(ExtensionHostSignal(rawValue: "future.signal")))
    }
}
