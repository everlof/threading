import Foundation

/// The cross-packet state an ATT value needs before an app definition can read it.
///
/// Three facts are not in any one packet. An L2CAP frame larger than the controller's ACL buffer
/// arrives as a start fragment and continuations, so it is reassembled per connection. An ATT
/// value names an attribute *handle*, while an app knows its characteristics by *UUID*; the
/// mapping is learned from the GATT discovery responses that pass by. And a Read Response carries
/// no handle at all, so the outstanding Read Request's handle is remembered.
///
/// A decoded row also names the peer, from the most specific thing the capture says about it: the
/// GATT Device Name (0x2A00) read on that connection, else the local name the device advertised
/// before it connected, else the definitions' service name, else its address.
///
/// Everything is bounded: one pending frame per connection, a fixed number of connections, a
/// fixed number of learned handles and advertised names, so a long or hostile capture cannot grow it.
struct BluetoothATTSession {
    enum Limits {
        static let connections = 16
        static let handlesPerConnection = 1_024
        static let frameBytes = 65_535 + 4
        static let advertisedNames = 256
        static let nameBytes = 64
    }

    /// The capturing iPhone's side of every row; the capture is always taken on the phone.
    static let localName = "iPhone"

    /// The subsystem of a row decoded by the app's definitions; the pane filters on it exactly.
    static let appProtocolName = "App"

    /// The application's definitions, replaced when the file changes. `nil` means protocol-only.
    var definitions: BluetoothPacketDefinitions?

    private struct Connection {
        var pending: [UInt8] = []
        var expected = 0
        var uuids: [Int: String] = [:]
        var readByTypeUUID: String?
        var readHandle: Int?
        var address: String?
        var deviceName: String?
    }

    private var connections: [Int: Connection] = [:]
    private var order: [Int] = []
    private var advertisedNames: [String: String] = [:]
    private var advertisedOrder: [String] = []

    /// What an ACL packet means, after reassembly.
    struct Summary {
        let protocolName: String
        let text: String
        var error = false
        /// The definitions matched but the bytes did not fit them; logged at Warning.
        var warning = false
        /// Replaces the packet bytes in the row's preview, when the meaningful bytes are an app
        /// value rather than the packet that happened to complete it.
        var preview: [UInt8]?
    }

    mutating func acl(_ payload: [UInt8]) -> Summary {
        guard payload.count >= 4, word(payload, 2) == payload.count - 4 else {
            return Summary(protocolName: "ACL", text: "Malformed ACL Data", error: true)
        }
        let flagsAndHandle = word(payload, 0)
        let handle = flagsAndHandle & 0x0fff
        let packetBoundary = (flagsAndHandle >> 12) & 0x03
        let prefix = "ACL handle=\(hex(handle))"
        let data = Array(payload[4...])

        if packetBoundary == 1 {
            guard var connection = connections[handle], connection.expected > 0 else {
                return Summary(protocolName: "ACL", text: prefix + " continuation")
            }
            connection.pending.append(contentsOf: data)
            guard connection.pending.count >= connection.expected else {
                let progress = "\(connection.pending.count)/\(connection.expected)"
                store(connection, for: handle)
                return Summary(protocolName: "ACL", text: prefix + " continuation \(progress)")
            }
            let frame = connection.pending
            connection.pending = []
            connection.expected = 0
            store(connection, for: handle)
            // `expected` is at most 65,539 by construction, so only an overshoot can go wrong:
            // a lost start fragment followed by another frame's continuations.
            guard frame.count == word(frame, 0) + 4 else {
                return Summary(protocolName: "L2CAP", text: prefix + " reassembly overran the frame", error: true)
            }
            return l2cap(frame, connectionHandle: handle, prefix: prefix + " reassembled")
        }

        guard data.count >= 4 else {
            return Summary(protocolName: "ACL", text: prefix + " incomplete L2CAP header")
        }
        let l2capLength = word(data, 0)
        if l2capLength + 4 > data.count {
            // A start fragment: hold it until the continuations complete the frame.
            var connection = connections[handle] ?? Connection()
            connection.pending = data
            connection.expected = l2capLength + 4
            store(connection, for: handle)
            return Summary(
                protocolName: "L2CAP",
                text: prefix + " CID=\(hex(word(data, 2))) start \(data.count)/\(l2capLength + 4)"
            )
        }
        guard l2capLength + 4 == data.count else {
            return Summary(protocolName: "L2CAP", text: prefix + " CID=\(hex(word(data, 2))) length mismatch", error: true)
        }
        return l2cap(data, connectionHandle: handle, prefix: prefix)
    }

