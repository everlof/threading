import Foundation
import ThreadingPluginKit
import XCTest
@testable import Threading

final class NativeWorkspaceNavigatorDiscoveryTests: XCTestCase {
    @MainActor
    func testShippedT3NavigatorIsARealDiscoverableNativePlugin() throws {
        let bundleURL = try XCTUnwrap(NativePluginCatalog.bundledPlugin(
            identifier: "codes.threading.plugin.t3navigator"
        ))
        let descriptor = try XCTUnwrap(NativeWorkspaceNavigatorDiscovery.descriptors(
            at: bundleURL,
            isBundled: true
        ).first)

        XCTAssertEqual(descriptor.navigatorID, "t3-native")
        XCTAssertEqual(descriptor.title, "T3 Native Threads POC")
        XCTAssertEqual(descriptor.preferredWidth, 320)

        switch NativePluginCatalog.load(bundleURL) {
        case .success(let plugin):
            XCTAssertEqual(plugin.pluginIdentifier, "codes.threading.plugin.t3navigator")
        case .failure(let failure):
            XCTFail("the shipped navigator plugin did not load: \(failure)")
        }
    }

    func testValidStaticMetadataProducesBoundedDescriptorWithoutLoadingExecutable() throws {
        let bundle = try makeBundle(
            identifier: "com.example.navigator",
            navigators: [["id": "focused", "title": "Focused", "preferredWidth": 312]],
            principalClass: "AClassThatMustNotExist"
        )
        defer { try? FileManager.default.removeItem(at: bundle) }

        let descriptors = NativeWorkspaceNavigatorDiscovery.descriptors(
            at: bundle,
            isBundled: true
        )

        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors.first?.pluginIdentifier, "com.example.navigator")
        XCTAssertEqual(descriptors.first?.navigatorID, "focused")
        XCTAssertEqual(descriptors.first?.title, "Focused")
        XCTAssertEqual(descriptors.first?.preferredWidth, 312)
        XCTAssertNil(NSClassFromString("AClassThatMustNotExist"))
    }

    func testInvalidWidthAndOversizedOrDuplicateDeclarationsAreRejectedOrBounded() throws {
        var declarations: [[String: Any]] = [
            ["id": "too-narrow", "title": "No", "preferredWidth": 179],
            ["id": "valid", "title": "First"],
            ["id": "valid", "title": "Duplicate"],
        ]
        for index in 0..<20 { declarations.append(["id": "n\(index)", "title": "N\(index)"]) }
        let bundle = try makeBundle(identifier: "com.example.bounded", navigators: declarations)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let descriptors = NativeWorkspaceNavigatorDiscovery.descriptors(
            at: bundle,
            isBundled: true
        )

        XCTAssertLessThanOrEqual(
            descriptors.count,
            NativeWorkspaceNavigatorDiscovery.maximumNavigatorsPerPlugin
        )
        XCTAssertFalse(descriptors.contains { $0.navigatorID == "too-narrow" })
        XCTAssertEqual(descriptors.filter { $0.navigatorID == "valid" }.count, 1)
    }

    func testInstalledSignatureIdentityMustMatchDeclaredIdentifier() throws {
        let bundle = try makeBundle(
            identifier: "com.example.claimed",
            navigators: [["id": "focused", "title": "Focused"]]
        )
        defer { try? FileManager.default.removeItem(at: bundle) }

        XCTAssertTrue(NativeWorkspaceNavigatorDiscovery.descriptors(
            at: bundle,
            isBundled: false,
            verifiedInstalledIdentity: identity("com.example.signed", hash: "signed")
        ).isEmpty)
    }

    func testInstalledMetadataWithoutVerifiedIdentityIsNeverPublished() throws {
        let bundle = try makeBundle(
            identifier: "com.example.unsigned",
            navigators: [["id": "focused", "title": "Focused"]]
        )
        defer { try? FileManager.default.removeItem(at: bundle) }

        XCTAssertTrue(NativeWorkspaceNavigatorDiscovery.descriptors(
            at: bundle,
            isBundled: false
        ).isEmpty)
    }

    func testBundledDescriptorWinsInstalledIdentityCollision() throws {
        let bundled = try makeBundle(
            name: "Bundled",
            identifier: "com.example.same",
            navigators: [["id": "focused", "title": "Bundled"]]
        )
        let installed = try makeBundle(
            name: "Installed",
            identifier: "com.example.same",
            navigators: [["id": "focused", "title": "Installed"]]
        )
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: installed)
        }

        let result = NativeWorkspaceNavigatorDiscovery.inventory(
            candidates: [
                .init(url: installed, isBundled: false),
                .init(url: bundled, isBundled: true),
            ],
            installedIdentity: { _ in self.identity("com.example.same", hash: "installed") }
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "Bundled")
        XCTAssertTrue(result.first?.isBundled == true)
    }

    func testBundledProviderOwnsItsWholeNavigatorNamespace() throws {
        let bundled = try makeBundle(
            name: "BundledProvider",
            identifier: "com.example.same-provider",
            navigators: [["id": "built-in", "title": "Built In"]]
        )
        let installed = try makeBundle(
            name: "InstalledProvider",
            identifier: "com.example.same-provider",
            navigators: [["id": "injected", "title": "Injected"]]
        )
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: installed)
        }

        let result = NativeWorkspaceNavigatorDiscovery.inventory(
            candidates: [
                .init(url: bundled, isBundled: true),
                .init(url: installed, isBundled: false),
            ],
            installedIdentity: {
                _ in self.identity("com.example.same-provider", hash: "installed")
            }
        )

        XCTAssertEqual(result.map(\.navigatorID), ["built-in"])
    }

    func testAmbiguousInstalledRouteRejectsEveryClaimant() throws {
        let first = try makeBundle(
            name: "FirstInstalled",
            identifier: "com.example.ambiguous",
            navigators: [["id": "focused", "title": "First"]]
        )
        let second = try makeBundle(
            name: "SecondInstalled",
            identifier: "com.example.ambiguous",
            navigators: [["id": "focused", "title": "Second"]]
        )
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let result = NativeWorkspaceNavigatorDiscovery.inventory(
            candidates: [
                .init(url: first, isBundled: false),
                .init(url: second, isBundled: false),
            ],
            installedIdentity: { url in
                self.identity("com.example.ambiguous", hash: url.lastPathComponent)
            }
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testInstalledDescriptorIsBoundToTheVerifiedBuild() throws {
        let bundle = try makeBundle(
            identifier: "com.example.bound",
            navigators: [["id": "focused", "title": "Focused"]]
        )
        defer { try? FileManager.default.removeItem(at: bundle) }
        let discovered = identity("com.example.bound", team: "TEAM", hash: "before")
        let descriptor = try XCTUnwrap(NativeWorkspaceNavigatorDiscovery.descriptors(
            at: bundle,
            isBundled: false,
            verifiedInstalledIdentity: discovered
        ).first)

        XCTAssertEqual(descriptor.verifiedInstalledIdentity, discovered)
        XCTAssertTrue(NativeWorkspaceNavigatorDiscovery.installedBuildStillMatches(
            descriptor,
            identity: { _ in discovered }
        ))
        XCTAssertFalse(NativeWorkspaceNavigatorDiscovery.installedBuildStillMatches(
            descriptor,
            identity: { _ in self.identity("com.example.bound", team: "TEAM", hash: "after") }
        ))
    }

    func testOversizedPlistAndControlBearingMetadataAreRejected() throws {
        let oversized = try makeBundle(
            name: "Oversized",
            identifier: "com.example.oversized",
            navigators: [["id": "focused", "title": "Focused"]]
        )
        let info = oversized.appendingPathComponent("Contents/Info.plist")
        try Data(
            repeating: 0x41,
            count: NativeWorkspaceNavigatorDiscovery.maximumInfoPlistBytes + 1
        ).write(to: info)
        let controls = try makeBundle(
            name: "Controls",
            identifier: "com.example.controls",
            navigators: [
                ["id": "one\u{0}two", "title": "NUL"],
                ["id": "bidi", "title": "Trusted\u{202e}txt"],
                ["id": "newline", "title": "Two\nLines"],
            ]
        )
        defer {
            try? FileManager.default.removeItem(at: oversized)
            try? FileManager.default.removeItem(at: controls)
        }

        XCTAssertTrue(NativeWorkspaceNavigatorDiscovery.descriptors(
            at: oversized,
            isBundled: true
        ).isEmpty)
        XCTAssertTrue(NativeWorkspaceNavigatorDiscovery.descriptors(
            at: controls,
            isBundled: true
        ).isEmpty)
    }

    @MainActor
    func testNativePluginNavigatorSelectionRoundTripsAndRejectsEmptyIdentity() throws {
        let suite = "NativeNavigatorSelection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let valid = WorkspaceNavigatorSelection.nativePluginNavigator(
            pluginIdentifier: "com.example.navigator",
            navigatorID: "focused"
        )

        settings.workspaceNavigatorSelection = valid
        XCTAssertEqual(AppSettings(defaults: defaults).workspaceNavigatorSelection, valid)
        settings.workspaceNavigatorSelection = .nativePluginNavigator(
            pluginIdentifier: "",
            navigatorID: "focused"
        )
        XCTAssertEqual(settings.workspaceNavigatorSelection, valid)
        settings.workspaceNavigatorSelection = .nativePluginNavigator(
            pluginIdentifier: "com.example.navigator",
            navigatorID: " focused "
        )
        XCTAssertEqual(settings.workspaceNavigatorSelection, valid)
        settings.workspaceNavigatorSelection = .nativePluginNavigator(
            pluginIdentifier: "com.example.navigator\u{202e}",
            navigatorID: "focused"
        )
        XCTAssertEqual(settings.workspaceNavigatorSelection, valid)
    }

    private func identity(
        _ identifier: String,
        team: String? = nil,
        hash: String
    ) -> PluginLoader.PluginIdentity {
        PluginLoader.PluginIdentity(bundleIdentifier: identifier, team: team, cdHash: hash)
    }

    private func makeBundle(
        name: String = UUID().uuidString,
        identifier: String,
        navigators: [[String: Any]],
        principalClass: String? = nil
    ) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name).bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "ThreadingWorkspaceNavigators": navigators,
        ]
        if let principalClass { plist["NSPrincipalClass"] = principalClass }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return root
    }
}
