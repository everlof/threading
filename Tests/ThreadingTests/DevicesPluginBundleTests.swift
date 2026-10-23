import AppKit
import XCTest
import ThreadingPluginKit
@testable import Threading

@MainActor
final class DevicesPluginBundleTests: XCTestCase {
    func testBundledDevicesPluginOwnsTheTrustedSimulatorHelper() throws {
        let bundle = SimulatorHelperLocation.bundledExecutable()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        XCTAssertEqual(bundle.lastPathComponent, "DevicesPlugin.bundle")

        let helper = SimulatorHelperLocation.bundledExecutable()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/threading-simulator-helper").path))
        XCTAssertNoThrow(try SimulatorHelperTrust.verify(executableURL: helper))

        switch NativePluginCatalog.load(bundle) {
        case .success(let plugin):
            XCTAssertEqual(plugin.pluginIdentifier, NativePluginManagedOffer.devices.identifier)
            XCTAssertEqual(type(of: plugin).pluginAPIVersion, ThreadingPluginAPI.version)
            XCTAssertNotNil(plugin.makePaneView)
        case .failure(let failure):
            XCTFail("the bundled Devices plugin was refused: \(failure)")
        }
        let pane = try XCTUnwrap(NativePluginPaneDiscovery.descriptor(at: bundle, isBundled: true))
        XCTAssertEqual(pane.sections.map(\.identifier), ["snapshots"])
        XCTAssertEqual(pane.routes.map(\.identifier), ["from-device"])
    }

    func testAHelperOutsideTheDeviceBundleIsRefused() {
        let unrelated = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-simulator-helper")
        XCTAssertThrowsError(try SimulatorHelperTrust.verify(executableURL: unrelated))
    }

    func testSnapshotsPaneUsesTheNativeHostAndSharedImageComponent() throws {
        let bundle = try XCTUnwrap(NativePluginCatalog.bundledPlugin(
            identifier: NativePluginManagedOffer.devices.identifier
        ))
        let host = NativePluginPaneViewController(
            bundleURL: bundle, owningSessionID: nil,
            loadPlugin: { _ in NativePluginCatalog.load(bundle) }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.contentViewController = host
        window.setContentSize(NSSize(width: 640, height: 420))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(host.view.bounds.width, 600)

        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        let kinds = descendants(host.view).map { String(describing: type(of: $0)) }
        XCTAssertTrue(kinds.contains("PaneHeaderView"), "\(kinds)")
        XCTAssertTrue(kinds.contains("ThemedBitmapView"), "\(kinds)")

        if let path = ProcessInfo.processInfo.environment["THREADING_DEVICE_SNAPSHOT_RENDER_PATH"] {
            let image = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    func testSnapshotsPaneBuiltFromTheExportedSDKLoadsInTheNativeHost() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_EXTERNAL_DEVICES_BUNDLE"] != nil,
            "Set TEST_RUNNER_THREADING_EXTERNAL_DEVICES_BUNDLE to an SDK-built Devices bundle."
        )
        let path = try XCTUnwrap(
            ProcessInfo.processInfo.environment["THREADING_EXTERNAL_DEVICES_BUNDLE"]
        )
        let bundle = URL(fileURLWithPath: path)
        XCTAssertFalse(bundle.path.hasPrefix(Bundle.main.bundleURL.path))
        let identity = try PluginLoader.identity(of: bundle)
        let descriptor = try XCTUnwrap(NativePluginPaneDiscovery.descriptor(
            at: bundle, isBundled: false, verifiedInstalledIdentity: identity
        ))
        XCTAssertEqual(descriptor.sections.map(\.identifier), ["snapshots"])

        let plugin = try PluginLoader.signatureAndDecision().load(bundleAt: bundle) {
            $0 == identity
        }
        XCTAssertEqual(type(of: plugin).pluginAPIVersion, ThreadingPluginAPI.version)
        let host = NativePluginPaneViewController(
            bundleURL: bundle, owningSessionID: nil,
            loadPlugin: { _ in .success(plugin) }
        )
        host.loadView()
        XCTAssertEqual(host.loaded?.pluginIdentifier, NativePluginManagedOffer.devices.identifier)
        XCTAssertTrue(host.view.subviews.flatMap { [$0] + $0.subviews }
            .contains { String(describing: type(of: $0)) == "ThemedBitmapView" })
    }

    func testAnUnmanagedInstallCannotDisplaceTheBundledHelper() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devices-unmanaged-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = SimulatorHelperLocation.installedExecutable(in: directory)
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: helper, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )

        let selected = try SimulatorHelperTrust.availableExecutable(directory: directory)
        XCTAssertEqual(
            selected.standardizedFileURL,
            SimulatorHelperLocation.bundledExecutable().resolvingSymlinksInPath()
                .standardizedFileURL
        )
    }
}
