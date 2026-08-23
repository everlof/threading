import XCTest
@testable import ThreadingPTYHostKit

final class PTYHostProtocolTests: XCTestCase {

    /// Both numbers are pinned so a bump fails a test once, deliberately — the bump policy in
    /// `PTYHostProtocol` is a decision, not a reflex.
    func testTheShippedVersionPairIsPinned() {
        XCTAssertEqual(PTYHostProtocol.current, 1)
        XCTAssertEqual(PTYHostProtocol.minimumSupported, 1)
    }

    // MARK: - The matrix

    func testAPeerSpeakingWhatWeSpeakIsCompatible() {
        XCTAssertEqual(
            PTYHostCompatibility.evaluate(peerVersion: 1, peerMinimum: 1),
            .compatible
        )
    }

    func testAPeerOlderThanWeSupportIsPeerTooOld() {
        XCTAssertEqual(
            PTYHostCompatibility.evaluate(peerVersion: 0, peerMinimum: 0),
            .peerTooOld
        )
    }

    func testAPeerThatNoLongerSupportsUsIsSelfTooOld() {
        XCTAssertEqual(
            PTYHostCompatibility.evaluate(peerVersion: 9, peerMinimum: 9),
            .selfTooOld
        )
    }

    /// A newer peer that still speaks our version is compatible — that is what "a breaking
    /// change bumps `current` while still speaking the old version" buys.
    func testANewerPeerThatStillSpeaksOurVersionIsCompatible() {
        XCTAssertEqual(
            PTYHostCompatibility.evaluate(peerVersion: 9, peerMinimum: 1),
            .compatible
        )
    }

    /// Both ends behind at once: the peer's age is decided first, because "you should update"
    /// is the answer that can actually be acted on.
    func testAPeerTooOldWinsWhenBothClausesWouldFire() {
        XCTAssertEqual(
            PTYHostCompatibility.evaluate(peerVersion: 0, peerMinimum: 9),
            .peerTooOld
        )
    }

    func testEvaluatingAHelloUsesItsDeclaredPair() {
        let hello = PTYHostHello(protocolVersion: 0, minimumSupported: 0, build: "old", pid: 1)
        XCTAssertEqual(PTYHostCompatibility.evaluate(peer: hello), .peerTooOld)
    }

    /// The build string is reported and journalled and never gates admission: a commit on master
    /// reinstalls the app several times a day, and a build-gated daemon would retire and drain
    /// each time for a change that touched no frame.
    func testABuildDifferenceDoesNotAffectCompatibility() {
        let mine = PTYHostHello(build: "2026.8.23-a1b2c3d", pid: 1)
        let theirs = PTYHostHello(build: "2026.7.01-deadbee", pid: 2)
        XCTAssertEqual(PTYHostCompatibility.evaluate(peer: mine), .compatible)
        XCTAssertEqual(PTYHostCompatibility.evaluate(peer: theirs), .compatible)
    }

    // MARK: - Which side has to move

    func testCompatibleNamesNoUpdateTarget() {
        XCTAssertNil(PTYHostCompatibility.compatible.updateTarget(evaluatedBy: .app))
        XCTAssertNil(PTYHostCompatibility.compatible.updateTarget(evaluatedBy: .daemon))
    }

    /// The whole reason the evaluator is a parameter: the same verdict names opposite sides.
    func testTheSameVerdictNamesTheOtherSideDependingOnWhoEvaluated() {
        XCTAssertEqual(PTYHostCompatibility.peerTooOld.updateTarget(evaluatedBy: .daemon), .app)
        XCTAssertEqual(PTYHostCompatibility.peerTooOld.updateTarget(evaluatedBy: .app), .daemon)
        XCTAssertEqual(PTYHostCompatibility.selfTooOld.updateTarget(evaluatedBy: .daemon), .daemon)
        XCTAssertEqual(PTYHostCompatibility.selfTooOld.updateTarget(evaluatedBy: .app), .app)
    }
}
