import Foundation
import XCTest
@testable import DeviceLogsPlugin

/// Reading across packets: bit fields, conditional fields, a switch on another characteristic,
/// severities, transactions and streams. Each fixture is the shape a real protocol has — a
/// write-then-read command channel, an async error notification, a firmware log split at
/// arbitrary bytes, a firmware image with a CRC — but written generically.
final class BluetoothFlowTests: XCTestCase {

    // MARK: Values

    func testBitsConditionsAndLevels() throws {
        let definitions = try BluetoothPacketDefinitions.compile("""
            services:
              - name: Watch
                characteristics:
                  - { name: Header, handle: 0x10, message: Header }
                  - { name: Rate, handle: 0x12, message: Rate }
            types:
              Header:
                seq:
                  - id: word
                    type: u16
                    bits: { command: { bits: 0-7, enum: Command }, token: 8-15 }
                  - id: body
                    type: { switch-on: word.command, cases: { ping: Ping, _: bytes } }
              Ping:
                seq:
                  - { id: status, type: u8, enum: Status }
              Rate:
                seq:
                  - { id: flags, type: u8, flags: { wide: 0, energy: 3 } }
                  - { id: narrow, type: u8, if: "!wide" }
                  - { id: wide, type: u16, if: wide }
                  - { id: energy, type: u16, if: energy }
            enums:
              Command: { 1: ping }
              Status:
                0: { name: ok, level: info }
                5: { name: BATTERY_WARNING, level: warning }
                9: { name: broken, level: error }
            """)
        let ping = definitions.decode([0x01, 0x2a, 0x09], as: .named("Header"))
        XCTAssertEqual(ping.text, "word={command=ping token=42} body={status=broken}")
        XCTAssertEqual(ping.level, .error)
        XCTAssertEqual(ping.values["token"], .number(42, name: nil))
        XCTAssertEqual(ping.values["word.command"], .number(1, name: "ping"))
        XCTAssertEqual(definitions.decode([0x01, 0x00, 0x05], as: .named("Header")).level, .warning)

        XCTAssertEqual(definitions.decode([0x00, 72], as: .named("Rate")).text, "flags=none narrow=72")
        XCTAssertEqual(definitions.decode([0x09, 0x2c, 0x01, 0x10, 0x00], as: .named("Rate")).text,
                       "flags=wide|energy wide=300 energy=16")
        XCTAssertNil(definitions.decode([0x09, 0x2c, 0x01, 0x10, 0x00], as: .named("Rate")).problem)
    }

    func testMessagePackLevelsRepeatingShapesAndNamedInnerKeys() throws {
        let definitions = try BluetoothPacketDefinitions.compile("""
            services:
              - name: Watch
                characteristics:
                  - { name: Command, handle: 0x10, message: Message }
            types:
              Message:
                summary: "{value}"
                seq:
                  - id: value
                    type: msgpack
                    match:
                      - { pattern: "{ error: $code:int }", summary: "error {code}", level: error }
                      - { pattern: "{ diag: $fields }", summary: "diag {fields}" }
                      - { pattern: "{ $cmd: $value }", summary: "{cmd} {value}" }
                    enum: { cmd: Name, code: Error, fields: Name }
                    values: Values
            enums:
              Name: { 1: error, 2: alarm, 3: diag, 40: uptime, 41: resets }
              Error:
                22: { name: BATTERY_OK, level: info }
                4: OUT_OF_MEMORY
            shapes:
              Values:
                alarm: [hours, minutes, days, ...]
            """)
        let type = BluetoothPacketDefinitions.TypeRef.named("Message")
        // {1: 22} — error BATTERY_OK is not an error.
        let ok = definitions.decode([0x81, 0x01, 0x16], as: type)
        XCTAssertEqual(ok.text, "error BATTERY_OK")
        XCTAssertEqual(ok.level, .info)
        XCTAssertEqual(definitions.decode([0x81, 0x01, 0x04], as: type).level, .error)
        // {2: [7, 30, 31, 9, 0, 96]} — two alarms.
        XCTAssertEqual(definitions.decode([0x81, 0x02, 0x96, 7, 30, 31, 9, 0, 0x60], as: type).text,
                       "alarm {hours=7 minutes=30 days=31}, {hours=9 minutes=0 days=96}")
        // {3: {40: 1000, 41: 2}} — the diag map's keys are names from the same id space.
        XCTAssertEqual(definitions.decode([0x81, 0x03, 0x82, 40, 0xcd, 0x03, 0xe8, 41, 2], as: type).text,
                       "diag {uptime=1000 resets=2}")
    }

