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

    /// The first App Store release is iPhone-only: Apple allows adding iPad support in an update
    /// but not removing it, and ITMS-90474 refused the universal build for declaring no iPad
    /// orientations. The app constrains orientation nowhere in code, so the iPhone declaration
    /// states what it already did: every orientation but upside-down.
    func testTheBuiltAppIsIPhoneOnlyAndDeclaresItsOrientations() throws {
        let info = try rawInfoPlist()

        XCTAssertEqual(info["UIDeviceFamily"] as? [Int], [1], "an iPad family cannot be withdrawn later")
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
        let collected = try XCTUnwrap(
            manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]
        )
        let crashData = try XCTUnwrap(collected.first {
            $0["NSPrivacyCollectedDataType"] as? String
                == "NSPrivacyCollectedDataTypeCrashData"
        })
        XCTAssertEqual(crashData["NSPrivacyCollectedDataTypeLinked"] as? Bool, false)
        XCTAssertEqual(crashData["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)

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
