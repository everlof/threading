import Foundation
import XCTest
@testable import ThreadingMobile

@MainActor
final class MobileUsageWidgetTests: XCTestCase {
    func testInstalledAppCanResolveItsWidgetAppGroup() throws {
        XCTAssertNotNil(FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.codes.threading.mobile"
        ))
    }

    func testBuiltAppEmbedsTheUsageExtension() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let bundle = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("ThreadingGlance.appex")))
        XCTAssertEqual(bundle.bundleIdentifier, "codes.threading.mobile.glance")
        let declaration = try XCTUnwrap(bundle.infoDictionary?["NSExtension"] as? [String: Any])
        XCTAssertEqual(declaration["NSExtensionPointIdentifier"] as? String, "com.apple.widgetkit-extension")
        XCTAssertNotNil(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "sv.lproj"))
    }

    func testUnpairedWidgetRouteDoesNotOpenPairingOrInventAHost() throws {
        let model = RemoteAppModel()
        let hosts = model.hosts
        let url = try XCTUnwrap(URL(string: "threading://usage?host=unknown-widget-host&account=5%3Acodexpersonal"))
        XCTAssertTrue(model.open(url))
        XCTAssertEqual(model.hosts, hosts)
        XCTAssertNil(model.widgetUsageRoute)
        XCTAssertFalse(model.isPairing)
    }
}
