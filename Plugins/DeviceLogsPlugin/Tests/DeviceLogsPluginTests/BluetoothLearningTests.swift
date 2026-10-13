import AppKit
import XCTest
import ThreadingDesignKit
@testable import DeviceLogsPlugin

/// msgpack patterns, enums learned from traffic, named shapes, and the store that keeps what a
/// device taught across captures.
final class BluetoothLearningTests: XCTestCase {

    // MARK: Patterns

    func testPatternsBindEveryEntryAndRespectKindsGlobsAndRest() throws {
        let names: [Int64: String] = [0: "map_cmd", 17: "map_settings", 20: "datetime"]
        let lookup: (Int64) -> String? = { names[$0] }

        let entries = try MessagePackPattern.parse("{ $cmd: $value }")
        let notify = MessagePackValue.map([.init(key: .int(19), value: .int(22)), .init(key: .int(25), value: .array([.int(1)]))])
        XCTAssertEqual(entries.match(notify, name: lookup).count, 2, "one binding per entry")

        let page = try MessagePackPattern.parse("{ map_*: { $number:int: $name:str } }")
        let settings = MessagePackValue.map([.init(key: .int(17), value: .map([
            .init(key: .int(160), value: .string("adv_fastest_timeout")),
            .init(key: .int(161), value: .string("adv_fast_timeout")),
        ]))])
        XCTAssertEqual(page.match(settings, name: lookup).map { $0["number"] }, [.int(160), .int(161)])
        let notAMap = MessagePackValue.map([.init(key: .int(20), value: .map([.init(key: .int(1), value: .string("x"))]))])
        XCTAssertTrue(page.match(notAMap, name: lookup).isEmpty, "datetime is not map_*")
        let wrongKind = MessagePackValue.map([.init(key: .int(17), value: .map([.init(key: .string("x"), value: .string("y"))]))])
        XCTAssertTrue(page.match(wrongKind, name: lookup).isEmpty, "$number:int refuses a string")

        let read = try MessagePackPattern.parse("[ $cmd, ...$args ]")
        let bindings = read.match(.array([.int(17), .int(2), .int(3)]), name: lookup)
        XCTAssertEqual(bindings.first?["args"], .array([.int(2), .int(3)]))
        XCTAssertTrue(read.match(.array([]), name: lookup).isEmpty)
        XCTAssertEqual(try MessagePackPattern.parse("[1, _, \"x\"]").match(.array([.int(1), .null, .string("x")]), name: lookup).count, 1)

        for bad in ["{ $a $b }", "[ $a, ", "$", "{ a: b } extra", String(repeating: "[", count: 300)] {
            XCTAssertThrowsError(try MessagePackPattern.parse(bad), bad)
        }
        XCTAssertTrue(MessagePackPattern.glob("map_*", matches: "map_settings"))
        XCTAssertTrue(MessagePackPattern.glob("*_done", matches: "onboarding_done"))
        XCTAssertFalse(MessagePackPattern.glob("map_*", matches: "datetime"))
    }

    /// Nested maps multiply bindings; the budget stops a hostile value at a bound.
    func testMatchingIsBounded() throws {
        let wide = MessagePackValue.map((0..<200).map { outer in
            .init(key: .int(Int64(outer)), value: .map((0..<200).map { .init(key: .int(Int64($0)), value: .int(0)) }))
        })
        let pattern = try MessagePackPattern.parse("{ $a: { $b: $c } }")
        XCTAssertLessThanOrEqual(pattern.match(wide, name: { _ in nil }).count, MessagePackPattern.Limits.bindings)
    }

    // MARK: Definitions

    private static let anima = """
        services:
          - name: Kronaby
            characteristics:
              - { name: Anima Command, handle: 0x2e, message: AnimaMessage }
        types:
          AnimaMessage:
            seq:
              - id: value
                type: msgpack
                match:
                  - { pattern: "{ $cmd: $value }", summary: "{cmd} {value}" }
                  - { pattern: "[ $cmd, ...$args ]", summary: "read {cmd} {args}" }
                  - { pattern: "$cmd:int", summary: "read {cmd}" }
                enum: { cmd: AnimaCommand }
                values: AnimaValues
        shapes:
          AnimaValues:
            datetime: [year, month, date, hourOfDay, minute, second, dayOfWeek, utcOffset]
        enums:
          AnimaCommand:
            0x00: map_cmd
            learn:
              from: Anima Command
              pattern: "{ map_cmd: { $number: $name } }"
              scope: peer
          AnimaSetting:
            learn:
              from: Anima Command
              pattern: "{ map_settings: { $number: $name } }"
              names: AnimaCommand
        """

