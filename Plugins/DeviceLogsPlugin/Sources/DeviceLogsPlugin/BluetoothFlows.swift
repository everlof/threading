import Foundation

/// What several packets mean together: which response answers which request (`transactions:`),
/// and which values are pieces of one longer thing (`streams:`) — a log, a file, a firmware image.
///
/// Both are declared over *endpoints*: a characteristic, an operation, and conditions on the
/// values its definition decoded. Nothing here knows any product; the Festina watches, the Nordic
/// DFU profiles and a heart-rate strap are all just YAML.
extension BluetoothPacketDefinitions {
    /// What a packet did, as an endpoint names it.
    enum Operation: String, Sendable, CaseIterable {
        case write, read, notify, indicate

        /// From the verb the session gives an app row.
        init?(verb: String) {
            switch verb {
            case "write", "long write", "signed write": self = .write
            case "read": self = .read
            case "notify": self = .notify
            case "indicate": self = .indicate
            default: return nil
            }
        }
    }

    /// `{ characteristic: Anima Command, op: write, where: { cmd: live_logs }, match: "[$cmd, ...]" }`
    struct Endpoint: Sendable {
        let characteristic: String
        /// nil is any operation.
        let operation: Operation?
        /// Every one must hold: a decoded value is one of `values` (`packetType: RESPONSE`,
        /// `packetType: [INIT, PAGE_START]`), or — negated — none of them (`code: "!BATTERY_OK"`).
        let conditions: [ValueTest]
        /// When present, one must match the characteristic's MessagePack value; its captures join
        /// the decoded values.
        let patterns: [MessagePackPattern]
        /// Value names this endpoint reads: `data`, `offset`, `total`, `key`, `crc32`, `crc16`.
        let roles: [String: String]

        /// The values this packet offers when it is this endpoint, or nil when it is not.
        func evaluate(
            characteristic name: String, operation: Operation?, decoded: BluetoothPacketDefinitions.Decoded,
            resolve: (Int64) -> String?, names: (String, Int64) -> String? = { _, _ in nil }
        ) -> [String: BluetoothValue]? {
            guard name == characteristic, self.operation.map({ $0 == operation }) ?? true else { return nil }
            var values = decoded.values
            if !patterns.isEmpty {
                guard let message = decoded.message else { return nil }
                var matched = false
                for pattern in patterns {
                    guard let binding = pattern.match(message, name: resolve).first else { continue }
                    for (id, value) in binding where values[id] == nil {
                        // A capture the characteristic's own definition binds is named by its enum.
                        let name = value.integer.flatMap { number in
                            decoded.captureEnums[id].flatMap { names($0, number) } ?? resolve(number)
                        }
                        values[id] = BluetoothValue(value, name: name)
                    }
                    matched = true
                    break
                }
                guard matched else { return nil }
            }
            for condition in conditions where !condition.holds(values[condition.name]) { return nil }
            // A packet without a value this endpoint reads is a different packet on the same
            // characteristic: the sizes of a DFU image, not its bytes.
            for name in roles.values where values[name] == nil { return nil }
            return values
        }

        func value(_ role: String, in values: [String: BluetoothValue]) -> BluetoothValue? {
            values[roles[role] ?? role]
        }
    }

    struct ValueTest: Sendable {
        let name: String
        let values: [String]
        let negated: Bool

        func holds(_ found: BluetoothValue?) -> Bool {
            // A negated condition on a value the packet does not carry holds: it is not that value.
            guard let found else { return negated }
            return values.contains(where: found.matches) != negated
        }
    }

    struct Transaction: Sendable {
        let name: String
        let request: Endpoint
        let response: Endpoint
        /// A value both sides carry: request name → response name.
        let key: (request: String, response: String)?
        /// A response matching this is "not ready yet", and does not close the request.
        let pending: MessagePackPattern?
        /// Seconds after which an unanswered request is reported.
        let timeout: Double?
        /// Seconds within which a response may pair; after it the request lapses unreported.
        let within: Double?
    }

