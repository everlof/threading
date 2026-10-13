import AppKit
import XCTest
@testable import DeviceLogsPlugin

/// An app log line and the packet it describes find each other — by characteristic, direction
/// and key, nearest in time — in the pure linker, in the decoder's rows, and across the two tabs.
final class BluetoothLogLinkTests: XCTestCase {
    static let yaml = """
        services:
          - name: Watch
            characteristics:
              - { name: Command, handle: 0x2e, message: Message }
        types:
          Message:
            summary: "{value}"
            seq:
              - id: value
                type: msgpack
                match:
                  - { pattern: "{ $cmd: $value }", summary: "{cmd} {value}" }
                enum: { cmd: Name }
        enums:
          Name: { 3: dnd, 4: alarm }
        logs:
          - match: 'Write -> cmd: "(?<key>[^"]+)"'
            packet: { characteristic: Command, op: write, key: cmd }
        """

    private func packet(_ value: [UInt8], at seconds: Int) throws -> DeviceLogRow {
        var decoder = BluetoothPacketDecoder()
        decoder.definitions = try BluetoothPacketDefinitions.compile(Self.yaml)
        let pdu: [UInt8] = [0x12, 0x2e, 0x00] + value
        let rows = try decoder.append(BluetoothPacketTests.header() + Self.record(BluetoothFlowTests.att(pdu), seconds: seconds))
        return try XCTUnwrap(rows.first)
    }

    /// One HCI ACL record at a given second, outgoing.
    private static func record(_ acl: [UInt8], seconds: Int) -> Data {
        let h4 = [UInt8(2)] + acl
        var data = Data()
        for value in [seconds, 0, h4.count + 4, h4.count + 4] { data += withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) } }
        data += Data([0, 0, 0, 0]) + Data(h4)
        return data
    }

    private func log(_ message: String, at seconds: Double) -> DeviceLogRow {
        DeviceLogRow(time: "", level: "Info", process: "App", subsystem: "bluetooth", message: message,
                     timestamp: Date(timeIntervalSince1970: seconds))
    }

    func testAPacketRowCarriesItsLinkAndTheLinkerPairsByKeyThenTime() throws {
        let rules = try BluetoothPacketDefinitions.compile(Self.yaml).logLinks
        let dnd = try packet([0x81, 0x03, 0x01], at: 100)
        XCTAssertEqual(dnd.link.flatMap(BluetoothLogLink.PacketLink.init),
                       .init(characteristic: "Command", operation: .write, values: ["cmd": "dnd"]))
        let packets = [try packet([0x81, 0x04, 0x01], at: 99), dnd, try packet([0x81, 0x03, 0x00], at: 108)]

        let line = log(#"[DeviceWriter] Write -> cmd: "dnd" as msgpack"#, at: 100.2)
        XCTAssertEqual(BluetoothLogLinker.packet(for: line, rules: rules, in: packets), 1, "the alarm is closer but not dnd")
        XCTAssertNil(BluetoothLogLinker.packet(for: log(#"Write -> cmd: "dnd""#, at: 120), rules: rules, in: packets),
                     "outside the window")
        XCTAssertNil(BluetoothLogLinker.packet(for: log("unrelated", at: 100), rules: rules, in: packets))

        let logs = [log(#"Write -> cmd: "alarm""#, at: 99.9), line, log("other", at: 100)]
        XCTAssertEqual(BluetoothLogLinker.log(for: dnd, rules: rules, in: logs), 1)
    }

    func testRulesAreCheckedWhenTheFileLoads() {
        XCTAssertThrowsError(try BluetoothPacketDefinitions.compile(Self.yaml.replacingOccurrences(of: "(?<key>[^\"]+)", with: "([^\"]+)")))
        XCTAssertThrowsError(try BluetoothPacketDefinitions.compile(Self.yaml.replacingOccurrences(of: "Write -> cmd", with: "Write -> (cmd")))
        XCTAssertThrowsError(try BluetoothPacketDefinitions.compile(Self.yaml.replacingOccurrences(of: "characteristic: Command, op: write", with: "characteristic: Nope, op: write")))
    }

    @MainActor
    func testSelectingARowInOneTabSelectsItsPartnerInTheOther() throws {
        let workspace = DeviceLogWorkspaceViewController(sessionID: nil, toolPath: nil, preferredMachineID: nil)
        let regular = workspace.sectionView(.regular)
        _ = workspace.sectionView(.bluetooth)
        _ = regular
        let logs = try XCTUnwrap(workspace.panes[.regular])
        let packets = try XCTUnwrap(workspace.panes[.bluetooth])
        packets.setLogLinksForTesting(try BluetoothPacketDefinitions.compile(Self.yaml).logLinks)
        let dnd = try packet([0x81, 0x03, 0x01], at: 100)
        packets.installRowsForTesting([try packet([0x81, 0x04, 0x01], at: 99), dnd])
        logs.installRowsForTesting([log("hello", at: 98), log(#"Write -> cmd: "dnd""#, at: 100.1)])

        logs.selectHeldRowAsReaderForTesting(1)
        XCTAssertEqual(packets.selectedHeldRowForTesting?.link, dnd.link)

        logs.selectHeldRowAsReaderForTesting(0)
        packets.selectHeldRowAsReaderForTesting(0)
        XCTAssertEqual(logs.selectedHeldRowForTesting?.message, "hello", "the alarm packet has no log line")
        packets.selectHeldRowAsReaderForTesting(1)
        XCTAssertEqual(logs.selectedHeldRowForTesting?.message, #"Write -> cmd: "dnd""#)
    }
}
