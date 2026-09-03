import XCTest
@testable import Threading

/// What the user agreed to, and what that agreement covers.
///
/// This gate replaced an allowlist holding our own signing team, which meant nobody else could ship
/// a plugin at all. Removing the check instead would have made the plugins folder an install path
/// for arbitrary in-process code, so the gate changed rather than went — and the rules it now
/// encodes are worth testing directly, because getting them wrong is a grant nobody gave.
final class NativePluginApprovalTests: XCTestCase {

    private let fingerprint = "aaaa1111"
    private let identifier = "com.example.plugin"

    func testAnUnknownPluginHasNoAnswerYet() {
        let approvals = NativePluginApprovals()
        XCTAssertNil(approvals.decision(identifier: identifier, fingerprint: fingerprint))
    }

    /// The property the whole design rests on: an approval is for a *build*, not for a name. A
    /// rebuilt, updated or substituted bundle under the same identifier is a different identity and
    /// has to be asked about again — otherwise anything able to write that folder inherits a grant
    /// the user gave to something else.
    func testAnApprovalDoesNotCarryToDifferentBytes() {
        var approvals = NativePluginApprovals()
        approvals.remember(true, identifier: identifier, fingerprint: fingerprint)
        XCTAssertEqual(approvals.decision(identifier: identifier, fingerprint: fingerprint), true)
        XCTAssertNil(
            approvals.decision(identifier: identifier, fingerprint: "bbbb2222"),
            "a different build of the same plugin inherited an approval"
        )
    }

    /// A refusal is remembered too. Asking every launch is how a user learns to click through the
    /// question that protects them.
    func testARefusalIsRememberedRatherThanReAsked() {
        var approvals = NativePluginApprovals()
        approvals.remember(false, identifier: identifier, fingerprint: fingerprint)
        XCTAssertEqual(approvals.decision(identifier: identifier, fingerprint: fingerprint), false)
    }

    func testTheNewestAnswerWins() {
        var approvals = NativePluginApprovals()
        approvals.remember(false, identifier: identifier, fingerprint: fingerprint)
        approvals.remember(true, identifier: identifier, fingerprint: fingerprint)
        XCTAssertEqual(approvals.decision(identifier: identifier, fingerprint: fingerprint), true)
        XCTAssertEqual(approvals.entries.count, 1, "the old answer is replaced, not stacked")
    }

    /// Revoking is about the plugin, not one build of it: a reinstall must ask again rather than
    /// find an old approval for bytes that happen to match.
    func testRevokingForgetsEveryBuildOfThatPlugin() {
        var approvals = NativePluginApprovals()
        approvals.remember(true, identifier: identifier, fingerprint: fingerprint)
        approvals.remember(true, identifier: identifier, fingerprint: "bbbb2222")
        approvals.remember(true, identifier: "com.example.other", fingerprint: fingerprint)
        approvals.revoke(identifier: identifier)
        XCTAssertNil(approvals.decision(identifier: identifier, fingerprint: fingerprint))
        XCTAssertNil(approvals.decision(identifier: identifier, fingerprint: "bbbb2222"))
        XCTAssertEqual(
            approvals.decision(identifier: "com.example.other", fingerprint: fingerprint),
            true,
            "revoking one plugin took another's answer with it"
        )
    }

    /// A plugins folder is externally sized, so the record is capped. Losing the oldest costs one
    /// extra question, never a wrong grant — so the *newest* entries are the ones kept.
    func testTheRecordIsCappedAndForgetsTheOldestFirst() {
        var approvals = NativePluginApprovals()
        for index in 0..<(NativePluginApprovals.capacity + 10) {
            approvals.remember(true, identifier: "com.example.p\(index)", fingerprint: fingerprint)
        }
        XCTAssertEqual(approvals.entries.count, NativePluginApprovals.capacity)
        XCTAssertNil(
            approvals.decision(identifier: "com.example.p0", fingerprint: fingerprint),
            "the oldest answer should have been dropped"
        )
        XCTAssertEqual(
            approvals.decision(identifier: "com.example.p109", fingerprint: fingerprint),
            true,
            "the newest answer must survive"
        )
    }
}
