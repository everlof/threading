import XCTest
@testable import Threading

final class TriggerModelsTests: XCTestCase {
    func testMatcherRequiresEveryTypedCondition() {
        let sourceID = TriggerSourceInstallationID()
        let event = TriggerEvent(
            sourceInstallationID: sourceID,
            externalID: "case-12",
            revision: "3",
            kind: "case.changed",
            occurredAt: Date(timeIntervalSince1970: 100),
            receivedAt: Date(timeIntervalSince1970: 101),
            title: "Case 12",
            attributes: [
                "status": .string("needs_review"),
                "attempt": .integer(3),
            ],
            deepLink: nil,
            resources: []
        )

        XCTAssertTrue(TriggerMatcher.matches(event, conditions: [
            TriggerCondition(attribute: "status", comparison: .equals, value: .string("needs_review")),
            TriggerCondition(attribute: "attempt", comparison: .greaterThan, value: .integer(2)),
        ]))
        XCTAssertFalse(TriggerMatcher.matches(event, conditions: [
            TriggerCondition(attribute: "status", comparison: .equals, value: .string("complete")),
        ]))
    }

    func testEventStorageKeySeparatesAmbiguousComponents() {
        let source = TriggerSourceInstallationID()
        let first = event(source: source, externalID: "a.b", revision: "c")
        let second = event(source: source, externalID: "a", revision: "b.c")
        XCTAssertNotEqual(first.storageKey, second.storageKey)
    }

    func testOvernightQuietHours() {
        let hours = TriggerQuietHours(
            startMinute: 23 * 60,
            endMinute: 7 * 60,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let midnight = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 10, hour: 0, minute: 30
        ))!
        let noon = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 10, hour: 12
        ))!
        XCTAssertTrue(hours.contains(midnight))
        XCTAssertFalse(hours.contains(noon))
    }

    private func event(
        source: TriggerSourceInstallationID,
        externalID: String,
        revision: String
    ) -> TriggerEvent {
        TriggerEvent(
            sourceInstallationID: source,
            externalID: externalID,
            revision: revision,
            kind: "test",
            occurredAt: Date(),
            receivedAt: Date(),
            title: "Test",
            attributes: [:],
            deepLink: nil,
            resources: []
        )
    }
}
