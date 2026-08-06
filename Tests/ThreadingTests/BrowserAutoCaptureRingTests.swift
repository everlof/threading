import XCTest

@testable import Threading

/// The before-shot ring, and the boundaries that keep it from becoming the baseline library.
@MainActor
final class BrowserAutoCaptureRingTests: XCTestCase {

    private var ring: BrowserAutoCaptureRing!
    private var sessionID: SessionID!

    override func setUp() {
        super.setUp()
        ring = BrowserAutoCaptureRing()
        sessionID = SessionID()
    }

    override func tearDown() {
        ring = nil
        sessionID = nil
        super.tearDown()
    }

    func testTheLatestEntryIsWhatComparingWithThePastMeans() throws {
        for index in 1...3 {
            ring.record(
                action: "browser_click",
                pngData: Data(repeating: UInt8(index), count: 16),
                conditions: BrowserBaselineStoreTests.conditions(width: 100, height: 80),
                for: sessionID
            )
        }
        XCTAssertEqual(ring.entries(for: sessionID).count, 3)
        XCTAssertEqual(ring.latest(for: sessionID)?.pngData.first, 3, "Newest, not oldest")
    }

    func testTheRingIsBoundedByCountAndDropsTheOldest() {
        let cap = BrowserAutoCaptureDefaults.maximumEntriesPerSession
        for index in 0..<(cap + 4) {
            ring.record(
                action: "browser_type",
                pngData: Data([UInt8(index)]),
                conditions: BrowserBaselineStoreTests.conditions(width: 10, height: 10),
                for: sessionID
            )
        }
        let entries = ring.entries(for: sessionID)
        XCTAssertEqual(entries.count, cap)
        XCTAssertEqual(entries.first?.pngData.first, 4, "The four oldest fell off the front")
    }

    /// A single capture larger than the per-entry ceiling is refused outright rather than
    /// evicting the whole history to make room for itself.
    func testAnOversizedCaptureIsRefusedWithoutDisturbingTheHistory() {
        ring.record(
            action: "browser_click",
            pngData: Data([1]),
            conditions: BrowserBaselineStoreTests.conditions(width: 10, height: 10),
            for: sessionID
        )
        let refused = ring.record(
            action: "browser_click",
            pngData: Data(count: BrowserAutoCaptureDefaults.maximumEntryBytes + 1),
            conditions: BrowserBaselineStoreTests.conditions(width: 10, height: 10),
            for: sessionID
        )
        XCTAssertNil(refused)
        XCTAssertEqual(ring.entries(for: sessionID).count, 1)
    }

    func testEachSessionKeepsItsOwnHistoryAndADeletedOneLosesIt() {
        let other = SessionID()
        ring.record(
            action: "browser_click",
            pngData: Data([1]),
            conditions: BrowserBaselineStoreTests.conditions(width: 10, height: 10),
            for: sessionID
        )
        ring.record(
            action: "browser_click",
            pngData: Data([2]),
            conditions: BrowserBaselineStoreTests.conditions(width: 10, height: 10),
            for: other
        )
        XCTAssertEqual(ring.latest(for: sessionID)?.pngData.first, 1)
        XCTAssertEqual(ring.latest(for: other)?.pngData.first, 2)

        ring.retainOnly(sessionIDs: [sessionID])
        XCTAssertNotNil(ring.latest(for: sessionID))
        XCTAssertNil(ring.latest(for: other))
    }

    /// Navigation is deliberately not a mutation: a new document is not a change to the old one,
    /// and comparing across the two would be the false claim the dimension rules already refuse.
    func testNavigationIsNotOneOfTheToolsAShotIsTakenInFrontOf() {
        XCTAssertFalse(BrowserAutoCaptureDefaults.mutatingTools.contains(.browserNavigate))
        XCTAssertFalse(BrowserAutoCaptureDefaults.mutatingTools.contains(.browserHistory))
        XCTAssertTrue(BrowserAutoCaptureDefaults.mutatingTools.contains(.browserClick))
        XCTAssertTrue(BrowserAutoCaptureDefaults.mutatingTools.contains(.browserType))
        // Reads must never pay for a screenshot.
        XCTAssertFalse(BrowserAutoCaptureDefaults.mutatingTools.contains(.browserSnapshot))
        XCTAssertFalse(BrowserAutoCaptureDefaults.mutatingTools.contains(.browserScreenshot))
        XCTAssertFalse(BrowserAutoCaptureDefaults.mutatingTools.contains(.browserVisualCompare))
    }

    /// The whole feature is opt-in, and the default is what a machine that has never seen the
    /// setting answers.
    func testCapturingBeforeActionsIsOffUntilAskedFor() throws {
        let suite = "BeforeActionCapture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertFalse(settings.capturesPageBeforeAgentActions)
        settings.capturesPageBeforeAgentActions = true
        XCTAssertTrue(AppSettings(defaults: defaults).capturesPageBeforeAgentActions)
    }
}
