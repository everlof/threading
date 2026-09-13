import Foundation
import XCTest
@testable import ThreadingMobile

/// What App Store Connect refuses in a bundle that every archive and export accepts.
///
/// None of these fails a build. Apple reports the first two from `altool --validate-app` or an
/// upload, and the third as an email after processing, so each is asserted against the built app
/// a person installs rather than against the project file.
final class MobileAppStoreSubmissionTests: XCTestCase {

    private static let portrait = "UIInterfaceOrientationPortrait"
    private static let upsideDown = "UIInterfaceOrientationPortraitUpsideDown"
    private static let landscapeLeft = "UIInterfaceOrientationLandscapeLeft"
    private static let landscapeRight = "UIInterfaceOrientationLandscapeRight"

    /// ITMS-90474. A universal app that declares no orientations is refused, because iPad
    /// multitasking requires all four. The app constrains orientation nowhere in code, so the
    /// declaration states what it already did: every orientation on iPad, all but upside-down on
    /// iPhone.
    func testTheBuiltAppDeclaresEveryOrientationIPadMultitaskingRequires() throws {
        let info = try rawInfoPlist()

        XCTAssertEqual(
            Set(try XCTUnwrap(info["UISupportedInterfaceOrientations~ipad"] as? [String])),
            [Self.portrait, Self.upsideDown, Self.landscapeLeft, Self.landscapeRight],
            "App Store Connect refuses a universal app without all four iPad orientations"
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(info["UISupportedInterfaceOrientations~iphone"] as? [String])),
            [Self.portrait, Self.landscapeLeft, Self.landscapeRight]
        )
    }

    /// ITMS-90592 was the refusal while the app said YES without a compliance code. WebRTC's
    /// DTLS/SRTP is standard encryption, which needs no US documentation and only a French
    /// declaration if the app is sold in France; releasing.md records that condition, and this
    /// flips to YES plus `ITSEncryptionExportComplianceCode` if the answer changes.
    func testTheBuiltAppDeclaresItsEncryptionExemptFromDocumentation() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool,
            false
        )
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "ITSEncryptionExportComplianceCode"))
    }

    /// ITMS-91053. The statically linked packages count as this binary, so the manifest has to
    /// declare a reason for each required-reason API category any of them calls.
    func testTheBuiltAppCarriesAPrivacyManifestForItsRequiredReasonAPIs() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "without the manifest every upload is refused for its required-reason APIs"
        )
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        let accessed = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        XCTAssertEqual(
            Set(accessed.compactMap { $0["NSPrivacyAccessedAPIType"] as? String }),
            [
                "NSPrivacyAccessedAPICategoryUserDefaults",
                "NSPrivacyAccessedAPICategoryFileTimestamp",
                "NSPrivacyAccessedAPICategorySystemBootTime",
                "NSPrivacyAccessedAPICategoryDiskSpace",
            ]
        )
        for entry in accessed {
            XCTAssertFalse(
                (entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []).isEmpty,
                "\(entry["NSPrivacyAccessedAPIType"] ?? "an entry") declares no reason"
            )
        }
    }

    // MARK: - Private Methods

    /// The file as built, because `Bundle.infoDictionary` folds the `~ipad` and `~iphone` variants
    /// into the plain key for the device running the test, and an iPhone simulator would never see
    /// the iPad list.
    private func rawInfoPlist() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Info", withExtension: "plist"))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
                as? [String: Any]
        )
    }
}