    struct Stream: Sendable {
        enum Check: String, Sendable { case crc32, crc16 }

        let name: String
        let start: Endpoint?
        /// Supplies a total or checksum later, without starting over.
        let info: Endpoint?
        let data: Endpoint
        let end: Endpoint?
        /// Joined bytes are text, emitted a line at a time.
        let lines: Bool
        /// A token in a line → its level (`E: Error`).
        let levels: [String: BluetoothSeverity]
    }
}

extension BluetoothValue {
    init(_ value: MessagePackValue, name: String?) {
        switch value {
        case .string(let text): self = .text(text)
        case .binary(let data): self = .bytes(data)
        default:
            if let number = value.integer { self = .number(number, name: name) }
            else { self = .text(MessagePack.render(value)) }
        }
    }

    /// The bytes a stream carries: binary as is, text as UTF-8.
    var data: [UInt8]? {
        switch self {
        case .bytes(let bytes): return bytes
        case .text(let text): return Array(text.utf8)
        case .number: return nil
        }
    }
}

// MARK: - Runtime

/// Per-connection state for transactions and streams. Bounded: a few open requests per
/// transaction, a few keyed transfers per stream, one partial line per stream.
struct BluetoothFlowState {
    enum Limits {
        static let openRequests = 16
        static let transfersPerStream = 8
        static let lineBytes = 4_096
        static let linesPerValue = 64
        static let summaryCharacters = 80
        /// Progress is reported at most this often, as a fraction of the total.
        static let progressStep = 0.1
        /// Without a total, every this many bytes.
        static let progressBytes = 64 * 1_024
    }

    /// A row the flows add beside the packet that caused it.
    struct Row: Equatable {
        let text: String
        let level: BluetoothSeverity
        let incoming: Bool
    }

    private struct Request {
        let time: Double
        let summary: String
        let key: String?
    }

    private struct Transfer {
        var started: Double
        var received = 0
        var total: Int?
        var expected: (kind: BluetoothPacketDefinitions.Stream.Check, value: UInt32)?
        var crc32 = CRC.crc32Seed
        var crc16 = CRC.crc16Seed
        var contiguous = true
        var reported = 0.0
        var reportedBytes = 0
        var line: [UInt8] = []
        var touched: Double
    }

    private var open: [Int: [Request]] = [:]
    private var transfers: [Int: [String: Transfer]] = [:]

