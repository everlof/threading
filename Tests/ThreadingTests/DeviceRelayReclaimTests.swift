import XCTest
@testable import Threading

/// Which abandoned log readers may be reclaimed.
///
/// `com.apple.os_trace_relay` is effectively single-client: a second reader connects, is
/// acknowledged, and then receives nothing at all. So one leaked `idevicesyslog` silently breaks
/// the device source for everyone, with no error to say why — a real incident, three orphans deep,
/// that was misdiagnosed as a broken phone and sent a whole feature down a redesign.
///
/// Reclaiming is therefore worth doing and worth bounding. These tests hold the bound: only a
/// process orphaned to `launchd`, running this exact tool against this exact device.
final class DeviceRelayReclaimTests: XCTestCase {

    private let tool = "/opt/homebrew/bin/idevicesyslog"
    private let udid = "00008140-000C208C1108801C"

    private func pids(_ listing: String) -> [pid_t] {
        DeviceRelayReclaim.orphanPIDs(in: listing, udid: udid, toolPath: tool)
    }

    func testAnOrphanedReaderForThisDeviceIsReclaimed() {
        let listing = " 41493     1 \(tool) -u \(udid) --no-colors"
        XCTAssertEqual(pids(listing), [41493])
    }

    /// The discriminator that makes this safe. A reader the user started in their own terminal has
    /// their shell as its parent, not launchd, and must be left running.
    func testAReaderSomebodyIsStillRunningIsLeftAlone() {
        let listing = " 41493  9931 \(tool) -u \(udid) --no-colors"
        XCTAssertTrue(pids(listing).isEmpty, "a reader with a live parent is somebody's, not ours")
    }

    func testAnotherDevicesReaderIsNotTouched() {
        let listing = " 41493     1 \(tool) -u 00001111-AAAABBBBCCCCDDDD --no-colors"
        XCTAssertTrue(pids(listing).isEmpty)
    }

    func testAnUnrelatedOrphanIsNotTouched() {
        let listing = """
             1234     1 /usr/bin/some-other-tool -u \(udid)
             5678     1 /opt/homebrew/bin/idevicescreenshot -u \(udid)
            """
        XCTAssertTrue(pids(listing).isEmpty, "matching the device alone must not be enough")
    }

    func testEveryOrphanForTheDeviceIsFoundNotJustTheFirst() {
        let listing = """
             1795     1 \(tool) -u \(udid) --no-colors -n
            41493     1 \(tool) -u \(udid) --no-colors
            45374     1 \(tool) -u \(udid) --no-colors
             9931  4102 \(tool) -u \(udid) --no-colors
            """
        XCTAssertEqual(
            pids(listing),
            [1795, 41493, 45374],
            "the real incident had three, including one from the previous day"
        )
    }

    func testMalformedListingLinesAreIgnoredRatherThanGuessedAt() {
        let listing = """
            not a process line at all
             abc   1 \(tool) -u \(udid)
             41493
            """
        XCTAssertTrue(pids(listing).isEmpty)
    }
}
