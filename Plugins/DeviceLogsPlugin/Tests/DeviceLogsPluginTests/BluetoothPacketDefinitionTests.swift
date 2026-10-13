import Foundation
import XCTest
@testable import DeviceLogsPlugin

final class BluetoothPacketDefinitionTests: XCTestCase {
    private static let watchUUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

    // MARK: The shipped example

    func testShippedExampleCompilesAndDecodesALocation() throws {
        let definitions = try BluetoothPacketDefinitions.compile(BluetoothDefinitionsGuide.example)
        XCTAssertEqual(definitions.characteristics.map(\.name), ["Messages", "Battery Level"])
        XCTAssertEqual(definitions.characteristics.first?.uuid, Self.watchUUID)
        XCTAssertEqual(definitions.characteristics.last?.uuid, "2A19")

        let type = try XCTUnwrap(definitions.characteristic(handle: 0x25, uuid: Self.watchUUID)?.received)
        // kind=LOCATION seq=412 lat=59.3293 lon=18.0686 accuracy=4.5 m flags=precise
        let value: [UInt8] = [0x01] + le(412, 2) + le(593_293_000, 4) + le(180_686_000, 4) + le(45, 2) + [0x01]
        let decoded = definitions.decode(value, as: type)
        XCTAssertNil(decoded.problem)
        XCTAssertEqual(decoded.text, "LOCATION #412 {lat=59.3293° lon=18.0686° accuracy=4.5 m flags=precise}")
    }

    func testShippedExampleDecodesStringsHiddenLengthsAndRepeats() throws {
        let definitions = try BluetoothPacketDefinitions.compile(BluetoothDefinitionsGuide.example)
        let type = try XCTUnwrap(definitions.characteristic(handle: 1, uuid: Self.watchUUID)?.sent)
        let value: [UInt8] = [0x02] + le(7, 2) + [3] + Array("ABC".utf8) + le(2_150, 2) + le(UInt64(UInt16(bitPattern: -5)), 2)
        let decoded = definitions.decode(value, as: type)
        XCTAssertNil(decoded.problem)
        XCTAssertEqual(decoded.text, "STATUS #7 {name=\"ABC\" readings=[21.5, -0.05]}")
    }

    func testUnknownCaseFallsBackAndShortValueNamesWhereItStopped() throws {
        let definitions = try BluetoothPacketDefinitions.compile(BluetoothDefinitionsGuide.example)
        let type = try XCTUnwrap(definitions.characteristic(handle: 1, uuid: Self.watchUUID)?.received)
        XCTAssertEqual(definitions.decode([0x09, 1, 0, 0xde, 0xad], as: type).text, "9? #1 <dead>")

        let short = definitions.decode([0x01, 1, 0, 0xaa, 0xbb], as: type)
        XCTAssertEqual(short.problem, "body.lat: needs 4 bytes, 2 left")
        XCTAssertEqual(short.text, "kind=LOCATION seq=1", "the fields that did fit are still shown")

        let trailing = definitions.decode([0x01, 1, 0] + [UInt8](repeating: 0, count: 11) + [0xff], as: type)
        XCTAssertEqual(trailing.problem, "1 trailing bytes not described")
    }

    // MARK: Authoring errors carry the line

    func testAuthoringMistakesNameTheLineAndTheFix() {
        func failure(_ text: String) -> BluetoothDefinitionError? {
            do { _ = try BluetoothPacketDefinitions.compile(text); return nil }
            catch { return error as? BluetoothDefinitionError }
        }
        let header = "services:\n  - characteristics:\n      - { uuid: 2A19, message: T }\ntypes:\n  T:\n    seq:\n"
        XCTAssertEqual(failure(header + "      - { id: a, type: u17 }")?.line, 7)
        XCTAssertTrue(failure(header + "      - { id: a, type: u17 }")?.message.contains("unknown type 'u17'") == true)
        XCTAssertTrue(failure(header + "      - { id: a, tpye: u8 }")?.message.contains("unknown key 'tpye'") == true)
        XCTAssertTrue(failure(header + "      - { id: s, type: str, size: n }")?.message.contains("earlier integer field") == true)
        XCTAssertTrue(failure(header + "      - { id: a, type: u8, enum: Nope }")?.message.contains("no enum called Nope") == true)
        XCTAssertTrue(failure(header + "      - { id: a, type: u8, size: 3 }")?.message.contains("not to fixed-width") == true)
        XCTAssertTrue(failure(header + "      - { id: a, type: { switch-on: b, cases: {} } }")?.message.contains("earlier field") == true)
        XCTAssertTrue(failure("services:\n  - characteristics:\n      - { uuid: nope, message: u8 }")?.message.contains("not a Bluetooth UUID") == true)
        XCTAssertTrue(failure("services:\n  - characteristics:\n      - { name: x, message: u8 }")?.message.contains("uuid, a handle") == true)
        XCTAssertEqual(failure("version: 2")?.line, 1)
        XCTAssertNotNil(failure("services: [\n"), "YAML syntax errors surface as definition errors")
    }

