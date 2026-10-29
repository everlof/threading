import Foundation
import ThreadingPluginKit
import XCTest
@testable import Threading

final class NativePluginDeviceServicesTests: XCTestCase {
    func testStructuredLogUsesFiniteHostOperationAndStopsItsReader() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = folder.appendingPathComponent("device-tool")
        try writeTool("""
            #!/bin/sh
            printf '%s\\n' '{"message":"from host"}'
            sleep 30
            """, to: tool)
        let service = NativePluginDeviceServices(resolveTool: { tool })
        let line = expectation(description: "host log line")
        let stream = try XCTUnwrap(service.startStructuredSystemLog(
            deviceID: "phone-1234", minimumSeverity: 1,
            onLine: { data in
                if String(decoding: data, as: UTF8.self).contains("from host") { line.fulfill() }
            },
            onEnd: { _ in }
        ))
        wait(for: [line], timeout: 3)
        stream.stop()
        XCTAssertNil(service.startStructuredSystemLog(
            deviceID: "bad;id", minimumSeverity: 1,
            onLine: { _ in }, onEnd: { _ in }
        ))
    }

    func testProfileIsValidatedBeforeTheHostRunsItsBoundedCommand() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = folder.appendingPathComponent("device-tool")
        let marker = folder.appendingPathComponent("arguments")
        try writeTool("""
            #!/bin/sh
            printf '%s\\n' "$@" > '\(marker.path)'
            """, to: tool)
        let service = NativePluginDeviceServices(resolveTool: { tool })
        XCTAssertEqual(service.installBluetoothLoggingProfile(Data("wrong".utf8), deviceID: "phone-1234"),
                       .invalidProfile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        let profile = try PropertyListSerialization.data(fromPropertyList: [
            "PayloadType": "Configuration",
            "PayloadIdentifier": "com.apple.bluetooth.logging",
            "PayloadContent": [["PayloadType": "com.apple.bluetooth.logging"]],
        ], format: .xml, options: 0)
        XCTAssertEqual(service.installBluetoothLoggingProfile(profile, deviceID: "phone-1234"), .sent)
        let arguments = try String(contentsOf: marker)
        XCTAssertTrue(arguments.contains("profile\ninstall\n--udid\nphone-1234"))
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-device-services-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func writeTool(_ script: String, to url: URL) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