    private mutating func l2cap(_ frame: [UInt8], connectionHandle: Int, prefix: String) -> Summary {
        let channel = word(frame, 2)
        guard channel == 0x0004, frame.count > 4 else {
            return Summary(protocolName: "L2CAP", text: prefix + " CID=\(hex(channel))")
        }
        return att(Array(frame[4...]), connectionHandle: connectionHandle, prefix: prefix)
    }

    private mutating func att(_ pdu: [UInt8], connectionHandle: Int, prefix: String) -> Summary {
        let opcode = pdu[0]
        var connection = connections[connectionHandle] ?? Connection()
        defer { store(connection, for: connectionHandle) }
        learn(opcode: opcode, pdu: pdu, connection: &connection)

        var text = prefix + " ATT " + (Self.attributes[opcode] ?? "opcode=\(hex(Int(opcode)))")
        var attribute: Int?
        if Self.handleOpcodes.contains(opcode), pdu.count >= 3 {
            attribute = word(pdu, 1)
            text += " attribute=\(hex(word(pdu, 1)))"
        }
        if opcode == 0x01, pdu.count >= 5 {
            text += " request=\(hex(Int(pdu[1]))) attribute=\(hex(word(pdu, 2))) error=\(hex(Int(pdu[4])))"
            return Summary(protocolName: "ATT", text: text, error: true)
        }
        if opcode == 0x0b {
            attribute = connection.readHandle
            connection.readHandle = nil
            if let attribute, connection.uuids[attribute] == Self.deviceNameUUID {
                connection.deviceName = Self.name(pdu[1...]) ?? connection.deviceName
            }
        }

        if let definitions, let attribute, let value = Self.value(opcode: opcode, pdu: pdu),
           let characteristic = definitions.characteristic(handle: attribute, uuid: connection.uuids[attribute]),
           let type = Self.received.contains(opcode) ? characteristic.received : characteristic.sent {
            let decoded = definitions.decode(value, as: type)
            let peer = connection.deviceName
                ?? connection.address.flatMap { advertisedNames[$0] }
                ?? characteristic.service
                ?? connection.address
                ?? "peripheral"
            let route = Self.received.contains(opcode) ? "\(peer) → \(Self.localName)" : "\(Self.localName) → \(peer)"
            var appText = "\(route) · \(characteristic.name) \(Self.verbs[opcode] ?? "value") · \(decoded.text)"
            if let problem = decoded.problem { appText += " ⚠ \(problem)" }
            return Summary(
                protocolName: Self.appProtocolName, text: appText, warning: decoded.problem != nil, preview: value
            )
        }
        if let attribute, let uuid = connection.uuids[attribute] {
            text += " uuid=\(uuid)"
        }
        return Summary(protocolName: "ATT", text: text)
    }

    /// Remember what discovery and reads reveal about this connection's attributes.
    private func learn(opcode: UInt8, pdu: [UInt8], connection: inout Connection) {
        switch opcode {
        case 0x08 where pdu.count >= 7:
            // Read By Type Request: start, end, then the attribute type being enumerated.
            connection.readByTypeUUID = BluetoothUUID.canonical(wire: pdu[5...])
        case 0x09 where pdu.count >= 2 && connection.readByTypeUUID == "2803":
            // Characteristic declarations: handle(2) properties(1) value handle(2) UUID(2|16).
            let length = Int(pdu[1])
            guard length == 7 || length == 21 else { return }
            var index = 2
            while index + length <= pdu.count, connection.uuids.count < Limits.handlesPerConnection {
                let valueHandle = word(pdu, index + 3)
                if let uuid = BluetoothUUID.canonical(wire: pdu[(index + 5)..<(index + length)]) {
                    connection.uuids[valueHandle] = uuid
                }
                index += length
            }
        case 0x09 where pdu.count >= 4 && connection.readByTypeUUID == Self.deviceNameUUID:
            // iOS reads the Device Name by type: length, then handle(2) and the value.
            let length = Int(pdu[1])
            guard length > 2, 2 + length <= pdu.count else { return }
            connection.deviceName = Self.name(pdu[4..<(2 + length)]) ?? connection.deviceName
        case 0x0a where pdu.count >= 3, 0x0c where pdu.count >= 3:
            connection.readHandle = word(pdu, 1)
        default:
            break
        }
    }

    /// The application bytes an opcode carries, or nil when it carries none.
    private static func value(opcode: UInt8, pdu: [UInt8]) -> [UInt8]? {
        switch opcode {
        case 0x12, 0x52, 0x1b, 0x1d:
            return pdu.count >= 3 ? Array(pdu[3...]) : nil
        case 0xd2:
            // Signed Write Command ends in a 12-byte authentication signature.
            return pdu.count >= 15 ? Array(pdu[3..<(pdu.count - 12)]) : nil
        case 0x0b:
            return Array(pdu[1...])
        default:
            return nil
        }
    }