    /// What one decoded app value means for the flows: the note for its own row, and rows to add.
    mutating func observe(
        definitions: BluetoothPacketDefinitions, characteristic: String, operation: BluetoothPacketDefinitions.Operation?,
        decoded: BluetoothPacketDefinitions.Decoded, incoming: Bool, peer: String, time: Double,
        resolve: (Int64) -> String?, names: (String, Int64) -> String? = { _, _ in nil }
    ) -> (note: String?, rows: [Row]) {
        var note: String?
        var rows: [Row] = []
        let summary = String(decoded.text.prefix(Limits.summaryCharacters))

        for (index, transaction) in definitions.transactions.enumerated() {
            if let values = transaction.response.evaluate(
                characteristic: characteristic, operation: operation, decoded: decoded, resolve: resolve, names: names
            ), var requests = open[index], !requests.isEmpty {
                let key = transaction.key.flatMap { values[$0.response]?.display }
                // "Not ready yet" carries no key; it answers the oldest request.
                let pending = transaction.pending.map { pattern in
                    decoded.message.map { !pattern.match($0, name: resolve).isEmpty } ?? false
                } ?? false
                // A windowed pairing answers the latest request; otherwise the oldest goes first.
                let candidates = requests.indices.filter { position in
                    let request = requests[position]
                    if let within = transaction.within, time - request.time > within { return false }
                    // A response must carry the key to pair: one that does not is some other value
                    // (a characteristic re-read after a write), not this request's answer.
                    return pending || transaction.key == nil || (key != nil && request.key == key)
                }
                if let position = transaction.within != nil ? candidates.last : candidates.first {
                    let request = requests[position]
                    let elapsed = Self.duration(time - request.time)
                    if pending {
                        note = note ?? "↩ \(transaction.name) pending: \(request.summary) · \(elapsed)"
                    } else {
                        requests.remove(at: position)
                        open[index] = requests
                        note = note ?? "↩ \(transaction.name): \(request.summary) · \(elapsed)"
                    }
                }
            }
            if let values = transaction.request.evaluate(
                characteristic: characteristic, operation: operation, decoded: decoded, resolve: resolve, names: names
            ) {
                var requests = open[index] ?? []
                requests.append(Request(time: time, summary: summary, key: transaction.key.flatMap { values[$0.request]?.display }))
                if requests.count > Limits.openRequests { requests.removeFirst() }
                open[index] = requests
            }
        }

        for (index, stream) in definitions.streams.enumerated() {
            if let start = stream.start, let values = start.evaluate(
                characteristic: characteristic, operation: operation, decoded: decoded, resolve: resolve, names: names
            ) {
                let key = start.value("key", in: values)?.display ?? ""
                if let previous = transfers[index]?[key], previous.received > 0 {
                    rows.append(Row(text: "\(peer) · \(stream.name)\(Self.label(key)) restarted after \(Self.size(previous.received))"
                        + (previous.total.map { " of \(Self.size($0))" } ?? ""), level: .warning, incoming: incoming))
                }
                var transfer = Transfer(started: time, touched: time)
                transfer.total = start.value("total", in: values)?.integer.map { Int(clamping: $0) }
                if let crc = start.value("crc32", in: values)?.integer { transfer.expected = (.crc32, UInt32(truncatingIfNeeded: crc)) }
                else if let crc = start.value("crc16", in: values)?.integer { transfer.expected = (.crc16, UInt32(truncatingIfNeeded: crc)) }
                store(transfer, stream: index, key: key)
                note = note ?? "\(stream.name) starts" + (transfer.total.map { " · \(Self.size($0))" } ?? "")
            }
            if let info = stream.info, let values = info.evaluate(
                characteristic: characteristic, operation: operation, decoded: decoded, resolve: resolve, names: names
            ) {
                let key = info.value("key", in: values)?.display ?? ""
                var transfer = transfers[index]?[key] ?? Transfer(started: time, touched: time)
                if let total = info.value("total", in: values)?.integer { transfer.total = Int(clamping: total) }
                if let crc = info.value("crc32", in: values)?.integer { transfer.expected = (.crc32, UInt32(truncatingIfNeeded: crc)) }
                else if let crc = info.value("crc16", in: values)?.integer { transfer.expected = (.crc16, UInt32(truncatingIfNeeded: crc)) }
                store(transfer, stream: index, key: key)
            }
            if let values = stream.data.evaluate(
                characteristic: characteristic, operation: operation, decoded: decoded, resolve: resolve, names: names
            ), let bytes = stream.data.value("data", in: values)?.data {
                let key = stream.data.value("key", in: values)?.display ?? ""
                var transfer = transfers[index]?[key] ?? Transfer(started: time, touched: time)
                transfer.touched = time
                if let total = stream.data.value("total", in: values)?.integer { transfer.total = Int(clamping: total) }
                if let offset = stream.data.value("offset", in: values)?.integer.map({ Int(clamping: $0) }) {
                    if offset == 0, transfer.received > 0 {
                        // Offset zero again: a new transfer under the same key.
                        transfer = Transfer(started: time, total: transfer.total, touched: time)
                    } else if offset != transfer.received {
                        transfer.contiguous = false
                    }
                    transfer.received = max(transfer.received, offset + bytes.count)
                } else {
                    transfer.received += bytes.count
                }
                if transfer.contiguous {
                    transfer.crc32 = CRC.crc32(bytes, transfer.crc32)
                    transfer.crc16 = CRC.crc16(bytes, transfer.crc16)
                }
                if stream.lines {
                    rows += lines(bytes, into: &transfer, stream: stream, peer: peer, incoming: incoming)
                } else if let total = transfer.total, total > 0 {
                    let fraction = min(1, Double(transfer.received) / Double(total))
                    if transfer.received >= total {
                        rows.append(finish(transfer, stream: stream, key: key, peer: peer, incoming: incoming, time: time))
                        transfers[index]?[key] = nil
                        continue
                    }
                    if fraction - transfer.reported >= Limits.progressStep {
                        transfer.reported = (fraction / Limits.progressStep).rounded(.down) * Limits.progressStep
                        rows.append(Row(text: progress(transfer, stream: stream, key: key, peer: peer, time: time), level: .info, incoming: incoming))
                    }
                } else if transfer.received - transfer.reportedBytes >= Limits.progressBytes {
                    transfer.reportedBytes = transfer.received
                    rows.append(Row(text: progress(transfer, stream: stream, key: key, peer: peer, time: time), level: .info, incoming: incoming))
                }
                store(transfer, stream: index, key: key)
            }
            if let end = stream.end, let values = end.evaluate(
                characteristic: characteristic, operation: operation, decoded: decoded, resolve: resolve, names: names
            ) {
                let key = end.value("key", in: values)?.display ?? ""
                if let transfer = transfers[index]?[key] {
                    rows.append(finish(transfer, stream: stream, key: key, peer: peer, incoming: incoming, time: time))
                    transfers[index]?[key] = nil
                }
            }
        }
        return (note, rows)
    }

