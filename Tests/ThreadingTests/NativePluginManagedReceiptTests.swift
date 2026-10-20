import Foundation
import XCTest
@testable import Threading

final class NativePluginManagedReceiptTests: XCTestCase {
    func testInstallOfferIsOnlyAvailableAtItsReservedTopLevelPath() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-plugin-offer-\(UUID().uuidString)", isDirectory: true)
        let deviceLogs = directory.appendingPathComponent("DeviceLogsPlugin.bundle", isDirectory: true)
        XCTAssertEqual(
            NativePluginManagedOffer.at(deviceLogs, directory: directory)?.identifier,
            "codes.threading.plugin.devicelogs"
        )
        XCTAssertEqual(
            NativePluginManagedOffer.at(
                directory.appendingPathComponent("DevicesPlugin.bundle", isDirectory: true),
                directory: directory
            )?.identifier,
            "codes.threading.plugin.devices"
        )
        XCTAssertNil(NativePluginManagedOffer.at(
            directory.appendingPathComponent("nested/DeviceLogsPlugin.bundle", isDirectory: true),
            directory: directory
        ))
        XCTAssertNil(NativePluginManagedOffer.at(
            directory.appendingPathComponent("UnknownPlugin.bundle", isDirectory: true),
            directory: directory
        ))
    }

    func testManagedSymlinkIsRecognizedWhenCallerUsesADirectoryURL() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("native-plugin-receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let version = NativePluginManagedPaths.managedDirectory(in: directory)
            .appendingPathComponent("versions/one")
        let bundle = version.appendingPathComponent("Fixture.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let visible = directory.appendingPathComponent("Fixture.bundle", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: visible, withDestinationURL: bundle)

        let directoryWithoutDirectoryHint = URL(fileURLWithPath: directory.path)
        XCTAssertTrue(NativePluginManagedReceipt.isManagedLocation(
            visible,
            directory: directoryWithoutDirectoryHint
        ))
    }

    func testInstallerOnlyReplacesItsOwnVersionLink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-plugin-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let visible = directory.appendingPathComponent("Fixture.bundle")
        let manual = directory.appendingPathComponent("manual.bundle")
        try FileManager.default.createSymbolicLink(at: visible, withDestinationURL: manual)
        XCTAssertNil(NativePluginManagedPaths.ownedVersion(for: visible, in: directory))

        try FileManager.default.removeItem(at: visible)
        let version = NativePluginManagedPaths.managedDirectory(in: directory)
            .appendingPathComponent("versions/\(UUID().uuidString)")
        let managed = version.appendingPathComponent("Fixture.bundle")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: visible, withDestinationURL: managed)
        XCTAssertEqual(
            NativePluginManagedPaths.ownedVersion(for: visible, in: directory)?.path,
            version.path
        )
    }
}
