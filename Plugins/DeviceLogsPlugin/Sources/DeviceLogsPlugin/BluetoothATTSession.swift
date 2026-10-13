import Foundation

/// The cross-packet state an ATT value needs before an app definition can read it.
///
/// Several facts are not in any one packet:
///
/// - An L2CAP frame larger than the controller's ACL buffer arrives as a start fragment and
///   continuations. They are reassembled per connection *and direction*, because both ends send
///   on the same connection handle and their fragments interleave.
/// - Both ends of an LE link can be GATT servers, each with its own handle space: the phone
///   hosts ANCS and Current Time, the accessory hosts the app's service, and the two may well
///   both have a handle 0x0028. Every ATT PDU therefore belongs to one *database*: odd opcodes
///   (responses, notifications, indications) are sent by that database's server, even opcodes
///   (requests, commands, the confirmation) are sent to it. Handles, discovery and pending reads
///   are all kept per database.
/// - A value names an attribute *handle*, while an app knows its characteristics by *UUID*; the
///   mapping is learned from the GATT discovery responses that pass by.
/// - A Read Response carries no handle, so the outstanding request's is remembered. A value
///   longer than one response continues in Read Blob responses, and a long write arrives as
///   Prepare Writes committed by an Execute Write; both are joined before decoding.
///
/// A decoded row also names the peer, from the most specific thing the capture says about it: the
/// GATT Device Name (0x2A00) read from the device, else the local name it advertised before it
/// connected, else the definitions' service name, else its address.
///
/// Everything is bounded: one pending frame per connection and direction, a fixed number of
/// connections, learned handles and advertised names, and long values capped at the ATT maximum.
struct BluetoothATTSession {
    enum Limits {
        static let connections = 16
        static let handlesPerDatabase = 1_024
        static let frameBytes = 65_535 + 4
        static let advertisedNames = 256
        static let nameBytes = 64
        /// The ATT maximum attribute length; a long read or write never grows past it.
        static let longValueBytes = 512
        static let preparedWrites = 64
        static let defaultMTU = 23
    }

    /// The capturing iPhone's side of every row; the capture is always taken on the phone.
    static let localName = "iPhone"

    /// The subsystem of a row decoded by the app's definitions; the pane filters on it exactly.
    static let appProtocolName = "App"

    /// The application's definitions, replaced when the file changes. `nil` means protocol-only.
    var definitions: BluetoothPacketDefinitions?

    /// What one GATT server's attribute database has revealed.
    private struct Database {
        var uuids: [Int: String] = [:]
        var readByTypeUUID: String?
        var readHandle: Int?
        /// A value being read in pieces: its handle and the bytes so far.
        var longRead: (handle: Int, value: [UInt8])?
        /// Prepare Write segments waiting for an Execute Write.
        var prepared: [(handle: Int, offset: Int, value: [UInt8])] = []
    }

    private struct Connection {
        /// Reassembly, indexed by direction: 0 sent by the phone, 1 received.
        var pending: [[UInt8]] = [[], []]
        var expected = [0, 0]
        var databases: [BluetoothGATTServer: Database] = [:]
        var requestedMTU: Int?
        var mtu = Limits.defaultMTU
        var address: String?
        var deviceName: String?
        /// The device's Firmware Revision String (0x2A26), when the capture read it.
        var firmware: String?

        /// Who taught a learned enum: the address when the connection was seen, else the name.
        var identity: String? { address ?? deviceName.map { "name:\($0)" } }
    }

    /// Enum entries devices taught, kept across captures by the capture worker.
    var learned = BluetoothLearnedEnums()
    /// Bumped whenever `learned` gains something, so the worker knows to save.
    private(set) var learnedRevision = 0

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

