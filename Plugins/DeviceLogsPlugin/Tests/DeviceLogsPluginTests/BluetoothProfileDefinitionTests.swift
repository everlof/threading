import Foundation
import XCTest
@testable import DeviceLogsPlugin

/// The built-in profiles: each compiles alone and together, a project's own definitions win, and
/// the protocols they describe decode as their specifications say.
final class BluetoothProfileDefinitionTests: XCTestCase {
    func testEveryProfileCompilesAloneAndTogether() throws {
        for name in BluetoothProfiles.names {
            XCTAssertNoThrow(try BluetoothPacketDefinitions.compile("include: [\(name)]"), name)
        }
        let all = try BluetoothPacketDefinitions.compile("include: [\(BluetoothProfiles.names.joined(separator: ", "))]")
        XCTAssertNotNil(all.characteristic(handle: 1, uuid: "2A37"))
        XCTAssertNotNil(all.characteristic(handle: 1, uuid: "8EC90001-F315-4F60-9FB8-838830DAEA50"))
        XCTAssertThrowsError(try BluetoothPacketDefinitions.compile("include: [nordic]")) { error in
            XCTAssertTrue((error as? BluetoothDefinitionError)?.message.contains("no profile called nordic") == true)
        }
    }

    func testTheProjectWinsAndMayUseProfileTypes() throws {
        let definitions = try BluetoothPacketDefinitions.compile("""
            include: [gatt]
            services:
              - name: Mine
                characteristics:
                  - { name: My Battery, uuid: 2A19, message: GattText }
            """)
        XCTAssertEqual(definitions.characteristic(handle: 1, uuid: "2A19")?.name, "My Battery")
        XCTAssertEqual(definitions.characteristic(handle: 1, uuid: "2A29")?.name, "Manufacturer Name")
    }

    func testHeartRateFieldsFollowTheirFlags() throws {
        let definitions = try BluetoothPacketDefinitions.compile("include: [gatt]")
        let type = try XCTUnwrap(definitions.characteristic(handle: 1, uuid: "2A37")?.received)
        XCTAssertEqual(definitions.decode([0x06, 72], as: type).text, "flags=contactDetected|contactSupported rate=72 bpm")
        // u16 rate, energy, two RR intervals of 1024/1024 s and 512/1024 s.
        let wide = definitions.decode([0x19, 0x2c, 0x01, 0x10, 0x00, 0x00, 0x04, 0x00, 0x02], as: type)
        XCTAssertEqual(wide.text, "flags=wideRate|energyPresent|intervalsPresent wideRate=300 bpm energy=16 kJ intervals=[1000 ms, 500 ms]")
        XCTAssertNil(wide.problem)
    }

    func testSecureDFUPairsResponsesAndNamesFailures() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile("""
            include: [nordic-dfu]
            services:
              - name: Pins
                characteristics:
                  - { name: Secure DFU Control Point, handle: 0x10, tx: NordicDfuRequest, rx: NordicDfuResponse }
            """)
        session.time = 1
        _ = session.acl(BluetoothFlowTests.att([0x12, 0x10, 0x00, 0x06, 0x01]), incoming: false)
        session.time = 1.02
        let selected = session.acl(BluetoothFlowTests.att([0x1b, 0x10, 0x00, 0x60, 0x06, 0x01]
            + [0x00, 0x02, 0, 0] + [0, 0, 0, 0] + [0, 0, 0, 0]), incoming: true)
        XCTAssertTrue(selected.text.hasSuffix("SELECT SUCCESS max 512 offset 0 crc32 0 ↩ Secure DFU: SELECT COMMAND · 20 ms"), selected.text)
        XCTAssertEqual(selected.level, .info)
        _ = session.acl(BluetoothFlowTests.att([0x12, 0x10, 0x00, 0x01, 0x02, 0x00, 0x10, 0, 0]), incoming: false)
        let refused = session.acl(BluetoothFlowTests.att([0x1b, 0x10, 0x00, 0x60, 0x01, 0x04]), incoming: true)
        XCTAssertTrue(refused.text.contains("CREATE INSUFFICIENT_RESOURCES ↩ Secure DFU: CREATE DATA 4096 B"), refused.text)
        XCTAssertEqual(refused.level, .error)
    }

    func testLegacyDFUReadsItsPacketByTheLastOpcodeAndChecksTheImage() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile("""
            include: [nordic-legacy-dfu]
            services:
              - name: Pins
                characteristics:
                  - { name: Legacy DFU Control Point, handle: 0x10, message: NordicLegacyControl }
                  - name: Legacy DFU Packet
                    handle: 0x12
                    message:
                      switch-on: Legacy DFU Control Point.op
                      cases:
                        START_DFU: { seq: [{ id: softdevice, type: u32 }, { id: bootloader, type: u32 }, { id: application, type: u32 }] }
                        INIT_PARAMS: NordicLegacyInitPacket
                        _: { summary: "{image}", seq: [{ id: image, type: bytes }] }
            """)
        let image = (0..<40).map { UInt8($0 * 7 % 256) }
        let crc = CRC.crc16(image, CRC.crc16Seed)
        func write(_ handle: UInt8, _ value: [UInt8]) -> BluetoothATTSession.Summary {
            session.acl(BluetoothFlowTests.att([0x12, handle, 0x00] + value), incoming: false)
        }
        _ = write(0x10, [0x01, 0x04])
        let sizes = write(0x12, [0, 0, 0, 0, 0, 0, 0, 0, 40, 0, 0, 0])
        XCTAssertTrue(sizes.text.contains("application=40"), sizes.text)
        _ = write(0x10, [0x02, 0x00])
        let initPacket = write(0x12, [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x00, 0xfe, 0xff, UInt8(crc & 0xff), UInt8(crc >> 8)])
        XCTAssertTrue(initPacket.text.contains("softdevices [65534] crc16 \(crc)"), initPacket.text)
        _ = write(0x10, [0x03])
        _ = session.takeFlowRows()
        _ = write(0x12, Array(image[0..<20]))
        _ = write(0x12, Array(image[20..<40]))
        let rows = session.takeFlowRows().map(\.text)
        XCTAssertTrue(rows.last?.contains("Legacy DFU image complete · 40 B") == true, rows.joined(separator: "\n"))
        XCTAssertTrue(rows.last?.contains("crc16 ok") == true, rows.joined(separator: "\n"))
    }
}