    func testRecursiveTypesAndRunawayRepeatsAreBounded() throws {
        let text = """
            services:
              - characteristics:
                  - { handle: 0x10, message: Node }
                  - { handle: 0x11, message: Zero }
            types:
              Node:
                seq:
                  - { id: v, type: u8 }
                  - { id: next, type: Node }
              Zero:
                seq:
                  - { id: nothing, type: bytes, size: 0, repeat: eos }
            """
        let definitions = try BluetoothPacketDefinitions.compile(text)
        let node = try XCTUnwrap(definitions.characteristic(handle: 0x10, uuid: nil)?.received)
        let deep = definitions.decode([UInt8](repeating: 1, count: 100), as: node)
        XCTAssertTrue(deep.problem?.contains("nested deeper than") == true, deep.problem ?? "")
        XCTAssertLessThanOrEqual(deep.text.count, BluetoothPacketDefinitions.Limits.renderedCharacters + 1)

        let zero = try XCTUnwrap(definitions.characteristic(handle: 0x11, uuid: nil)?.received)
        XCTAssertNotNil(definitions.decode([1, 2], as: zero).text, "a zero-width repeat terminates")
    }

    func testBigEndianSignedFloatsAndUUIDForms() throws {
        let text = """
            services:
              - characteristics:
                  - handle: 0x20
                    message:
                      seq:
                        - { id: a, type: s16be }
                        - { id: b, type: f32 }
                        - { id: c, type: s24 }
                        - { id: d, type: bool }
            """
        let definitions = try BluetoothPacketDefinitions.compile(text)
        let type = try XCTUnwrap(definitions.characteristic(handle: 0x20, uuid: nil)?.received)
        let float = Float(1.5).bitPattern
        let value: [UInt8] = [0xff, 0xfe] + le(UInt64(float), 4) + [0xff, 0xff, 0xff, 1]
        XCTAssertEqual(definitions.decode(value, as: type).text, "a=-2 b=1.5 c=-1 d=true")

        XCTAssertEqual(BluetoothUUID.canonical("0x2a19"), "2A19")
        XCTAssertEqual(BluetoothUUID.canonical("00002A19-0000-1000-8000-00805F9B34FB"), "2A19")
        XCTAssertEqual(BluetoothUUID.canonical("6e400003b5a3f393e0a9e50e24dcca9e"), Self.watchUUID)
        XCTAssertNil(BluetoothUUID.canonical("not-a-uuid"))
    }

    // MARK: The ACL session

    func testDiscoveryTeachesHandlesAndNotificationsDecodeThroughThem() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile(BluetoothDefinitionsGuide.example)
        // Read By Type Request for 0x2803 (characteristic declarations), then its response:
        // declaration 0x0024, properties 0x10 (notify), value handle 0x0025, 128-bit UUID.
        _ = session.acl(Self.att([0x08, 0x01, 0x00, 0xff, 0xff, 0x03, 0x28]))
        let uuid = Self.wireUUID(Self.watchUUID)
        _ = session.acl(Self.att([0x09, 21] + le(0x24, 2) + [0x10] + le(0x25, 2) + uuid))

        let notification = session.acl(Self.att([0x1b] + le(0x25, 2) + [0x02, 1, 0, 0]))
        XCTAssertEqual(notification.protocolName, "App")
        XCTAssertEqual(notification.text, "Example Watch → iPhone · Messages notify · STATUS #1 {name=\"\" readings=[]}")
        XCTAssertEqual(notification.preview, [0x02, 1, 0, 0])

