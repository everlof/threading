import Foundation
import XCTest
@testable import DeviceLogsPlugin

final class BluetoothDefinitionYAMLTests: XCTestCase {
    func testRealisticDefinitionsDocument() throws {
        let document = """
            # Chronos watch protocol
            ---
            services:
              - uuid: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E   # Nordic UART
                name: "Chronos Watch"
                characteristics:
                  - uuid: 6E400003-B5A3-F393-E0A9-E50E24DCCA9E
                    name: 'Watch → Phone'
                    handle: 0x0025
                    message:
                      seq:
                      - { id: kind, type: u8, enum: MessageKind }   # discriminator
                      - { id: seq,  type: u16le }
                      - id: body
                        switch-on: kind
                        cases:
                          LOCATION: Location
                          BATTERY: { seq: [ { id: percent, type: u8 } ] }

            # Shared types
            types:
              Location:
                seq:
                  - { id: lat, type: s32le, scale: 1e-7, unit: "°" }
                  - id: flags
                    type: u8
                    bits: { precise: 0,
                            background: 1 }
            enums:
              MessageKind:
                0x01: LOCATION
                0x02: BATTERY
            summary: "{kind} #{seq} {body}"
            empty:
            """
        let root = try YAMLSubset.parse(document)
        let service = try XCTUnwrap(root["services"]?[0])
        XCTAssertEqual(root["services"]?.line, 4)
        XCTAssertEqual(service["uuid"]?.value, .scalar("6E400001-B5A3-F393-E0A9-E50E24DCCA9E"))
        XCTAssertEqual(service["name"]?.value, .quoted("Chronos Watch"))
        let characteristic = try XCTUnwrap(service["characteristics"]?[0])
        XCTAssertEqual(characteristic["name"]?.value, .quoted("Watch → Phone"))
        XCTAssertEqual(characteristic["handle"]?.value, .scalar("0x0025"))
        let seq = try XCTUnwrap(characteristic["message"]?["seq"])
        XCTAssertEqual(seq[0]?["enum"]?.text, "MessageKind")
        XCTAssertEqual(seq[1]?["type"]?.text, "u16le")
        XCTAssertEqual(seq[2]?["switch-on"]?.text, "kind")
        XCTAssertEqual(seq[2]?["cases"]?["LOCATION"]?.text, "Location")
        XCTAssertEqual(seq[2]?["cases"]?["BATTERY"]?["seq"]?[0]?["id"]?.text, "percent")
        XCTAssertEqual(seq[2]?.line, 14)

        let location = try XCTUnwrap(root["types"]?["Location"]?["seq"])
        XCTAssertEqual(location[0]?["scale"]?.text, "1e-7")
        XCTAssertEqual(location[0]?["unit"]?.value, .quoted("°"))
        XCTAssertEqual(location[1]?["bits"]?["background"]?.text, "1")
        XCTAssertEqual(location[1]?["bits"]?["background"]?.line, 28)

        guard case .mapping(let kinds)? = root["enums"]?["MessageKind"]?.value else {
            return XCTFail("enum is not a mapping")
        }
        XCTAssertEqual(kinds.map(\.key), ["0x01", "0x02"])
        XCTAssertEqual(kinds.map(\.line), [31, 32])
        XCTAssertEqual(root["summary"]?.value, .quoted("{kind} #{seq} {body}"))
        XCTAssertEqual(root["empty"]?.value, .null)
    }

    func testRejectionsNameTheirLine() {
        let cases: [(String, Int, String)] = [
            ("a:\n\tb: 1", 2, "tabs"),
            ("a: &x 1", 1, "anchors"),
            ("a: 1\nb: *x", 2, "aliases"),
            ("a: !tag 1", 1, "tags"),
            ("a: |\n  text", 1, "block scalars"),
            ("a: >\n  text", 1, "block scalars"),
            ("a: 1\n---\nb: 2", 2, "multiple documents"),
            ("a: 1\n...", 2, "multiple documents"),
            ("a:\n    b: 1\n  c: 2", 3, "indentation"),
            ("a: 1\n  b: 2", 2, "indentation"),
            ("a: 1\n- b", 2, "mapping and a sequence"),
            ("- a\nb: 1", 2, "mapping and a sequence"),
            ("x:\n  - a\n  b: 1", 3, "mapping and a sequence"),
            ("a: \"open", 1, "unterminated quoted"),
            ("a: 'open", 1, "unterminated quoted"),
            ("a: [1, 2", 1, "unterminated flow sequence"),
            ("a:\n  b: {x: 1,\n     y: 2", 2, "unterminated flow mapping"),
            ("a: 1\na: 2", 2, "duplicate key 'a'"),
            ("a: {x: 1, x: 2}", 1, "duplicate key 'x'"),
            ("a: b: c", 1, "own line"),
        ]
        for (text, line, fragment) in cases {
            XCTAssertThrowsError(try YAMLSubset.parse(text), text) { error in
                guard let error = error as? YAMLError else { return XCTFail("\(error)") }
                XCTAssertEqual(error.line, line, "\(text): \(error.message)")
                XCTAssertTrue(error.message.contains(fragment), "\(text): \(error.message)")
            }
        }
    }

