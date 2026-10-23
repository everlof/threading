import Foundation
import ThreadingPluginKit
import XCTest
@testable import DeviceLogsPlugin

final class StructuredDeviceLogSourceTests: XCTestCase {
    func testBrokeredStructuredReaderUsesPublicDeviceService() throws {
        let service = TestDeviceLogService()
        let source = StructuredPairedDeviceLogRowSource(
            udid: "PHONE", overNetwork: false, deviceServices: service,
            fallbackToolPath: nil, minimumSeverity: 3
        )
        let ended = expectation(description: "brokered stream ended")
        source.onStreamEnded = { _ in ended.fulfill() }
        source.start()
        wait(for: [ended], timeout: 5)
        source.stop()

        XCTAssertEqual(service.requestedDeviceID, "PHONE")
        XCTAssertEqual(service.requestedSeverity, 3)
        XCTAssertEqual(source.drain().map(\.message), ["error"])
        XCTAssertTrue(source.didDecodeStructuredRow)
        XCTAssertTrue(service.stream.wasStopped)
    }

    func testExactProcessScopeFiltersBeforeBufferingAndQuietAppDoesNotTriggerFallback() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-scoped-log-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let structured = directory.appendingPathComponent("pymobiledevice3")
        let fallback = directory.appendingPathComponent("idevicesyslog")
        try makeExecutable(at: structured, script: """
        #!/bin/sh
        echo '{"timestamp":"2026-09-29T15:11:04.497349","level":"NOTICE","filename":"/kernel","message":"Ananke connected"}'
        echo '{"timestamp":"2026-09-29T15:11:04.497349","level":"NOTICE","filename":"/Apps/Ananke","message":"ready"}'
        echo '{"timestamp":"2026-09-29T15:11:04.497349","level":"NOTICE","filename":"/Apps/AnankeHelper","message":"helper"}'
        """)
        try makeExecutable(at: fallback, script: "#!/bin/sh\necho 'Sep 29 15:20:01.125000 Silent[42] <Notice>: wrong fallback'\n")

