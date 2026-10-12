import Foundation

/// Incremental reader for idevicebtlogger's microsecond PCAP, LINKTYPE_BLUETOOTH_HCI_H4_WITH_PHDR.
/// Protocol facts: libimobiledevice/tools/idevicebtlogger.c; no Apple decoder is linked or copied.
/// A feed is one bounded pipe read. Only one incomplete packet survives between feeds.
struct BluetoothPacketDecoder {
    enum Limits {
        static let chunkBytes = 32 * 1_024
        static let packetBytes = 65_535
        static let previewBytes = 256
        static let fileHeaderBytes = 24
        static let recordHeaderBytes = 16
        static let hciHeaderBytes = 5
        static let linkType = 201
    }

    enum DecodeError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let reason): return "Invalid Bluetooth capture: \(reason)."
            }
        }
    }

    private var buffer: [UInt8] = []
    private var littleEndian: Bool?
    private var snapLength = 0
    var bufferedBytes: Int { buffer.count }

    mutating func append(_ data: Data) throws -> [DeviceLogRow] {
        guard data.count <= Limits.chunkBytes else { throw DecodeError.invalid("oversized read") }
        buffer.append(contentsOf: data)
        var consumed = 0
        defer { if consumed > 0 { buffer.removeFirst(consumed) } }

        if littleEndian == nil {
            guard buffer.count >= Limits.fileHeaderBytes else { return [] }
            switch Array(buffer.prefix(4)) {
            case [0xa1, 0xb2, 0xc3, 0xd4]: littleEndian = false
            case [0xd4, 0xc3, 0xb2, 0xa1]: littleEndian = true
            default: throw DecodeError.invalid("expected microsecond PCAP")
            }
            guard number(4, bytes: 2) == 2, number(6, bytes: 2) == 4,
                  number(20) == Limits.linkType else {
                throw DecodeError.invalid("unsupported PCAP version or link type")
            }
            snapLength = number(16)
            guard (Limits.hciHeaderBytes...Limits.packetBytes).contains(snapLength) else {
                throw DecodeError.invalid("invalid snapshot length")
            }
            consumed = Limits.fileHeaderBytes
        }

        var rows: [DeviceLogRow] = []
        while buffer.count - consumed >= Limits.recordHeaderBytes {
            let seconds = number(consumed)
            let microseconds = number(consumed + 4)
            let captured = number(consumed + 8)
            let original = number(consumed + 12)
            guard (Limits.hciHeaderBytes...Limits.packetBytes).contains(captured),
                  captured <= snapLength, original >= captured,
                  microseconds < 1_000_000 else {
                throw DecodeError.invalid("invalid packet length or timestamp")
            }
            let start = consumed + Limits.recordHeaderBytes
            let end = start + captured
            guard buffer.count >= end else { break }
            // The pseudo-header is network order, independently of the PCAP file's byte order.
            let direction = buffer[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard direction <= 1 else { throw DecodeError.invalid("invalid HCI direction") }
            let packetType = buffer[start + 4]
            let payload = Array(buffer[start + Limits.hciHeaderBytes..<end])
            rows.append(BluetoothPacketSummary.row(
                type: packetType, incoming: direction == 1, payload: payload,
                seconds: seconds, microseconds: microseconds, truncated: captured < original
            ))
            consumed = end
        }
        return rows
    }

    func finish() throws {
        guard buffer.isEmpty else { throw DecodeError.invalid("truncated PCAP stream") }
    }

    private func number(_ offset: Int, bytes: Int = 4) -> Int {
        let slice = buffer[offset..<offset + bytes]
        if littleEndian == true { return slice.reversed().reduce(0) { ($0 << 8) | Int($1) } }
        return slice.reduce(0) { ($0 << 8) | Int($1) }
    }
}

private enum BluetoothPacketSummary {
    static func row(
        type: UInt8, incoming: Bool, payload: [UInt8],
        seconds: Int, microseconds: Int, truncated: Bool
    ) -> DeviceLogRow {
        let direction = incoming ? "RX" : "TX"
        let summary = decode(type: type, payload: payload)
        let clock = seconds % 86_400
        let time = String(format: "%02d:%02d:%02d.%06d", clock / 3_600, clock / 60 % 60, clock % 60, microseconds)
        let preview = payload.prefix(BluetoothPacketDecoder.Limits.previewBytes)
            .map { String(format: "%02x", $0) }.joined(separator: " ")
        let omitted = payload.count - min(payload.count, BluetoothPacketDecoder.Limits.previewBytes)
        let suffix = omitted > 0 ? " … (\(omitted) bytes omitted)" : ""
        return DeviceLogRow(
            time: time, level: summary.error ? "Error" : "Info", process: "Bluetooth",
            subsystem: summary.protocolName,
            message: "\(direction) \(summary.text) · \(payload.count) bytes"
                + (truncated ? " (capture truncated)" : "") + " | \(preview)\(suffix)",
            timestamp: Date(timeIntervalSince1970: Double(seconds) + Double(microseconds) / 1_000_000)
        )
    }

    private struct Summary {
        let protocolName: String
        let text: String
        var error = false
    }