    // MARK: HCI events

    /// Learns names and addresses from HCI events: advertising reports carry a device's local
    /// name, a connection complete ties its address to a connection handle, and a disconnection
    /// ends that handle's state so a reused handle does not inherit another device's name.
    mutating func event(_ payload: [UInt8]) {
        guard payload.count >= 3, Int(payload[1]) == payload.count - 2 else { return }
        switch payload[0] {
        case 0x05 where payload.count >= 6 && payload[2] == 0:
            forget(word(payload, 3) & 0x0fff)
        case 0x3e:
            switch payload[2] {
            case 0x01, 0x0a, 0x29:
                // Status, handle(2), role, peer address type, peer address(6), …
                guard payload.count >= 14, payload[3] == 0 else { return }
                let handle = word(payload, 4) & 0x0fff
                forget(handle)
                var connection = Connection()
                connection.address = Self.address(payload[8..<14])
                store(connection, for: handle)
            case 0x02:
                // Legacy reports: only a single report has an unambiguous layout.
                guard payload.count >= 13, payload[3] == 1 else { return }
                let length = Int(payload[12])
                guard 13 + length <= payload.count else { return }
                learnAdvertised(address: Self.address(payload[6..<12]), data: payload[13..<(13 + length)])
            case 0x0d:
                // Extended reports: 24 fixed bytes, then the data length and data, per report.
                var index = 4
                for _ in 0..<Int(payload[3]) {
                    guard index + 24 <= payload.count else { return }
                    let length = Int(payload[index + 23])
                    guard index + 24 + length <= payload.count else { return }
                    learnAdvertised(
                        address: Self.address(payload[(index + 3)..<(index + 9)]),
                        data: payload[(index + 24)..<(index + 24 + length)]
                    )
                    index += 24 + length
                }
            default:
                break
            }
        default:
            break
        }
    }

    private mutating func learnAdvertised(address: String, data: ArraySlice<UInt8>) {
        // AD structures: length, type, value. 0x09 is the complete local name, 0x08 a shortened one.
        var index = data.startIndex
        var shortened: String?
        while index < data.endIndex {
            let length = Int(data[index])
            guard length > 0, index + 1 + length <= data.endIndex else { break }
            let type = data[index + 1]
            let value = data[(index + 2)..<(index + 1 + length)]
            if type == 0x09, let name = Self.name(value) {
                return remember(name, for: address)
            }
            if type == 0x08 { shortened = Self.name(value) }
            index += 1 + length
        }
        if let shortened { remember(shortened, for: address) }
    }

    private mutating func remember(_ name: String, for address: String) {
        if advertisedNames[address] == nil {
            advertisedOrder.append(address)
            if advertisedOrder.count > Limits.advertisedNames {
                advertisedNames[advertisedOrder.removeFirst()] = nil
            }
        }
        advertisedNames[address] = name
    }

    private mutating func forget(_ handle: Int) {
        guard connections.removeValue(forKey: handle) != nil else { return }
        order.removeAll { $0 == handle }
    }

    private static let deviceNameUUID = "2A00"

    /// A device-supplied name, bounded and printable, or nil when there is nothing to show.
    private static func name(_ bytes: ArraySlice<UInt8>) -> String? {
        let text = String(decoding: bytes.prefix(Limits.nameBytes), as: UTF8.self)
            .filter { !$0.isNewline && $0 != "\0" }
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// HCI addresses are little-endian; people read them most-significant byte first.
    private static func address(_ bytes: ArraySlice<UInt8>) -> String {
        bytes.reversed().map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private mutating func store(_ connection: Connection, for handle: Int) {
        if connections[handle] == nil {
            order.append(handle)
            if order.count > Limits.connections {
                connections[order.removeFirst()] = nil
            }
        }
        connections[handle] = connection
    }

    private func word(_ bytes: [UInt8], _ index: Int) -> Int {
        Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
    }
    private func hex(_ value: Int) -> String { String(format: "0x%04x", value) }

    /// Values that flow from the peripheral to the phone; everything else is the phone sending.
    private static let received: Set<UInt8> = [0x1b, 0x1d, 0x0b]
    private static let verbs: [UInt8: String] = [
        0x12: "write", 0x52: "write", 0xd2: "signed write",
        0x1b: "notify", 0x1d: "indicate", 0x0b: "read",
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
