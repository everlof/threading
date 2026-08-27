import Foundation
import XCTest
@testable import Threading

/// The keys a remote journal row carries.
///
/// `recordRemoteEvent` used to take `[String: String]`, and every key was hand-spelled at the call
/// site — `"device"` in thirteen places, `"session"` in eight. A misspelling there is not a crash
/// and not a failing test: it is one row filed under a column nothing groups by, found months
/// later by whoever is reading a support report. The keys are typed now, so this file's job is to
/// hold the *strings* those cases stand for, because the type only protects the spelling it was
/// given.
final class RemoteEventJournalTests: XCTestCase {

    private var testDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-remote-journal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testDirectory {
            try? FileManager.default.removeItem(at: testDirectory)
        }
        testDirectory = nil
        try super.tearDownWithError()
    }

    /// Spelled out rather than derived: a test that compared `rawValue` against the case name
    /// would agree with any rename, and a rename here silently renames a column in every journal
    /// already on disk. The switch is exhaustive so a new field is a compile error in this test
    /// rather than an untested key.
    func testEveryFieldKeepsTheKeyAlreadyWrittenToJournalsOnDisk() {
        for field in RemoteEventField.allCases {
            let expected: String
            switch field {
            case .device: expected = "device"
            case .peer: expected = "peer"
            case .session: expected = "session"
            case .terminal: expected = "terminal"
            case .share: expected = "share"
            case .capability: expected = "capability"
            case .theme: expected = "theme"
            case .setting: expected = "setting"
            case .surface: expected = "surface"
            case .account: expected = "account"
            case .policy: expected = "policy"
            case .source: expected = "source"
            case .records: expected = "records"
            case .screenshot: expected = "screenshot"
            case .delivery: expected = "delivery"
            case .decision: expected = "decision"
            case .update: expected = "update"
            case .reason: expected = "reason"
            }
            XCTAssertEqual(field.rawValue, expected)
        }
        XCTAssertEqual(RemoteEventField.allCases.count, 18)
    }

    /// The typed key has to survive the one place it becomes a string again.
    func testATypedRemoteEventLandsInTheJournalUnderThoseKeys() throws {
        let log = EventLog(directory: testDirectory)
        log.recordRemoteEvent("Session renamed remotely", [
            .session: "5A17E4D2-0000-0000-0000-000000000001",
            .device: "iphone-of-someone",
        ])

        let records = try journalRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["category"] as? String, "remote")
        XCTAssertEqual(records[0]["message"] as? String, "Session renamed remotely")
        let detail = try XCTUnwrap(records[0]["detail"] as? [String: String])
        XCTAssertEqual(detail, [
            "session": "5A17E4D2-0000-0000-0000-000000000001",
            "device": "iphone-of-someone",
        ])
    }

    /// A row with nothing to say still says it. `EventLog` drops an empty detail rather than
    /// writing `"detail":{}`, and the typed overload must not have changed that.
    func testARemoteEventWithNoFieldsWritesNoDetail() throws {
        let log = EventLog(directory: testDirectory)
        log.recordRemoteEvent("Remote client connected", [:])

        let records = try journalRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0]["detail"])
    }

    // MARK: - Private Methods

    private func journalRecords() throws -> [[String: Any]] {
        let log = EventLog(directory: testDirectory)
        let contents = try String(contentsOf: log.currentJournalURL, encoding: .utf8)

        return try contents
            .split(separator: "\n")
            .map { line in
                let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
                return try XCTUnwrap(object as? [String: Any])
            }
    }
}
