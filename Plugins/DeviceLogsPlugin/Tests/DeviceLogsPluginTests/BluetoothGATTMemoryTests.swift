import Foundation
import XCTest
@testable import DeviceLogsPlugin

/// Remembered GATT tables: a capture without discovery decodes through what an earlier capture of
/// the same device saw, but only when the traffic fits that table.
final class BluetoothGATTMemoryTests: XCTestCase {
    private static let fotaRX = "6E400003-B5A3-F393-E043-565341544F46"
    private static let anima = "6E401980-B5A3-F393-E0A9-E6414D494E41"
    private static let ancs = "9FBF120D-6301-42D9-8C58-25E699A21DBD"
    private static let address: [UInt8] = [0x2a, 0x4f, 0x6a, 0x8d, 0x7c, 0xc4]

    private static let yaml = """
        services:
          - name: Kronaby
            characteristics:
              - { name: FOTA RX, uuid: \(fotaRX), message: { seq: [{ id: data, type: bytes }] } }
              - { name: Anima Command, uuid: \(anima), message: { seq: [{ id: data, type: bytes }] } }
              - { name: ANCS Source, uuid: \(ancs), server: phone, message: { seq: [{ id: data, type: bytes }] } }
              - { name: Stale Pin, uuid: 2A19, handle: 0x0028, message: { seq: [{ id: n, type: u8 }] } }
        """

    /// The 15:06 pairing: a connection event, then the phone discovers the watch and the watch
    /// discovers the phone. Both tables have a characteristic at 0x0028.
    private func pairing(firmware: String? = nil) throws -> BluetoothATTSession {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile(Self.yaml)
        session.phoneIdentity = "phone-udid"
        session.event([0x3e, 19, 0x01, 0x00, 0x4f, 0x00, 0x01, 0x01] + Self.address + [UInt8](repeating: 0, count: 7))
        // Watch: one service 0x0020–0x0030; FOTA RX (write) at 0x0028, Anima (read/write) at 0x002e,
        // a CCCD at 0x0029, Service Changed (indicate) at 0x0032.
        tx([0x10, 0x01, 0x00, 0xff, 0xff, 0x00, 0x28], &session)
        rx([0x11, 0x06, 0x20, 0x00, 0x30, 0x00, 0x01, 0x18], &session)
        tx([0x08, 0x01, 0x00, 0xff, 0xff, 0x03, 0x28], &session)
        rx([0x09, 21] + [0x27, 0x00, 0x0c, 0x28, 0x00] + Self.wire(Self.fotaRX)
           + [0x2d, 0x00, 0x0a, 0x2e, 0x00] + Self.wire(Self.anima), &session)
        rx([0x09, 7, 0x31, 0x00, 0x20, 0x32, 0x00, 0x05, 0x2a, 0x40, 0x00, 0x02, 0x41, 0x00, 0x26, 0x2a], &session)
        tx([0x04, 0x29, 0x00, 0x29, 0x00], &session)
        rx([0x05, 0x01, 0x29, 0x00, 0x02, 0x29], &session)
        // Phone: the watch discovers ANCS Notification Source (notify) at the same 0x0028.
        rx([0x08, 0x01, 0x00, 0xff, 0xff, 0x03, 0x28], &session)
        tx([0x09, 21, 0x27, 0x00, 0x10, 0x28, 0x00] + Self.wire(Self.ancs), &session)
        if let firmware {
            tx([0x0a, 0x41, 0x00], &session)
            rx([0x0b] + Array(firmware.utf8), &session)
        }
        return session
    }

    /// The capture restarted mid-connection: no connection event, no discovery, same store.
    private func later(_ earlier: BluetoothATTSession) -> BluetoothATTSession {
        var session = BluetoothATTSession()
        session.definitions = earlier.definitions
        session.gatt = earlier.gatt
        session.phoneIdentity = "phone-udid"
        return session
    }

    func testALaterCaptureDecodesThroughTheRememberedTablesWithoutPins() throws {
        var session = later(try pairing())
        let write = tx([0x12, 0x28, 0x00, 0x02, 0xf8], &session)
        XCTAssertTrue(write.text.contains("FOTA RX write · data=<02f8>"), write.text)
        XCTAssertTrue(session.gattSummary?.hasPrefix("GATT: Kronaby remembered") == true
                      || session.gattSummary?.hasPrefix("GATT: C4:7C:8D:6A:4F:2A remembered") == true, session.gattSummary ?? "nil")
        XCTAssertFalse(session.gattSummary?.contains("assumed") == true, "one table fits")

        let notify = tx([0x1b, 0x28, 0x00, 0x07], &session)
        XCTAssertTrue(notify.text.contains("ANCS Source notify"), "0x0028 in the iPhone's table: \(notify.text)")

        let cccd = tx([0x12, 0x29, 0x00, 0x01, 0x00], &session)
        XCTAssertTrue(cccd.text.hasSuffix("uuid=2902 (remembered)"), "a remembered UUID says so: \(cccd.text)")
        XCTAssertTrue(session.gattSummary?.contains("handle: 0x0028 on line") == true,
                      "the stale pin is named: \(session.gattSummary ?? "")")
    }

    func testTrafficThatContradictsEveryTableStaysRaw() throws {
        var session = later(try pairing())
        // Another watch indicates on 0x002e, which in the paired watch's table is read/write only.
        let indication = rx([0x1d, 0x2e, 0x00, 0x81], &session, connection: 0x4a)
        XCTAssertEqual(indication.protocolName, "ATT")
        XCTAssertFalse(indication.text.contains("uuid="), indication.text)
        XCTAssertEqual(session.gattSummary, "GATT: no remembered table fits this connection")
        let write = tx([0x12, 0x28, 0x00, 0x01], &session, connection: 0x4a)
        XCTAssertFalse(write.text.contains("FOTA"), "once rejected, the connection stays raw: \(write.text)")
    }

