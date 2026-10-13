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
        _ = session.acl(Self.att([0x08, 0x01, 0x00, 0xff, 0xff, 0x03, 0x28]), incoming: false)
        let uuid = Self.wireUUID(Self.watchUUID)
        _ = session.acl(Self.att([0x09, 21] + le(0x24, 2) + [0x10] + le(0x25, 2) + uuid), incoming: true)

        let notification = session.acl(Self.att([0x1b] + le(0x25, 2) + [0x02, 1, 0, 0]), incoming: true)
        XCTAssertEqual(notification.protocolName, "App")
        XCTAssertEqual(notification.text, "Example Watch → iPhone · Messages notify · STATUS #1 {name=\"\" readings=[]}")
        XCTAssertEqual(notification.preview, [0x02, 1, 0, 0])

        // Unknown attribute: protocol-level row, unchanged from before definitions.
        let other = session.acl(Self.att([0x1b] + le(0x40, 2) + [0xaa]), incoming: true)
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
        _ = session.acl(Self.att([0x0a] + le(0x30, 2)), incoming: false)
        XCTAssertEqual(session.acl(Self.att([0x0b, 87]), incoming: true).text, "peripheral → iPhone · Battery read · percent=87%")
        XCTAssertEqual(session.acl(Self.att([0x0b, 87]), incoming: true).protocolName, "ATT", "a response is matched once")
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
        let first = session.acl(Self.acl(Array(frame.prefix(20)), boundary: 2), incoming: true)
        XCTAssertTrue(first.text.contains("start 20/47"), first.text)
        let middle = session.acl(Self.acl(Array(frame[20..<30]), boundary: 1), incoming: true)
        XCTAssertTrue(middle.text.contains("continuation 30/47"), middle.text)
        let last = session.acl(Self.acl(Array(frame[30...]), boundary: 1), incoming: true)
        XCTAssertEqual(last.protocolName, "App")
        XCTAssertTrue(last.text.hasPrefix("peripheral → iPhone · Blob notify · data=<abab"), last.text)
        XCTAssertEqual(last.preview?.count, 40)

        let orphan = session.acl(Self.acl([1, 2, 3], boundary: 1), incoming: true)
        XCTAssertTrue(orphan.text.hasSuffix("continuation"), "no pending start: still labelled, not decoded")
    }

    // MARK: Naming the peer

    func testThePeerIsNamedFromWhatTheCaptureSaysAboutIt() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile(BluetoothDefinitionsGuide.example
            .replacingOccurrences(of: "# handle: 0x0025", with: "handle: 0x0025"))
        let notify = Self.att([0x1b] + le(0x25, 2) + [0x02, 1, 0, 0])
        let address: [UInt8] = [0x9f, 0x12, 0x6a, 0x8d, 0x7c, 0xc4]

        XCTAssertTrue(session.acl(notify, incoming: true).text.hasPrefix("Example Watch → iPhone · Messages notify"),
                      "without anything better, the definitions' service name")

        // LE Connection Complete for handle 0x0040 with that peer address: the address is next.
        session.event(Self.event(0x3e, [0x01, 0x00] + le(0x40, 2) + [0x01, 0x01] + address + [UInt8](repeating: 0, count: 7)))
        XCTAssertTrue(session.acl(notify, incoming: true).text.hasPrefix("Example Watch → iPhone"), "service name beats an address")

        // An advertised complete local name for that address beats the service name.
        let ad: [UInt8] = [0x02, 0x01, 0x06, 0x0c, 0x09] + Array("Ananke 4F2A".utf8)
        session.event(Self.event(0x3e, [0x02, 0x01, 0x00, 0x01] + address + [UInt8(ad.count)] + ad + [0xc0]))
        XCTAssertTrue(session.acl(notify, incoming: true).text.hasPrefix("Ananke 4F2A → iPhone"), session.acl(notify, incoming: true).text)

        // The GATT Device Name, read by type as iOS does, beats the advertisement.
        _ = session.acl(Self.att([0x08, 0x01, 0x00, 0xff, 0xff, 0x00, 0x2a]), incoming: false)
        _ = session.acl(Self.att([0x09, 2 + 6] + le(0x03, 2) + Array("Strap1".utf8)), incoming: true)
        XCTAssertTrue(session.acl(notify, incoming: true).text.hasPrefix("Strap1 → iPhone"))

        // A disconnection ends what was learned for that handle.
        session.event(Self.event(0x05, [0x00] + le(0x40, 2) + [0x13]))
        XCTAssertTrue(session.acl(notify, incoming: true).text.hasPrefix("Example Watch → iPhone"))
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
        let complete = LogFocus(subsystem: "App", excluding: BluetoothPacketFilter.problemMarker)
        XCTAssertEqual(rows.filter(complete.matches).count, 1)
    }

    // MARK: Two databases, long values

    /// The capture behind the bug: on one link the watch's FOTA RX and the iPhone's own ANCS
    /// Notification Source are both value handle 0x0028. Bytes are the report's, ACL header and all.
    func testEachEndsDatabaseKeepsItsOwnHandles() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile("""
            services:
              - name: Kronaby
                characteristics:
                  - { name: FOTA RX, uuid: 6E400003-B5A3-F393-E043-565341544F46, message: { seq: [{ id: data, type: bytes }] } }
                  - { name: ANCS Source, uuid: 9FBF120D-6301-42D9-8C58-25E699A21DBD, server: phone, message: { seq: [{ id: data, type: bytes }] } }
                  - { name: Pinned, handle: 0x0030, server: phone, message: { seq: [{ id: n, type: u8 }] } }
            """)
        // The phone discovers the watch's database; later the watch discovers the phone's.
        _ = session.acl(Self.hex("4f 20 0b 00 07 00 04 00 08 01 00 ff ff 03 28"), incoming: false)
        _ = session.acl(Self.hex("4f 20 1b 00 17 00 04 00 09 15 27 00 0c 28 00 46 4f 54 41 53 56 43 e0 93 f3 a3 b5 03 00 40 6e"), incoming: true)
        _ = session.acl(Self.hex("4f 20 0b 00 07 00 04 00 08 01 00 ff ff 03 28"), incoming: true)
        _ = session.acl(Self.hex("4f 00 1b 00 17 00 04 00 09 15 27 00 10 28 00 bd 1d a2 99 e6 25 58 8c d9 42 01 63 0d 12 bf 9f"), incoming: false)

        // FOTA_INIT: a Write Request the phone sends addresses the watch's database.
        let write = session.acl(Self.hex("4f 20 10 00 0c 00 04 00 12 28 00 02 f8 5e 02 00 4f d7 e0 5d"), incoming: false)
        XCTAssertEqual(write.protocolName, "App")
        XCTAssertTrue(write.text.hasPrefix("iPhone → Kronaby · FOTA RX write · data=<02f85e02004fd7e05d>"), write.text)

        // A notification the phone sends on the same handle comes from its own database.
        let notify = session.acl(Self.att([0x1b] + le(0x28, 2) + [7], connection: 0x4f), incoming: false)
        XCTAssertTrue(notify.text.hasPrefix("iPhone → Kronaby · ANCS Source notify · data=<07>"), notify.text)

        // A `server: phone` pin applies to the phone's handle 0x0030 and not the watch's.
        let pinned = session.acl(Self.att([0x52] + le(0x30, 2) + [7], connection: 0x4f), incoming: true)
        XCTAssertTrue(pinned.text.hasPrefix("Kronaby → iPhone · Pinned write · n=7"), pinned.text)
        let watchHandle = session.acl(Self.att([0x52] + le(0x30, 2) + [7], connection: 0x4f), incoming: false)
        XCTAssertEqual(watchHandle.protocolName, "ATT", watchHandle.text)
    }

    func testALongReadIsJoinedFromItsBlobs() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile("""
            services:
              - characteristics:
                  - { name: Anima Command, handle: 0x2e, message: msgpack }
            """)
        let value = Self.messagePack
        _ = session.acl(Self.att([0x0a] + le(0x2e, 2)), incoming: false)
        let first = session.acl(Self.att([0x0b] + value.prefix(22)), incoming: true)
        XCTAssertEqual(first.protocolName, "ATT")
        XCTAssertTrue(first.text.hasSuffix("22 bytes so far"), first.text)
        _ = session.acl(Self.att([0x0c] + le(0x2e, 2) + le(22, 2)), incoming: false)
        let last = session.acl(Self.att([0x0d] + value.dropFirst(22)), incoming: true)
        XCTAssertEqual(last.protocolName, "App")
        XCTAssertEqual(last.text, #"peripheral → iPhone · Anima Command read · {cmd="fastmode" ok=true list=[1, 2, 300] neg=-5}"#)
        XCTAssertEqual(last.preview, value)

        // An exact multiple of the MTU ends in an error to the next Read Blob instead.
        _ = session.acl(Self.att([0x0a] + le(0x2e, 2)), incoming: false)
        _ = session.acl(Self.att([0x0b, 0x92, 0xc3, 0xc2] + [UInt8](repeating: 0xc0, count: 19)), incoming: true)
        _ = session.acl(Self.att([0x0c] + le(0x2e, 2) + le(22, 2)), incoming: false)
        let ended = session.acl(Self.att([0x01, 0x0c] + le(0x2e, 2) + [0x0b]), incoming: true)
        XCTAssertTrue(ended.text.hasSuffix("read · [true, false] ⚠ 19 trailing bytes not described"), ended.text)
    }

    func testALongWriteIsJoinedAtExecute() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile("""
            services:
              - characteristics:
                  - { name: Anima Command, handle: 0x2e, message: msgpack }
            """)
        let value = Self.messagePack
        // Out of order on purpose: offsets, not arrival, place the segments.
        let second = session.acl(Self.att([0x16] + le(0x2e, 2) + le(18, 2) + value.dropFirst(18)), incoming: false)
        XCTAssertTrue(second.text.contains("offset=18 queued 16 bytes"), second.text)
        _ = session.acl(Self.att([0x16] + le(0x2e, 2) + le(0, 2) + value.prefix(18)), incoming: false)
        let execute = session.acl(Self.att([0x18, 0x01]), incoming: false)
        XCTAssertEqual(execute.text, #"iPhone → peripheral · Anima Command long write · {cmd="fastmode" ok=true list=[1, 2, 300] neg=-5}"#)

        _ = session.acl(Self.att([0x16] + le(0x2e, 2) + le(0, 2) + [1]), incoming: false)
        XCTAssertEqual(session.acl(Self.att([0x18, 0x00]), incoming: false).protocolName, "ATT", "a cancelled queue decodes nothing")
    }

    func testFragmentsFromEachDirectionAreReassembledSeparately() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile("""
            services:
              - characteristics:
                  - { name: Blob, handle: 0x25, message: { seq: [{ id: data, type: bytes }] } }
            """)
        let pdu: [UInt8] = [0x12] + le(0x25, 2) + [UInt8](repeating: 0xab, count: 30)
        let frame = le(UInt64(pdu.count), 2) + le(4, 2) + pdu
        _ = session.acl(Self.acl(Array(frame.prefix(20)), boundary: 2), incoming: false)
        // The watch's notification lands between the phone's fragments.
        let between = session.acl(Self.att([0x1b] + le(0x25, 2) + [1, 2]), incoming: true)
        XCTAssertEqual(between.text, "peripheral → iPhone · Blob notify · data=<0102>")
        let completed = session.acl(Self.acl(Array(frame.dropFirst(20)), boundary: 1), incoming: false)
        XCTAssertEqual(completed.protocolName, "App", completed.text)
    }

    func testMessagePackRendersEveryKindAndNamesIntegerKeys() throws {
        let definitions = try BluetoothPacketDefinitions.compile("""
            types:
              Anima: { seq: [{ id: body, type: msgpack, enum: AnimaKey }] }
            enums:
              AnimaKey: { 1: error, 2: steps_target }
            """)
        let type = BluetoothPacketDefinitions.TypeRef.named("Anima")
        // {1: 22, 2: 10000, 9: nil, "a b": bin<0102>, "x": ext(5, <ff>), "f": 1.5}
        let value: [UInt8] = [0x86, 0x01, 0x16, 0x02, 0xcd, 0x27, 0x10, 0x09, 0xc0,
                              0xa3, 0x61, 0x20, 0x62, 0xc4, 0x02, 0x01, 0x02,
                              0xa1, 0x78, 0xd4, 0x05, 0xff,
                              0xa1, 0x66, 0xcb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(definitions.decode(value, as: type).text,
                       #"body={error=22 steps_target=10000 9=nil "a b"=<0102> x=ext5<ff> f=1.5}"#)
        let truncated = definitions.decode([0x82, 0x01], as: type)
        XCTAssertEqual(truncated.problem, "body: needs 2 entries, 1 bytes left")
        XCTAssertNotNil(definitions.decode([0xc1], as: type).problem)
        // A deeply nested value stops at the depth bound instead of recursing.
        let deep = definitions.decode([UInt8](repeating: 0x91, count: 100) + [0x01], as: type)
        XCTAssertTrue(deep.problem?.contains("nested deeper") == true, String(describing: deep.problem))
        XCTAssertThrowsError(try BluetoothPacketDefinitions.compile("""
            types: { T: { seq: [{ id: s, type: str, enum: E }] } }
            enums: { E: { 1: a } }
            """))
    }

    /// {"cmd": "fastmode", "ok": true, "list": [1, 2, 300], "neg": -5}: 34 bytes, longer than
    /// one 23-byte-MTU response.
    private static let messagePack: [UInt8] = [0x84, 0xa3] + Array("cmd".utf8) + [0xa8] + Array("fastmode".utf8)
        + [0xa2] + Array("ok".utf8) + [0xc3]
        + [0xa4] + Array("list".utf8) + [0x93, 0x01, 0x02, 0xcd, 0x01, 0x2c]
        + [0xa3] + Array("neg".utf8) + [0xfb]

    private static func hex(_ text: String) -> [UInt8] {
        text.split(separator: " ").map { UInt8($0, radix: 16)! }
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

    func testAgentPromptCarriesThePathAndTheExample() throws {
        let prompt = BluetoothDefinitionsGuide.agentPrompt(path: "/repo/.threading/bluetooth.yaml")
        XCTAssertTrue(prompt.contains("/repo/.threading/bluetooth.yaml"))
        XCTAssertTrue(prompt.contains("switch-on: kind"))
        // Everything a newcomer can use is in the prompt, and the advanced snippet compiles.
        for construct in ["type: msgpack", "match:", "learn:", "names: Command", "shapes:", "server: phone",
                          "highlight:", "`visible`", "packets: \"app\"", "transactions:", "streams:", "logs:",
                          "include: [gatt", "level:", "`linked`"] {
            XCTAssertTrue(prompt.contains(construct), construct)
        }
        let advanced = try BluetoothPacketDefinitions.compile(BluetoothDefinitionsGuide.advancedExample)
        XCTAssertEqual(advanced.learners.map(\.enumName), ["Command", "Setting"])
        XCTAssertEqual(advanced.transactions.map(\.name), ["read", "error"])
        XCTAssertEqual(advanced.streams.map(\.name), ["firmware log", "file"])
        XCTAssertEqual(advanced.logLinks.count, 1)
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
