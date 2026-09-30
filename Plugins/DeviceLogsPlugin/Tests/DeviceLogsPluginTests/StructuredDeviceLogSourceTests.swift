import Foundation
import XCTest
@testable import DeviceLogsPlugin

final class StructuredDeviceLogSourceTests: XCTestCase {

    /// Installing a modern tool must not make an older or temporarily unsupported phone lose the
    /// system log it already had. The structured command exits without a row, then the legacy
    /// reader supplies one through the same source object.
    func testAReaderWithNoStructuredRowsFallsBackToTheLegacyRelay() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-structured-log-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let structuredTool = directory.appendingPathComponent("pymobiledevice3")
        let fallbackTool = directory.appendingPathComponent("idevicesyslog")
        try makeExecutable(
            at: structuredTool,
            script: "#!/bin/sh\necho 'native route unavailable' >&2\nexit 1\n"
        )
        try makeExecutable(
            at: fallbackTool,
            script: "#!/bin/sh\necho 'Sep 29 15:20:01.125000 SpringBoard[42] <Notice>: fallback works'\n"
        )

        let source = StructuredPairedDeviceLogRowSource(
            udid: "PHONE",
            overNetwork: false,
            toolPath: structuredTool.path,
            fallbackToolPath: fallbackTool.path
        )
        let ended = expectation(description: "fallback ended")
        source.onStreamEnded = { _ in ended.fulfill() }
        source.start()
        defer { source.stop() }

        wait(for: [ended], timeout: 5)
        let rows = source.drain()
        let row = try XCTUnwrap(rows.first)
        XCTAssertFalse(source.didDecodeStructuredRow)
        XCTAssertEqual(row.process, "SpringBoard")
        XCTAssertEqual(row.message, "fallback works")
    }

    func testAStructuredReaderThatStaysSilentAlsoFallsBack() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-silent-log-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let structuredTool = directory.appendingPathComponent("pymobiledevice3")
        let fallbackTool = directory.appendingPathComponent("idevicesyslog")
        try makeExecutable(at: structuredTool, script: "#!/bin/sh\nexec /bin/sleep 10\n")
        try makeExecutable(
            at: fallbackTool,
            script: "#!/bin/sh\necho 'Sep 29 15:20:02.125000 SpringBoard[42] <Notice>: silence recovered'\n"
        )

        let source = StructuredPairedDeviceLogRowSource(
            udid: "PHONE",
            overNetwork: false,
            toolPath: structuredTool.path,
            fallbackToolPath: fallbackTool.path,
            structuredStartupDeadline: 0.05
        )
        let ended = expectation(description: "fallback ended")
        source.onStreamEnded = { _ in ended.fulfill() }
        source.start()
        defer { source.stop() }

        wait(for: [ended], timeout: 5)
        XCTAssertEqual(source.drain().first?.message, "silence recovered")
        XCTAssertFalse(source.didDecodeStructuredRow)
    }

    private func makeExecutable(at url: URL, script: String) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