    /// An ATT Error Response: the read or write it refuses fails the transaction waiting on it.
    mutating func refused(
        definitions: BluetoothPacketDefinitions, characteristic: String, operation: BluetoothPacketDefinitions.Operation
    ) -> String? {
        for (index, transaction) in definitions.transactions.enumerated() {
            guard var requests = open[index], !requests.isEmpty else { continue }
            let failed: Request
            if transaction.response.characteristic == characteristic,
               transaction.response.operation.map({ $0 == operation }) ?? true {
                failed = requests.removeFirst()
            } else if operation == .write, transaction.request.characteristic == characteristic,
                      transaction.request.operation.map({ $0 == .write }) ?? true {
                failed = requests.removeLast()
            } else {
                continue
            }
            open[index] = requests
            return "↩ \(transaction.name) failed: \(failed.summary)"
        }
        return nil
    }

    /// Requests past their timeout, reported once and dropped.
    mutating func expire(definitions: BluetoothPacketDefinitions, time: Double) -> [Row] {
        var rows: [Row] = []
        for (index, requests) in open {
            guard definitions.transactions.indices.contains(index) else { open[index] = nil; continue }
            let transaction = definitions.transactions[index]
            let limit = transaction.timeout ?? transaction.within ?? .infinity
            let (lapsed, kept) = (requests.filter { time - $0.time > limit }, requests.filter { time - $0.time <= limit })
            guard !lapsed.isEmpty else { continue }
            open[index] = kept
            guard let timeout = transaction.timeout else { continue }
            for request in lapsed {
                // Reported by the first packet after the deadline, which a quiet link may delay.
                rows.append(Row(text: "\(transaction.name): no response within \(Self.duration(timeout)) to \(request.summary)"
                                + " (sent \(Self.duration(time - request.time)) ago)", level: .warning, incoming: false))
            }
        }
        return rows
    }

    private mutating func store(_ transfer: Transfer, stream: Int, key: String) {
        var keyed = transfers[stream] ?? [:]
        keyed[key] = transfer
        if keyed.count > Limits.transfersPerStream, let stale = keyed.min(by: { $0.value.touched < $1.value.touched })?.key {
            keyed[stale] = nil
        }
        transfers[stream] = keyed
    }

