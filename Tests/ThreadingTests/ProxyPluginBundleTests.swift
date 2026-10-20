import XCTest
import ThreadingPluginKit
@testable import Threading

@MainActor
final class ProxyPluginBundleTests: XCTestCase {
    func testBundledProxyPluginOwnsTheSignedHelperAndSetupScript() throws {
        let plugin = ProxyHelperLocation.bundledPlugin()
        let assets = ProxyHelperLocation.assets(in: plugin)
        let app = Bundle.main.bundleURL

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: assets.executable.path))
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: assets.setupScript.path))
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: plugin.appendingPathComponent(
            "Contents/Resources/Legal/ProxyHost/THIRD_PARTY_NOTICES.md"
        ).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: app.appendingPathComponent("Contents/Helpers/threading-proxyd").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: app.appendingPathComponent(
                "Contents/Resources/ProxyTools/apple_certificate.py"
            ).path
        ))
        XCTAssertNoThrow(try ProxyHelperTrust.verify(plugin: plugin, installed: false))

        switch NativePluginCatalog.load(plugin) {
        case .success(let loaded):
            XCTAssertEqual(loaded.pluginIdentifier, NativePluginManagedOffer.proxy.identifier)
            XCTAssertEqual(type(of: loaded).pluginAPIVersion, ThreadingPluginAPI.version)
        case .failure(let failure):
            XCTFail("the bundled Proxy plugin was refused: \(failure)")
        }
    }

    func testAProxyPluginOutsideItsReservedLocationIsRefused() {
        let unrelated = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyPlugin.bundle")
        XCTAssertThrowsError(try ProxyHelperTrust.verify(plugin: unrelated, installed: false))
    }

    func testUnmanagedInstallCannotDisplaceBundledProxyHelper() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-unmanaged-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let plugin = ProxyHelperLocation.installedPlugin(in: directory)
        let assets = ProxyHelperLocation.assets(in: plugin)
        try FileManager.default.createDirectory(
            at: assets.executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: assets.executable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )

        let selected = try ProxyHelperTrust.availableAssets(directory: directory)
        XCTAssertEqual(selected.executable.resolvingSymlinksInPath(), ProxyHelperLocation.assets(
            in: ProxyHelperLocation.bundledPlugin()
        ).executable.resolvingSymlinksInPath())
    }
}
