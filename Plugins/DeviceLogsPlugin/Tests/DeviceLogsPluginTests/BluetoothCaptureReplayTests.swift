import Foundation
import XCTest
@testable import DeviceLogsPlugin

/// Replays a stored Bluetooth capture through the current decoder. Opt-in: point
/// `THREADING_BT_REPLAY_ROWS` at `sqlite3 -separator $'\t' <capture>-bluetooth.sqlite
/// "select clock, subsystem, message from rows order by id"` and `THREADING_BT_REPLAY_YAML` at the
/// definitions. Rows keep each packet's bytes in their hex preview; rows an older decoder already
/// turned into App rows kept only the value, so those are rebuilt from the characteristic named.
final class BluetoothCaptureReplayTests: XCTestCase {
    func testReplayStoredCapture() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rowsPath = environment["THREADING_BT_REPLAY_ROWS"],
              let yamlPath = environment["THREADING_BT_REPLAY_YAML"] else {
            throw XCTSkip("set THREADING_BT_REPLAY_ROWS and THREADING_BT_REPLAY_YAML")
        }
        let definitions = try BluetoothPacketDefinitions.compile(String(contentsOfFile: yamlPath, encoding: .utf8))
        var session = BluetoothATTSession()
        session.definitions = definitions
        session.phoneIdentity = "replay"
        // `THREADING_BT_REPLAY_RESTART=15:08` starts a new session at that clock, carrying only
        // what Threading remembers across captures — as a capture restarted mid-connection would.
        var restart = environment["THREADING_BT_REPLAY_RESTART"]
        var phase = ""
        var unresolved = 0
        var connection = 0x40
        var decoded: [String: Int] = [:]
        var samples: [String: [String]] = [:]
        var skipped = 0
        for line in try String(contentsOfFile: rowsPath, encoding: .utf8).split(separator: "\n") {
            let columns = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard columns.count == 3, columns[2].count > 3 else { continue }
            let (clock, subsystem, message) = (columns[0], columns[1], columns[2])
            if let at = restart, clock >= at {
                var next = BluetoothATTSession()
                next.definitions = definitions
                next.phoneIdentity = "replay"
                next.gatt = session.gatt
                next.learned = session.learned
                session = next
                restart = nil
                phase = "after restart: "
                print("Replay: restarted at \(clock) with \(session.gatt.devices.count) remembered tables")
            }
            let incoming = message.hasPrefix("RX")
            let clockParts = clock.split(separator: ":").compactMap { Double($0) }
            if clockParts.count == 3 { session.time = clockParts[0] * 3_600 + clockParts[1] * 60 + clockParts[2] }
            defer {
                for row in session.takeFlowRows() {
                    let key = "flow \(row.level.level): " + row.text.components(separatedBy: " · ").prefix(2).joined(separator: " · ")
                        .components(separatedBy: CharacterSet.decimalDigits).first!
                    decoded[key, default: 0] += 1
                    if samples[key, default: []].count < (Int(environment["THREADING_BT_REPLAY_SAMPLES"] ?? "") ?? 3) {
                        samples[key, default: []].append("\(clock) \(row.text.prefix(300))")
                    }
                }
            }
            guard let bar = message.range(of: " | ", options: .backwards), !message.contains("omitted)") else {
                skipped += 1
                continue
            }
            let bytes = message[bar.upperBound...].split(separator: " ").compactMap { UInt8($0, radix: 16) }
            let summary: BluetoothATTSession.Summary
            switch subsystem {
            case "HCI" where message.contains("HCI Event"):
                if let event = session.event(bytes) {
                    let key = "link: " + event.text.components(separatedBy: CharacterSet(charactersIn: " ·")).prefix(2).joined(separator: " ")
                    decoded[key, default: 0] += 1
                    if samples[key, default: []].count < 3 { samples[key, default: []].append("\(clock) \(event.text)") }
                }
                continue
            case "ATT", "L2CAP", "ACL":
                // An App row does not say its connection; the last ATT exchange's is the best guess.
                if subsystem == "ATT", let handle = message.range(of: "ACL handle=0x").map({ message[$0.upperBound...].prefix(4) }),
                   let number = Int(handle, radix: 16) {
                    connection = number
                }
                summary = session.acl(bytes, incoming: incoming)
            case "App":
                guard let pdu = rebuild(message, value: bytes, definitions: definitions, session: session, connection: connection) else {
                    skipped += 1
                    continue
                }
                summary = session.acl(Self.att(pdu, connection: connection), incoming: incoming)
            default:
                continue
            }
            guard summary.protocolName == BluetoothATTSession.appProtocolName else {
                if !phase.isEmpty, summary.text.contains(" attribute="), !summary.text.contains("uuid=") {
                    unresolved += 1
                    if unresolved <= 10 { print("Replay: no UUID \(clock) \(summary.text.prefix(120))") }
                }
                continue
            }
            var name = phase + (summary.text.components(separatedBy: " · ").dropFirst().first ?? "?")
            if summary.text.contains(" ↩ ") { name += " (paired)" }
            if let level = summary.level, level != .info { name += " [\(level.level)]" }
            decoded[name, default: 0] += 1
            if samples[name, default: []].count < (Int(environment["THREADING_BT_REPLAY_SAMPLES"] ?? "") ?? 3) { samples[name, default: []].append("\(clock) \(summary.text.prefix(Int(environment["THREADING_BT_REPLAY_WIDTH"] ?? "") ?? 300))") }
        }
        print("Replay: skipped \(skipped) rows without whole bytes; \(unresolved) ATT rows after restart had no UUID")
        print("Replay: GATT line: \(session.gattSummary ?? "none")")
        for attempt in session.procedures.history.attempts {
            print("Replay timeline:\n" + BluetoothProcedureFormatting.timeline(attempt))
        }
        for (name, count) in decoded.sorted(by: { $0.value > $1.value }) {
            print("Replay: \(count) × \(name)")
            for sample in samples[name] ?? [] { print("    \(sample)") }
        }
    }

    /// The packet an older App row stood for: its verb says the opcode, its characteristic the handle.
    private func rebuild(_ message: String, value: [UInt8], definitions: BluetoothPacketDefinitions,
                         session: BluetoothATTSession, connection: Int) -> [UInt8]? {
        let parts = message.components(separatedBy: " · ")
        guard parts.count >= 3 else { return nil }
        let words = parts[1].split(separator: " ")
        guard let verb = words.last else { return nil }
        let name = words.dropLast().joined(separator: " ")
        if verb == "read" { return [0x0b] + value }
        guard let uuid = definitions.characteristics.first(where: { $0.name == name })?.uuid,
              let handle = session.handleForTesting(uuid: uuid, connection: connection) else { return nil }
        let opcode: UInt8 = verb == "notify" ? 0x1b : verb == "indicate" ? 0x1d : 0x12
        return [opcode, UInt8(handle & 0xff), UInt8(handle >> 8)] + value
    }

    private static func att(_ pdu: [UInt8], connection: Int) -> [UInt8] {
        let l2cap = [UInt8(pdu.count & 0xff), UInt8(pdu.count >> 8), 0x04, 0x00] + pdu
        return [UInt8(connection & 0xff), UInt8(0x20 | connection >> 8), UInt8(l2cap.count & 0xff), UInt8(l2cap.count >> 8)] + l2cap
    }
}