    func testASwitchOnAnotherCharacteristicReadsItsLastValue() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile("""
            services:
              - name: DFU
                characteristics:
                  - { name: Control Point, handle: 0x20, message: { seq: [{ id: op, type: u8, enum: Op }] } }
                  - name: Packet
                    handle: 0x22
                    message:
                      switch-on: Control Point.op
                      cases:
                        START: { seq: [{ id: softdevice, type: u32 }, { id: bootloader, type: u32 }, { id: application, type: u32 }] }
                        _: bytes
            enums:
              Op: { 1: START, 3: RECEIVE }
            """)
        let early = write(0x22, [1, 2], &session).text
        XCTAssertTrue(early.hasSuffix("<Control Point.op not seen yet> <0102>"), early)
        _ = write(0x20, [0x01], &session)
        let sizes = write(0x22, [0, 0, 0, 0] + [0, 0, 0, 0] + [0x00, 0x10, 0x00, 0x00], &session)
        XCTAssertTrue(sizes.text.hasSuffix("Packet write · softdevice=0 bootloader=0 application=4096"), sizes.text)
        _ = write(0x20, [0x03], &session)
        XCTAssertTrue(write(0x22, [0xde, 0xad], &session).text.hasSuffix("Packet write · <dead>"))
    }

    // MARK: Transactions

    static let commandYAML = """
        services:
          - name: Watch
            characteristics:
              - { name: Command, handle: 0x2e, message: Message }
              - { name: Events, handle: 0x30, message: Message }
        types:
          Message:
            summary: "{value}"
            seq:
              - id: value
                type: msgpack
                match:
                  - { pattern: "{ error: $code:int }", summary: "error {code}", level: error }
                  - { pattern: "{ $cmd: $value }", summary: "{cmd} {value}" }
                  - { pattern: "[ $cmd:int, ...$args ]", summary: "read {cmd} {args}" }
                  - { pattern: "$cmd:int", summary: "read {cmd}" }
                  - { pattern: "[]", summary: "not ready" }
                enum: { cmd: Name, code: Error }
        enums:
          Name: { 1: error, 2: battery, 3: dnd, 4: live_logs, 5: file }
          Error: { 4: OUT_OF_MEMORY }
        transactions:
          - name: read
            request:  { characteristic: Command, op: write, match: ["$cmd:int", "[$cmd:int, ...]"] }
            response: { characteristic: Command, op: read }
            key: cmd
            pending: "[]"
            timeout: 5s
          - name: error
            request:  { characteristic: Command, op: write }
            response: { characteristic: Events, match: "{ error: $code }" }
            within: 2s
        """

    func testAReadIsPairedWithItsRequestThroughPendingAnswers() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile(Self.commandYAML)
        session.time = 100
        _ = write(0x2e, [0x02], &session)                       // read battery
        session.time = 100.010
        let pending = read(0x2e, [0x90], &session).text
        XCTAssertTrue(pending.hasSuffix("not ready ↩ read pending: read battery · 10 ms"), pending)
        session.time = 100.042
        let answer = read(0x2e, [0x81, 0x02, 0x5a], &session)  // {battery: 90}
        XCTAssertTrue(answer.text.hasSuffix("battery 90 ↩ read: read battery · 42 ms"), answer.text)
        XCTAssertTrue(session.takeFlowRows().isEmpty)
    }

    func testAnUnansweredRequestIsReportedOnceAfterItsTimeout() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile(Self.commandYAML)
        session.time = 10
        _ = write(0x2e, [0x92, 0x03, 0x01], &session)          // [dnd, 1]
        session.time = 12
        _ = write(0x2e, [0x81, 0x03, 0x00], &session)           // {dnd: 0} — a write, not a read request
        XCTAssertTrue(session.takeFlowRows().isEmpty)
        session.time = 16
        _ = notify(0x30, [0x81, 0x02, 0x10], &session)
        let rows = session.takeFlowRows()
        XCTAssertEqual(rows, [.init(text: "read: no response within 5.0 s to read dnd [1] (sent 6.0 s ago)", level: .warning, incoming: false)])
        session.time = 30
        _ = notify(0x30, [0x81, 0x02, 0x10], &session)
        XCTAssertTrue(session.takeFlowRows().isEmpty, "reported once")
    }

    func testAnErrorPairsWithTheLatestWriteInsideItsWindowOnly() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile(Self.commandYAML)
        session.time = 1
        _ = write(0x2e, [0x81, 0x03, 0x01], &session)           // {dnd: 1}
        session.time = 1.5
        _ = write(0x2e, [0x81, 0x03, 0x00], &session)           // {dnd: 0}
        session.time = 1.8
        let error = notify(0x30, [0x81, 0x01, 0x04], &session)  // {error: 4}
        XCTAssertTrue(error.text.hasSuffix("error OUT_OF_MEMORY ↩ error: dnd 0 · 300 ms"), error.text)
        XCTAssertEqual(error.level, .error)
        session.time = 9
        XCTAssertFalse(notify(0x30, [0x81, 0x01, 0x04], &session).text.contains("↩"), "outside the window")
    }

    func testAnATTErrorFailsTheTransactionWaitingOnIt() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile(Self.commandYAML)
        _ = write(0x2e, [0x02], &session)
        _ = session.acl(Self.att([0x0a, 0x2e, 0x00]), incoming: false)
        let refused = session.acl(Self.att([0x01, 0x0a, 0x2e, 0x00, 0x02]), incoming: true)
        XCTAssertTrue(refused.error)
        XCTAssertTrue(refused.text.hasSuffix("↩ read failed: read battery"), refused.text)
    }

    func testAKeyOfTwoNamesPairsABinaryResponseByItsEchoedOpcode() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile("""
            services:
              - name: FOTA
                characteristics:
                  - { name: RX, handle: 0x28, message: { seq: [{ id: op, type: u8, enum: Op }, { id: rest, type: bytes }] } }
                  - name: TX
                    handle: 0x2a
                    message: { seq: [{ id: op, type: u8, enum: Op }, { id: responseTo, type: u8, enum: Op }, { id: code, type: u8, enum: Code }] }
            enums:
              Op: { 2: INIT, 3: PAGE_START, 0xAA: RESPONSE }
              Code: { 0: OK, 4: { name: HASH_MISMATCH, level: error } }
            transactions:
              - name: fota
                request:  { characteristic: RX }
                response: { characteristic: TX, where: { op: RESPONSE } }
                key: op = responseTo
            """)
        _ = write(0x28, [0x02, 1, 2], &session)
        _ = write(0x28, [0x03, 0], &session)
        let response = notify(0x2a, [0xaa, 0x03, 0x04], &session)
        XCTAssertTrue(response.text.contains("↩ fota: op=PAGE_START rest=<00>"), response.text)
        XCTAssertEqual(response.level, .error)
    }

    // MARK: Streams

    func testAByteStreamBecomesLinesWithLevels() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile(Self.commandYAML + """

            streams:
              - name: firmware log
                data: { characteristic: Events, where: { cmd: live_logs }, data: value }
                lines: true
                levels: { E: Error, W: Warning }
            """)
        func logs(_ text: String) -> [UInt8] { [0x81, 0x04, 0xc4, UInt8(text.utf8.count)] + Array(text.utf8) }
        _ = notify(0x30, logs("12:00:01.000 I [BT] conn"), &session)
        XCTAssertTrue(session.takeFlowRows().isEmpty, "no line ends yet")
        _ = notify(0x30, logs("ected\n12:00:01.200 E [FS] write fa"), &session)
        XCTAssertEqual(session.takeFlowRows(), [
            .init(text: "Watch · firmware log · 12:00:01.000 I [BT] connected", level: .info, incoming: true),
        ])
        _ = notify(0x30, logs("iled\r\n"), &session)
        XCTAssertEqual(session.takeFlowRows(), [
            .init(text: "Watch · firmware log · 12:00:01.200 E [FS] write failed", level: .error, incoming: true),
        ])
        _ = notify(0x30, logs("x\n"), &session)
        XCTAssertEqual(session.takeFlowRows().map(\.text), ["Watch · firmware log · x"])
    }

    func testATransferReportsProgressAndChecksItsCRC() throws {
        let yaml = """
            services:
              - name: FOTA
                characteristics:
                  - name: RX
                    handle: 0x28
                    message:
                      seq:
                        - { id: op, type: u8, enum: Op }
                        - id: body
                          type:
                            switch-on: op
                            cases:
                              INIT: { seq: [{ id: size, type: u32 }, { id: crc, type: u32 }] }
                              DATA: { seq: [{ id: chunk, type: bytes }] }
                              _: bytes
            enums:
              Op: { 2: INIT, 4: DATA, 7: VERIFY }
            streams:
              - name: image
                start: { characteristic: RX, where: { op: INIT }, total: size, crc32: crc }
                data:  { characteristic: RX, where: { op: DATA }, data: chunk }
            """
        let image = (0..<200).map { UInt8($0 % 251) }
        let crc = ~CRC.crc32(image, CRC.crc32Seed)
        XCTAssertEqual(~CRC.crc32(Array("123456789".utf8), CRC.crc32Seed), 0xcbf4_3926, "the CRC-32 check value")
        XCTAssertEqual(CRC.crc16(Array("123456789".utf8), CRC.crc16Seed), 0x29b1, "the CRC-16/CCITT-FALSE check value")

        for (expected, verdict, level) in [(crc, "crc32 ok", BluetoothSeverity.info),
                                           (crc ^ 1, "crc32 mismatch", .error)] {
            var session = BluetoothATTSession()
            session.definitions = try BluetoothPacketDefinitions.compile(yaml)
            session.time = 0
            let start = write(0x28, [0x02] + le(200, 4) + le(Int(expected), 4), &session)
            XCTAssertTrue(start.text.hasSuffix("image starts · 200 B"), start.text)
            var rows: [BluetoothFlowState.Row] = []
            for (index, offset) in stride(from: 0, to: 200, by: 19).enumerated() {
                session.time = Double(index) * 0.1
                _ = write(0x28, [0x04] + image[offset..<min(offset + 19, 200)], &session)
                rows += session.takeFlowRows()
            }
            XCTAssertEqual(rows.filter { $0.text.contains("%") }.count, 9, rows.map(\.text).joined(separator: "\n"))
            let last = try XCTUnwrap(rows.last)
            XCTAssertTrue(last.text.hasPrefix("FOTA · image complete · 200 B in 1.0 s"), last.text)
            XCTAssertTrue(last.text.contains(verdict), last.text)
            XCTAssertEqual(last.level, level)
        }
    }

    func testExplicitOffsetsKeyTransfersApartAndOutOfOrderIsNotAMismatch() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile(Self.commandYAML + """

            streams:
              - name: file
                data: { characteristic: Command, match: "{ file: [$key:str, $total:int, $offset:int, $data:bin, ...] }" }
            """)
        func chunk(_ path: String, _ total: Int, _ offset: Int, _ data: [UInt8]) -> [UInt8] {
            [0x81, 0x05, 0x94, 0xa0 | UInt8(path.utf8.count)] + Array(path.utf8) + [UInt8(total), UInt8(offset), 0xc4, UInt8(data.count)] + data
        }
        _ = write(0x2e, chunk("a", 4, 0, [1, 2]), &session)
        _ = write(0x2e, chunk("b", 2, 0, [9]), &session)
        _ = write(0x2e, chunk("a", 4, 2, [3, 4]), &session)
        _ = write(0x2e, chunk("b", 2, 1, [9]), &session)
        XCTAssertEqual(session.takeFlowRows().map(\.text).filter { $0.contains("complete") }.map { $0.components(separatedBy: " in ")[0] }, [
            "Watch · file a complete · 4 B", "Watch · file b complete · 2 B",
        ])
    }

    // MARK: Fixtures

    private func write(_ handle: Int, _ value: [UInt8], _ session: inout BluetoothATTSession) -> BluetoothATTSession.Summary {
        session.acl(Self.att([0x12] + le(handle, 2) + value), incoming: false)
    }

    private func notify(_ handle: Int, _ value: [UInt8], _ session: inout BluetoothATTSession) -> BluetoothATTSession.Summary {
        session.acl(Self.att([0x1b] + le(handle, 2) + value), incoming: true)
    }

    private func read(_ handle: Int, _ value: [UInt8], _ session: inout BluetoothATTSession) -> BluetoothATTSession.Summary {
        _ = session.acl(Self.att([0x0a] + le(handle, 2)), incoming: false)
        return session.acl(Self.att([0x0b] + value), incoming: true)
    }

    private func le(_ value: Int, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8((value >> ($0 * 8)) & 0xff) } }

    static func att(_ pdu: [UInt8], connection: Int = 0x40) -> [UInt8] {
        let l2cap = [UInt8(pdu.count & 0xff), UInt8(pdu.count >> 8), 0x04, 0x00] + pdu
        return [UInt8(connection), 0x20, UInt8(l2cap.count & 0xff), UInt8(l2cap.count >> 8)] + l2cap
    }
}