    func testMatchRulesNameCommandsAndShapeTheirValues() throws {
        let definitions = try BluetoothPacketDefinitions.compile(Self.anima)
        let type = BluetoothPacketDefinitions.TypeRef.named("AnimaMessage")
        let learned: [String: [Int64: String]] = ["AnimaCommand": [20: "datetime", 8: "fastmode", 19: "error"]]
        // The report's 15:06:39.626 write: {20: [2026, 10, 13, 15, 6, 39, 1]}.
        let datetime: [UInt8] = [0x81, 0x14, 0x97, 0xcd, 0x07, 0xea, 0x0a, 0x0d, 0x0f, 0x06, 0x27, 0x01]
        XCTAssertEqual(definitions.decode(datetime, as: type, learned: learned).text,
                       "value=datetime {year=2026 month=10 date=13 hourOfDay=15 minute=6 second=39 dayOfWeek=1}")
        XCTAssertEqual(definitions.decode([0x92, 0x11, 0x02], as: type, learned: learned).text, "value=read 17? [2]")
        XCTAssertEqual(definitions.decode([0x08], as: type, learned: learned).text, "value=read fastmode")
        XCTAssertEqual(definitions.decode([0x82, 0x13, 0x16, 0x08, 0xc3], as: type, learned: learned).text,
                       "value=error 22, fastmode true", "a map with two commands")
        XCTAssertEqual(definitions.decode([0xc3], as: type, learned: learned).text, "value=true", "no rule fits: plain")
    }

    func testCompileRejectsWhatCannotWork() {
        func failure(_ yaml: String) -> String? {
            do { _ = try BluetoothPacketDefinitions.compile(yaml); return nil } catch {
                return (error as? BluetoothDefinitionError)?.message
            }
        }
        XCTAssertEqual(failure("""
            enums:
              E:
                learn: { from: Nowhere, pattern: "{ $number: $name }" }
            """), "enum E learn: no characteristic named Nowhere under services:")
        XCTAssertTrue(failure("""
            services: [{ characteristics: [{ name: C, handle: 1, message: bytes }] }]
            enums:
              E:
                learn: { from: C, pattern: "{ $n: $name }" }
            """)?.contains("must bind $number and $name") == true)
        XCTAssertTrue(failure("""
            types: { T: { seq: [{ id: v, type: msgpack, match: [{ pattern: "$a", summary: "{b}" }] }] } }
            """)?.contains("summary names {b}") == true)
        XCTAssertTrue(failure("""
            types: { T: { seq: [{ id: v, type: u8, match: [{ pattern: "$a" }] }] } }
            """)?.contains("match: applies to a msgpack field") == true)
    }

    // MARK: Learning on the wire

