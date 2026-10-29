import SQLite3
import XCTest
@testable import DeviceLogsPlugin

final class DeviceLogCaptureMetadataTests: XCTestCase {
    func testStructuredRecordRetainsOriginalLineAndIndependentFields() throws {
        let line = #"{"pid":423,"timestamp":"2026-10-25T11:12:13.123456","level":"ERROR","filename":"/Applications/Ananke.app/Ananke","message":"failed","label":{"subsystem":"com.example.network","category":"connection"}}"#
        let row = try XCTUnwrap(DeviceLogDecoding.pymobiledevice3(Array(line.utf8)[...]))
        XCTAssertEqual(row.pid, 423)
        XCTAssertEqual(row.processPath, "/Applications/Ananke.app/Ananke")
        XCTAssertEqual(row.subsystem, "com.example.network")
        XCTAssertEqual(row.category, "connection")
        XCTAssertEqual(row.rawLine, line)
        XCTAssertEqual(row.source, .system)
        XCTAssertNil(row.bundleID, "a subsystem is not proof of the application's bundle ID")
        XCTAssertFalse(row.id.isEmpty)
    }

    func testDescriptorSourcesRequireExactTapProof() throws {
        func row(subsystem: String, category: String = "tap", message: String) throws -> DeviceLogRow {
            let data = try JSONSerialization.data(withJSONObject: [
                "pid": 423, "filename": "/App.app/App", "message": message,
                "label": ["subsystem": subsystem, "category": category],
            ])
            return try XCTUnwrap(DeviceLogDecoding.pymobiledevice3(Array(data)[...]))
        }
        XCTAssertEqual(try row(subsystem: "codes.threading.logtap", message: "[stdout] hello").source, .stdout)
        XCTAssertEqual(try row(subsystem: "codes.threading.logtap", message: "[stderr] failed").source, .stderr)
        XCTAssertEqual(try row(subsystem: "codes.threading.logtap", message: "[stdio] old tap").source, .console)
        XCTAssertEqual(try row(subsystem: "com.example.app", message: "[stdout] ordinary text").source, .system)
        XCTAssertEqual(try row(subsystem: "codes.threading.logtap", category: "other", message: "[stderr] text").source, .system)
    }

    func testSystemAvailabilityDoesNotClaimStdoutFromSystemLogs() {
        let machine = DeviceLogSourceOption.Machine(id: "sim", title: "Simulator", isSimulator: true)
        let option = DeviceLogSourceOption(machine: machine, title: "System", kind: .simulator(udid: "sim"))
        let availability = option.captureAvailability()
        XCTAssertEqual(availability.availableSources, [.system])
        XCTAssertEqual(availability.unavailableSources, [.stdout, .stderr])
    }

    func testHandoffBoundsAggregatePayloadAndReportsDroppedRows() {
        let source = BufferedDeviceLogSource()
        let payload = String(repeating: "x", count: 1_048_576)
        let row = DeviceLogRow(time: "", level: "Info", process: "App", subsystem: nil, message: payload, rawLine: payload)
        let admitted = BufferedDeviceLogSource.handoffByteCapacity / row.estimatedRetainedBytes
        source.enqueue(Array(repeating: row, count: admitted + 3))
        let rows = source.drain()
        XCTAssertEqual(rows.count, admitted)
        XCTAssertEqual(source.dropped, 3)
        XCTAssertLessThanOrEqual(rows.reduce(0) { $0 + $1.estimatedRetainedBytes }, BufferedDeviceLogSource.handoffByteCapacity)
        source.enqueue(row)
        XCTAssertEqual(source.drain().count, 1, "draining returns the aggregate byte budget")
    }

    func testOversizedRowDoesNotPreventFollowingSmallRowsFromBeingCaptured() {
        let source = BufferedDeviceLogSource()
        let huge = DeviceLogRow(time: "", level: "Info", process: "App", subsystem: nil,
                                message: String(repeating: "x", count: BufferedDeviceLogSource.handoffByteCapacity))
        let small = DeviceLogRow(time: "", level: "Info", process: "App", subsystem: nil, message: "small")
        source.enqueue([huge, small])
        XCTAssertEqual(source.dropped, 1)
        XCTAssertEqual(source.drain().map(\.id), [small.id])
    }

    func testTransportActivitySurvivesEmptySelectedProcessResultAndResetsOnStart() {
        let identity = DeviceLogProcessIdentity(name: "Selected", executablePath: "/Selected.app/Selected")
        let source: any DeviceLogRowSource = BufferedDeviceLogSource(processIdentity: identity)
        let buffered = source as! BufferedDeviceLogSource
        buffered.enqueue(DeviceLogRow(time: "", level: "Info", process: "Other", subsystem: nil, message: "activity", processPath: "/Other.app/Other"))
        XCTAssertTrue(source.drain().isEmpty)
        XCTAssertNotNil(source.lastTransportActivity)
        source.start()
        XCTAssertNil(source.lastTransportActivity)
    }