        for process in ["Ananke", "Silent"] {
            let source = StructuredPairedDeviceLogRowSource(
                udid: "PHONE", overNetwork: false, toolPath: structured.path,
                fallbackToolPath: fallback.path, processName: process
            )
            let ended = expectation(description: "scoped stream ended")
            source.onStreamEnded = { _ in ended.fulfill() }
            source.start()
            wait(for: [ended], timeout: 5)
            source.stop()
            XCTAssertTrue(source.didDecodeStructuredRow)
            XCTAssertEqual(source.drain().map(\.process), process == "Ananke" ? ["Ananke"] : [])
            XCTAssertEqual(source.dropped, 0)
        }
    }

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

    /// Errors only: the phone is asked for neither Debug nor Info, and the Notice rows the tool
    /// still sends are dropped before buffering. A phone that is quiet at that level has still
    /// produced structured rows, so it must not fall back to the relay.
    func testTheStructuredRouteAsksThePhoneForTheLevelAndQuietIsNotAFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-level-log-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let structured = directory.appendingPathComponent("pymobiledevice3")
        let fallback = directory.appendingPathComponent("idevicesyslog")
        let asked = directory.appendingPathComponent("arguments")
        try makeExecutable(at: structured, script: """
        #!/bin/sh
        echo "$@" > '\(asked.path)'
        echo '{"timestamp":"2026-10-18T12:47:28.047435","level":"NOTICE","filename":"/kernel","message":"notice"}'
        echo '{"timestamp":"2026-10-18T12:47:28.047510","level":"ERROR","filename":"/kernel","message":"error"}'
        """)
        try makeExecutable(at: fallback, script: "#!/bin/sh\necho 'Oct 18 12:47:28.047435 Relay[1] <Error>: wrong fallback'\n")

        let source = StructuredPairedDeviceLogRowSource(
            udid: "PHONE", overNetwork: false, toolPath: structured.path,
            fallbackToolPath: fallback.path, minimumSeverity: 3
        )
        let ended = expectation(description: "levelled stream ended")
        source.onStreamEnded = { _ in ended.fulfill() }
        source.start()
        wait(for: [ended], timeout: 5)
        source.stop()
        XCTAssertEqual(source.drain().map(\.message), ["error"])
        XCTAssertTrue(source.didDecodeStructuredRow)
        let arguments = try String(contentsOf: asked, encoding: .utf8).split(whereSeparator: \.isWhitespace).map(String.init)
        XCTAssertTrue(arguments.contains("--no-debug"))
        XCTAssertTrue(arguments.contains("--no-info"))
    }

    /// The relay has no level option, so the level is applied as each line is decoded: a Debug
    /// row never reaches the ring or the recorder only to be hidden there.
    func testTheLegacyRelayDropsRowsBelowTheLevelBeforeBuffering() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-relay-level-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appendingPathComponent("idevicesyslog")
        try makeExecutable(at: tool, script: """
        #!/bin/sh
        echo 'Oct 18 12:47:28.047435 remoted[42] <Debug>: debug'
        echo 'Oct 18 12:47:28.047510 locationd[43] <Info>: info'
        echo 'Oct 18 12:47:28.047525 kernel[0] <Notice>: notice'
        """)
        let source = PairedDeviceLogRowSource(udid: "PHONE", overNetwork: false, toolPath: tool.path, minimumSeverity: 1)
        source.reclaimRelay = { _, _ in }
        let ended = expectation(description: "relay ended")
        source.onStreamEnded = { _ in ended.fulfill() }
        source.start()
        wait(for: [ended], timeout: 5)
        source.stop()
        XCTAssertEqual(source.drain().map(\.message), ["info", "notice"])
    }

    private func makeExecutable(at url: URL, script: String) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func testLegacyStartAndStopDoNotWaitForReclaimOrLaunchAfterCancellation() throws {
        try assertCancellationWhileReclaiming(structured: false)
    }

    func testStructuredStopDoesNotWaitForReclaimOrLaunchFallbackAfterCancellation() throws {
        try assertCancellationWhileReclaiming(structured: true)
    }

    private func assertCancellationWhileReclaiming(structured: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-log-cancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let structuredTool = directory.appendingPathComponent("structured")
        let fallbackTool = directory.appendingPathComponent("legacy")
        let marker = directory.appendingPathComponent("launched")
        try makeExecutable(at: structuredTool, script: "#!/bin/sh\nexit 1\n")
        try makeExecutable(at: fallbackTool, script: "#!/bin/sh\ntouch '\(marker.path)'\n")

        let entered = expectation(description: "reclaim entered")
        let released = expectation(description: "reclaim released")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let reclaim: @Sendable (String, String) -> Void = { _, _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
            released.fulfill()
        }
        let source: BufferedDeviceLogSource
        if structured {
            let reader = StructuredPairedDeviceLogRowSource(
                udid: "PHONE", overNetwork: false, toolPath: structuredTool.path,
                fallbackToolPath: fallbackTool.path
            )
            reader.reclaimRelay = reclaim
            source = reader
        } else {
            let reader = PairedDeviceLogRowSource(
                udid: "PHONE", overNetwork: false, toolPath: fallbackTool.path
            )
            reader.reclaimRelay = reclaim
            source = reader
        }
        let unexpectedEnd = expectation(description: "cancelled reader must not launch")
        unexpectedEnd.isInverted = true
        source.onStreamEnded = { _ in unexpectedEnd.fulfill() }
        let startTime = CFAbsoluteTimeGetCurrent()
        source.start()
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - startTime, 0.1)
        wait(for: [entered], timeout: 1)
        let stopTime = CFAbsoluteTimeGetCurrent()
        source.stop()
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - stopTime, 0.1)
        release.signal()
        wait(for: [released], timeout: 1)
        wait(for: [unexpectedEnd], timeout: 0.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(source.drain().isEmpty)
    }
}

private final class TestDeviceLogService: PluginDeviceServices, @unchecked Sendable {
    let stream = TestDeviceLogStream()
    private let lock = NSLock()
    private var request: (String, Int)?

    var requestedDeviceID: String? { lock.withLock { request?.0 } }
    var requestedSeverity: Int? { lock.withLock { request?.1 } }

    func hasStructuredSystemLog() -> Bool { true }

    func startStructuredSystemLog(
        deviceID: String, minimumSeverity: Int,
        onLine: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (String) -> Void
    ) -> (any PluginDeviceLogStream)? {
        lock.withLock { request = (deviceID, minimumSeverity) }
        onLine(Data(#"{"timestamp":"2026-10-18T12:47:28.047435","level":"NOTICE","filename":"/kernel","message":"notice"}"#.utf8))
        onLine(Data(#"{"timestamp":"2026-10-18T12:47:28.047510","level":"ERROR","filename":"/kernel","message":"error"}"#.utf8))
        onEnd("test stream ended")
        return stream
    }

    func installBluetoothLoggingProfile(_ profile: Data, deviceID: String) -> PluginDeviceOperationResult {
        .toolUnavailable
    }
}

private final class TestDeviceLogStream: PluginDeviceLogStream, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var wasStopped: Bool { lock.withLock { stopped } }

    func stop() { lock.withLock { stopped = true } }
}
