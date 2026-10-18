import XCTest
@testable import DeviceLogsPlugin

/// The bound on the directory of recorded histories, which had none: 13,482 files and 6.2 GB on
/// the machine that found it, almost all of them stores of sessions that no longer existed.
final class DeviceLogStoreRetentionTests: XCTestCase {

    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    /// A store as SQLite leaves it: the database and both sidecars, all dated `age` ago — except
    /// the shared-memory file, which opening a store rewrites, dated `shmAge` ago.
    private func store(_ name: String, age: TimeInterval, bytes: Int = 4_096, shmAge: TimeInterval = 0) throws {
        for (suffix, fileAge) in [("", age), ("-wal", age), ("-shm", shmAge)] {
            let url = directory.appendingPathComponent("\(name).sqlite\(suffix)")
            try Data(count: suffix.isEmpty ? bytes : 0).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-fileAge)],
                ofItemAtPath: url.path
            )
        }
    }

    private func remaining() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    // MARK: - Age

    func testAStoreUntouchedForLongerThanTheMaximumAgeGoesWithItsSidecars() throws {
        try store("old", age: 30 * day)
        try store("fresh", age: day)

        let outcome = DeviceLogStoreRetention.sweep(directory: directory, protecting: [], now: now)

        XCTAssertEqual(outcome.removedStores, 1)
        XCTAssertEqual(try remaining(), ["fresh.sqlite", "fresh.sqlite-wal", "fresh.sqlite-shm"])
    }

    /// Opening a store rewrites its `-shm`; that must not make weeks-old data look fresh.
    func testARecentlyOpenedButOldStoreStillExpires() throws {
        try store("old", age: 30 * day, shmAge: 0)

        DeviceLogStoreRetention.sweep(directory: directory, protecting: [], now: now)

        XCTAssertEqual(try remaining(), [])
    }

    func testTheStoreBeingOpenedIsNeverRemoved() throws {
        try store("mine", age: 30 * day)

        DeviceLogStoreRetention.sweep(directory: directory, protecting: ["mine.sqlite"], now: now)

        XCTAssertTrue(try remaining().contains("mine.sqlite"))
    }

    // MARK: - Budget

    func testOverBudgetTheOldestGoFirst() throws {
        try store("a-oldest", age: 3 * day, bytes: 400_000)
        try store("b-middle", age: 2 * day, bytes: 400_000)
        try store("c-newest", age: 1 * day, bytes: 400_000)

        let outcome = DeviceLogStoreRetention.sweep(
            directory: directory,
            protecting: [],
            now: now,
            byteBudget: 900_000
        )

        XCTAssertEqual(outcome.removedStores, 1)
        XCTAssertFalse(try remaining().contains("a-oldest.sqlite"))
        XCTAssertTrue(try remaining().contains("c-newest.sqlite"))
    }

    // MARK: - Leaves alone

    func testFilesThatAreNotStoresAreLeftAlone() throws {
        let other = directory.appendingPathComponent("learned-enums.json")
        try Data("{}".utf8).write(to: other)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90 * day)], ofItemAtPath: other.path)

        DeviceLogStoreRetention.sweep(directory: directory, protecting: [], now: now)

        XCTAssertEqual(try remaining(), ["learned-enums.json"])
    }

    func testAMissingDirectoryIsNotAnError() {
        let outcome = DeviceLogStoreRetention.sweep(
            directory: directory.appendingPathComponent("absent"),
            protecting: [],
            now: now
        )

        XCTAssertEqual(outcome, DeviceLogStoreRetention.Outcome())
    }
}
