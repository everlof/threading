import Foundation
import XCTest
@testable import ThreadingMobile

/// An address that keeps refusing the phone's identity check is rested, for a bounded and
/// doubling interval, and only for refusals. 758 attempts a day against two origins that never
/// once answered is what this replaces.
@MainActor
final class MobileRouteHealthLedgerTests: XCTestCase {
    private let ipv4 = URL(string: "https://100.65.47.126:8760")!
    private let dnsName = URL(string: "https://davids-macbook-pro.example.ts.net:8760")!
    private let lan = URL(string: "https://192.168.1.181:8760")!

    func testOnlyTheTLSFamilyIsARefusal() {
        XCTAssertTrue(MobileRouteHealthLedger.isRefusal(code: "url.-1200"))
        XCTAssertTrue(MobileRouteHealthLedger.isRefusal(code: "url.-1202"))
        XCTAssertTrue(MobileRouteHealthLedger.isRefusal(code: "url.-1206"))
        XCTAssertFalse(MobileRouteHealthLedger.isRefusal(code: "url.-1001"), "a timeout")
        XCTAssertFalse(MobileRouteHealthLedger.isRefusal(code: "url.-1004"), "cannot connect")
        XCTAssertFalse(MobileRouteHealthLedger.isRefusal(code: "url.-1009"), "offline")
        XCTAssertFalse(MobileRouteHealthLedger.isRefusal(code: "swift.cancelled"))
        XCTAssertFalse(MobileRouteHealthLedger.isRefusal(code: "remote.http.503"))
    }

    func testThreeIdenticalRefusalsRestTheAddressAndOneSuccessClearsIt() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let ledger = MobileRouteHealthLedger(now: { now })

        ledger.noteFailure(origin: ipv4, code: "url.-1200")
        ledger.noteFailure(origin: ipv4, code: "url.-1200")
        XCTAssertFalse(ledger.isCoolingDown(origin: ipv4), "two is a bad moment, not an address")
        ledger.noteFailure(origin: ipv4, code: "url.-1200")
        XCTAssertTrue(ledger.isCoolingDown(origin: ipv4))
        XCTAssertFalse(ledger.isCoolingDown(origin: dnsName), "another origin is another question")

        now = now.addingTimeInterval(MobileRouteHealthDefaults.initialCooldown - 1)
        XCTAssertTrue(ledger.isCoolingDown(origin: ipv4))
        now = now.addingTimeInterval(2)
        XCTAssertFalse(ledger.isCoolingDown(origin: ipv4), "the rest ends; one more attempt")

        ledger.noteSuccess(origin: ipv4)
        XCTAssertNil(ledger.entry(for: ipv4))
    }

    func testEachFurtherRefusalDoublesTheRestUpToAnHour() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let ledger = MobileRouteHealthLedger(now: { now })
        for _ in 0..<MobileRouteHealthDefaults.refusalsBeforeCooldown {
            ledger.noteFailure(origin: ipv4, code: "url.-1200")
        }
        var expected = MobileRouteHealthDefaults.initialCooldown
        for _ in 0..<6 {
            let until = ledger.entry(for: ipv4)?.cooldownUntil
            XCTAssertEqual(until, now.addingTimeInterval(expected))
            now = now.addingTimeInterval(expected + 1)
            ledger.noteFailure(origin: ipv4, code: "url.-1200")
            expected = min(expected * 2, MobileRouteHealthDefaults.maximumCooldown)
        }
        XCTAssertEqual(
            ledger.entry(for: ipv4)?.cooldownUntil,
            now.addingTimeInterval(MobileRouteHealthDefaults.maximumCooldown)
        )
    }

    /// A timeout in between is a different fact and does not add up with the refusals; a
    /// different refusal starts counting again.
    func testOtherFailuresDoNotAccumulate() {
        let ledger = MobileRouteHealthLedger(now: { Date() })
        ledger.noteFailure(origin: ipv4, code: "url.-1200")
        ledger.noteFailure(origin: ipv4, code: "url.-1200")
        ledger.noteFailure(origin: ipv4, code: "url.-1001")
        ledger.noteFailure(origin: ipv4, code: "url.-1200")
        XCTAssertFalse(ledger.isCoolingDown(origin: ipv4))

        ledger.noteFailure(origin: dnsName, code: "url.-1200")
        ledger.noteFailure(origin: dnsName, code: "url.-1200")
        ledger.noteFailure(origin: dnsName, code: "url.-1202")
        XCTAssertFalse(ledger.isCoolingDown(origin: dnsName))
        XCTAssertEqual(ledger.entry(for: dnsName)?.consecutiveRefusals, 1)
    }

    /// A rested origin leaves the walk and is reported; when every origin is resting none does.
    func testAdmittingKeepsTheWalkAliveAndReportsWhatItSkipped() {
        let ledger = MobileRouteHealthLedger(now: { Date() })
        for origin in [ipv4, dnsName] {
            for _ in 0..<MobileRouteHealthDefaults.refusalsBeforeCooldown {
                ledger.noteFailure(origin: origin, code: "url.-1200")
            }
        }
        var skipped: [URL] = []
        let admitted = ledger.admitting([ipv4, dnsName, lan], origin: { $0 }) { skipped.append($0) }
        XCTAssertEqual(admitted, [lan])
        XCTAssertEqual(skipped, [ipv4, dnsName])

        skipped = []
        let all = ledger.admitting([ipv4, dnsName], origin: { $0 }) { skipped.append($0) }
        XCTAssertEqual(all, [ipv4, dnsName], "a race with no lanes is not a race")
        XCTAssertTrue(skipped.isEmpty)
    }
}
