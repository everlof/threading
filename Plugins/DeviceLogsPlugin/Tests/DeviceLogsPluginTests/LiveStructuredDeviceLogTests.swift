import Foundation
import XCTest
@testable import DeviceLogsPlugin

/// Opt-in proof through the shipping source, not just through the command-line tool.
///
/// It is skipped in ordinary builds. A developer with a paired phone can set the two environment
/// variables to verify the native RSD route before changing the phone's OS or the external tool.
final class LiveStructuredDeviceLogTests: XCTestCase {

    func testAConnectedPhoneStreamsStructuredUnifiedLogRows() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let udid = environment["THREADING_DEVICE_LOG_LIVE_UDID"], !udid.isEmpty,
              let toolPath = environment["THREADING_PHYSICAL_DEVICE_PROBE_PATH"],
              FileManager.default.isExecutableFile(atPath: toolPath)
        else {
            throw XCTSkip(
                "Set THREADING_DEVICE_LOG_LIVE_UDID and "
                    + "THREADING_PHYSICAL_DEVICE_PROBE_PATH to run the read-only phone probe."
            )
        }

        let discoveryFinished = expectation(description: "device-log discovery finished")
        let discovered = LockedValue<[DeviceLogSourceOption]>([])
        DeviceLogSourceCatalog.discover { options in
            discovered.set(options)
            discoveryFinished.fulfill()
        }
        wait(for: [discoveryFinished], timeout: 45)

        let option = try XCTUnwrap(
            discovered.value.first {
                $0.machine.id == udid && $0.title.hasPrefix("System log")
            },
            "the connected phone was not offered by Device Logs discovery"
        )
        guard case .structuredDevice(_, _, let selectedToolPath, _) = option.kind else {
            return XCTFail("discovery did not select the structured live reader: \(option.kind)")
        }
        XCTAssertEqual(selectedToolPath, toolPath)

        let source = try XCTUnwrap(
            option.makeSource(predicate: nil) as? StructuredPairedDeviceLogRowSource
        )
        source.start()
        defer { source.stop() }

        let deadline = Date().addingTimeInterval(12)
        var rows: [DeviceLogRow] = []
        while rows.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            rows.append(contentsOf: source.drain())
        }

        XCTAssertTrue(source.didDecodeStructuredRow, "the source never decoded modern NDJSON")
        XCTAssertFalse(rows.isEmpty, "the connected phone produced no unified-log rows")
        XCTAssertTrue(rows.contains { $0.time != DeviceLogLimits.undatedTime })
        XCTAssertTrue(rows.contains { $0.process != "?" })
        XCTAssertTrue(
            rows.contains { $0.subsystem?.contains("com.apple") == true },
            "the stream never carried a real subsystem/category label"
        )
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
