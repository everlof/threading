import Foundation
import XCTest
@testable import ThreadingDomain

final class AccountAppearanceTests: XCTestCase {
    func testPersistedFixtureRoundTripsWithoutLosingExplicitFalseOrFutureSurface() throws {
        let data = Data(#"{"shortName":"Work","shared":{"badgeMode":"text","badgeText":"WK","showBadge":false,"showName":true,"backgroundHex":"automatic"},"surfaces":{"sidebar":{"showEmail":false},"future-surface":{"showName":false}}}"#.utf8)
        let preferences = try JSONDecoder().decode(AccountAppearancePreferences.self, from: data)
        XCTAssertEqual(preferences.shortName, "Work")
        XCTAssertEqual(preferences.shared?.showBadge, false)
        XCTAssertNil(preferences.shared?.showEmail)
        XCTAssertEqual(preferences.surfaces?["future-surface"]?.showName, false)
        let encoded = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testEmptyLegacyPreferencesStillInherit() throws {
        let preferences = try JSONDecoder().decode(AccountAppearancePreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(preferences, AccountAppearancePreferences())
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? NSDictionary,
                       NSDictionary())
    }

    func testExplicitFalseOverridesWhileAbsentFieldsInherit() {
        var base = AccountAppearance()
        base.showBadge = true
        base.showName = true
        base.badgeText = "A"
        var override = AccountAppearance()
        override.showBadge = false
        let resolved = base.overlaying(override)
        XCTAssertEqual(resolved.showBadge, false)
        XCTAssertEqual(resolved.showName, true)
        XCTAssertEqual(resolved.badgeText, "A")
        XCTAssertEqual(base.overlaying(nil), base)
    }

    func testNormalizationKeepsAutomaticColorAndGraphemeSemantics() {
        var appearance = AccountAppearance()
        appearance.badgeMode = "emoji"
        appearance.badgeText = " 👩🏽‍💻extra "
        appearance.backgroundHex = " auto "
        appearance.foregroundHex = " #aabbcc "
        appearance.imageID = "not-an-image-id"
        let normalized = appearance.normalized()
        XCTAssertEqual(normalized.badgeText, "👩🏽‍💻")
        XCTAssertEqual(normalized.backgroundHex, "automatic")
        XCTAssertEqual(normalized.foregroundHex, "#AABBCC")
        XCTAssertNil(normalized.imageID)
    }

    func testPersistedSurfaceIdentifiersRemainStable() {
        XCTAssertEqual(AccountAppearanceSurface.allCases.map(\.rawValue),
                       ["sidebar", "chooser", "details", "usage", "notifications"])
    }
}