    /// `incoming` is the capture's direction: true when the phone received the packet.
    mutating func acl(_ payload: [UInt8], incoming: Bool) -> Summary {
        guard payload.count >= 4, word(payload, 2) == payload.count - 4 else {
            return Summary(protocolName: "ACL", text: "Malformed ACL Data", error: true)
        }
        let flagsAndHandle = word(payload, 0)
        let handle = flagsAndHandle & 0x0fff
        let packetBoundary = (flagsAndHandle >> 12) & 0x03
        let prefix = "ACL handle=\(hex(handle))"
        let data = Array(payload[4...])
        let lane = incoming ? 1 : 0

        if packetBoundary == 1 {
            guard var connection = connections[handle], connection.expected[lane] > 0 else {
                return Summary(protocolName: "ACL", text: prefix + " continuation")
            }
            connection.pending[lane].append(contentsOf: data)
            guard connection.pending[lane].count >= connection.expected[lane] else {
                let progress = "\(connection.pending[lane].count)/\(connection.expected[lane])"
                store(connection, for: handle)
                return Summary(protocolName: "ACL", text: prefix + " continuation \(progress)")
            }
            let frame = connection.pending[lane]
            connection.pending[lane] = []
            connection.expected[lane] = 0
            store(connection, for: handle)
            // `expected` is at most 65,539 by construction, so only an overshoot can go wrong:
            // a lost start fragment followed by another frame's continuations.
            guard frame.count == word(frame, 0) + 4 else {
                return Summary(protocolName: "L2CAP", text: prefix + " reassembly overran the frame", error: true)
            }
            return l2cap(frame, connectionHandle: handle, incoming: incoming, prefix: prefix + " reassembled")
        }

        guard data.count >= 4 else {
            return Summary(protocolName: "ACL", text: prefix + " incomplete L2CAP header")
        }
        let l2capLength = word(data, 0)
        if l2capLength + 4 > data.count {
            // A start fragment: hold it until the continuations complete the frame.
            var connection = connections[handle] ?? Connection()
            connection.pending[lane] = data
            connection.expected[lane] = l2capLength + 4
            store(connection, for: handle)
            return Summary(
                protocolName: "L2CAP",
                text: prefix + " CID=\(hex(word(data, 2))) start \(data.count)/\(l2capLength + 4)"
            )
        }
        guard l2capLength + 4 == data.count else {
            return Summary(protocolName: "L2CAP", text: prefix + " CID=\(hex(word(data, 2))) length mismatch", error: true)
        }
        return l2cap(data, connectionHandle: handle, incoming: incoming, prefix: prefix)
    }

    private mutating func l2cap(_ frame: [UInt8], connectionHandle: Int, incoming: Bool, prefix: String) -> Summary {
        let channel = word(frame, 2)
        guard channel == 0x0004, frame.count > 4 else {
            return Summary(protocolName: "L2CAP", text: prefix + " CID=\(hex(channel))")
        }
        var connection = connections[connectionHandle] ?? Connection()
        let summary = att(Array(frame[4...]), incoming: incoming, connection: &connection, prefix: prefix)
        store(connection, for: connectionHandle)
        return summary
    }

    // MARK: ATT