    func testExecutableIdentityFollowsNewPIDAndNeverGuessesBundle() {
        let identity = DeviceLogProcessIdentity(name: "Ananke", executablePath: "/var/App.app/Ananke", pid: 10, bundleID: "com.example.app")
        func row(pid: Int, path: String?) -> DeviceLogRow {
            DeviceLogRow(time: "", level: "Info", process: "Ananke", subsystem: nil, message: "message", pid: pid, processPath: path)
        }
        XCTAssertTrue(identity.matches(row(pid: 10, path: "/private/var/App.app/Ananke")))
        XCTAssertTrue(identity.matches(row(pid: 20, path: "/var/App.app/Ananke")))
        XCTAssertFalse(identity.matches(row(pid: 20, path: "/var/Other.app/Ananke")))
        XCTAssertTrue(identity.matches(row(pid: 20, path: nil)), "legacy exact-name rows remain usable")
        XCTAssertFalse(identity.provesBundleIdentity(of: row(pid: 20, path: nil)))
        let source = BufferedDeviceLogSource(deviceID: "phone", bundleID: identity.bundleID, processIdentity: identity)
        source.enqueue(row(pid: 20, path: nil))
        XCTAssertNil(source.drain().first?.bundleID, "a legacy name match must not invent bundle proof")
    }

    func testProcessCatalogPreservesTwoExecutablesAndUnknownBundleIDs() throws {
        let data = Data(#"{"result":{"runningProcesses":[{"executable":"file:///var/A.app/Ananke","processIdentifier":10},{"executable":"file:///var/B.app/Ananke","processIdentifier":20},{"executable":"file:///usr/libexec/backboardd","processIdentifier":1}]}}"#.utf8)
        let processes = DeviceLogSourceCatalog.decodeRunningAppProcesses(data)
        XCTAssertEqual(processes.map(\.pid), [10, 20])
        XCTAssertEqual(Set(processes.compactMap(\.executablePath)).count, 2)
        XCTAssertTrue(processes.allSatisfy { $0.bundleID == nil })
    }

    func testSimulatorCatalogUsesBundleExecutableRatherThanDisplayName() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "com.example.chameleon": ["ApplicationType": "User", "CFBundleDisplayName": "Chameleon", "CFBundleExecutable": "Ananke", "Path": "/App/Ananke.app"],
        ], format: .xml, options: 0)
        let app = try XCTUnwrap(DeviceLogSourceCatalog.decodeSimulatorApplications(data).first)
        XCTAssertEqual(app.name, "Chameleon")
        XCTAssertEqual(app.executableName, "Ananke")
        XCTAssertEqual(app.executablePath, "/App/Ananke.app/Ananke")
        XCTAssertEqual(app.bundleID, "com.example.chameleon")
    }

    func testHistoryRetainsStableIdentityRawLineAndSubsecondTimestampAfterReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.sqlite")
        let row = DeviceLogRow(time: "11:12:13.123", level: "Error", process: "Ananke", subsystem: "com.example", message: "failure",
                               timestamp: Date(timeIntervalSince1970: 1_761_390_733.123456), link: "link", id: "stable-record",
                               deviceID: "phone", bundleID: "com.example.app", pid: 423, category: "network", source: .stderr,
                               rawLine: "original unmodified line  ", processPath: "/App.app/Ananke")
        do { try DeviceLogStore(url: file).append([row]) }
        let restored = try XCTUnwrap(try DeviceLogStore(url: file).row(1))
        XCTAssertEqual(restored.id, row.id)
        XCTAssertEqual(restored.timestamp, row.timestamp)
        XCTAssertEqual(restored.rawLine, row.rawLine)
        XCTAssertEqual(restored.bundleID, row.bundleID)
        XCTAssertEqual(restored.deviceID, row.deviceID)
        XCTAssertEqual(restored.pid, row.pid)
        XCTAssertEqual(restored.category, row.category)
        XCTAssertEqual(restored.source, row.source)
        XCTAssertEqual(restored.processPath, row.processPath)
        XCTAssertEqual(restored.link, row.link)
    }

    func testLegacyHistoryMigratesWithoutInventingSourceOrChangingIdentityOnReopen() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TABLE rows (id INTEGER PRIMARY KEY, instant_ms INTEGER, clock TEXT NOT NULL, level TEXT NOT NULL, severity INTEGER NOT NULL, process TEXT NOT NULL, subsystem TEXT, message TEXT NOT NULL); INSERT INTO rows VALUES(1,NULL,'','Info',1,'App',NULL,'old message');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let first = try XCTUnwrap(try DeviceLogStore(url: file).row(1))
        let reopened = try XCTUnwrap(try DeviceLogStore(url: file).row(1))
        XCTAssertEqual(first.id, reopened.id)
        XCTAssertEqual(first.source, .unknown)
        XCTAssertEqual(first.rawLine, "old message")
        XCTAssertNil(first.pid)
    }
}
