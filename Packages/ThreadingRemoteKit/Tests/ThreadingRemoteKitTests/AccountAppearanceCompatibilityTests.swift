import Foundation
import XCTest
import ThreadingDomain
import ThreadingRemoteKit

final class AccountAppearanceCompatibilityTests: XCTestCase {
    func testPublicWireNamesAreTheSameDomainTypes() throws {
        var wire = ThreadingRemoteKit.AccountAppearancePreferences()
        var style = ThreadingRemoteKit.AccountAppearance()
        style.showName = false
        wire.shared = style
        let domain: ThreadingDomain.AccountAppearancePreferences = wire
        let returned: ThreadingRemoteKit.AccountAppearancePreferences = domain
        XCTAssertEqual(returned, wire)
        let surface: ThreadingDomain.AccountAppearanceSurface = ThreadingRemoteKit.AccountAppearanceSurface.sidebar
        XCTAssertEqual(surface.rawValue, "sidebar")
        let encoded = try JSONEncoder().encode(wire)
        XCTAssertEqual(try JSONDecoder().decode(ThreadingDomain.AccountAppearancePreferences.self, from: encoded), domain)
    }
}