    func testTheDeviceTeachesSeveralMapsAndLaterPacketsUseThem() throws {
        var session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile(Self.anima)
        // The command map: {0: {0: "map_cmd", 17: "map_settings", 20: "datetime"}}, read in full.
        let commands: [UInt8] = [0x81, 0x00, 0x83, 0x00, 0xa7] + Array("map_cmd".utf8)
            + [0x11, 0xac] + Array("map_settings".utf8) + [0x14, 0xa8] + Array("datetime".utf8)
        XCTAssertGreaterThan(commands.count, 22)
        _ = session.acl(Self.att([0x0a, 0x2e, 0x00]), incoming: false)
        _ = session.acl(Self.att([0x0b] + commands.prefix(22)), incoming: true)
        _ = session.acl(Self.att([0x0c, 0x2e, 0x00, 22, 0]), incoming: false)
        let page = session.acl(Self.att([0x0d] + commands.dropFirst(22)), incoming: true)
        XCTAssertEqual(page.protocolName, "App", page.text)
        XCTAssertTrue(page.text.hasSuffix(#"value=map_cmd {0="map_cmd" 17="map_settings" 20="datetime"}"#), page.text)
        XCTAssertEqual(session.learned.tables(for: nil, enums: ["AnimaCommand"])["AnimaCommand"]?[20], "datetime")

        // The settings map is named by a command the first page taught.
        let settings: [UInt8] = [0x81, 0x11, 0x81, 0xcc, 0xa0, 0xa4] + Array("tick".utf8)
        _ = session.acl(Self.att([0x1b, 0x2e, 0x00] + settings), incoming: true)
        XCTAssertEqual(session.learned.tables(for: nil, enums: ["AnimaSetting"])["AnimaSetting"]?[160], "tick")

        let write = session.acl(Self.att([0x12, 0x2e, 0x00, 0x81, 0x14, 0x92, 0xcd, 0x07, 0xea, 0x0a]), incoming: false)
        XCTAssertTrue(write.text.hasSuffix("Anima Command write · value=datetime {year=2026 month=10}"), write.text)
        let revision = session.learnedRevision
        _ = session.acl(Self.att([0x1b, 0x2e, 0x00] + settings), incoming: true)
        XCTAssertEqual(session.learnedRevision, revision, "the same page again teaches nothing new")

        // A new capture of the same watch starts after the maps were exchanged.
        var later = BluetoothATTSession()
        later.definitions = session.definitions
        later.learned = session.learned
        let replayed = later.acl(Self.att([0x12, 0x2e, 0x00, 0x81, 0x14, 0x91, 0xcd, 0x07, 0xea]), incoming: false)
        XCTAssertTrue(replayed.text.hasSuffix("value=datetime {year=2026}"), replayed.text)
    }

    func testTheStoreRoundTripsAndIsBounded() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("learned.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = BluetoothLearnedEnums()
        XCTAssertTrue(store.learn([(0, "map_cmd"), (20, "datetime")], enumName: "AnimaCommand", identity: "C4:7C",
                                  name: "Kronaby", firmware: "20240705", limit: 2))
        XCTAssertFalse(store.learn([(21, "overflow")], enumName: "AnimaCommand", identity: "C4:7C",
                                   name: nil, firmware: nil, limit: 2), "the table is full")
        try store.save(to: url)
        let loaded = BluetoothLearnedEnums.load(from: url)
        XCTAssertEqual(loaded.tables(for: "C4:7C", enums: ["AnimaCommand"])["AnimaCommand"], [0: "map_cmd", 20: "datetime"])
        XCTAssertEqual(loaded.summary(enums: ["AnimaCommand"]), "AnimaCommand: 2 learned (Kronaby, fw 20240705)")
        XCTAssertEqual(loaded.tables(for: "another", enums: ["AnimaCommand"])["AnimaCommand"]?[20], "datetime",
                       "an unknown device falls back to the latest that taught this enum")
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(BluetoothLearnedEnums.load(from: url).devices.isEmpty, "a damaged file is an empty store")
    }

    // MARK: Colour by name

    func testANameIsAlwaysTheSameLegibleColour() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let first = NameColor.resolved("datetime", appearance: dark)
        XCTAssertEqual(NameColor.resolved("datetime", appearance: dark), first)
        XCTAssertNotEqual(NameColor.resolved("fastmode", appearance: dark).oklch.hueDegrees.rounded(),
                          first.oklch.hueDegrees.rounded())
        XCTAssertEqual(NameColor.hash("datetime"), 0xccea6d90, "FNV-1a, stable across launches")
        let ground = AppThemePalette.current.resolved(.ground, appearance: dark)
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(first, ground), ThemeContrast.minimumRatio - 0.01)

        let spans = LogMessageHighlighter.spans("RX W → iPhone · C notify · datetime {year=2026}", kind: .bluetoothApp,
                                                names: ["datetime"])
        XCTAssertTrue(spans.contains { $0.style == .named("datetime") })
    }

    private static func att(_ pdu: [UInt8]) -> [UInt8] {
        let l2cap = [UInt8(pdu.count), 0, 0x04, 0x00] + pdu
        return [0x40, 0x20, UInt8(l2cap.count), 0] + l2cap
    }
}
