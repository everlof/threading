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
        /// Other characteristics' last values kept per connection, for contextual switches.
        static let contextValues = 256
        /// Flow rows waiting for the decoder to collect them.
        static let pendingRows = 256
    }

    /// What a row whose bytes did not fit their definition says before the reason.
    static let problemMarker = " ⚠ "

    private static let unnamedPeer = "peripheral"

    /// The capturing iPhone's side of every row; the capture is always taken on the phone.
    static let localName = "iPhone"

    /// The subsystem of a row decoded by the app's definitions; the pane filters on it exactly.
    static let appProtocolName = "App"
    /// The subsystem of the link's own events: connection, parameters, encryption, disconnection.
    static let linkProtocolName = "Link"
    private static let clientConfigurationUUID = "2902"

    /// The application's definitions, replaced when the file changes. `nil` means protocol-only.
    var definitions: BluetoothPacketDefinitions?
    /// The capture time of the packet being read, in seconds; set by the decoder per packet.
    var time: Double = 0
    /// Rows transactions and streams added since the decoder last collected them.
    private var flowRows: [BluetoothFlowState.Row] = []

    /// What one GATT server's attribute database has revealed.
    private struct Database {
        /// What discovery in *this* capture revealed; it wins over anything remembered.
        var live = BluetoothGATTTable()
        var readByTypeUUID: String?
        var groupTypeUUID: String?
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

        /// The remembered table this connection uses, and how it was chosen.
        var gattChoice: String?
        /// Tables still consistent with the traffic, when the connection started before the capture.
        var gattCandidates: [String]?
        var gattAssumed = false
        var gattRejected = false
        /// A key for a device seen with neither a connection event nor a name.
        var mintedIdentity: String?
        /// Transactions waiting for answers and streams being joined.
        var flows = BluetoothFlowState()
        /// `Characteristic.field` → the last number decoded there, for contextual switches.
        var context: [String: BluetoothValue] = [:]
        /// Per database, a characteristic's value handle → what its CCCD was last set to.
        var subscriptions: [BluetoothGATTServer: [Int: UInt16]] = [:]
        /// The role this connection plays for a device that came back as something else
        /// (`bootloader`), the device's key, and its name, from an `identities:` rule.
        var role: String?
        var family: String?
        var familyName: String?

        /// Who taught a learned enum: the address when the connection was seen, else the name.
        var identity: String? { address ?? deviceName.map { "name:\($0)" } }
    }

    /// Remembered GATT tables, per device; loaded and saved by the capture worker.
    var gatt = BluetoothGATTTables()
    private(set) var gattRevision = 0
    /// The capturing phone, whose own table is the same for every peer.
    var phoneIdentity: String?
    /// One line for the footer about the connection most recently seen.
    private(set) var gattSummary: String?
    /// `handle:` pins that disagree with a known table: file line → handle.
    private var pinConflicts: [Int: Int] = [:]
    private var phoneKey: String { "phone:" + (phoneIdentity ?? Self.localName) }

    /// Enum entries devices taught, kept across captures by the capture worker.
    var learned = BluetoothLearnedEnums()
    /// Bumped whenever `learned` gains something, so the worker knows to save.
    private(set) var learnedRevision = 0
    /// The device and build most recently identified, for the footer's learned-enum line.
    private(set) var learnedFirmware: (identity: String?, firmware: String?) = (nil, nil)

    /// Procedures in progress and what earlier ones recorded; the history is loaded and saved
    /// by the capture worker.
    var procedures = BluetoothProcedureState()

    /// A device expected to come back under another identity.
    private struct IdentityWatch {
        let rule: BluetoothPacketDefinitions.IdentityRule
        let family: String
        let name: String
        let address: String?
        let deadline: Double
    }
    private var identityWatches: [IdentityWatch] = []
    /// Service UUIDs each address advertised, for `identities:` that recognise a successor by them.
    private var advertisedServices: [String: Set<String>] = [:]

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
        /// The level the app's definitions give the value, when they give one.
        var level: BluetoothSeverity?
        /// For `logs:` rules: what this packet is, encoded (`BluetoothLogLink.PacketLink`).
        var link: String?
        /// Replaces the packet bytes in the row's preview, when the meaningful bytes are an app
        /// value rather than the packet that happened to complete it.
        var preview: [UInt8]?
    }

    /// `incoming` is the capture's direction: true when the phone received the packet.
    mutating func acl(_ payload: [UInt8], incoming: Bool) -> Summary {
        advance()
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
        defer {
            connection.databases[server] = database
            summarize(connection)
        }
        learn(opcode: opcode, pdu: pdu, server: server, database: &database, connection: &connection)

        var text = prefix + " ATT " + (Self.attributes[opcode] ?? "opcode=\(hex(Int(opcode)))")
        if server == .phone { text += " (iPhone's database)" }
        var attribute: Int?
        if Self.handleOpcodes.contains(opcode), pdu.count >= 3 {
            attribute = word(pdu, 1)
            text += " attribute=\(hex(word(pdu, 1)))"
        }
        // A connection that began before the capture has no discovery: find the remembered
        // table its traffic fits, packet by packet.
        if server == .device, let attribute, let operation = Self.operation(opcode),
           database.live.uuid(for: attribute) == nil {
            fit(&connection, handle: attribute, operation: operation)
        }
        func uuid(_ handle: Int) -> String? { resolve(handle, server: server, database: database, connection: connection)?.uuid }
        func annotated(_ attribute: Int?) -> String {
            guard let attribute, let found = resolve(attribute, server: server, database: database, connection: connection) else {
                return text
            }
            return text + " uuid=\(found.uuid)" + (found.remembered ? " (remembered)" : "")
        }
        // Service Changed: the device says a range of its table is no longer valid.
        if opcode == 0x1d, let attribute, pdu.count >= 7, uuid(attribute) == Self.serviceChangedUUID {
            let range = word(pdu, 3)...max(word(pdu, 3), word(pdu, 5))
            database.live.drop(range)
            signal(.event(.serviceChanged), connection: connection,
                   text: "Service Changed: handles \(hex(range.lowerBound))–\(hex(range.upperBound)) changed", level: .warning)
            if let key = deviceKey(connection, server: server) {
                gatt.update(key, isPhone: server == .phone) { $0.table.drop(range) }
                gattRevision += 1
            }
        }

        // A CCCD write says whether the characteristic before it may notify or indicate.
        if [0x12, 0x52].contains(opcode), let attribute, pdu.count >= 5, uuid(attribute) == Self.clientConfigurationUUID {
            let target = configuredCharacteristic(attribute, server: server, database: database, connection: connection)
            if connection.subscriptions[server, default: [:]][target] != nil
                || connection.subscriptions[server, default: [:]].count < Limits.handlesPerDatabase {
                connection.subscriptions[server, default: [:]][target] = UInt16(pdu[3]) | UInt16(pdu[4]) << 8
            }
        }
        // …and a value pushed while it says no is worth knowing: the client never asked for it.
        var unrequested: String?
        if [0x1b, 0x1d].contains(opcode), let attribute, let flags = connection.subscriptions[server]?[attribute],
           flags & (opcode == 0x1b ? 0x01 : 0x02) == 0 {
            unrequested = " · \(opcode == 0x1b ? "notified" : "indicated") while its CCCD is off"
        }

        switch opcode {
        case 0x01 where pdu.count >= 5:
            let request = pdu[1]
            let handle = word(pdu, 2)
            // A long value ends in an error when its length was an exact multiple of the MTU.
            if request == 0x0c, let long = database.longRead, long.handle == handle {
                database.longRead = nil
                database.readHandle = nil
                if server == .device { noteDevice(long.value, uuid: uuid(handle), connection: &connection) }
                if let row = app(handle, long.value, verb: "read", incoming: incoming, server: server,
                                 database: database, connection: &connection) {
                    return row
                }
            }
            text += " request=\(hex(Int(request))) attribute=\(hex(handle)) error=\(hex(Int(pdu[4])))"
                + (Self.attErrors[pdu[4]].map { " (\($0))" } ?? "")
            if let definitions, !definitions.transactions.isEmpty,
               let operation: BluetoothPacketDefinitions.Operation = [0x0a, 0x0c].contains(request) ? .read
                    : [0x12, 0x16, 0x18].contains(request) ? .write : nil,
               let characteristic = matched(definitions, handle, server: server, database: database, connection: connection),
               let note = connection.flows.refused(definitions: definitions, characteristic: characteristic.name, operation: operation) {
                text += " " + note
            }
            let refused = definitions.flatMap { matched($0, handle, server: server, database: database, connection: connection) }
            signal(.note, connection: connection, text: "ATT error \(hex(Int(pdu[4]))) refusing "
                + (refused?.name ?? "attribute \(hex(handle))") + (Self.attErrors[pdu[4]].map { ": \($0)" } ?? ""), level: .error)
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
            // A full response may be the first piece of a longer value; the Read Blobs that
            // follow decide. Joined even without definitions: a firmware revision or device name
            // read in pieces must not be remembered as its first piece.
            if value.count >= connection.mtu - 1 {
                database.longRead = (handle, value)
                return Summary(protocolName: "ATT", text: annotated(handle) + " attribute=\(hex(handle)) \(value.count) bytes so far")
            }
            if server == .device { noteDevice(value, uuid: uuid(handle), connection: &connection) }
            if let row = app(handle, value, verb: "read", incoming: incoming, server: server,
                             database: database, connection: &connection) {
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
            if server == .device { noteDevice(long.value, uuid: uuid(handle), connection: &connection) }
            if let row = app(handle, long.value, verb: "read", incoming: incoming, server: server,
                             database: database, connection: &connection) {
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
                             database: database, connection: &connection) {
                return row
            }
            return Summary(protocolName: "ATT", text: annotated(handle) + " attribute=\(hex(handle)) \(value.count) bytes")
        default:
            if let attribute, let value = Self.value(opcode: opcode, pdu: pdu),
               var row = app(attribute, value, verb: Self.verbs[opcode] ?? "value", incoming: incoming,
                             server: server, database: database, connection: &connection) {
                if let unrequested {
                    row = Summary(protocolName: row.protocolName, text: row.text + unrequested, error: row.error,
                                  warning: row.warning, level: max(row.level ?? .warning, .warning), link: row.link,
                                  preview: row.preview)
                }
                return row
            }
            if let unrequested { return Summary(protocolName: "ATT", text: annotated(attribute) + unrequested, warning: true) }
        }
        return Summary(protocolName: "ATT", text: annotated(attribute))
    }

    /// The app row for a value, when the definitions describe this attribute in this database.
    private mutating func app(
        _ attribute: Int, _ value: [UInt8], verb: String, incoming: Bool,
        server: BluetoothGATTServer, database: Database, connection: inout Connection
    ) -> Summary? {
        guard let definitions,
              let characteristic = matched(definitions, attribute, server: server, database: database, connection: connection),
              let type = incoming ? characteristic.received : characteristic.sent else { return nil }
        let enums = definitions.learnedEnumNames
        if incoming, !enums.isEmpty {
            // Learn first, so the page that teaches a name is already shown with it.
            let known = learned.tables(for: connection.identity, firmware: connection.firmware, enums: enums)
            for lesson in definitions.lessons(from: characteristic.name, value: value, known: known)
            where learned.learn(
                lesson.entries, enumName: lesson.enumName, identity: connection.identity ?? "unidentified",
                name: connection.deviceName, firmware: connection.firmware,
                limit: BluetoothPacketDefinitions.Limits.enumCases
            ) {
                learnedRevision += 1
            }
        }
        let tables = enums.isEmpty ? [:] : learned.tables(for: connection.identity, firmware: connection.firmware, enums: enums)
        var decoded = definitions.decode(value, as: type, learned: tables, context: connection.context)
        // `firmware:` names the characteristic whose value identifies the build, when it is not
        // the standard Firmware Revision String.
        if incoming, definitions.firmwareCharacteristic == characteristic.name {
            let text = decoded.values.values.lazy.compactMap { value -> String? in
                if case .text(let text) = value { return text }
                return nil
            }.first ?? decoded.text
            if let firmware = Self.name(Array(text.utf8)[...]) { noteFirmware(firmware, connection: &connection) }
        }
        for (id, found) in decoded.values where !id.contains(".") || decoded.values.count < 32 {
            guard case .number = found else { continue }
            let key = "\(characteristic.name).\(id)"
            if connection.context[key] != nil || connection.context.count < Limits.contextValues { connection.context[key] = found }
        }
        // Flows and procedures may also test another characteristic's last value
        // (`Secure DFU Control Point.type: DATA`), so they see the connection's context too.
        for (key, found) in connection.context where decoded.values[key] == nil { decoded.values[key] = found }
        let peer = label(connection, fallback: (server == .device ? connection.gattChoice.flatMap { gatt[$0]?.name } : nil)
            ?? characteristic.service)
        let route = incoming ? "\(peer) → \(Self.localName)" : "\(Self.localName) → \(peer)"
        var text = "\(route) · \(characteristic.name) \(verb) · \(decoded.text)"
        if let problem = decoded.problem { text += Self.problemMarker + problem }
        if !definitions.transactions.isEmpty || !definitions.streams.isEmpty {
            let words = decoded.wordEnums
            let flows = connection.flows.observe(
                definitions: definitions, characteristic: characteristic.name,
                operation: BluetoothPacketDefinitions.Operation(verb: verb), decoded: decoded,
                incoming: incoming, peer: peer, time: time,
                resolve: { number in
                    for name in words { if let found = tables[name]?[number] ?? definitions.enums[name]?[number] { return found } }
                    return nil
                },
                names: { name, number in tables[name]?[number] ?? definitions.enums[name]?[number] }
            )
            if let note = flows.note { text += " " + note }
            addFlowRows(flows.rows)
            for row in flows.rows { signal(.note, connection: connection, text: row.text, level: row.level) }
        }
        if !definitions.procedures.isEmpty || !definitions.identities.isEmpty {
            let operation = BluetoothPacketDefinitions.Operation(verb: verb)
            let shown = "\(characteristic.name) \(verb) · \(decoded.text)" + (decoded.problem.map { Self.problemMarker + $0 } ?? "")
            let level = decoded.problem != nil ? BluetoothSeverity.warning : decoded.level ?? .info
            let words = decoded.wordEnums
            let resolve: (Int64) -> String? = { number in
                for name in words { if let found = tables[name]?[number] ?? definitions.enums[name]?[number] { return found } }
                return nil
            }
            let names: (String, Int64) -> String? = { name, number in tables[name]?[number] ?? definitions.enums[name]?[number] }
            let kind = BluetoothProcedureState.Signal.Kind.value(characteristic: characteristic.name, operation: operation, decoded: decoded)
            watchForSuccessors(after: kind, connection: connection, text: shown, resolve: resolve, names: names)
            signal(kind, connection: connection, text: shown, level: level, resolve: resolve, names: names)
        }
        let link = definitions.logLinks.isEmpty ? nil : definitions.packetLink(
            characteristic: characteristic.name, operation: BluetoothPacketDefinitions.Operation(verb: verb), values: decoded.values
        )
        return Summary(
            protocolName: Self.appProtocolName, text: text, warning: decoded.problem != nil,
            level: decoded.level, link: link, preview: value
        )
    }

    // MARK: Identities and procedures

    /// The device a connection belongs to, across the identities it comes back as.
    private func family(_ connection: Connection) -> String {
        connection.family ?? connection.identity ?? connection.gattChoice ?? "this capture"
    }

    /// The name rows use: the device's, with the role it is playing (`Kronaby (bootloader)`).
    private func label(_ connection: Connection, fallback: String? = nil) -> String {
        let base = connection.familyName ?? connection.deviceName
            ?? connection.address.flatMap { advertisedNames[$0] } ?? fallback ?? connection.address ?? Self.unnamedPeer
        return connection.role.map { "\(base) (\($0))" } ?? base
    }

    /// Tells the procedures something happened on this connection's device.
    private mutating func signal(
        _ kind: BluetoothProcedureState.Signal.Kind, connection: Connection, text: String, level: BluetoothSeverity,
        resolve: (Int64) -> String? = { _ in nil }, names: (String, Int64) -> String? = { _, _ in nil }
    ) {
        guard let definitions, !definitions.procedures.isEmpty else { return }
        let signal = BluetoothProcedureState.Signal(
            kind: kind, family: family(connection), device: connection.familyName ?? label(connection),
            role: connection.role, text: text, level: level, time: time
        )
        addFlowRows(procedures.observe(signal, definitions: definitions, resolve: resolve, names: names))
    }

    /// An `identities:` rule whose `after:` just happened: the device may come back as that role.
    private mutating func watchForSuccessors(
        after kind: BluetoothProcedureState.Signal.Kind, connection: Connection, text: String,
        resolve: (Int64) -> String? = { _ in nil }, names: (String, Int64) -> String? = { _, _ in nil }
    ) {
        guard let definitions, !definitions.identities.isEmpty else { return }
        let signal = BluetoothProcedureState.Signal(
            kind: kind, family: family(connection), device: label(connection), role: connection.role,
            text: text, level: .info, time: time
        )
        identityWatches.removeAll { $0.deadline < time }
        for rule in definitions.identities where rule.after.fires(on: signal, resolve: resolve, names: names) {
            identityWatches.removeAll { $0.rule.name == rule.name && $0.family == signal.family }
            identityWatches.append(IdentityWatch(
                rule: rule, family: signal.family, name: connection.familyName ?? label(connection),
                address: connection.address, deadline: time + rule.within
            ))
            if identityWatches.count > BluetoothProcedureState.Limits.identityWatches { identityWatches.removeFirst() }
        }
    }

    /// A new connection that is a watched device come back: it joins that device's family.
    private mutating func joinFamily(_ connection: inout Connection) -> IdentityWatch? {
        guard let address = connection.address else { return nil }
        let services = advertisedServices[address] ?? []
        let name = advertisedNames[address]
        guard let index = identityWatches.firstIndex(where: { watch in
            guard watch.deadline >= time else { return false }
            let rule = watch.rule
            switch rule.address {
            case .same: guard watch.address == address else { return false }
            case .plusOne: guard watch.address.map(Self.incremented) == address else { return false }
            case .any: break
            }
            // Advertising identifies it: by a service it lists, or by its name.
            let byService = !services.isDisjoint(with: rule.advertises)
            let byName = rule.advertisedName.map { pattern in name.map { MessagePackPattern.glob(pattern, matches: $0) } ?? false } ?? false
            let hasCriteria = !rule.advertises.isEmpty || rule.advertisedName != nil
            // With any address, advertising is all there is. With an address rule, advertising must
            // agree when the capture saw any — it often starts after the advertisement.
            if rule.address == .any { return hasCriteria && (byService || byName) }
            if hasCriteria, !services.isEmpty || name != nil { return byService || byName }
            return true
        }) else { return nil }
        let watch = identityWatches.remove(at: index)
        connection.role = watch.rule.name
        connection.family = watch.family
        connection.familyName = watch.name
        return watch
    }

    /// Nordic's bootloader adds one to the address's least significant byte, without carry.
    static func incremented(_ address: String) -> String {
        var parts = address.split(separator: ":").map(String.init)
        guard let last = parts.last, let byte = UInt8(last, radix: 16) else { return address }
        parts[parts.count - 1] = String(format: "%02X", byte &+ 1)
        return parts.joined(separator: ":")
    }

    /// Rows transactions and streams added, in order, since the last call.
    mutating func takeFlowRows() -> [BluetoothFlowState.Row] {
        defer { flowRows = [] }
        return flowRows
    }

    private mutating func addFlowRows(_ rows: [BluetoothFlowState.Row]) {
        flowRows += rows.prefix(max(0, Limits.pendingRows - flowRows.count))
    }

    /// What time alone decides, by the next packet of any kind: overdue requests, idle tries.
    private mutating func advance() {
        expireRequests()
        if let definitions, !definitions.procedures.isEmpty {
            addFlowRows(procedures.tick(definitions: definitions, time: time))
        }
    }

    /// Requests whose answer is overdue, on every connection, reported by the next packet.
    private mutating func expireRequests() {
        guard let definitions, !definitions.transactions.isEmpty else { return }
        for handle in order {
            guard var connection = connections[handle] else { continue }
            let rows = connection.flows.expire(definitions: definitions, time: time)
            guard !rows.isEmpty else { continue }
            connections[handle] = connection
            addFlowRows(rows)
            for row in rows { signal(.note, connection: connection, text: row.text, level: row.level) }
        }
    }

    /// Remember what discovery and reads reveal about one database.
    private mutating func learn(
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
            var found: [BluetoothGATTTable.Characteristic] = []
            var index = 2
            while index + length <= pdu.count, found.count < Limits.handlesPerDatabase {
                if let uuid = BluetoothUUID.canonical(wire: pdu[(index + 5)..<(index + length)]) {
                    found.append(.init(declaration: word(pdu, index), value: word(pdu, index + 3),
                                       properties: pdu[index + 2], uuid: uuid))
                }
                index += length
            }
            for characteristic in found { database.live.discover(characteristic) }
            record(server: server, connection: &connection) { table in
                for characteristic in found { table.discover(characteristic) }
            }
        case 0x10 where pdu.count >= 7:
            // Read By Group Type Request: the group type is primary (0x2800) or secondary services.
            database.groupTypeUUID = BluetoothUUID.canonical(wire: pdu[5...])
        case 0x11 where pdu.count >= 2 && ["2800", "2801"].contains(database.groupTypeUUID ?? ""):
            // Service ranges: start(2) end(2) UUID(2|16).
            let length = Int(pdu[1])
            guard length == 6 || length == 20 else { return }
            var found: [BluetoothGATTTable.Service] = []
            var index = 2
            while index + length <= pdu.count, found.count < Limits.handlesPerDatabase {
                if let uuid = BluetoothUUID.canonical(wire: pdu[(index + 4)..<(index + length)]) {
                    found.append(.init(start: word(pdu, index), end: max(word(pdu, index), word(pdu, index + 2)), uuid: uuid))
                }
                index += length
            }
            for service in found { database.live.discover(service: service) }
            record(server: server, connection: &connection) { table in
                for service in found { table.discover(service: service) }
            }
        case 0x05 where pdu.count >= 2:
            // Find Information Response: format 1 is handle + 16-bit UUID, format 2 a 128-bit one.
            let length = pdu[1] == 1 ? 4 : pdu[1] == 2 ? 18 : 0
            guard length > 0 else { return }
            var found: [(Int, String)] = []
            var index = 2
            while index + length <= pdu.count, found.count < Limits.handlesPerDatabase {
                if let uuid = BluetoothUUID.canonical(wire: pdu[(index + 2)..<(index + length)]) {
                    found.append((word(pdu, index), uuid))
                }
                index += length
            }
            for (handle, uuid) in found { database.live.discover(descriptor: handle, uuid: uuid) }
            record(server: server, connection: &connection) { table in
                for (handle, uuid) in found { table.discover(descriptor: handle, uuid: uuid) }
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
        guard let state = connections[connection] else { return nil }
        if let live = state.databases[server]?.live.characteristics.values.first(where: { $0.uuid == uuid }) { return live.value }
        let key = server == .phone ? phoneKey : state.gattChoice
        return key.flatMap { gatt[$0]?.table.characteristics.values.first { $0.uuid == uuid }?.value }
    }
    #endif

    // MARK: HCI events

    /// What an HCI event says, in words, when the session can say more than the event's number.
    struct EventSummary: Equatable {
        let text: String
        var error = false
        var warning = false
    }

    /// Learns names and addresses from HCI events: advertising reports carry a device's local
    /// name, a connection complete ties its address to a connection handle, and a disconnection
    /// ends that handle's state so a reused handle does not inherit another device's name.
    ///
    /// It also reads the link's health aloud — connection parameters, data length, PHY,
    /// encryption, why a link ended — naming the device where the capture knows it. These are
    /// the facts that explain a slow transfer or a dropped watch, and no app definition is needed.
    @discardableResult
    mutating func event(_ payload: [UInt8]) -> EventSummary? {
        advance()
        guard payload.count >= 3, Int(payload[1]) == payload.count - 2 else { return nil }
        switch payload[0] {
        case 0x05 where payload.count >= 6:
            let handle = word(payload, 3) & 0x0fff
            let who = peerName(handle)
            let reason = payload[5]
            let name = Self.disconnectReasons[reason] ?? "reason \(hex(Int(reason)))"
            let summary = EventSummary(
                text: "Disconnected \(who): \(name)", error: payload[2] != 0,
                warning: !Self.ordinaryDisconnects.contains(reason)
            )
            if let connection = connections[handle] {
                let level: BluetoothSeverity = summary.error ? .error : summary.warning ? .warning : .info
                watchForSuccessors(after: .event(.disconnected), connection: connection, text: summary.text)
                signal(.event(.disconnected), connection: connection, text: summary.text, level: level)
            }
            if payload[2] == 0 { forget(handle) }
            return summary
        case 0x08 where payload.count >= 6:
            let handle = word(payload, 3) & 0x0fff
            let status = payload[2]
            guard status == 0 else {
                // PIN or Key Missing right after a reboot is the classic lost bond.
                let summary = EventSummary(text: "Encryption failed \(peerName(handle)): \(Self.disconnectReasons[status] ?? hex(Int(status)))"
                    + (status == 0x06 ? " — the phone's bond no longer matches the device's keys" : ""), error: true)
                if let connection = connections[handle] {
                    signal(.event(.encryptionFailed), connection: connection, text: summary.text, level: .error)
                }
                return summary
            }
            return note(EventSummary(text: "Encryption \(payload[5] == 0 ? "off" : "on") \(peerName(handle))"), handle)
        case 0x30 where payload.count >= 5:
            let handle = word(payload, 3) & 0x0fff
            return note(EventSummary(text: "Encryption key refreshed \(peerName(handle))", error: payload[2] != 0), handle)
        case 0x3e:
            switch payload[2] {
            case 0x01, 0x0a, 0x29:
                // Status, handle(2), role, peer address type, peer address(6), [local and peer
                // RPAs (12) in the enhanced forms], interval(2), latency(2), timeout(2).
                guard payload.count >= 14 else { return nil }
                guard payload[3] == 0 else {
                    let status = payload[3]
                    return EventSummary(text: "Connection failed: \(Self.disconnectReasons[status] ?? hex(Int(status)))", error: true)
                }
                let handle = word(payload, 4) & 0x0fff
                forget(handle)
                var connection = Connection()
                connection.address = Self.address(payload[8..<14])
                let joined = joinFamily(&connection)
                store(connection, for: handle)
                let parameters = payload[2] == 0x01 ? 14 : 26
                var text = "Connected \(peerName(handle)) · \(Self.localName) is \(payload[6] == 0 ? "central" : "peripheral")"
                if let joined, let address = connection.address {
                    text += " · the same device at \(address)"
                    if let previous = joined.address, previous != address { text += " (was \(previous))" }
                }
                if payload.count >= parameters + 6 { text += " · " + Self.parameters(payload, at: parameters) }
                signal(.event(.connected), connection: connection, text: text, level: .info)
                return EventSummary(text: text)
            case 0x03 where payload.count >= 12:
                let handle = word(payload, 4) & 0x0fff
                guard payload[3] == 0 else {
                    return EventSummary(text: "Connection update failed \(peerName(handle)): \(hex(Int(payload[3])))", error: true)
                }
                return note(EventSummary(text: "Connection parameters \(peerName(handle)) · " + Self.parameters(payload, at: 6)), handle)
            case 0x07 where payload.count >= 13:
                let handle = word(payload, 3) & 0x0fff
                return note(EventSummary(text: "Data length \(peerName(handle)) · tx \(word(payload, 5)) B / \(word(payload, 7)) µs"
                    + " · rx \(word(payload, 9)) B / \(word(payload, 11)) µs"), handle)
            case 0x0c where payload.count >= 8:
                let handle = word(payload, 4) & 0x0fff
                guard payload[3] == 0 else {
                    return EventSummary(text: "PHY update failed \(peerName(handle)): \(hex(Int(payload[3])))", error: true)
                }
                return note(EventSummary(text: "PHY \(peerName(handle)) · tx \(Self.phy(payload[6])) · rx \(Self.phy(payload[7]))"), handle)
            case 0x05 where payload.count >= 5:
                return EventSummary(text: "Long-term key requested \(peerName(word(payload, 3) & 0x0fff))")
            case 0x06 where payload.count >= 13:
                let handle = word(payload, 3) & 0x0fff
                let interval = "\(Self.decimal(Double(word(payload, 5)) * 1.25))–\(Self.decimal(Double(word(payload, 7)) * 1.25)) ms"
                return note(EventSummary(text: "\(peerName(handle)) asks for interval \(interval) latency \(word(payload, 9))"
                    + " timeout \(word(payload, 11) * 10) ms"), handle)
            case 0x02:
                // Legacy reports: only a single report has an unambiguous layout.
                guard payload.count >= 13, payload[3] == 1 else { return nil }
                let length = Int(payload[12])
                guard 13 + length <= payload.count else { return nil }
                let rssi = 13 + length < payload.count ? Int(Int8(bitPattern: payload[13 + length])) : nil
                return learnAdvertised(address: Self.address(payload[6..<12]), data: payload[13..<(13 + length)], rssi: rssi)
                    .map { EventSummary(text: $0) }
            case 0x0d:
                // Extended reports: 24 fixed bytes, then the data length and data, per report.
                var index = 4
                var texts: [String] = []
                for _ in 0..<Int(payload[3]) {
                    guard index + 24 <= payload.count else { break }
                    let length = Int(payload[index + 23])
                    guard index + 24 + length <= payload.count else { break }
                    if let text = learnAdvertised(
                        address: Self.address(payload[(index + 3)..<(index + 9)]),
                        data: payload[(index + 24)..<(index + 24 + length)],
                        rssi: Int(Int8(bitPattern: payload[index + 13]))
                    ) {
                        texts.append(text)
                    }
                    index += 24 + length
                }
                return texts.isEmpty ? nil : EventSummary(text: texts.joined(separator: " · "))
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// The best name the capture has for a connection: the device's own (with the role it is
    /// playing), its advertised one, its address, else the handle.
    private func peerName(_ handle: Int) -> String {
        guard let connection = connections[handle] else { return "handle \(hex(handle))" }
        let named = label(connection)
        return named == Self.unnamedPeer ? "handle \(hex(handle))" : named
    }

    /// A link fact goes into the timeline of a procedure running on that device.
    private mutating func note(_ summary: EventSummary, _ handle: Int) -> EventSummary {
        if let connection = connections[handle] {
            signal(.note, connection: connection, text: summary.text,
                   level: summary.error ? .error : summary.warning ? .warning : .info)
        }
        return summary
    }

    /// interval(2) latency(2) timeout(2), in the units HCI uses: 1.25 ms and 10 ms.
    private static func parameters(_ payload: [UInt8], at index: Int) -> String {
        let interval = Int(payload[index]) | Int(payload[index + 1]) << 8
        let latency = Int(payload[index + 2]) | Int(payload[index + 3]) << 8
        let timeout = Int(payload[index + 4]) | Int(payload[index + 5]) << 8
        return "interval \(decimal(Double(interval) * 1.25)) ms latency \(latency) timeout \(timeout * 10) ms"
    }

    private static func decimal(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static func phy(_ value: UInt8) -> String {
        switch value { case 1: "1M"; case 2: "2M"; case 3: "Coded"; default: "PHY \(value)" }
    }

    /// Core Specification Vol 1 Part F, the reasons a capture most often shows.
    private static let disconnectReasons: [UInt8: String] = [
        0x02: "Unknown Connection Identifier", 0x05: "Authentication Failure", 0x06: "PIN or Key Missing",
        0x07: "Memory Capacity Exceeded", 0x08: "Connection Timeout", 0x0c: "Command Disallowed",
        0x12: "Invalid HCI Command Parameters",
        0x13: "Remote User Terminated", 0x14: "Remote Low Resources", 0x15: "Remote Power Off",
        0x16: "Local Host Terminated", 0x1a: "Unsupported Remote Feature", 0x1f: "Unspecified Error",
        0x22: "LL Response Timeout", 0x23: "LL Procedure Collision", 0x28: "Instant Passed",
        0x2a: "Different Transaction Collision", 0x3b: "Unacceptable Connection Parameters",
        0x3c: "Advertising Timeout", 0x3d: "MIC Failure", 0x3e: "Failed to Establish",
    ]
    /// Ends somebody chose; everything else is worth a second look.
    private static let ordinaryDisconnects: Set<UInt8> = [0x13, 0x15, 0x16]

    /// Learns the advertised name and reads manufacturer data the definitions describe; returns
    /// the row's text when there is something to say.
    private mutating func learnAdvertised(address: String, data: ArraySlice<UInt8>, rssi: Int? = nil) -> String? {
        // AD structures: length, type, value. 0x09 is the complete local name, 0x08 a shortened one,
        // 0xFF manufacturer data (company identifier first, little-endian).
        var index = data.startIndex
        var complete: String?
        var shortened: String?
        var manufacturer: String?
        while index < data.endIndex {
            let length = Int(data[index])
            guard length > 0, index + 1 + length <= data.endIndex else { break }
            let type = data[index + 1]
            let value = data[(index + 2)..<(index + 1 + length)]
            switch type {
            case 0x09: complete = Self.name(value) ?? complete
            case 0x08: shortened = Self.name(value) ?? shortened
            case 0x02, 0x03, 0x06, 0x07:
                // Lists of 16-bit or 128-bit service UUIDs.
                let width = type <= 0x03 ? 2 : 16
                var start = value.startIndex
                var found = advertisedServices[address] ?? []
                while start + width <= value.endIndex {
                    if let uuid = BluetoothUUID.canonical(wire: value[start..<(start + width)]) { found.insert(uuid) }
                    start += width
                }
                if !found.isEmpty, advertisedServices[address] != nil || advertisedServices.count < Limits.advertisedNames {
                    advertisedServices[address] = found
                }
            case 0xff where value.count >= 2:
                let company = Int(value[value.startIndex]) | Int(value[value.startIndex + 1]) << 8
                if let entry = definitions?.advertising.first(where: { $0.company == company }) {
                    let decoded = definitions!.decode(Array(value.dropFirst(2)), as: entry.message)
                    manufacturer = "\(entry.name) \(decoded.text)" + (decoded.problem.map { Self.problemMarker + $0 } ?? "")
                }
            default:
                break
            }
            index += 1 + length
        }
        if let name = complete ?? shortened { remember(name, for: address) }
        guard manufacturer != nil || complete != nil || shortened != nil else { return nil }
        var text = "Advertising \(address)"
        if let name = complete ?? shortened { text += " \"\(name)\"" }
        if let rssi { text += " \(rssi) dBm" }
        if let manufacturer { text += " · \(manufacturer)" }
        return text
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
    private static let serviceChangedUUID = "2A05"
    private static let databaseHashUUID = "2B2A"

    /// The device's build, from the Firmware Revision String or the `firmware:` characteristic.
    private mutating func noteFirmware(_ firmware: String, connection: inout Connection) {
        if definitions?.procedures.isEmpty == false {
            let changed = procedures.noteFirmware(firmware, family: family(connection))
            signal(changed ? .event(.firmwareChanged) : .note, connection: connection,
                   text: (changed ? "firmware changed to " : "firmware ") + firmware, level: .info)
        }
        connection.firmware = firmware
        learnedFirmware = (connection.identity, firmware)
        if let identity = connection.identity, learned.adopt(identity: identity, firmware: firmware) { learnedRevision += 1 }
        guard let key = deviceKey(connection, server: .device) else { return }
        // Firmware updates often keep the layout, so a new firmware marks the table stale
        // rather than dropping it; traffic that disagrees rejects it soon enough.
        gatt.update(key) { device in
            if let known = device.firmware, known != firmware, !device.table.isEmpty { device.stale = true }
            device.firmware = firmware
        }
        gattRevision += 1
    }

    /// What a completed read of the device's own database says about the device itself, and
    /// what it means for the device's remembered table.
    private mutating func noteDevice(_ value: [UInt8], uuid: String?, connection: inout Connection) {
        switch uuid {
        case Self.deviceNameUUID?:
            connection.deviceName = Self.name(value[...]) ?? connection.deviceName
        case Self.firmwareRevisionUUID? where definitions?.firmwareCharacteristic == nil:
            guard let firmware = Self.name(value[...]) else { return }
            noteFirmware(firmware, connection: &connection)
        case Self.databaseHashUUID? where value.count == 16:
            let hash = value.map { String(format: "%02x", $0) }.joined()
            guard let key = deviceKey(connection, server: .device) else { return }
            gatt.update(key) { device in
                // A different hash is a different table.
                if let known = device.databaseHash, known != hash { device.table = BluetoothGATTTable(); device.stale = false }
                device.databaseHash = hash
            }
            gattRevision += 1
        default:
            break
        }
    }

    // MARK: Remembered tables

    /// The UUID of a handle: discovered in this capture first, then remembered for this device.
    private func resolve(
        _ handle: Int, server: BluetoothGATTServer, database: Database, connection: Connection
    ) -> (uuid: String, remembered: Bool)? {
        if let uuid = database.live.uuid(for: handle) { return (uuid, false) }
        let key = server == .phone ? phoneKey : (connection.gattRejected ? nil : connection.gattChoice)
        guard let key, let uuid = gatt[key]?.table.uuid(for: handle) else { return nil }
        return (uuid, true)
    }

    /// The characteristic a CCCD configures: the nearest value handle below it in the known table,
    /// else the handle just before it, where nearly every server puts it.
    private func configuredCharacteristic(
        _ descriptor: Int, server: BluetoothGATTServer, database: Database, connection: Connection
    ) -> Int {
        let key = server == .phone ? phoneKey : connection.gattChoice
        let tables = [database.live, key.flatMap { gatt[$0]?.table }].compactMap { $0 }
        for table in tables {
            if let value = table.characteristics.keys.filter({ $0 < descriptor }).max() { return value }
        }
        return descriptor - 1
    }

    /// The definition for a handle. A known table decides by UUID; a `handle:` pin only fills in
    /// when no table knows the handle, and one that disagrees with a table is the stale one.
    private mutating func matched(
        _ definitions: BluetoothPacketDefinitions, _ handle: Int, server: BluetoothGATTServer,
        database: Database, connection: Connection
    ) -> BluetoothPacketDefinitions.Characteristic? {
        let known = resolve(handle, server: server, database: database, connection: connection)?.uuid
        if let known, let pin = definitions.pin(handle: handle, server: server), let pinned = pin.uuid, pinned != known {
            pinConflicts[pin.line] = handle
        }
        return definitions.characteristic(handle: handle, uuid: known, server: server)
    }

    /// Where a database's discovery is remembered: the phone's under the phone, a device's under
    /// its identity, else the table the connection already uses, else a key minted for it.
    private func deviceKey(_ connection: Connection, server: BluetoothGATTServer) -> String? {
        server == .phone ? phoneKey : connection.identity ?? connection.gattChoice ?? connection.mintedIdentity
    }

    private mutating func record(
        server: BluetoothGATTServer, connection: inout Connection, _ change: (inout BluetoothGATTTable) -> Void
    ) {
        if server == .device, deviceKey(connection, server: .device) == nil {
            connection.mintedIdentity = "unidentified " + ISO8601DateFormatter().string(from: Date())
        }
        guard let key = deviceKey(connection, server: server) else { return }
        let name = server == .device ? connection.deviceName : Self.localName
        let firmware = server == .device ? connection.firmware : nil
        gatt.update(key, isPhone: server == .phone) { device in
            change(&device.table)
            if let name { device.name = name }
            if let firmware { device.firmware = firmware }
        }
        if server == .device {
            procedures.noteDiscovery(family: family(connection))
            // This connection is this device now; nothing left to guess.
            connection.gattChoice = key
            connection.gattCandidates = [key]
            connection.gattAssumed = false
            connection.gattRejected = false
        }
        gattRevision += 1
    }

    /// Narrows the remembered tables a connection could be using to those that allow what it just
    /// did. With an identity from the connection event only that device's table is considered.
    private func fit(_ connection: inout Connection, handle: Int, operation: BluetoothGATTTable.Operation) {
        guard !connection.gattRejected else { return }
        if connection.gattCandidates == nil {
            if let identity = connection.identity {
                connection.gattCandidates = gatt[identity]?.table.isEmpty == false ? [identity] : []
            } else {
                connection.gattCandidates = gatt.peripheralIdentities
            }
        }
        let candidates = (connection.gattCandidates ?? []).filter { gatt[$0]?.table.fits(handle, operation) == true }
        connection.gattCandidates = candidates
        guard let first = candidates.first else {
            connection.gattChoice = nil
            connection.gattRejected = true
            return
        }
        connection.gattChoice = first
        connection.gattAssumed = connection.identity == nil && candidates.count > 1
    }

    private static func operation(_ opcode: UInt8) -> BluetoothGATTTable.Operation? {
        switch opcode {
        case 0x0a, 0x0c: return .read
        case 0x12, 0x16: return .write
        case 0x52: return .writeWithoutResponse
        case 0xd2: return .signedWrite
        case 0x1b: return .notify
        case 0x1d: return .indicate
        default: return nil
        }
    }

    /// The footer's line about the connection just seen.
    private mutating func summarize(_ connection: Connection) {
        var parts: [String] = []
        let live = connection.databases[.device]?.live.characteristics.count ?? 0
        if connection.gattRejected {
            parts.append("GATT: no remembered table fits this connection")
        } else if live > 0 {
            let who = connection.deviceName ?? connection.address ?? "device"
            parts.append("GATT: \(who) discovered in this capture · \(live) characteristics")
        } else if let key = connection.gattChoice, let device = gatt[key] {
            var line = "GATT: \(device.name ?? key)"
            if let firmware = device.firmware { line += " (fw \(firmware))" }
            line += " remembered \(Self.dateFormatter.string(from: device.updated))"
            line += " · \(device.table.characteristics.count) characteristics"
            if connection.gattAssumed { line += " · assumed" }
            if device.stale { line += " · stale (firmware changed)" }
            parts.append(line)
        }
        for (line, handle) in pinConflicts.sorted(by: { $0.key < $1.key }).prefix(3) {
            parts.append("handle: \(hex(handle)) on line \(line) disagrees with the device's table")
        }
        if !parts.isEmpty { gattSummary = parts.joined(separator: " · ") }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()

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

    /// Core Specification Vol 3 Part F 3.4.1.1; 0x80–0x9F are the application's own.
    static let attErrors: [UInt8: String] = [
        0x01: "Invalid Handle", 0x02: "Read Not Permitted", 0x03: "Write Not Permitted", 0x04: "Invalid PDU",
        0x05: "Insufficient Authentication", 0x06: "Request Not Supported", 0x07: "Invalid Offset",
        0x08: "Insufficient Authorization", 0x09: "Prepare Queue Full", 0x0a: "Attribute Not Found",
        0x0b: "Attribute Not Long", 0x0c: "Insufficient Key Size", 0x0d: "Invalid Attribute Value Length",
        0x0e: "Unlikely Error", 0x0f: "Insufficient Encryption", 0x10: "Unsupported Group Type",
        0x11: "Insufficient Resources", 0x12: "Database Out of Sync", 0x13: "Value Not Allowed",
        0xfc: "Write Request Rejected", 0xfd: "CCCD Improperly Configured", 0xfe: "Procedure Already in Progress",
        0xff: "Out of Range",
    ]

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
