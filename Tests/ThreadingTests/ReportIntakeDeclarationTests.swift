import XCTest
@testable import Threading

/// The intake endpoint is injected at archive time, and the only thing standing between a user's
/// bug report and the developer.
///
/// This exists because the declaration silently went missing once. The key was written as
/// `INFOPLIST_KEY_ThreadingReportIntakeURL` in the project file, which Xcode consults only when it
/// *generates* an Info.plist; this target ships an explicit one, so the setting was inert and the
/// key never appeared in a single build. Nothing failed. `release.sh` passed the value, the
/// archive succeeded, notarization succeeded, and the shipped app quietly posted nothing —
/// indistinguishable from a build that had simply never been wired up.
///
/// So the assertion is about the *declaration*, not the value. A test host injects nothing, so the
/// value is empty here and that is correct; what must never be true again is the key being absent.
final class ReportIntakeDeclarationTests: XCTestCase {

    func testTheBundleDeclaresTheIntakeKey() {
        let declared = Bundle.main.infoDictionary?.keys.contains("ThreadingReportIntakeURL")
        XCTAssertEqual(
            declared, true,
            "Info.plist must declare ThreadingReportIntakeURL for release.sh to have anything to "
                + "inject into. An absent key ships an app whose reports never leave the Mac."
        )
    }

    /// Empty in a test host, and empty must mean *no endpoint* rather than a malformed one. There
    /// is deliberately no compiled-in fallback, so this is the whole of the absent case.
    func testAnEmptyValueMeansNoEndpointRatherThanABadURL() {
        XCTAssertNil(
            MacIssueReportOutbox.configuredEndpoint(
                environment: [:],
                infoDictionary: ["ThreadingReportIntakeURL": ""]
            )
        )
        XCTAssertNil(
            MacIssueReportOutbox.configuredEndpoint(environment: [:], infoDictionary: [:])
        )
    }

    func testAnInjectedValueIsUsedVerbatim() {
        let endpoint = MacIssueReportOutbox.configuredEndpoint(
            environment: [:],
            infoDictionary: ["ThreadingReportIntakeURL": "https://remote.threading.codes/v1/reports"]
        )
        XCTAssertEqual(endpoint?.absoluteString, "https://remote.threading.codes/v1/reports")
    }
}