    private func lines(
        _ bytes: [UInt8], into transfer: inout Transfer, stream: BluetoothPacketDefinitions.Stream, peer: String, incoming: Bool
    ) -> [Row] {
        var rows: [Row] = []
        func emit(_ line: [UInt8]) {
            var text = String(decoding: line, as: UTF8.self)
            while text.hasSuffix("\r") || text.hasSuffix("\0") { text.removeLast() }
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty, rows.count < Limits.linesPerValue else { return }
            let tokens = text.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true).prefix(4)
            let level = tokens.lazy.compactMap { stream.levels[String($0)] }.first ?? .info
            rows.append(Row(text: "\(peer) · \(stream.name) · \(text)", level: level, incoming: incoming))
        }
        for byte in bytes {
            if byte == 0x0a {
                emit(transfer.line)
                transfer.line.removeAll(keepingCapacity: true)
            } else {
                transfer.line.append(byte)
                if transfer.line.count >= Limits.lineBytes {
                    emit(transfer.line)
                    transfer.line.removeAll(keepingCapacity: true)
                }
            }
        }
        return rows
    }

    private func progress(_ transfer: Transfer, stream: BluetoothPacketDefinitions.Stream, key: String, peer: String, time: Double) -> String {
        var text = "\(peer) · \(stream.name)\(Self.label(key)) \(Self.size(transfer.received))"
        if let total = transfer.total, total > 0 {
            text += " of \(Self.size(total)) · \(Int((Double(transfer.received) / Double(total) * 100).rounded(.down)))%"
        }
        return text + Self.rate(transfer, time: time)
    }

    private func finish(
        _ transfer: Transfer, stream: BluetoothPacketDefinitions.Stream, key: String, peer: String, incoming: Bool, time: Double
    ) -> Row {
        let short = transfer.total.map { transfer.received < $0 } ?? false
        var text = "\(peer) · \(stream.name)\(Self.label(key)) "
        if short, let total = transfer.total {
            text += "ended at \(Self.size(transfer.received)) of \(Self.size(total))"
        } else {
            text += "complete · \(Self.size(transfer.received))"
        }
        text += " in \(Self.duration(time - transfer.started))" + Self.rate(transfer, time: time)
        var level = BluetoothSeverity.info
        if let (kind, expected) = transfer.expected {
            let actual = kind == .crc32 ? ~transfer.crc32 : UInt32(transfer.crc16)
            let width = kind == .crc32 ? 8 : 4
            if !transfer.contiguous {
                text += " · \(kind.rawValue) not checked (pieces out of order)"
            } else if actual == expected {
                text += " · \(kind.rawValue) ok"
            } else {
                text += " · \(kind.rawValue) mismatch: expected \(Self.hex(expected, width)), got \(Self.hex(actual, width))"
                level = .error
            }
        }
        if short { level = max(level, .warning) }
        return Row(text: text, level: level, incoming: incoming)
    }

    private static func label(_ key: String) -> String { key.isEmpty ? "" : " \(key)" }

    private static func hex(_ value: UInt32, _ width: Int) -> String { "0x" + String(format: "%0\(width)x", value) }

    private static func rate(_ transfer: Transfer, time: Double) -> String {
        let seconds = time - transfer.started
        guard seconds >= 0.5 else { return "" }
        return " · \(size(Int(Double(transfer.received) / seconds)))/s"
    }

    static func size(_ bytes: Int) -> String {
        bytes < 10_240 ? "\(bytes) B" : bytes < 10_485_760 ? "\(bytes / 1_024) KiB" : "\(bytes / 1_048_576) MiB"
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1_000).rounded())) ms" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        return "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }
}

/// The two checksums transfers declare: CRC-32 (IEEE 802.3, as zlib) and CRC-16/CCITT-FALSE (as
/// Nordic's legacy DFU). Incremental, so no image is held to check it.
enum CRC {
    static let crc32Seed: UInt32 = 0xffff_ffff
    static let crc16Seed: UInt16 = 0xffff

    private static let table32: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1 }
        return value
    }

    /// Continues a CRC-32 register; the final value is the complement (`~`).
    static func crc32(_ bytes: [UInt8], _ register: UInt32) -> UInt32 {
        var crc = register
        for byte in bytes { crc = table32[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc
    }

    static func crc16(_ bytes: [UInt8], _ register: UInt16) -> UInt16 {
        var crc = register
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }
}
