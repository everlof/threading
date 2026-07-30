import XCTest
@testable import Threading

/// The threshold that decides whether an agent is told about the disk at all.
///
/// Worth pinning because both halves of it are load-bearing, and each covers a case the other
/// gets wrong.
final class DiskSpaceTests: XCTestCase {

    private func reading(freeGB: Double, totalGB: Double) -> DiskSpace.Reading {
        DiskSpace.Reading(
            available: Int64(freeGB * 1_000_000_000),
            capacity: Int64(totalGB * 1_000_000_000)
        )
    }

    /// A roomy disk says nothing, which is the case that must stay silent: an ordinary session
    /// should never hear about storage.
    func testHealthyDiskIsNotUnderPressure() {
        XCTAssertFalse(reading(freeGB: 400, totalGB: 1000).isUnderPressure)
        XCTAssertFalse(reading(freeGB: 120, totalGB: 500).isUnderPressure)
    }

    /// The absolute floor: 3% of a 4 TB disk is 120 GB, which no fraction test would flag and
    /// which is plenty of room. The floor must not fire here…
    func testLargeDiskWithRoomIsNotFlaggedByFractionAlone() {
        let huge = reading(freeGB: 120, totalGB: 4000)
        XCTAssertGreaterThan(huge.usedFraction, 0.9)
        XCTAssertFalse(huge.isUnderPressure, "120 GB free is not short, whatever the percentage")
    }

    /// …but 8 GB free *is* short, even on a disk that is only two-thirds full.
    func testSmallAbsoluteFreeSpaceIsPressureWhateverTheFraction() {
        let tight = reading(freeGB: 8, totalGB: 24)
        XCTAssertLessThan(tight.usedFraction, DiskSpaceDefaults.pressureFraction)
        XCTAssertTrue(tight.isUnderPressure, "8 GB free is short however small the disk")
    }

    /// And a nearly-full disk is pressure even when the absolute number is still above the
    /// floor — the case the floor alone would miss, and the reason the fraction exists.
    func testNearlyFullDiskIsPressure() {
        let full = reading(freeGB: 25, totalGB: 500)
        XCTAssertGreaterThan(full.available, DiskSpaceDefaults.lowWaterMark)
        XCTAssertTrue(full.isUnderPressure)
    }

    /// The boundary the two clauses meet at: proportionally full, but with real room left.
    func testComfortableFreeSpaceOutranksTheFraction() {
        let roomy = reading(freeGB: 150, totalGB: 4000)
        XCTAssertGreaterThan(roomy.usedFraction, DiskSpaceDefaults.pressureFraction)
        XCTAssertFalse(roomy.isUnderPressure)

        let tighter = reading(freeGB: 60, totalGB: 4000)
        XCTAssertTrue(tighter.isUnderPressure)
    }

    func testEmptyCapacityDoesNotDivideByZero() {
        XCTAssertEqual(DiskSpace.Reading(available: 0, capacity: 0).usedFraction, 0)
    }

    /// The real volume answers at all, which is the part no synthetic reading can prove.
    func testHomeVolumeReports() throws {
        let reading = try XCTUnwrap(DiskSpace.homeReading())
        XCTAssertGreaterThan(reading.capacity, 0)
        XCTAssertGreaterThanOrEqual(reading.available, 0)
    }
}
