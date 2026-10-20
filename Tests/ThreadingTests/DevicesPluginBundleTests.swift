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
        case .failure(let failure):
            XCTFail("the bundled Devices plugin was refused: \(failure)")
        }
    }

    func testAHelperOutsideTheDeviceBundleIsRefused() {
        let unrelated = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-simulator-helper")
        XCTAssertThrowsError(try SimulatorHelperTrust.verify(executableURL: unrelated))
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
