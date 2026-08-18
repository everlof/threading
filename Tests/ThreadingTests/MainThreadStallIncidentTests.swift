import Foundation
import XCTest
@testable import Threading

final class MainThreadStallIncidentTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stall-incidents-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    /// Detection is the durable boundary. If the user force-quits before main answers, the
    /// incident still says which semantic operation was in flight.
    func testDetectionIsReadableBeforeTheMainThreadRecovers() throws {
        let store = MainThreadStallIncidentStore(directory: directory)
        let id = try XCTUnwrap(store.begin(
            thresholdMilliseconds: 250,
            mainThreadID: 42,
            activeOperations: [PerformanceActiveSpanSnapshot(
                name: "onboarding.import-list.rebuild",
                category: "ui",
                ageMilliseconds: 318,
                metadata: ["conversations": "1495"]
            )],
            detectedAt: Date(timeIntervalSince1970: 1_000)
        ))

        guard case .read(let detected) = store.read() else {
            return XCTFail("Expected the detected incident to be readable")
        }
        XCTAssertEqual(detected.incidentCount, 1)
        XCTAssertEqual(detected.incompleteCount, 1)
        XCTAssertEqual(detected.longestObservedMilliseconds, 250)
        XCTAssertEqual(detected.operationNames, ["onboarding.import-list.rebuild"])

        store.complete(
            id: id,
            durationMilliseconds: 423_326,
            completedAt: Date(timeIntervalSince1970: 1_424)
        )
        guard case .read(let completed) = store.read() else {
            return XCTFail("Expected the completed incident to be readable")
        }
        XCTAssertEqual(completed.incompleteCount, 0)
        XCTAssertEqual(completed.longestObservedMilliseconds, 423_326)
    }

    /// The support summary admits compile-time-looking machine tokens only. The owner-local JSON
    /// keeps the full recorder context, but a future dynamic span cannot smuggle a path into a
    /// share-safe report.
    func testShareSummaryRejectsAFreeFormOperationName() throws {
        let store = MainThreadStallIncidentStore(directory: directory)
        XCTAssertNotNil(store.begin(
            thresholdMilliseconds: 250,
            mainThreadID: 42,
            activeOperations: [PerformanceActiveSpanSnapshot(
                name: "/Users/person/private operation",
                category: "test",
                ageMilliseconds: 250,
                metadata: [:]
            )]
        ))

        guard case .read(let summary) = store.read() else {
            return XCTFail("Expected a readable incident")
        }
        XCTAssertTrue(summary.operationNames.isEmpty)
    }

    func testRetentionKeepsTheNewestBoundedSet() {
        let store = MainThreadStallIncidentStore(directory: directory, reportLimit: 2)
        for index in 0..<3 {
            XCTAssertNotNil(store.begin(
                thresholdMilliseconds: Double(250 + index),
                mainThreadID: 42,
                activeOperations: []
            ))
        }

        guard case .read(let summary) = store.read() else {
            return XCTFail("Expected retained incidents")
        }
        XCTAssertEqual(summary.incidentCount, 2)
    }
}