    private mutating func att(_ pdu: [UInt8], incoming: Bool, connection: inout Connection, prefix: String) -> Summary {
        let opcode = pdu[0]
        // A server sends odd opcodes about its own database; a client sends even ones to the
        // other end's. The phone is the sender when the packet is outgoing.
        let serverSent = opcode & 1 == 1
        let server: BluetoothGATTServer = serverSent != incoming ? .phone : .device
        var database = connection.databases[server] ?? Database()
        defer { connection.databases[server] = database }
        learn(opcode: opcode, pdu: pdu, server: server, database: &database, connection: &connection)

        var text = prefix + " ATT " + (Self.attributes[opcode] ?? "opcode=\(hex(Int(opcode)))")
        if server == .phone { text += " (iPhone's database)" }
        func annotated(_ attribute: Int?) -> String {
            guard let attribute, let uuid = database.uuids[attribute] else { return text }
            return text + " uuid=\(uuid)"
        }
        var attribute: Int?
        if Self.handleOpcodes.contains(opcode), pdu.count >= 3 {
            attribute = word(pdu, 1)
            text += " attribute=\(hex(word(pdu, 1)))"
        }

        switch opcode {
        case 0x01 where pdu.count >= 5:
            let request = pdu[1]
            let handle = word(pdu, 2)
            // A long value ends in an error when its length was an exact multiple of the MTU.
            if request == 0x0c, let long = database.longRead, long.handle == handle {
                database.longRead = nil
                database.readHandle = nil
                if server == .device { Self.note(long.value, uuid: database.uuids[handle], connection: &connection) }
                if let row = app(handle, long.value, verb: "read", incoming: incoming, server: server,
                                 database: database, connection: connection) {
                    return row
                }
            }
            text += " request=\(hex(Int(request))) attribute=\(hex(handle)) error=\(hex(Int(pdu[4])))"
            return Summary(protocolName: "ATT", text: text, error: true)
        case 0x02 where pdu.count >= 3:
            connection.requestedMTU = word(pdu, 1)
            return Summary(protocolName: "ATT", text: text + " mtu=\(word(pdu, 1))")
        case 0x03 where pdu.count >= 3:
            let offered = word(pdu, 1)
            connection.mtu = max(Limits.defaultMTU, min(offered, connection.requestedMTU ?? offered))
            return Summary(protocolName: "ATT", text: text + " mtu=\(offered)")
        case 0x0b:
            guard let handle = database.readHandle else { break }
            database.readHandle = nil
            let value = Array(pdu[1...])
            if server == .device { Self.note(value, uuid: database.uuids[handle], connection: &connection) }
            // A full response may be the first piece of a longer value; the Read Blobs that
            // follow decide. Without definitions there is nothing to join for.
            if definitions != nil, value.count >= connection.mtu - 1 {
                database.longRead = (handle, value)
                return Summary(protocolName: "ATT", text: annotated(handle) + " attribute=\(hex(handle)) \(value.count) bytes so far")
            }
            if let row = app(handle, value, verb: "read", incoming: incoming, server: server,
                             database: database, connection: connection) {
                return row
            }
            return Summary(protocolName: "ATT", text: annotated(handle) + " attribute=\(hex(handle))")
        case 0x0c where pdu.count >= 5:
            return Summary(protocolName: "ATT", text: annotated(attribute) + " offset=\(word(pdu, 3))")
        case 0x0d:
            guard let handle = database.readHandle else { break }
            database.readHandle = nil
            guard var long = database.longRead, long.handle == handle else {
                return Summary(protocolName: "ATT", text: annotated(handle) + " attribute=\(hex(handle))")
            }
            let part = pdu[1...]
            long.value += part.prefix(Limits.longValueBytes - long.value.count)
            if part.count >= connection.mtu - 1, long.value.count < Limits.longValueBytes {
                database.longRead = long
                return Summary(protocolName: "ATT", text: annotated(handle) + " attribute=\(hex(handle)) \(long.value.count) bytes so far")
            }
            database.longRead = nil
            if server == .device { Self.note(long.value, uuid: database.uuids[handle], connection: &connection) }
            if let row = app(handle, long.value, verb: "read", incoming: incoming, server: server,
                             database: database, connection: connection) {
                return row
            }
            return Summary(protocolName: "ATT", text: annotated(handle) + " attribute=\(hex(handle)) \(long.value.count) bytes")
        case 0x16 where pdu.count >= 5:
            let handle = word(pdu, 1)
            let offset = word(pdu, 3)
            let value = Array(pdu[5...])
            let queued = database.prepared.reduce(0) { $0 + $1.value.count }
            if database.prepared.count < Limits.preparedWrites, queued + value.count <= Limits.longValueBytes * 2 {
                database.prepared.append((handle, offset, value))
            }
            return Summary(protocolName: "ATT", text: annotated(handle) + " offset=\(offset) queued \(queued + value.count) bytes")
        case 0x18 where pdu.count >= 2:
            let segments = database.prepared
            database.prepared = []
            guard pdu[1] == 0x01, let handle = segments.first?.handle else {
                return Summary(protocolName: "ATT", text: text + (pdu[1] == 0 ? " cancel" : ""))
            }
            guard segments.allSatisfy({ $0.handle == handle }) else {
                return Summary(protocolName: "ATT", text: text + " \(Set(segments.map(\.handle)).count) attributes")
            }
            // Segments carry their own offsets; lay them out rather than trusting arrival order.
            var value: [UInt8] = []
            for segment in segments.sorted(by: { $0.offset < $1.offset }) where segment.offset <= value.count {
                let end = min(segment.offset + segment.value.count, Limits.longValueBytes)
                guard end > segment.offset else { continue }
                if value.count < end { value += [UInt8](repeating: 0, count: end - value.count) }
                value.replaceSubrange(segment.offset..<end, with: segment.value.prefix(end - segment.offset))
            }
            if let row = app(handle, value, verb: "long write", incoming: incoming, server: server,
                             database: database, connection: connection) {
                return row
            }
            return Summary(protocolName: "ATT", text: annotated(handle) + " attribute=\(hex(handle)) \(value.count) bytes")
        default:
            if let attribute, let value = Self.value(opcode: opcode, pdu: pdu),
               let row = app(attribute, value, verb: Self.verbs[opcode] ?? "value", incoming: incoming,
                             server: server, database: database, connection: connection) {
                return row
            }
        }
        return Summary(protocolName: "ATT", text: annotated(attribute))
    }

