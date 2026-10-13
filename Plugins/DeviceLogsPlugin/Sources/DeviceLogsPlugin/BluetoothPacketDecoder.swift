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
    private var session = BluetoothATTSession()
    /// The app's own definitions for ATT values; replaced live when the file changes.
    var definitions: BluetoothPacketDefinitions? {
        get { session.definitions }
        set { session.definitions = newValue }
    }
    /// Enum entries devices taught; loaded and saved by the capture worker.
    var learned: BluetoothLearnedEnums {
        get { session.learned }
        set { session.learned = newValue }
    }
    var learnedRevision: Int { session.learnedRevision }
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
            // The header's snapshot length is not a bound on records: idevicebtlogger hard-codes
            // 2,048 ("larger than any ACL") yet writes every packet whole, and LE Data Length
            // Extension ACLs exceed it. Each record is bounded by `Limits.packetBytes` instead.
            consumed = Limits.fileHeaderBytes
        }

        var rows: [DeviceLogRow] = []
        while buffer.count - consumed >= Limits.recordHeaderBytes {
            let seconds = number(consumed)
            let microseconds = number(consumed + 4)
            let captured = number(consumed + 8)
            let original = number(consumed + 12)
            guard (Limits.hciHeaderBytes...Limits.packetBytes).contains(captured),
                  original >= captured,
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
            if packetType == 4 { session.event(payload) }
            let acl = packetType == 2 ? session.acl(payload, incoming: direction == 1) : nil
            rows.append(BluetoothPacketSummary.row(
                type: packetType, incoming: direction == 1, payload: payload, acl: acl,
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
        type: UInt8, incoming: Bool, payload: [UInt8], acl: BluetoothATTSession.Summary?,
        seconds: Int, microseconds: Int, truncated: Bool
    ) -> DeviceLogRow {
        let direction = incoming ? "RX" : "TX"
        let summary = acl.map {
            Summary(protocolName: $0.protocolName, text: $0.text, error: $0.error, warning: $0.warning)
        } ?? decode(type: type, payload: payload)
        let clock = seconds % 86_400
        let time = String(format: "%02d:%02d:%02d.%06d", clock / 3_600, clock / 60 % 60, clock % 60, microseconds)
        let payload = acl?.preview ?? payload
        let preview = payload.prefix(BluetoothPacketDecoder.Limits.previewBytes)
            .map { String(format: "%02x", $0) }.joined(separator: " ")
        let omitted = payload.count - min(payload.count, BluetoothPacketDecoder.Limits.previewBytes)
        let suffix = omitted > 0 ? " … (\(omitted) bytes omitted)" : ""
        return DeviceLogRow(
            time: time, level: summary.error ? "Error" : summary.warning ? "Warning" : "Info", process: "Bluetooth",
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
        var warning = false
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
        case 3: return Summary(protocolName: "SCO", text: "SCO Data")
        default: return Summary(protocolName: "HCI", text: "HCI type=\(hex(Int(type)))")
        }
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
}