        // Unknown attribute: protocol-level row, unchanged from before definitions.
        let other = session.acl(Self.att([0x1b] + le(0x40, 2) + [0xaa]))
        XCTAssertEqual(other.protocolName, "ATT")
        XCTAssertTrue(other.text.contains("Handle Value Notification attribute=0x0040"))
    }

    func testReadResponseUsesTheOutstandingRequestsHandle() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile("""
            services:
              - characteristics:
                  - { name: Battery, handle: 0x30, message: { seq: [{ id: percent, type: u8, unit: "%" }] } }
            """)
        _ = session.acl(Self.att([0x0a] + le(0x30, 2)))
        XCTAssertEqual(session.acl(Self.att([0x0b, 87])).text, "peripheral → iPhone · Battery read · percent=87%")
        XCTAssertEqual(session.acl(Self.att([0x0b, 87])).protocolName, "ATT", "a response is matched once")
    }

    func testFragmentedNotificationIsReassembledAcrossContinuations() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile("""
            services:
              - characteristics:
                  - { name: Blob, handle: 0x25, message: { seq: [{ id: data, type: bytes }] } }
            """)
        let pdu: [UInt8] = [0x1b] + le(0x25, 2) + [UInt8](repeating: 0xab, count: 40)
        let frame = le(UInt64(pdu.count), 2) + le(4, 2) + pdu
        let first = session.acl(Self.acl(Array(frame.prefix(20)), boundary: 2))
        XCTAssertTrue(first.text.contains("start 20/47"), first.text)
        let middle = session.acl(Self.acl(Array(frame[20..<30]), boundary: 1))
        XCTAssertTrue(middle.text.contains("continuation 30/47"), middle.text)
        let last = session.acl(Self.acl(Array(frame[30...]), boundary: 1))
        XCTAssertEqual(last.protocolName, "App")
        XCTAssertTrue(last.text.hasPrefix("peripheral → iPhone · Blob notify · data=<abab"), last.text)
        XCTAssertEqual(last.preview?.count, 40)

        let orphan = session.acl(Self.acl([1, 2, 3], boundary: 1))
        XCTAssertTrue(orphan.text.hasSuffix("continuation"), "no pending start: still labelled, not decoded")
    }

    // MARK: Naming the peer

    func testThePeerIsNamedFromWhatTheCaptureSaysAboutIt() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile(BluetoothDefinitionsGuide.example
            .replacingOccurrences(of: "# handle: 0x0025", with: "handle: 0x0025"))
        let notify = Self.att([0x1b] + le(0x25, 2) + [0x02, 1, 0, 0])
        let address: [UInt8] = [0x9f, 0x12, 0x6a, 0x8d, 0x7c, 0xc4]

        XCTAssertTrue(session.acl(notify).text.hasPrefix("Example Watch → iPhone · Messages notify"),
                      "without anything better, the definitions' service name")

        // LE Connection Complete for handle 0x0040 with that peer address: the address is next.
        session.event(Self.event(0x3e, [0x01, 0x00] + le(0x40, 2) + [0x01, 0x01] + address + [UInt8](repeating: 0, count: 7)))
        XCTAssertTrue(session.acl(notify).text.hasPrefix("Example Watch → iPhone"), "service name beats an address")

        // An advertised complete local name for that address beats the service name.
        let ad: [UInt8] = [0x02, 0x01, 0x06, 0x0c, 0x09] + Array("Ananke 4F2A".utf8)
        session.event(Self.event(0x3e, [0x02, 0x01, 0x00, 0x01] + address + [UInt8(ad.count)] + ad + [0xc0]))
        XCTAssertTrue(session.acl(notify).text.hasPrefix("Ananke 4F2A → iPhone"), session.acl(notify).text)

        // The GATT Device Name, read by type as iOS does, beats the advertisement.
        _ = session.acl(Self.att([0x08, 0x01, 0x00, 0xff, 0xff, 0x00, 0x2a]))
        _ = session.acl(Self.att([0x09, 2 + 6] + le(0x03, 2) + Array("Strap1".utf8)))
        XCTAssertTrue(session.acl(notify).text.hasPrefix("Strap1 → iPhone"))

        // A disconnection ends what was learned for that handle.
        session.event(Self.event(0x05, [0x00] + le(0x40, 2) + [0x13]))
        XCTAssertTrue(session.acl(notify).text.hasPrefix("Example Watch → iPhone"))
    }

    func testABadFitIsAWarningSoFullyDecodedCanLeaveItOut() throws {
        var decoder = BluetoothPacketDecoder()
        decoder.definitions = try BluetoothPacketDefinitions.compile(BluetoothDefinitionsGuide.example
            .replacingOccurrences(of: "# handle: 0x0025", with: "handle: 0x0025"))
        let fits = [UInt8(2)] + Self.att([0x1b] + le(0x25, 2) + [0x02, 1, 0, 0])
        let short = [UInt8(2)] + Self.att([0x1b] + le(0x25, 2) + [0x01, 1, 0, 0])
        let rows = try decoder.append(BluetoothPacketTests.header()
            + BluetoothPacketTests.packet(fits, incoming: true) + BluetoothPacketTests.packet(short, incoming: true))
        XCTAssertEqual(rows.map(\.level), ["Info", "Warning"])
        XCTAssertEqual(rows.map(\.subsystem), ["App", "App"])
        let complete = LogFocus(subsystem: "App", maximumSeverity: BluetoothPacketFilter.completeMaximumSeverity)
        XCTAssertEqual(rows.filter(complete.matches).count, 1)
    }

    func testDecoderAppliesDefinitionsToCaptureRows() throws {
        var decoder = BluetoothPacketDecoder()
        decoder.definitions = try BluetoothPacketDefinitions.compile("""
            services:
              - characteristics:
                  - { name: Ping, handle: 0x25, tx: { seq: [{ id: n, type: u8 }] } }
            """)
        let write = [UInt8(2)] + Self.att([0x52] + le(0x25, 2) + [7])
        let row = try XCTUnwrap(decoder.append(BluetoothPacketTests.header() + BluetoothPacketTests.packet(write)).first)
        XCTAssertEqual(row.subsystem, "App")
        XCTAssertTrue(row.message.hasPrefix("TX iPhone → peripheral · Ping write · n=7 · 1 bytes | 07"), row.message)
    }

    // MARK: The file

    func testFileStatusMissingLoadedAndFailed() throws {
        let checkout = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: checkout) }
        XCTAssertEqual(BluetoothDefinitionsFile.load(checkout: nil).1, .noCheckout)
        guard case .missing(let expected) = BluetoothDefinitionsFile.load(checkout: checkout.path).1 else {
            return XCTFail("expected missing")
        }
        XCTAssertEqual(expected.lastPathComponent, "bluetooth.yaml")

        try FileManager.default.createDirectory(at: expected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BluetoothDefinitionsGuide.example.write(to: expected, atomically: true, encoding: .utf8)
        let (definitions, status) = BluetoothDefinitionsFile.load(checkout: checkout.path)
        XCTAssertNotNil(definitions)
        XCTAssertEqual(status, .loaded(expected, characteristics: 2, types: 3))
        XCTAssertTrue(status.summary.contains(".threading/bluetooth.yaml"), status.summary)

        try "types:\n  T:\n    seq:\n      - { id: a, type: u17 }\n".write(to: expected, atomically: true, encoding: .utf8)
        let failed = BluetoothDefinitionsFile.load(checkout: checkout.path).1
        XCTAssertTrue(failed.isFailure)
        XCTAssertTrue(failed.summary.contains("line 4"), failed.summary)
    }

    func testAgentPromptCarriesThePathAndTheExample() {
        let prompt = BluetoothDefinitionsGuide.agentPrompt(path: "/repo/.threading/bluetooth.yaml")
        XCTAssertTrue(prompt.contains("/repo/.threading/bluetooth.yaml"))
        XCTAssertTrue(prompt.contains("switch-on: kind"))
    }

    // MARK: Fixtures

    private static func event(_ code: UInt8, _ parameters: [UInt8]) -> [UInt8] {
        [code, UInt8(parameters.count)] + parameters
    }

    private static func att(_ pdu: [UInt8], connection: Int = 0x40) -> [UInt8] {
        acl(le(UInt64(pdu.count), 2) + le(4, 2) + pdu, boundary: 2, connection: connection)
    }

    private static func acl(_ data: [UInt8], boundary: Int, connection: Int = 0x40) -> [UInt8] {
        le(UInt64(connection | (boundary << 12)), 2) + le(UInt64(data.count), 2) + data
    }

    private static func wireUUID(_ text: String) -> [UInt8] {
        let hex = Array(text.replacingOccurrences(of: "-", with: ""))
        return stride(from: 0, to: hex.count, by: 2).map { UInt8(String(hex[$0..<$0 + 2]), radix: 16)! }.reversed()
    }
}

private func le(_ value: UInt64, _ bytes: Int) -> [UInt8] {
    (0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
}