    func testQuotedEscapesAndComments() throws {
        let root = try YAMLSubset.parse(#"""
            a: "q\"b\\c\nd\t\x41\u00e9"
            b: 'it''s # not a comment'
            c: plain # a comment
            d: don't stop # here
            "quoted key": [ "x, y", 'z' ]   # trailing
            url: http://example.com/a#b
            """#)
        XCTAssertEqual(root["a"]?.value, .quoted("q\"b\\c\nd\tAé"))
        XCTAssertEqual(root["b"]?.value, .quoted("it's # not a comment"))
        XCTAssertEqual(root["c"]?.value, .scalar("plain"))
        XCTAssertEqual(root["d"]?.value, .scalar("don't stop"))
        XCTAssertEqual(root["quoted key"]?[0]?.value, .quoted("x, y"))
        XCTAssertEqual(root["quoted key"]?[1]?.value, .quoted("z"))
        XCTAssertEqual(root["url"]?.value, .scalar("http://example.com/a#b"))
        XCTAssertThrowsError(try YAMLSubset.parse(#"a: "\q""#))
    }

    func testCompactAndNestedSequences() throws {
        let root = try YAMLSubset.parse("""
            -   id: a
                type: u8
            - - x
              - y
            -
              id: b
            -
            """)
        XCTAssertEqual(root[0]?["type"]?.text, "u8")
        XCTAssertEqual(root[1]?[1]?.text, "y")
        XCTAssertEqual(root[2]?["id"]?.text, "b")
        XCTAssertEqual(root[3]?.value, .null)
        XCTAssertEqual(try YAMLSubset.parse("").value, .null)
        XCTAssertEqual(try YAMLSubset.parse("# only\n---\n").value, .null)
    }

    func testLimits() {
        let deepFlow = String(repeating: "[", count: 40) + String(repeating: "]", count: 40)
        XCTAssertThrowsError(try YAMLSubset.parse("a: " + deepFlow)) { error in
            XCTAssertTrue((error as? YAMLError)?.message.contains("deeper") == true, "\(error)")
        }
        let deepBlock = (0..<40).map { String(repeating: " ", count: $0 * 2) + "k:" }.joined(separator: "\n")
        XCTAssertThrowsError(try YAMLSubset.parse(deepBlock)) { error in
            XCTAssertTrue((error as? YAMLError)?.message.contains("deeper") == true, "\(error)")
        }
        let large = "a: " + String(repeating: "x", count: YAMLSubset.Limits.bytes)
        XCTAssertThrowsError(try YAMLSubset.parse(large)) { error in
            XCTAssertEqual((error as? YAMLError)?.line, 1)
        }
        let many = "[" + Array(repeating: "1", count: YAMLSubset.Limits.nodes + 1).joined(separator: ",") + "]"
        XCTAssertThrowsError(try YAMLSubset.parse(many)) { error in
            XCTAssertTrue((error as? YAMLError)?.message.contains("values") == true, "\(error)")
        }
    }
}

private extension YAMLNode {
    subscript(_ key: String) -> YAMLNode? {
        guard case .mapping(let entries) = value else { return nil }
        return entries.first { $0.key == key }?.value
    }

    subscript(_ index: Int) -> YAMLNode? {
        guard case .sequence(let items) = value, items.indices.contains(index) else { return nil }
        return items[index]
    }

    var text: String? {
        switch value {
        case .scalar(let text), .quoted(let text): return text
        default: return nil
        }
    }
}
