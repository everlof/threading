import Foundation
import XCTest
@testable import DeviceLogsPlugin

final class BluetoothPacketTests: XCTestCase {
    func testEveryChunkBoundaryPreservesTimestampDirectionAndCommand() throws {
        for littleEndian in [false, true] {
            let data = Self.header(littleEndian: littleEndian)
                + Self.packet([1, 0x03, 0x0c, 0], littleEndian: littleEndian)
            for split in 0...data.count {
                var decoder = BluetoothPacketDecoder()
                let rows = try decoder.append(data.prefix(split)) + decoder.append(data.dropFirst(split))
                try decoder.finish()
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows.first?.time, "00:00:01.123456")
                XCTAssertEqual(rows.first?.timestamp?.timeIntervalSince1970 ?? 0, 1.123456, accuracy: 0.000001)
                XCTAssertTrue(rows.first?.message.contains("TX HCI Command 0x0c03 Reset") == true)
                XCTAssertTrue(rows.first?.message.contains("03 0c 00") == true)
            }
        }
    }

    func testATTWriteAndNotificationAreDecodedOnlyForCompleteL2CAP() throws {
        // handle=1, PB=start, L2CAP length=4, ATT fixed channel, Write Command, attribute 0x25.
        let acl: [UInt8] = [2, 1, 0x20, 8, 0, 4, 0, 4, 0, 0x52, 0x25, 0, 0xab]
        var decoder = BluetoothPacketDecoder()
        let write = try XCTUnwrap(decoder.append(Self.header() + Self.packet(acl)).first)
        XCTAssertEqual(write.subsystem, "ATT")
        XCTAssertTrue(write.message.contains("Write Command attribute=0x0025"))

        var notification = acl
        notification[9] = 0x1b
        let received = try XCTUnwrap(decoder.append(Self.packet(notification, incoming: true)).first)
        XCTAssertTrue(received.message.hasPrefix("RX"))
        XCTAssertTrue(received.message.contains("Handle Value Notification"))

        var continuation = acl
        continuation[2] = 0x10
        let fragment = try XCTUnwrap(decoder.append(Self.packet(continuation)).first)
        XCTAssertEqual(fragment.subsystem, "ACL")
        XCTAssertTrue(fragment.message.contains("continuation"))
        continuation = acl
        continuation[5] = 10
        let firstFragment = try XCTUnwrap(decoder.append(Self.packet(continuation)).first)
        XCTAssertEqual(firstFragment.subsystem, "L2CAP")
        XCTAssertTrue(firstFragment.message.contains("start 8/14"), firstFragment.message)
    }

    func testMalformedLengthsLinkTypeAndTruncatedStreamAreRejected() throws {
        var header = Self.header()
        header[23] = 1
        var decoder = BluetoothPacketDecoder()
        XCTAssertThrowsError(try decoder.append(header))

        var record = Self.packet([1, 0x03, 0x0c, 0])
        record.replaceSubrange(8..<12, with: [0x7f, 0xff, 0xff, 0xff])
        decoder = BluetoothPacketDecoder()
        XCTAssertThrowsError(try decoder.append(Self.header() + record))
        XCTAssertLessThan(decoder.bufferedBytes, 100)

        decoder = BluetoothPacketDecoder()
        _ = try decoder.append(Self.header() + Self.packet([4, 0x0e, 0]).dropLast())
        XCTAssertThrowsError(try decoder.finish())
    }

    func testRecordLargerThanTheToolsDeclaredSnapshotLengthIsDecoded() throws {
        // idevicebtlogger declares snaplen 2,048 but writes whole packets; a long ACL exceeded
        // it on a real phone and stopped the reader with "invalid packet length or timestamp".
        let body = [UInt8](repeating: 0xaa, count: 2_100)
        let l2cap = [UInt8(body.count & 0xff), UInt8(body.count >> 8), 0x40, 0]
        let aclLength = l2cap.count + body.count
        let acl = [UInt8(2), 0x1a, 0x20, UInt8(aclLength & 0xff), UInt8(aclLength >> 8)] + l2cap + body
        var decoder = BluetoothPacketDecoder()
        let rows = try decoder.append(Self.header() + Self.packet(acl, incoming: true))
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.subsystem, "L2CAP")
        XCTAssertTrue(row.message.contains("RX ACL handle=0x001a CID=0x0040 · \(acl.count - 1) bytes"), row.message)
        XCTAssertEqual(decoder.bufferedBytes, 0)
    }

    func testCommandStatusErrorAndPreviewLimit() throws {
        var decoder = BluetoothPacketDecoder()
        let status = try XCTUnwrap(decoder.append(
            Self.header() + Self.packet([4, 0x0f, 4, 0x0c, 1, 0x0d, 0x20], incoming: true)
        ).first)
        XCTAssertEqual(status.level, "Error")
        XCTAssertTrue(status.message.contains("Command Status opcode=0x200d status=0x000c"))
        let data = [UInt8(3)] + [UInt8](repeating: 0xaa, count: 1_000)
        let row = try XCTUnwrap(decoder.append(Self.packet(data)).first)
        XCTAssertTrue(row.message.contains("744 bytes omitted"))
        XCTAssertLessThan(row.message.utf8.count, 900)
    }

    func testBurstKeepsOnlyAnIncompletePacketBetweenReads() throws {
        let count = ProcessInfo.processInfo.environment["THREADING_BLUETOOTH_STRESS"] == "1" ? 100_000 : 2_000
        let packet = Self.packet([1, 0x03, 0x0c, 0])
        var decoder = BluetoothPacketDecoder()
        _ = try decoder.append(Self.header())
        let started = Date()
        var decoded = 0
        // 1,000 small packets fit in one bounded pipe chunk.
        let batch = (0..<1_000).reduce(into: Data()) { data, _ in data.append(packet) }
        for _ in 0..<count / 1_000 {
            decoded += try decoder.append(batch).count
            XCTAssertEqual(decoder.bufferedBytes, 0)
        }
        XCTAssertEqual(decoded, count)
        print("Bluetooth decoder: \(count) packets in \(Date().timeIntervalSince(started)) seconds; retained bytes=\(decoder.bufferedBytes)")
    }

    func testShippingSourceDeliversFinalPacketBeforeEndingAndReportsMalformedInput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = directory.appendingPathComponent("capture.pcap")
        try (Self.header() + Self.packet([1, 0x03, 0x0c, 0])).write(to: capture)
        let tool = directory.appendingPathComponent("reader")
        try "#!/bin/sh\nexec /bin/cat '\(capture.path)'\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let source = BluetoothLogRowSource(udid: "fixture", overNetwork: false, toolPath: tool.path)
        let ended = expectation(description: "reader reached EOF")
        source.onStreamEnded = { _ in ended.fulfill() }
        source.start()
        wait(for: [ended], timeout: 3)
        XCTAssertEqual(source.drain().count, 1, "EOF must not overtake buffered stdout")
        source.stop()

        try Data("not a capture file with at least 24 bytes".utf8).write(to: capture)
        let invalid = expectation(description: "invalid input is reported")
        source.onStreamEnded = { reason in
            XCTAssertTrue(reason.contains("Invalid Bluetooth capture"), reason)
            invalid.fulfill()
        }
        source.start()
        wait(for: [invalid], timeout: 3)
        XCTAssertTrue(source.drain().isEmpty)
        source.stop()
    }

    func testMissingToolIsAnActionableFailureAndTransportPinsOnePhone() {
        XCTAssertEqual(BluetoothLogRowSource.arguments(udid: "phone", overNetwork: false),
                       ["-u", "phone", "-x", "-f", "pcap", "-"])
        XCTAssertEqual(BluetoothLogRowSource.arguments(udid: "phone", overNetwork: true),
                       ["-u", "phone", "-x", "-f", "pcap", "-n", "-"])
        let source = BluetoothLogRowSource(udid: "phone", overNetwork: false, toolPath: nil)
        let ended = expectation(description: "missing dependency")
        source.onStreamEnded = { reason in
            XCTAssertTrue(reason.contains("brew install libimobiledevice"))
            ended.fulfill()
        }
        source.start()
        wait(for: [ended], timeout: 2)
    }

    func testSilentChildCanBeStoppedAndServiceFailureDoesNotWaitForExit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let tool = directory.appendingPathComponent("reader")
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 60\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let source = BluetoothLogRowSource(udid: "fixture", overNetwork: false, toolPath: tool.path)
        source.start()
        defer { source.stop() }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let pid = try XCTUnwrap(Int32(try String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), 0)
        source.stop()
        let stopped = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0, Date() < stopped { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertNotEqual(kill(pid, 0), 0, "a silent child must not outlive its pane")

        try "#!/bin/sh\necho 'ERROR: Unable to start capturing bt_packet_logger.' >&2\nexec /bin/sleep 60\n"
            .write(to: tool, atomically: true, encoding: .utf8)
        let failed = expectation(description: "service-start failure without EOF")
        source.onStreamEnded = { reason in
            XCTAssertTrue(reason.contains("Unable to start capturing"))
            failed.fulfill()
        }
        source.start()
        wait(for: [failed], timeout: 3)
    }

    /// Opt-in hardware proof uses discovery and the same source the app ships.
    func testLivePhoneProducesPackets() throws {
        guard let udid = ProcessInfo.processInfo.environment["THREADING_BLUETOOTH_LIVE_UDID"],
              !udid.isEmpty else { throw XCTSkip("Set THREADING_BLUETOOTH_LIVE_UDID with a prepared phone") }
        let found = expectation(description: "discovered phone")
        let source = BluetoothTestSourceBox()
        DeviceLogSourceCatalog.discover { options in
            source.set(options.first {
                guard $0.machine.id == udid else { return false }
                if case .bluetooth = $0.kind { return true }
                return false
            }?.makeSource(predicate: nil) as? BluetoothLogRowSource)
            found.fulfill()
        }
        wait(for: [found], timeout: 60)
        let reader = try XCTUnwrap(source.get())
        reader.start()
        defer { reader.stop() }
        let deadline = Date().addingTimeInterval(18)
        var rows: [DeviceLogRow] = []
        while rows.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            rows = reader.drain()
        }
        XCTAssertFalse(rows.isEmpty, "No packets; install Apple's profile and generate Bluetooth activity")
        XCTAssertTrue(rows.allSatisfy { $0.process == "Bluetooth" && $0.timestamp != nil })
        print("Bluetooth hardware probe: \(rows.count) packets; protocols=\(Set(rows.compactMap(\.subsystem)))")
    }

    /// idevicebtlogger's own header declares a 2,048-byte snapshot length.
    static func header(littleEndian: Bool = false, snapLength: Int = 2_048) -> Data {
        var data = Data(littleEndian ? [0xd4, 0xc3, 0xb2, 0xa1] : [0xa1, 0xb2, 0xc3, 0xd4])
        data.append(contentsOf: littleEndian ? [2, 0, 4, 0] : [0, 2, 0, 4])
        for value in [0, 0, snapLength, 201] { data.append(word(value, littleEndian: littleEndian)) }
        return data
    }

    static func packet(_ h4: [UInt8], incoming: Bool = false, littleEndian: Bool = false) -> Data {
        var data = Data()
        for value in [1, 123_456, h4.count + 4, h4.count + 4] {
            data.append(word(value, littleEndian: littleEndian))
        }
        data.append(contentsOf: [0, 0, 0, incoming ? 1 : 0])
        data.append(contentsOf: h4)
        return data
    }

    private static func word(_ value: Int, littleEndian: Bool) -> Data {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        return Data(littleEndian ? bytes.reversed() : bytes)
    }
}

private final class BluetoothTestSourceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var source: BluetoothLogRowSource?
    func set(_ source: BluetoothLogRowSource?) {
        lock.lock()
        self.source = source
        lock.unlock()
    }
    func get() -> BluetoothLogRowSource? {
        lock.lock()
        defer { lock.unlock() }
        return source
    }
}