    func testSeveralFittingTablesUseTheLatestAndSaySoAssumed() throws {
        let first = try pairing()
        var gatt = first.gatt
        // A second watch with the same layout, recorded later.
        for identity in gatt.peripheralIdentities {
            let table = gatt[identity]!.table
            gatt.update("other watch", now: Date().addingTimeInterval(60)) { $0.table = table; $0.name = "Other" }
        }
        var session = later(first)
        session.gatt = gatt
        _ = tx([0x12, 0x28, 0x00, 0x01], &session)
        XCTAssertTrue(session.gattSummary?.hasPrefix("GATT: Other remembered") == true, session.gattSummary ?? "")
        XCTAssertTrue(session.gattSummary?.contains("· assumed") == true)
    }

    func testServiceChangedHashAndFirmwareInvalidate() throws {
        var paired = try pairing(firmware: "20240705")
        let identity = try XCTUnwrap(paired.gatt.peripheralIdentities.first)
        XCTAssertEqual(paired.gatt[identity]?.firmware, "20240705")

        // A new firmware keeps the table but marks it stale.
        tx([0x0a, 0x41, 0x00], &paired)
        rx([0x0b] + Array("20241001".utf8), &paired)
        XCTAssertEqual(paired.gatt[identity]?.stale, true)
        XCTAssertEqual(paired.gatt[identity]?.table.uuid(for: 0x28), Self.fotaRX)

        // Service Changed for 0x0025–0x002a drops FOTA RX and the CCCD, keeps Anima.
        rx([0x1d, 0x32, 0x00, 0x25, 0x00, 0x2a, 0x00], &paired)
        XCTAssertNil(paired.gatt[identity]?.table.uuid(for: 0x28))
        XCTAssertNil(paired.gatt[identity]?.table.uuid(for: 0x29))
        XCTAssertEqual(paired.gatt[identity]?.table.uuid(for: 0x2e), Self.anima)

        // A Database Hash, then a different one: the whole table goes.
        paired.gatt.update(identity) { $0.table.discover(.init(declaration: 0x50, value: 0x51, properties: 0x02, uuid: "2B2A")) }
        var session = later(paired)
        session.event([0x3e, 19, 0x01, 0x00, 0x4f, 0x00, 0x01, 0x01] + Self.address + [UInt8](repeating: 0, count: 7))
        tx([0x0a, 0x51, 0x00], &session)
        rx([0x0b] + [UInt8](repeating: 0xaa, count: 16), &session)
        XCTAssertEqual(session.gatt[identity]?.databaseHash, String(repeating: "aa", count: 16))
        XCTAssertNotNil(session.gatt[identity]?.table.uuid(for: 0x2e), "the first hash only records")
        tx([0x0a, 0x51, 0x00], &session)
        rx([0x0b] + [UInt8](repeating: 0xbb, count: 16), &session)
        XCTAssertNil(session.gatt[identity]?.table.uuid(for: 0x2e), "a different hash is a different table")
    }

    func testTheStoreRoundTripsBoundsAndSurvivesDamage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("gatt.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let paired = try pairing(firmware: "20240705")
        try paired.gatt.save(to: url)
        let loaded = BluetoothGATTTables.load(from: url)
        XCTAssertEqual(loaded.devices.mapValues(\.table), paired.gatt.devices.mapValues(\.table))
        XCTAssertEqual(loaded.devices.mapValues(\.firmware), paired.gatt.devices.mapValues(\.firmware))
        XCTAssertEqual(loaded.devices.mapValues(\.isPhone), paired.gatt.devices.mapValues(\.isPhone))

        var table = BluetoothGATTTable()
        for handle in 0..<(BluetoothGATTTable.attributeLimit + 10) {
            table.discover(.init(declaration: handle * 2, value: handle * 2 + 1, properties: 0x02, uuid: "2A19"))
        }
        XCTAssertEqual(table.attributeCount, BluetoothGATTTable.attributeLimit)
        var store = BluetoothGATTTables()
        for index in 0..<(BluetoothGATTTables.Limits.devices + 5) {
            store.update("device \(index)", now: Date(timeIntervalSince1970: Double(index))) { $0.name = "\(index)" }
        }
        XCTAssertEqual(store.devices.count, BluetoothGATTTables.Limits.devices)
        XCTAssertNil(store["device 0"], "the oldest goes first")

        try Data("{".utf8).write(to: url)
        XCTAssertTrue(BluetoothGATTTables.load(from: url).devices.isEmpty)
    }

    // MARK: Fixtures

    @discardableResult
    private func tx(_ pdu: [UInt8], _ session: inout BluetoothATTSession, connection: Int = 0x4f) -> BluetoothATTSession.Summary {
        session.acl(Self.att(pdu, connection: connection), incoming: false)
    }

    @discardableResult
    private func rx(_ pdu: [UInt8], _ session: inout BluetoothATTSession, connection: Int = 0x4f) -> BluetoothATTSession.Summary {
        session.acl(Self.att(pdu, connection: connection), incoming: true)
    }

    private static func att(_ pdu: [UInt8], connection: Int) -> [UInt8] {
        let l2cap = [UInt8(pdu.count), 0, 0x04, 0x00] + pdu
        return [UInt8(connection), 0x20, UInt8(l2cap.count), 0] + l2cap
    }

    private static func wire(_ uuid: String) -> [UInt8] {
        let hex = uuid.replacingOccurrences(of: "-", with: "")
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return bytes.reversed()
    }
}
