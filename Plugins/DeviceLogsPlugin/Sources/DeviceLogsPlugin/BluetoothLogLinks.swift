import Foundation

/// `logs:` — which app log lines talk about which packets.
///
/// An app usually logs what it sends and receives (`[DeviceWriter] Write -> cmd: "dnd"`) without
/// an operation id or the bytes, so the link cannot be exact. A rule turns a log line into the
/// packet it describes — characteristic, direction, and a key value its definition decodes — and
/// the pair is the nearest such packet in time within a window. Time is the tie-break, never the
/// match: two rows only link when the key, the characteristic and the direction all agree.
struct BluetoothLogLink: @unchecked Sendable, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.characteristic == rhs.characteristic && lhs.operation == rhs.operation
            && lhs.key == rhs.key && lhs.window == rhs.window
    }

    enum Limits {
        static let rules = 64
        static let patternCharacters = 512
        /// The phone writes both streams with its own clock, so they agree to milliseconds; the
        /// window is for an app that logs after the round trip.
        static let defaultWindow: TimeInterval = 5
        static let maximumWindow: TimeInterval = 60
    }

    /// `NSRegularExpression` is immutable once built and documented as thread-safe.
    let expression: NSRegularExpression
    let source: String
    let characteristic: String
    let operation: BluetoothPacketDefinitions.Operation?
    /// The value name the packet's definition decodes (`cmd`); its value is the regex's `key` group.
    let key: String?
    let window: TimeInterval

    /// What this rule says a log line is about, or nil when the line is not one of its lines.
    func target(for message: String) -> Target? {
        let range = NSRange(message.startIndex..., in: message)
        guard let match = expression.firstMatch(in: message, range: range) else { return nil }
        var value: String?
        if key != nil {
            let group = match.range(withName: "key")
            guard group.location != NSNotFound, let found = Range(group, in: message) else { return nil }
            value = String(message[found])
        }
        return Target(characteristic: characteristic, operation: operation, key: key, value: value)
    }

    struct Target: Equatable {
        let characteristic: String
        let operation: BluetoothPacketDefinitions.Operation?
        let key: String?
        let value: String?

        /// Whether a packet row's link describes this.
        func matches(_ link: PacketLink) -> Bool {
            guard link.characteristic == characteristic, operation.map({ $0 == link.operation }) ?? true else { return false }
            guard let key else { return true }
            return link.values[key] == value
        }
    }

    /// What an app packet row carries for linking: its characteristic, operation, and the values
    /// its definition decoded under the names `logs:` rules use as keys.
    struct PacketLink: Equatable {
        static let separator: Character = "\u{1f}"

        let characteristic: String
        let operation: BluetoothPacketDefinitions.Operation?
        let values: [String: String]

        var encoded: String {
            ([characteristic, operation?.rawValue ?? ""] + values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
                .joined(separator: String(Self.separator))
        }

        init(characteristic: String, operation: BluetoothPacketDefinitions.Operation?, values: [String: String]) {
            self.characteristic = characteristic
            self.operation = operation
            self.values = values
        }

        init?(_ encoded: String) {
            let parts = encoded.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { return nil }
            characteristic = parts[0]
            operation = BluetoothPacketDefinitions.Operation(rawValue: parts[1])
            var values: [String: String] = [:]
            for part in parts.dropFirst(2) {
                guard let equals = part.firstIndex(of: "=") else { continue }
                values[String(part[..<equals])] = String(part[part.index(after: equals)...])
            }
            self.values = values
        }
    }
}

extension BluetoothPacketDefinitions {
    /// The link an app row carries, when some `logs:` rule could point at this characteristic.
    func packetLink(characteristic: String, operation: Operation?, values: [String: BluetoothValue]) -> String? {
        let rules = logLinks.filter { $0.characteristic == characteristic }
        guard !rules.isEmpty else { return nil }
        var kept: [String: String] = [:]
        for name in Set(rules.compactMap(\.key)) {
            if let value = values[name] { kept[name] = value.display }
        }
        return BluetoothLogLink.PacketLink(characteristic: characteristic, operation: operation, values: kept).encoded
    }
}

/// Finds a row's partner in the other stream. Pure, so the workspace and the agent tool share it.
enum BluetoothLogLinker {
    /// The packet a log row is about: the matching row nearest in time within the rule's window.
    static func packet(for log: DeviceLogRow, rules: [BluetoothLogLink], in packets: [DeviceLogRow]) -> Int? {
        guard let time = log.timestamp else { return nil }
        for rule in rules {
            guard let target = rule.target(for: log.message) else { continue }
            return nearest(in: packets, to: time, window: rule.window) { row in
                row.link.flatMap(BluetoothLogLink.PacketLink.init).map(target.matches) ?? false
            }
        }
        return nil
    }

    /// The log row about a packet: a log line some rule turns into this packet's link.
    static func log(for packet: DeviceLogRow, rules: [BluetoothLogLink], in logs: [DeviceLogRow]) -> Int? {
        guard let time = packet.timestamp, let link = packet.link.flatMap(BluetoothLogLink.PacketLink.init) else { return nil }
        let relevant = rules.filter { $0.characteristic == link.characteristic }
        guard let window = relevant.map(\.window).max() else { return nil }
        return nearest(in: logs, to: time, window: window) { row in
            relevant.contains { $0.target(for: row.message)?.matches(link) == true }
        }
    }

    /// Rows are in time order, so the scan starts where the window does and stops where it ends.
    private static func nearest(
        in rows: [DeviceLogRow], to time: Date, window: TimeInterval, matching: (DeviceLogRow) -> Bool
    ) -> Int? {
        var lower = 0, upper = rows.count
        let start = time.addingTimeInterval(-window)
        while lower < upper {
            let middle = (lower + upper) / 2
            if let stamp = rows[middle].timestamp, stamp < start { lower = middle + 1 } else { upper = middle }
        }
        var best: (index: Int, distance: TimeInterval)?
        var index = lower
        while index < rows.count {
            defer { index += 1 }
            guard let stamp = rows[index].timestamp else { continue }
            let distance = stamp.timeIntervalSince(time)
            if distance > window { break }
            guard abs(distance) <= window, best.map({ abs(distance) < $0.distance }) ?? true, matching(rows[index]) else { continue }
            best = (index, abs(distance))
        }
        return best?.index
    }
}
