import Foundation
import XCTest
@testable import Threading

final class NativePluginManagedUsageTests: XCTestCase {
    func testUsedPluginsSurviveBuildRefreshAndRemainBounded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-plugin-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try NativePluginManagedUsage.record("codes.threading.plugin.t3", in: directory)
        try NativePluginManagedUsage.record("codes.threading.plugin.devices", in: directory)
        try NativePluginManagedUsage.record("codes.threading.plugin.t3", in: directory)
        try NativePluginManagedUsage.markRefreshed("release-v1", in: directory)

        let state = try NativePluginManagedUsage.read(in: directory)
        XCTAssertEqual(state.identifiers, [
            "codes.threading.plugin.devices", "codes.threading.plugin.t3",
        ])
        XCTAssertEqual(state.lastRefreshedBuild, "release-v1")
    }

    func testOversizedUsageRecordIsRejectedBeforeDecoding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-plugin-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let managed = NativePluginManagedPaths.managedDirectory(in: directory)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 8 * 1024 + 1)
            .write(to: managed.appendingPathComponent("usage.json"))

        XCTAssertThrowsError(try NativePluginManagedUsage.read(in: directory))
    }
}
