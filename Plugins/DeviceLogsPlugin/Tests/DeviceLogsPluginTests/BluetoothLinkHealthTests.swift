import Foundation
import XCTest
@testable import DeviceLogsPlugin

/// The link's own story — parameters, data length, PHY, encryption, why it ended — read aloud
/// without any definitions, plus advertising manufacturer data and CCCD bookkeeping.
final class BluetoothLinkHealthTests: XCTestCase {
    private static let address: [UInt8] = [0x2a, 0x4f, 0x6a, 0x8d, 0x7c, 0xc4]

    private func connected() -> BluetoothATTSession {
        var session = BluetoothATTSession()
        // Connection Complete: handle 0x40, peripheral role, interval 24 (30 ms), latency 0, timeout 600 (6 s).
        let summary = session.event(event(0x3e, [0x01, 0x00, 0x40, 0x00, 0x00, 0x00] + Self.address
            + [0x18, 0x00, 0x00, 0x00, 0x58, 0x02, 0x00]))
        XCTAssertEqual(summary?.text, "Connected C4:7C:8D:6A:4F:2A · iPhone is central · interval 30 ms latency 0 timeout 6000 ms")
        return session
    }

    func testTheLinksEventsReadAsWords() {
        var session = connected()
        XCTAssertEqual(session.event(event(0x3e, [0x03, 0x00, 0x40, 0x00, 0x06, 0x00, 0x04, 0x00, 0xc8, 0x00]))?.text,
                       "Connection parameters C4:7C:8D:6A:4F:2A · interval 7.50 ms latency 4 timeout 2000 ms")
        XCTAssertEqual(session.event(event(0x3e, [0x07, 0x40, 0x00, 0xfb, 0x00, 0x48, 0x08, 0xfb, 0x00, 0x48, 0x08]))?.text,
                       "Data length C4:7C:8D:6A:4F:2A · tx 251 B / 2120 µs · rx 251 B / 2120 µs")
        XCTAssertEqual(session.event(event(0x3e, [0x0c, 0x00, 0x40, 0x00, 0x02, 0x02]))?.text,
                       "PHY C4:7C:8D:6A:4F:2A · tx 2M · rx 2M")
        let failedEncryption = session.event(event(0x08, [0x06, 0x40, 0x00, 0x00]))
        XCTAssertEqual(failedEncryption, .init(text: "Encryption failed C4:7C:8D:6A:4F:2A: PIN or Key Missing", error: true))
        let timeout = session.event(event(0x05, [0x00, 0x40, 0x00, 0x08]))
        XCTAssertEqual(timeout, .init(text: "Disconnected C4:7C:8D:6A:4F:2A: Connection Timeout", warning: true))
        XCTAssertEqual(session.event(event(0x05, [0x00, 0x40, 0x00, 0x13]))?.warning, false)
    }

    func testEventRowsCarryTheLinkSubsystem() throws {
        var decoder = BluetoothPacketDecoder()
        let rows = try decoder.append(BluetoothPacketTests.header()
            + BluetoothPacketTests.packet([0x04] + event(0x05, [0x00, 0x40, 0x00, 0x08]), incoming: true))
        XCTAssertEqual(rows.first?.subsystem, BluetoothATTSession.linkProtocolName)
        XCTAssertEqual(rows.first?.level, "Warning")
        XCTAssertTrue(rows.first?.message.hasPrefix("RX Disconnected handle 0x0040: Connection Timeout") == true, rows.first?.message ?? "")
    }

    func testManufacturerDataIsDecodedByCompany() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile("""
            advertising:
              - name: Example watch
                company: 0x0D30
                message: { summary: "model {model} variant {variant}", seq: [{ id: model, type: u8, enum: Model }, { id: variant, type: u8 }] }
            enums:
              Model: { 3: pronto }
            """)
        let name = Array("Kronaby".utf8)
        let ad: [UInt8] = [UInt8(name.count + 1), 0x09] + name + [0x05, 0xff, 0x30, 0x0d, 0x03, 0x07]
        let report = session.event(event(0x3e, [0x02, 0x01, 0x00, 0x01] + Self.address + [UInt8(ad.count)] + ad + [0xc4]))
        XCTAssertEqual(report?.text, "Advertising C4:7C:8D:6A:4F:2A \"Kronaby\" -60 dBm · Example watch model pronto variant 7")
    }

    func testANotificationWhileItsCCCDIsOffIsFlagged() throws {
        var session = connected()
        // CCCD at 0x0031 for the characteristic at 0x0030: notifications on, then off.
        session.definitions = try BluetoothPacketDefinitions.compile("""
            services:
              - name: Watch
                characteristics:
                  - { name: Events, handle: 0x30, message: { seq: [{ id: n, type: u8 }] } }
            """)
        // Find Information teaches the descriptor's UUID.
        _ = session.acl(BluetoothFlowTests.att([0x04, 0x31, 0x00, 0x31, 0x00]), incoming: false)
        _ = session.acl(BluetoothFlowTests.att([0x05, 0x01, 0x31, 0x00, 0x02, 0x29]), incoming: true)
        _ = session.acl(BluetoothFlowTests.att([0x12, 0x31, 0x00, 0x01, 0x00]), incoming: false)
        XCTAssertFalse(session.acl(BluetoothFlowTests.att([0x1b, 0x30, 0x00, 0x07]), incoming: true).text.contains("CCCD"))
        _ = session.acl(BluetoothFlowTests.att([0x12, 0x31, 0x00, 0x00, 0x00]), incoming: false)
        let late = session.acl(BluetoothFlowTests.att([0x1b, 0x30, 0x00, 0x07]), incoming: true)
        XCTAssertTrue(late.text.hasSuffix("Events notify · n=7 · notified while its CCCD is off"), late.text)
        XCTAssertEqual(late.level, .warning)
    }

    private func event(_ code: UInt8, _ parameters: [UInt8]) -> [UInt8] {
        [code, UInt8(parameters.count)] + parameters
    }
}