    /// The app row for a value, when the definitions describe this attribute in this database.
    private mutating func app(
        _ attribute: Int, _ value: [UInt8], verb: String, incoming: Bool,
        server: BluetoothGATTServer, database: Database, connection: Connection
    ) -> Summary? {
        guard let definitions,
              let characteristic = definitions.characteristic(handle: attribute, uuid: database.uuids[attribute], server: server),
              let type = incoming ? characteristic.received : characteristic.sent else { return nil }
        let enums = definitions.learnedEnumNames
        if incoming, !enums.isEmpty {
            // Learn first, so the page that teaches a name is already shown with it.
            let known = learned.tables(for: connection.identity, enums: enums)
            for lesson in definitions.lessons(from: characteristic.name, value: value, known: known)
            where learned.learn(
                lesson.entries, enumName: lesson.enumName, identity: connection.identity ?? "unidentified",
                name: connection.deviceName, firmware: connection.firmware,
                limit: BluetoothPacketDefinitions.Limits.enumCases
            ) {
                learnedRevision += 1
            }
        }
        let tables = enums.isEmpty ? [:] : learned.tables(for: connection.identity, enums: enums)
        let decoded = definitions.decode(value, as: type, learned: tables)
        let peer = connection.deviceName
            ?? connection.address.flatMap { advertisedNames[$0] }
            ?? characteristic.service
            ?? connection.address
            ?? "peripheral"
        let route = incoming ? "\(peer) → \(Self.localName)" : "\(Self.localName) → \(peer)"
        var text = "\(route) · \(characteristic.name) \(verb) · \(decoded.text)"
        if let problem = decoded.problem { text += " ⚠ \(problem)" }
        return Summary(protocolName: Self.appProtocolName, text: text, warning: decoded.problem != nil, preview: value)
    }

    /// Remember what discovery and reads reveal about one database.
    private func learn(
        opcode: UInt8, pdu: [UInt8], server: BluetoothGATTServer,
        database: inout Database, connection: inout Connection
    ) {
        switch opcode {
        case 0x08 where pdu.count >= 7:
            // Read By Type Request: start, end, then the attribute type being enumerated.
            database.readByTypeUUID = BluetoothUUID.canonical(wire: pdu[5...])
        case 0x09 where pdu.count >= 2 && database.readByTypeUUID == "2803":
            // Characteristic declarations: handle(2) properties(1) value handle(2) UUID(2|16).
            let length = Int(pdu[1])
            guard length == 7 || length == 21 else { return }
            var index = 2
            while index + length <= pdu.count, database.uuids.count < Limits.handlesPerDatabase {
                let valueHandle = word(pdu, index + 3)
                if let uuid = BluetoothUUID.canonical(wire: pdu[(index + 5)..<(index + length)]) {
                    database.uuids[valueHandle] = uuid
                }
                index += length
            }
        case 0x09 where pdu.count >= 4 && database.readByTypeUUID == Self.deviceNameUUID && server == .device:
            // iOS reads the device's name by type: length, then handle(2) and the value. The
            // phone's own Device Name is the phone, not the peer.
            let length = Int(pdu[1])
            guard length > 2, 2 + length <= pdu.count else { return }
            connection.deviceName = Self.name(pdu[4..<(2 + length)]) ?? connection.deviceName
        case 0x0a where pdu.count >= 3:
            database.readHandle = word(pdu, 1)
            database.longRead = nil
        case 0x0c where pdu.count >= 3:
            database.readHandle = word(pdu, 1)
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
        default:
            return nil
        }
    }

    #if DEBUG
    /// The value handle discovery taught for a UUID, for replaying captures in tests.
    func handleForTesting(uuid: String, connection: Int, server: BluetoothGATTServer = .device) -> Int? {
        connections[connection]?.databases[server]?.uuids.first { $0.value == uuid }?.key
    }
    #endif

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
    private static let firmwareRevisionUUID = "2A26"

    /// What a completed read of the device's own database says about the device itself.
    private static func note(_ value: [UInt8], uuid: String?, connection: inout Connection) {
        switch uuid {
        case deviceNameUUID?: connection.deviceName = name(value[...]) ?? connection.deviceName
        case firmwareRevisionUUID?: connection.firmware = name(value[...]) ?? connection.firmware
        default: break
        }
    }

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