    private static func decode(type: UInt8, payload: [UInt8]) -> Summary {
        switch type {
        case 1:
            guard payload.count >= 3, Int(payload[2]) == payload.count - 3 else {
                return Summary(protocolName: "HCI", text: "Malformed HCI Command", error: true)
            }
            let opcode = word(payload, 0)
            let name = commands[opcode].map { " \($0)" } ?? ""
            return Summary(protocolName: "HCI", text: "HCI Command \(hex(opcode))\(name)")
        case 4:
            guard payload.count >= 2, Int(payload[1]) == payload.count - 2 else {
                return Summary(protocolName: "HCI", text: "Malformed HCI Event", error: true)
            }
            let event = payload[0]
            var text = "HCI Event \(hex(Int(event)))"
            var failed = false
            if event == 0x0e, payload.count >= 5 {
                // Command Complete's return parameters are command-specific, so do not assume
                // their first byte is a status for every opcode (some return a handle directly).
                text += " Command Complete opcode=\(hex(word(payload, 3)))"
            } else if event == 0x0f, payload.count >= 6 {
                text += " Command Status opcode=\(hex(word(payload, 4))) status=\(hex(Int(payload[2])))"
                failed = payload[2] != 0
            } else if event == 0x3e, payload.count >= 3 {
                text += " LE Meta subevent=\(hex(Int(payload[2])))"
            } else if event == 0x05, payload.count >= 6 {
                text += " Disconnection Complete handle=\(hex(word(payload, 3))) reason=\(hex(Int(payload[5])))"
                failed = payload[2] != 0
            }
            return Summary(protocolName: "HCI", text: text, error: failed)
        case 2: return acl(payload)
        case 3: return Summary(protocolName: "SCO", text: "SCO Data")
        default: return Summary(protocolName: "HCI", text: "HCI type=\(hex(Int(type)))")
        }
    }

    private static func acl(_ payload: [UInt8]) -> Summary {
        guard payload.count >= 4, word(payload, 2) == payload.count - 4 else {
            return Summary(protocolName: "ACL", text: "Malformed ACL Data", error: true)
        }
        let flagsAndHandle = word(payload, 0)
        let handle = flagsAndHandle & 0x0fff
        let packetBoundary = (flagsAndHandle >> 12) & 0x03
        let prefix = "ACL handle=\(hex(handle))"
        // No cross-packet reassembly in this reader. A continuation cannot be interpreted as a
        // new L2CAP header, even when its bytes happen to resemble the ATT fixed channel.
        guard packetBoundary != 1 else {
            return Summary(protocolName: "ACL", text: prefix + " continuation")
        }
        guard payload.count >= 8 else {
            return Summary(protocolName: "ACL", text: prefix + " incomplete L2CAP header")
        }
        let l2capLength = word(payload, 4)
        let channel = word(payload, 6)
        guard l2capLength == payload.count - 8 else {
            return Summary(protocolName: "L2CAP", text: prefix + " CID=\(hex(channel)) fragmented L2CAP")
        }
        guard channel == 0x0004, payload.count > 8 else {
            return Summary(protocolName: "L2CAP", text: prefix + " CID=\(hex(channel))")
        }
        let opcode = payload[8]
        var text = prefix + " ATT " + (attributes[opcode] ?? "opcode=\(hex(Int(opcode)))")
        if handleOpcodes.contains(opcode), payload.count >= 11 {
            text += " attribute=\(hex(word(payload, 9)))"
        }
        if opcode == 0x01, payload.count >= 13 {
            text += " request=\(hex(Int(payload[9]))) attribute=\(hex(word(payload, 10))) error=\(hex(Int(payload[12])))"
        }
        return Summary(protocolName: "ATT", text: text, error: opcode == 0x01)
    }

    private static func word(_ bytes: [UInt8], _ index: Int) -> Int {
        Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
    }
    private static func hex(_ value: Int) -> String { String(format: "0x%04x", value) }

    private static let commands: [Int: String] = [
        0x0406: "Disconnect", 0x0c03: "Reset", 0x0c01: "Set Event Mask",
        0x2006: "LE Set Advertising Parameters", 0x2008: "LE Set Advertising Data",
        0x200a: "LE Set Advertising Enable", 0x200b: "LE Set Scan Parameters",
        0x200c: "LE Set Scan Enable", 0x200d: "LE Create Connection",
        0x2013: "LE Connection Update", 0x2019: "LE Start Encryption",
        0x2041: "LE Set Extended Scan Parameters", 0x2042: "LE Set Extended Scan Enable",
        0x2043: "LE Extended Create Connection",
    ]
    private static let handleOpcodes: Set<UInt8> = [0x0a, 0x0c, 0x12, 0x16, 0x17, 0x1b, 0x1d, 0x52, 0xd2]
    private static let attributes: [UInt8: String] = [
        0x01: "Error Response", 0x02: "Exchange MTU Request", 0x03: "Exchange MTU Response",
        0x04: "Find Information Request", 0x05: "Find Information Response",
        0x08: "Read By Type Request", 0x09: "Read By Type Response",
        0x0a: "Read Request", 0x0b: "Read Response", 0x0c: "Read Blob Request",
        0x0d: "Read Blob Response", 0x10: "Read By Group Type Request", 0x11: "Read By Group Type Response",
        0x12: "Write Request", 0x13: "Write Response", 0x16: "Prepare Write Request",
        0x17: "Prepare Write Response", 0x18: "Execute Write Request", 0x19: "Execute Write Response",
        0x1b: "Handle Value Notification", 0x1d: "Handle Value Indication",
        0x1e: "Handle Value Confirmation", 0x52: "Write Command", 0xd2: "Signed Write Command",
    ]
}
