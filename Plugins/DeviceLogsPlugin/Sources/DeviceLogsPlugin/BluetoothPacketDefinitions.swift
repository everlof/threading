import Foundation

/// What an app says its own Bluetooth values mean, compiled from `.threading/bluetooth.yaml`.
///
/// HCI, L2CAP and ATT are the radio's grammar and the decoder reads them itself. The bytes inside
/// an ATT value are the app's own invention, so only the app's author can say what they mean; this
/// is how they say it. The shape borrows Kaitai Struct's vocabulary (a type is a sequence of
/// fields, a field may switch on an earlier one) so it reads familiarly, but it is a small
/// interpreter of our own with every loop bounded — a definition file is untrusted input that runs
/// once per packet on the capture worker.
///
/// The authoring guide lives beside the pane (`BluetoothDefinitionsGuide`) and in
/// `docs/bluetooth-packet-definitions.md`; keep the three in step.
struct BluetoothPacketDefinitions: Sendable {
    enum Limits {
        static let types = 512
        static let fieldsPerType = 256
        static let characteristics = 512
        static let enumCases = 4_096
        /// Nested type instantiations per value. Named types may refer to themselves; this is
        /// what stops a recursive definition from recursing forever.
        static let depth = 16
        /// Field decodes per value, across every nesting and repeat.
        static let steps = 20_000
        static let repeatItems = 4_096
        static let renderedRepeatItems = 16
        static let renderedBytes = 32
        static let renderedCharacters = 1_024
        static let highlights = 256
        static let learners = 16
        static let shapes = 1_024
        /// A learned name longer than this is not a name.
        static let learnedNameCharacters = 64
        /// Named values one decode leaves behind for rules and later packets.
        static let values = 128
        static let bitFields = 32
        /// Transactions, and streams, per file.
        static let flows = 64
        static let conditions = 16
        static let patterns = 8
    }

    /// A shape's last position when the group repeats.
    static let repeatGroup = "..."

    /// Where a project keeps its definitions, relative to the session's checkout, in lookup order.
    static let relativePaths = [".threading/bluetooth.yaml", ".threading/bluetooth.yml"]

    struct Characteristic: Sendable {
        let name: String
        /// The enclosing service's `name:`, the last fallback for naming the peer in a row.
        var service: String? = nil
        /// Whose attribute database the characteristic lives in. Both ends of an LE link can be
        /// GATT servers with separate handle spaces; nil matches a UUID in either, and a
        /// `handle:` pin then means the device's.
        var server: BluetoothGATTServer? = nil
        /// Where the characteristic is written in the file, so a stale pin can be named.
        var line = 0
        /// Canonical: four upper-case hex digits for a Bluetooth SIG UUID, otherwise the dashed
        /// 128-bit form. See `BluetoothUUID`.
        let uuid: String?
        let handle: Int?
        let received: TypeRef?
        let sent: TypeRef?
    }

    indirect enum TypeRef: Sendable {
        case primitive(Primitive)
        case named(String)
        case structure(StructType)
        case switchOn(Switch)
    }

    enum Primitive: Sendable, Equatable {
        case integer(bytes: Int, signed: Bool, bigEndian: Bool)
        case float(bytes: Int, bigEndian: Bool)
        case bool
        case bytes
        case string
        /// One MessagePack value; an `enum:` on the field names its integer map keys.
        case msgpack
    }

    struct StructType: Sendable {
        let fields: [Field]
        let summary: [SummaryPart]?
    }

    enum SummaryPart: Sendable, Equatable {
        case text(String)
        case field(String)
    }

    struct Field: Sendable {
        let id: String
        let type: TypeRef
        let enumName: String?
        let scale: Double?
        let unit: String?
        let flags: [(name: String, bit: Int)]
        let size: Size?
        let repetition: Repetition?
        let hidden: Bool
        /// msgpack only: the first rule whose pattern fits renders the value.
        var match: [MatchRule] = []
        /// msgpack only: which enum names each pattern capture (`enum: { cmd: AnimaCommand }`).
        var captureEnums: [String: String] = [:]
        /// msgpack only: a `shapes:` set naming array positions, keyed by the bound enum name.
        var values: String? = nil
        /// Integer only: named bit ranges inside the value (`bits: { command: 0-7, token: 8-15 }`).
        var bits: [BitField] = []
        /// `if:` — the field is present only when this holds for earlier fields.
        var condition: Condition? = nil
    }

    /// `token: { bits: 8-15, enum: Token }` — bits `low...high` of an integer, counted from 0.
    struct BitField: Sendable, Equatable {
        let name: String
        let low: Int
        let high: Int
        let enumName: String?

        func extract(_ number: Int64) -> Int64 {
            let width = high - low + 1
            let shifted = UInt64(bitPattern: number) >> UInt64(low)
            return Int64(bitPattern: width >= 64 ? shifted : shifted & ((1 << UInt64(width)) - 1))
        }
    }

    /// `if: flag`, `if: "!flag"`, `if: "op == START"` — over earlier fields of the same type.
    struct Condition: Sendable, Equatable {
        enum Subject: Sendable, Equatable {
            /// A named bit of an earlier `flags:` field.
            case flag(field: String, bit: Int)
            /// An earlier integer field (or a `bits:` part, as `field.part`).
            case field(String)
        }
        let subject: Subject
        /// nil tests the subject for non-zero.
        let equals: CaseKey?
        let negated: Bool
    }

    /// `- { pattern: "{ $cmd: $value }", summary: "{cmd} {value}" }`
    struct MatchRule: Sendable {
        let pattern: MessagePackPattern
        let summary: [SummaryPart]?
        /// The row's level when this rule renders it, unless an enum entry it names says otherwise.
        var level: BluetoothSeverity? = nil
    }

    /// `learn:` under an enum: the device teaches number → name entries in its own traffic.
    struct Learner: Sendable {
        let enumName: String
        /// The characteristic whose received values carry the table.
        let from: String
        /// Binds `$number` and `$name` once per entry.
        let pattern: MessagePackPattern
        /// The enum that names the pattern's words — `map_settings` in a settings table is a
        /// command. Defaults to the enum being learned.
        let names: String
    }

    enum Size: Sendable, Equatable {
        case fixed(Int)
        case field(String)
        case rest
    }

    enum Repetition: Sendable, Equatable {
        case untilEnd
        case count(Int)
        case field(String)
    }

    struct Switch: Sendable {
        let on: String
        let cases: [(key: CaseKey, type: TypeRef)]
        let fallback: TypeRef?
        /// `on` names another characteristic's field, which may not have been seen yet.
        var contextual = false
    }

    enum CaseKey: Sendable, Equatable {
        case number(Int64)
        case name(String)
    }

    let characteristics: [Characteristic]
    let types: [String: StructType]
    let enums: [String: [Int64: String]]
    /// Per enum, a case name → the level a row naming it is shown at (`22: { name: BATTERY_OK,
    /// level: info }`). Keyed by name so it applies to learned entries too.
    var levels: [String: [String: BluetoothSeverity]] = [:]
    /// `highlight:` — a word (an enum or flag name, a field id) and the colour it is drawn in.
    let highlights: [String: BluetoothHighlightColor]
    /// `shapes:` — per set, an enum name → the names of an array value's positions.
    let shapes: [String: [String: [String]]]
    let learners: [Learner]
    var transactions: [Transaction] = []
    var streams: [Stream] = []
    /// `firmware:` — the characteristic whose value names the device's build, when it is not the
    /// standard Firmware Revision String (0x2A26). Learned enums are kept per build.
    var firmwareCharacteristic: String? = nil
    /// `advertising:` — manufacturer data, by Bluetooth SIG company identifier.
    var advertising: [Advertisement] = []
    /// `logs:` — app log lines that describe packets.
    var logLinks: [BluetoothLogLink] = []

    struct Advertisement: Sendable {
        let company: Int
        let name: String
        let message: TypeRef
    }

    private let byHandle: [BluetoothGATTServer: [Int: Int]]
    private let byUUID: [String: Int]

    init(
        characteristics: [Characteristic], types: [String: StructType], enums: [String: [Int64: String]],
        highlights: [String: BluetoothHighlightColor] = [:],
        shapes: [String: [String: [String]]] = [:], learners: [Learner] = []
    ) {
        self.characteristics = characteristics
        self.highlights = highlights
        self.shapes = shapes
        self.learners = learners
        self.types = types
        self.enums = enums
        var byHandle: [BluetoothGATTServer: [Int: Int]] = [:]
        var byUUID: [String: Int] = [:]
        for (index, characteristic) in characteristics.enumerated() {
            if let handle = characteristic.handle { byHandle[characteristic.server ?? .device, default: [:]][handle] = index }
            if let uuid = characteristic.uuid { byUUID[uuid] = index }
        }
        self.byHandle = byHandle
        self.byUUID = byUUID
    }

    /// A known UUID — discovered in this capture or remembered for the device — decides. A
    /// `handle:` pin only fills in when no table knows the handle: pins exist to cover a missing
    /// discovery, and once the device's real table is known a pin that disagrees is the stale one.
    func characteristic(handle: Int, uuid: String?, server: BluetoothGATTServer = .device) -> Characteristic? {
        if let uuid {
            guard let index = byUUID[uuid], characteristics[index].server.map({ $0 == server }) ?? true else { return nil }
            return characteristics[index]
        }
        return pin(handle: handle, server: server)
    }

    /// The characteristic pinned to a handle in one server's database, if any.
    func pin(handle: Int, server: BluetoothGATTServer) -> Characteristic? {
        byHandle[server]?[handle].map { characteristics[$0] }
    }
}

/// One end of an LE link acting as a GATT server. The capture is taken on the phone, so the other
/// end is "the device".
enum BluetoothGATTServer: String, Sendable, Hashable, CaseIterable {
    case device, phone
}

/// A named value one decode left behind: an integer field (with its enum name), a pattern capture,
/// bytes or text. Transactions, streams and later packets refer to values by these names.
enum BluetoothValue: Sendable, Equatable {
    case number(Int64, name: String?)
    case bytes([UInt8])
    case text(String)

    var integer: Int64? {
        if case .number(let number, _) = self { return number }
        return nil
    }

    /// What a key or a `where:` compares: an enum name when there is one, else the number or text.
    var display: String {
        switch self {
        case .number(let number, let name): return name ?? String(number)
        case .bytes(let bytes): return bytes.map { String(format: "%02x", $0) }.joined()
        case .text(let text): return text
        }
    }

    /// Whether `text` (a number or a name) names this value.
    func matches(_ text: String) -> Bool {
        switch self {
        case .number(let number, let name):
            return name == text || BluetoothPacketDefinitions.number(text) == number
        default:
            return display == text
        }
    }
}

/// How loud a row is, as an app's definitions see it: `22: { name: BATTERY_OK, level: info }`.
enum BluetoothSeverity: Int, Sendable, Comparable, CaseIterable {
    case debug, info, warning, error

    init?(name: String) {
        switch name.lowercased() {
        case "debug": self = .debug
        case "info", "ok": self = .info
        case "warning", "warn": self = .warning
        case "error", "fault": self = .error
        default: return nil
        }
    }

    /// The row level the pane understands.
    var level: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension BluetoothPacketDefinitions {
    /// `0x1f`, `0b101`, `1_000` or `-3`, as the file writes numbers.
    static func number(_ text: String) -> Int64? {
        let trimmed = text.replacingOccurrences(of: "_", with: "")
        if trimmed.lowercased().hasPrefix("0x") { return Int64(trimmed.dropFirst(2), radix: 16) }
        if trimmed.lowercased().hasPrefix("0b") { return Int64(trimmed.dropFirst(2), radix: 2) }
        return Int64(trimmed)
    }
}

// MARK: - Compiling

struct BluetoothDefinitionError: Error, Equatable, LocalizedError {
    let line: Int
    let message: String
    var errorDescription: String? { "line \(line): \(message)" }
}

extension BluetoothPacketDefinitions {
    static func compile(_ text: String) throws -> BluetoothPacketDefinitions {
        let root: YAMLNode
        do {
            root = try YAMLSubset.parse(text)
        } catch let error as YAMLError {
            throw BluetoothDefinitionError(line: error.line, message: error.message)
        }
        // Profiles first, so the project's own definitions win wherever both say something.
        var base: BluetoothPacketDefinitions?
        if case .mapping(let entries) = root.value, let include = entries.first(where: { $0.key == "include" }) {
            let names: [(String, Int)]
            switch include.value.value {
            case .sequence(let items):
                names = items.compactMap { item in
                    switch item.value { case .scalar(let text), .quoted(let text): return (text, item.line); default: return nil }
                }
            case .scalar(let text), .quoted(let text):
                names = [(text, include.line)]
            default:
                names = []
            }
            for (name, line) in names {
                guard let text = BluetoothProfiles.text(name) else {
                    throw BluetoothDefinitionError(line: line, message: "include: no profile called \(name) — use \(BluetoothProfiles.names.joined(separator: ", "))")
                }
                let profile: BluetoothPacketDefinitions
                do {
                    profile = try Compiler().compile(try YAMLSubset.parse(text), inherited: base)
                } catch let error as BluetoothDefinitionError {
                    throw BluetoothDefinitionError(line: line, message: "profile \(name), line \(error.line): \(error.message)")
                }
                base = base.map { $0.merging(profile) } ?? profile
            }
        }
        let project = try Compiler().compile(root, inherited: base)
        return base.map { $0.merging(project) } ?? project
    }

    /// `other` laid over this: its characteristics found first by UUID, its names replacing ours.
    func merging(_ other: BluetoothPacketDefinitions) -> BluetoothPacketDefinitions {
        var merged = BluetoothPacketDefinitions(
            characteristics: characteristics + other.characteristics,
            types: types.merging(other.types) { $1 },
            enums: enums.merging(other.enums) { $1 },
            highlights: highlights.merging(other.highlights) { $1 },
            shapes: shapes.merging(other.shapes) { $1 },
            learners: learners + other.learners
        )
        merged.levels = levels.merging(other.levels) { $1 }
        merged.transactions = transactions + other.transactions
        merged.streams = streams + other.streams
        merged.firmwareCharacteristic = other.firmwareCharacteristic ?? firmwareCharacteristic
        merged.advertising = other.advertising + advertising
        merged.logLinks = logLinks + other.logLinks
        return merged
    }
}

private struct Compiler {
    typealias Definitions = BluetoothPacketDefinitions
    typealias Failure = BluetoothDefinitionError

    private static let rootKeys: Set<String> = [
        "version", "services", "types", "enums", "highlight", "shapes", "transactions", "streams",
        "include", "firmware", "logs", "advertising",
    ]
    private static let serviceKeys: Set<String> = ["name", "uuid", "characteristics"]
    private static let characteristicKeys: Set<String> = ["name", "uuid", "handle", "server", "message", "rx", "tx"]
    private static let typeKeys: Set<String> = ["seq", "summary"]
    private static let fieldKeys: Set<String> = [
        "id", "type", "enum", "scale", "unit", "flags", "size", "repeat", "hidden", "doc", "match", "values",
        "bits", "if",
    ]
    private static let switchKeys: Set<String> = ["switch-on", "cases"]

    func compile(_ root: YAMLNode, inherited: Definitions? = nil) throws -> Definitions {
        let entries = try mapping(root, what: "the file")
        try rejectUnknown(entries, allowed: Self.rootKeys, in: "the file")
        if let version = entries.first(where: { $0.key == "version" }) {
            guard scalar(version.value) == "1" else {
                throw Failure(line: version.line, message: "only version: 1 is understood")
            }
        }

        // Inherited names are visible to this file's references; only its own are returned.
        var enums: [String: [Int64: String]] = [:]
        var visibleEnums: [String: [Int64: String]] { (inherited?.enums ?? [:]).merging(enums) { $1 } }
        var levels: [String: [String: BluetoothSeverity]] = [:]
        var pendingLearners: [(enumName: String, entry: YAMLEntry, node: YAMLNode)] = []
        if let node = value("enums", in: entries) {
            for entry in try mapping(node, what: "enums") {
                try checkIdentifier(entry.key, line: entry.line, what: "enum name")
                var cases: [Int64: String] = [:]
                for item in try mapping(entry.value, what: "enum \(entry.key)") {
                    if item.key == "learn" {
                        // One table, or a list of them teaching the same enum (a shared id space).
                        if case .sequence(let tables) = item.value.value {
                            pendingLearners += tables.map { (entry.key, item, $0) }
                        } else {
                            pendingLearners.append((entry.key, item, item.value))
                        }
                        continue
                    }
                    // `22: BATTERY_OK`, `22: { name: BATTERY_OK, level: info }`, or — for a name a
                    // device teaches — `BATTERY_OK: { level: info }`.
                    var name = scalar(item.value)
                    if case .mapping(let details) = item.value.value {
                        try rejectUnknown(details, allowed: ["name", "level"], in: "enum \(entry.key) \(item.key)")
                        name = value("name", in: details).flatMap(scalar)
                        if let text = value("level", in: details).flatMap(scalar) {
                            guard let level = BluetoothSeverity(name: text) else {
                                throw Failure(line: item.line, message: "enum \(entry.key) \(item.key): level is debug, info, warning or error")
                            }
                            levels[entry.key, default: [:]][name ?? item.key] = level
                        }
                    }
                    guard let number = Self.integer(item.key) else {
                        if case .mapping = item.value.value, name == nil { continue }
                        throw Failure(line: item.line, message: "enum \(entry.key): key '\(item.key)' is not a number (write 0x01 or 1)")
                    }
                    guard let name, !name.isEmpty else {
                        throw Failure(line: item.line, message: "enum \(entry.key): \(item.key) needs a name")
                    }
                    cases[number] = name
                }
                guard enums.values.reduce(cases.count, { $0 + $1.count }) <= Definitions.Limits.enumCases else {
                    throw Failure(line: entry.line, message: "more than \(Definitions.Limits.enumCases) enum cases")
                }
                enums[entry.key] = cases
            }
        }

        var shapes: [String: [String: [String]]] = [:]
        if let node = value("shapes", in: entries) {
            var count = 0
            for set in try mapping(node, what: "shapes") {
                try checkIdentifier(set.key, line: set.line, what: "shape set")
                var names: [String: [String]] = [:]
                for shape in try mapping(set.value, what: "shapes \(set.key)") {
                    count += 1
                    guard count <= Definitions.Limits.shapes else {
                        throw Failure(line: shape.line, message: "more than \(Definitions.Limits.shapes) shapes")
                    }
                    let nodes = try sequence(shape.value, what: "shape \(shape.key)")
                    let positions = try nodes.enumerated().map { index, node -> String in
                        guard let name = scalar(node) else {
                            throw Failure(line: node.line, message: "shape \(shape.key): positions are names, as in [year, month, date]")
                        }
                        // A trailing `...` repeats the group: [hours, minutes, bits, ...].
                        if name == Definitions.repeatGroup {
                            guard index == nodes.count - 1, index > 0 else {
                                throw Failure(line: node.line, message: "shape \(shape.key): ... goes last, after the positions it repeats")
                            }
                            return name
                        }
                        try checkIdentifier(name, line: node.line, what: "shape position")
                        return name
                    }
                    names[shape.key] = positions
                }
                shapes[set.key] = names
            }
        }

        // Names first, bodies second, so a type may refer to one declared below it.
        let typeEntries = try value("types", in: entries).map { try mapping($0, what: "types") } ?? []
        guard typeEntries.count <= Definitions.Limits.types else {
            throw Failure(line: typeEntries[Definitions.Limits.types].line, message: "more than \(Definitions.Limits.types) types")
        }
        let typeNames = Set(typeEntries.map(\.key)).union(inherited.map { Set($0.types.keys) } ?? [])
        for entry in typeEntries {
            try checkIdentifier(entry.key, line: entry.line, what: "type name")
            guard Self.primitive(entry.key) == nil else {
                throw Failure(line: entry.line, message: "'\(entry.key)' is a built-in type name; choose another")
            }
        }
        // Characteristic names first too: a switch may read another characteristic's last value.
        var characteristicNames = Set(inherited?.characteristics.map(\.name) ?? [])
        if case .sequence(let services)? = value("services", in: entries)?.value {
            for service in services {
                guard case .mapping(let fields) = service.value,
                      case .sequence(let list)? = value("characteristics", in: fields)?.value else { continue }
                for node in list {
                    if case .mapping(let fields) = node.value, let name = value("name", in: fields).flatMap(scalar) {
                        characteristicNames.insert(name)
                    }
                }
            }
        }
        let context = Context(
            typeNames: typeNames, enums: visibleEnums, shapes: (inherited?.shapes ?? [:]).merging(shapes) { $1 },
            characteristicNames: characteristicNames
        )
        var types: [String: Definitions.StructType] = [:]
        for entry in typeEntries {
            types[entry.key] = try structure(entry.value, context: context, what: "type \(entry.key)")
        }

        var characteristics: [Definitions.Characteristic] = []
        if let node = value("services", in: entries) {
            for service in try sequence(node, what: "services") {
                let fields = try mapping(service, what: "a service")
                try rejectUnknown(fields, allowed: Self.serviceKeys, in: "a service")
                if let uuid = fields.first(where: { $0.key == "uuid" }) {
                    guard scalar(uuid.value).flatMap(BluetoothUUID.canonical) != nil else {
                        throw Failure(line: uuid.line, message: "service uuid is not a Bluetooth UUID")
                    }
                }
                guard let list = value("characteristics", in: fields) else { continue }
                let serviceName = value("name", in: fields).flatMap(scalar)
                for node in try sequence(list, what: "characteristics") {
                    var characteristic = try characteristic(node, context: context)
                    characteristic.service = serviceName
                    characteristics.append(characteristic)
                    guard characteristics.count <= Definitions.Limits.characteristics else {
                        throw Failure(line: node.line, message: "more than \(Definitions.Limits.characteristics) characteristics")
                    }
                }
            }
        }
        var highlights: [String: BluetoothHighlightColor] = [:]
        if let node = value("highlight", in: entries) {
            let items = try mapping(node, what: "highlight")
            guard items.count <= Definitions.Limits.highlights else {
                throw Failure(line: node.line, message: "more than \(Definitions.Limits.highlights) highlight words")
            }
            for item in items {
                try checkIdentifier(item.key, line: item.line, what: "highlight word")
                guard let name = scalar(item.value), let color = BluetoothHighlightColor(rawValue: name) else {
                    throw Failure(line: item.line, message: "highlight \(item.key): unknown colour '\(scalar(item.value) ?? "")' — use "
                        + BluetoothHighlightColor.allCases.map(\.rawValue).joined(separator: ", "))
                }
                highlights[item.key] = color
            }
        }
        guard pendingLearners.count <= Definitions.Limits.learners else {
            throw Failure(line: pendingLearners[Definitions.Limits.learners].entry.line, message: "more than \(Definitions.Limits.learners) learn: blocks")
        }
        let learners = try pendingLearners.map {
            try learner($0.entry, node: $0.node, enumName: $0.enumName,
                        characteristics: characteristics + (inherited?.characteristics ?? []), enumNames: Set(visibleEnums.keys))
        }
        var definitions = Definitions(
            characteristics: characteristics, types: types, enums: enums, highlights: highlights,
            shapes: shapes, learners: learners
        )
        definitions.levels = levels
        let names = Set(characteristics.map(\.name)).union(inherited?.characteristics.map(\.name) ?? [])
        if let node = value("transactions", in: entries) {
            let items = try sequence(node, what: "transactions")
            guard items.count <= Definitions.Limits.flows else {
                throw Failure(line: node.line, message: "more than \(Definitions.Limits.flows) transactions")
            }
            definitions.transactions = try items.map { try transaction($0, characteristics: names) }
        }
        if let node = value("streams", in: entries) {
            let items = try sequence(node, what: "streams")
            guard items.count <= Definitions.Limits.flows else {
                throw Failure(line: node.line, message: "more than \(Definitions.Limits.flows) streams")
            }
            definitions.streams = try items.map { try stream($0, characteristics: names) }
        }
        if let node = value("advertising", in: entries) {
            for item in try sequence(node, what: "advertising") {
                let fields = try mapping(item, what: "an advertising entry")
                try rejectUnknown(fields, allowed: ["company", "name", "message"], in: "an advertising entry")
                guard let company = value("company", in: fields).flatMap(scalar).flatMap(Self.integer), (0...0xffff).contains(company) else {
                    throw Failure(line: item.line, message: "advertising: company is the Bluetooth SIG company identifier, such as 0x004C")
                }
                guard let message = value("message", in: fields) else {
                    throw Failure(line: item.line, message: "advertising: each entry needs message: describing the bytes after the company identifier")
                }
                let name = value("name", in: fields).flatMap(scalar) ?? String(format: "company 0x%04X", company)
                definitions.advertising.append(.init(company: Int(company), name: name,
                                                     message: try typeRef(message, context: context, what: "advertising \(name)")))
            }
            guard definitions.advertising.count <= Definitions.Limits.flows else {
                throw Failure(line: node.line, message: "more than \(Definitions.Limits.flows) advertising entries")
            }
        }
        if let node = value("logs", in: entries) {
            let items = try sequence(node, what: "logs")
            guard items.count <= BluetoothLogLink.Limits.rules else {
                throw Failure(line: node.line, message: "more than \(BluetoothLogLink.Limits.rules) logs: rules")
            }
            definitions.logLinks = try items.map { try logLink($0, characteristics: names) }
        }
        if let entry = entries.first(where: { $0.key == "firmware" }) {
            guard let name = scalar(entry.value), names.contains(name) else {
                throw Failure(line: entry.line, message: "firmware: names the characteristic whose value is the build, as listed under services:")
            }
            definitions.firmwareCharacteristic = name
        }
        return definitions
    }

    private static let learnKeys: Set<String> = ["from", "pattern", "scope", "names"]

    private func learner(
        _ entry: YAMLEntry, node: YAMLNode, enumName: String, characteristics: [Definitions.Characteristic], enumNames: Set<String>
    ) throws -> Definitions.Learner {
        let what = "enum \(enumName) learn"
        let fields = try mapping(node, what: what)
        try rejectUnknown(fields, allowed: Self.learnKeys, in: what)
        func line(_ key: String) -> Int { fields.first { $0.key == key }?.line ?? entry.line }
        guard let from = value("from", in: fields).flatMap(scalar) else {
            throw Failure(line: entry.line, message: "\(what) needs from: naming the characteristic that carries the table")
        }
        guard characteristics.contains(where: { $0.name == from }) else {
            throw Failure(line: line("from"), message: "\(what): no characteristic named \(from) under services:")
        }
        guard let text = value("pattern", in: fields).flatMap(scalar) else {
            throw Failure(line: entry.line, message: "\(what) needs pattern: binding $number and $name, as in \"{ map_*: { $number: $name } }\"")
        }
        let pattern = try messagePackPattern(text, line: line("pattern"), what: what)
        guard Set(pattern.captures).isSuperset(of: ["number", "name"]) else {
            throw Failure(line: line("pattern"), message: "\(what): the pattern must bind $number and $name")
        }
        if let scope = value("scope", in: fields).flatMap(scalar), !["peer", "device"].contains(scope) {
            throw Failure(line: line("scope"), message: "\(what): scope is peer — tables are remembered per device")
        }
        let names = value("names", in: fields).flatMap(scalar) ?? enumName
        guard enumNames.contains(names) else {
            throw Failure(line: line("names"), message: "\(what): names: \(names) is not an enum under enums:")
        }
        return .init(enumName: enumName, from: from, pattern: pattern, names: names)
    }

    private func messagePackPattern(_ text: String, line: Int, what: String) throws -> MessagePackPattern {
        do {
            return try MessagePackPattern.parse(text)
        } catch let failure as MessagePack.Failure {
            throw Failure(line: line, message: "\(what): \(failure.message)")
        }
    }

    private struct Context {
        let typeNames: Set<String>
        let enums: [String: [Int64: String]]
        let shapes: [String: [String: [String]]]
        var characteristicNames: Set<String> = []

        /// `DFU Control Point.op` → the characteristic and field, when the name is one.
        func contextual(_ reference: String) -> (characteristic: String, field: String)? {
            guard let dot = reference.lastIndex(of: ".") else { return nil }
            let characteristic = String(reference[..<dot])
            let field = String(reference[reference.index(after: dot)...])
            guard characteristicNames.contains(characteristic), !field.isEmpty else { return nil }
            return (characteristic, field)
        }
    }

    private func characteristic(_ node: YAMLNode, context: Context) throws -> Definitions.Characteristic {
        let entries = try mapping(node, what: "a characteristic")
        try rejectUnknown(entries, allowed: Self.characteristicKeys, in: "a characteristic")
        var uuid: String?
        if let entry = entries.first(where: { $0.key == "uuid" }) {
            guard let canonical = scalar(entry.value).flatMap(BluetoothUUID.canonical) else {
                throw Failure(line: entry.line, message: "characteristic uuid is not a Bluetooth UUID (write 2A19 or 6E400003-B5A3-F393-E0A9-E50E24DCCA9E)")
            }
            uuid = canonical
        }
        var handle: Int?
        if let entry = entries.first(where: { $0.key == "handle" }) {
            guard let value = scalar(entry.value).flatMap(Self.integer), (1...0xffff).contains(value) else {
                throw Failure(line: entry.line, message: "handle must be an attribute handle such as 0x0025")
            }
            handle = Int(value)
        }
        guard uuid != nil || handle != nil else {
            throw Failure(line: node.line, message: "a characteristic needs a uuid, a handle, or both")
        }
        let name = value("name", in: entries).flatMap(scalar) ?? uuid ?? String(format: "0x%04x", handle ?? 0)
        let message = try value("message", in: entries).map { try typeRef($0, context: context, what: "\(name) message") }
        let received = try value("rx", in: entries).map { try typeRef($0, context: context, what: "\(name) rx") } ?? message
        let sent = try value("tx", in: entries).map { try typeRef($0, context: context, what: "\(name) tx") } ?? message
        guard received != nil || sent != nil else {
            throw Failure(line: node.line, message: "\(name) needs a message: (or rx:/tx:) type")
        }
        var server: BluetoothGATTServer?
        if let entry = entries.first(where: { $0.key == "server" }) {
            guard let value = scalar(entry.value).flatMap(BluetoothGATTServer.init(rawValue:)) else {
                throw Failure(line: entry.line, message: "server must be device (the accessory's database) or phone (the iPhone's)")
            }
            server = value
        }
        return .init(name: name, server: server, line: node.line, uuid: uuid, handle: handle, received: received, sent: sent)
    }

    private func structure(_ node: YAMLNode, context: Context, what: String) throws -> Definitions.StructType {
        let entries = try mapping(node, what: what)
        try rejectUnknown(entries, allowed: Self.typeKeys, in: what)
        guard let seqNode = value("seq", in: entries) else {
            throw Failure(line: node.line, message: "\(what) needs a seq: list of fields")
        }
        let items = try sequence(seqNode, what: "\(what) seq")
        guard items.count <= Definitions.Limits.fieldsPerType else {
            throw Failure(line: seqNode.line, message: "\(what) has more than \(Definitions.Limits.fieldsPerType) fields")
        }
        var fields: [Definitions.Field] = []
        var integerFields: Set<String> = []
        for item in items {
            let field = try self.field(item, earlier: fields, integerFields: integerFields, context: context, owner: what)
            if case .primitive(.integer) = field.type, field.repetition == nil {
                integerFields.insert(field.id)
                for part in field.bits { integerFields.insert("\(field.id).\(part.name)") }
            }
            fields.append(field)
        }
        var summary: [Definitions.SummaryPart]?
        if let entry = entries.first(where: { $0.key == "summary" }) {
            guard let template = scalar(entry.value) else {
                throw Failure(line: entry.line, message: "\(what) summary must be text such as \"{kind} #{seq}\"")
            }
            let parts = Self.template(template)
            let ids = Set(fields.map(\.id))
            for case .field(let id) in parts where !ids.contains(id) {
                throw Failure(line: entry.line, message: "\(what) summary names {\(id)}, which is not a field of this type")
            }
            summary = parts
        }
        return .init(fields: fields, summary: summary)
    }

    private func field(
        _ node: YAMLNode, earlier: [Definitions.Field], integerFields: Set<String>,
        context: Context, owner: String
    ) throws -> Definitions.Field {
        let entries = try mapping(node, what: "a field of \(owner)")
        try rejectUnknown(entries, allowed: Self.fieldKeys, in: "a field of \(owner)")
        guard let id = value("id", in: entries).flatMap(scalar) else {
            throw Failure(line: node.line, message: "every field of \(owner) needs an id:")
        }
        try checkIdentifier(id, line: node.line, what: "field id")
        guard !earlier.contains(where: { $0.id == id }) else {
            throw Failure(line: node.line, message: "\(owner) has two fields called \(id)")
        }
        let label = "\(owner).\(id)"
        guard let typeNode = value("type", in: entries) else {
            throw Failure(line: node.line, message: "\(label) needs a type: (u8, u16, s32, f32, bytes, str, a type name, …)")
        }
        let type = try typeRef(typeNode, context: context, what: label, earlier: earlier)
        func line(_ key: String) -> Int { entries.first { $0.key == key }?.line ?? node.line }
        func requireInteger(_ key: String) throws {
            guard case .primitive(.integer) = type else {
                throw Failure(line: line(key), message: "\(label): \(key): only applies to an integer field")
            }
        }

        var enumName: String?
        var captureEnums: [String: String] = [:]
        var rules: [Definitions.MatchRule] = []
        var shapeSet: String?
        let isMessagePack: Bool
        if case .primitive(.msgpack) = type { isMessagePack = true } else { isMessagePack = false }
        if let node = value("match", in: entries) {
            guard isMessagePack else {
                throw Failure(line: line("match"), message: "\(label): match: applies to a msgpack field")
            }
            for item in try sequence(node, what: "\(label) match") {
                let rule = try mapping(item, what: "a \(label) match rule")
                try rejectUnknown(rule, allowed: ["pattern", "summary", "level"], in: "a \(label) match rule")
                guard let text = value("pattern", in: rule).flatMap(scalar) else {
                    throw Failure(line: item.line, message: "\(label) match: each rule needs pattern:, as in \"{ $cmd: $value }\"")
                }
                let pattern = try messagePackPattern(text, line: item.line, what: "\(label) match")
                var summary: [Definitions.SummaryPart]?
                if let template = value("summary", in: rule).flatMap(scalar) {
                    let parts = Self.template(template)
                    for case .field(let id) in parts where !pattern.captures.contains(id) {
                        throw Failure(line: item.line, message: "\(label) match: summary names {\(id)}, which the pattern does not bind")
                    }
                    summary = parts
                }
                var level: BluetoothSeverity?
                if let text = value("level", in: rule).flatMap(scalar) {
                    guard let parsed = BluetoothSeverity(name: text) else {
                        throw Failure(line: item.line, message: "\(label) match: level is debug, info, warning or error")
                    }
                    level = parsed
                }
                rules.append(.init(pattern: pattern, summary: summary, level: level))
            }
        }
        if let node = value("enum", in: entries), case .mapping(let bindings) = node.value {
            guard isMessagePack else {
                throw Failure(line: line("enum"), message: "\(label): enum: { capture: Enum } applies to a msgpack field with match:")
            }
            let captures = Set(rules.flatMap(\.pattern.captures))
            for binding in bindings {
                guard captures.contains(binding.key) else {
                    throw Failure(line: binding.line, message: "\(label) enum: no match: pattern binds $\(binding.key)")
                }
                guard let name = scalar(binding.value), context.enums[name] != nil else {
                    throw Failure(line: binding.line, message: "\(label) enum: \(binding.key) needs an enum declared under enums:")
                }
                captureEnums[binding.key] = name
            }
        } else if let name = value("enum", in: entries).flatMap(scalar) {
            // On a msgpack field the enum names integer map keys.
            if case .primitive(.msgpack) = type {} else { try requireInteger("enum") }
            guard context.enums[name] != nil else {
                throw Failure(line: line("enum"), message: "\(label): no enum called \(name) under enums:")
            }
            enumName = name
        }
        var scale: Double?
        if let text = value("scale", in: entries).flatMap(scalar) {
            if case .primitive(.float) = type {} else { try requireInteger("scale") }
            guard let number = Double(text), number.isFinite, number != 0 else {
                throw Failure(line: line("scale"), message: "\(label): scale must be a non-zero number such as 0.01")
            }
            scale = number
        }
        var flags: [(name: String, bit: Int)] = []
        if let node = value("flags", in: entries) {
            try requireInteger("flags")
            for entry in try mapping(node, what: "\(label) flags") {
                guard let bit = scalar(entry.value).flatMap(Self.integer), (0..<64).contains(bit) else {
                    throw Failure(line: entry.line, message: "\(label) flags: \(entry.key) needs a bit number 0–63")
                }
                flags.append((entry.key, Int(bit)))
            }
        }

        let isVariable: Bool
        switch type {
        case .primitive(.bytes), .primitive(.string), .primitive(.msgpack), .named, .structure, .switchOn: isVariable = true
        default: isVariable = false
        }
        var size: Definitions.Size?
        if let text = value("size", in: entries).flatMap(scalar) {
            guard isVariable else {
                throw Failure(line: line("size"), message: "\(label): size: applies to bytes, str and types, not to fixed-width numbers")
            }
            size = try sizeValue(text, label: "\(label) size", line: line("size"), integerFields: integerFields)
        }
        var repetition: Definitions.Repetition?
        if let text = value("repeat", in: entries).flatMap(scalar) {
            switch try sizeValue(text, label: "\(label) repeat", line: line("repeat"), integerFields: integerFields) {
            case .rest: repetition = .untilEnd
            case .fixed(let count): repetition = .count(count)
            case .field(let id): repetition = .field(id)
            }
        }
        if let name = value("values", in: entries).flatMap(scalar) {
            guard isMessagePack, !captureEnums.isEmpty else {
                throw Failure(line: line("values"), message: "\(label): values: needs a msgpack field whose enum: names a capture")
            }
            guard context.shapes[name] != nil else {
                throw Failure(line: line("values"), message: "\(label): no shape set called \(name) under shapes:")
            }
            shapeSet = name
        }
        var bits: [Definitions.BitField] = []
        if let node = value("bits", in: entries) {
            try requireInteger("bits")
            let items = try mapping(node, what: "\(label) bits")
            guard items.count <= Definitions.Limits.bitFields else {
                throw Failure(line: line("bits"), message: "\(label): more than \(Definitions.Limits.bitFields) bit fields")
            }
            for item in items {
                try checkIdentifier(item.key, line: item.line, what: "bit field")
                var range = scalar(item.value)
                var enumName: String?
                if case .mapping(let details) = item.value.value {
                    try rejectUnknown(details, allowed: ["bits", "enum"], in: "\(label) bits \(item.key)")
                    range = value("bits", in: details).flatMap(scalar)
                    enumName = value("enum", in: details).flatMap(scalar)
                    if let enumName, context.enums[enumName] == nil {
                        throw Failure(line: item.line, message: "\(label) bits \(item.key): no enum called \(enumName) under enums:")
                    }
                }
                let bounds = (range ?? "").split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard (1...2).contains(bounds.count), let low = bounds.first ?? nil, let high = bounds.last ?? nil,
                      0 <= low, low <= high, high < 64 else {
                    throw Failure(line: item.line, message: "\(label) bits \(item.key): write a bit or a range such as 8-15 (bits 0–63)")
                }
                bits.append(.init(name: item.key, low: low, high: high, enumName: enumName))
            }
        }
        var condition: Definitions.Condition?
        if let text = value("if", in: entries).flatMap(scalar) {
            condition = try self.condition(text, earlier: earlier, integerFields: integerFields, label: label, line: line("if"), context: context)
        }
        let hidden = value("hidden", in: entries).flatMap(scalar).map { $0 == "true" || $0 == "yes" } ?? false
        return .init(
            id: id, type: type, enumName: enumName, scale: scale,
            unit: value("unit", in: entries).flatMap(scalar),
            flags: flags, size: size, repetition: repetition, hidden: hidden,
            match: rules, captureEnums: captureEnums, values: shapeSet, bits: bits, condition: condition
        )
    }

    /// `flag`, `!flag`, `field`, `field == NAME`, `field != 3`.
    private func condition(
        _ text: String, earlier: [Definitions.Field], integerFields: Set<String>, label: String, line: Int, context: Context
    ) throws -> Definitions.Condition {
        var body = text.trimmingCharacters(in: .whitespaces)
        var negated = false
        var equals: Definitions.CaseKey?
        for (symbol, negates) in [("!=", true), ("==", false)] {
            guard let range = body.range(of: symbol) else { continue }
            let right = body[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !right.isEmpty else { break }
            equals = Self.integer(right).map(Definitions.CaseKey.number) ?? .name(right)
            negated = negates
            body = body[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            break
        }
        if equals == nil, body.hasPrefix("!") {
            negated = true
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if integerFields.contains(body) {
            return .init(subject: .field(body), equals: equals, negated: negated)
        }
        if equals == nil {
            for field in earlier.reversed() {
                if let flag = field.flags.first(where: { $0.name == body }) {
                    return .init(subject: .flag(field: field.id, bit: flag.bit), equals: nil, negated: negated)
                }
            }
        }
        throw Failure(line: line, message: "\(label) if: '\(body)' is neither an earlier integer field nor a flag of one")
    }

    private func sizeValue(_ text: String, label: String, line: Int, integerFields: Set<String>) throws -> Definitions.Size {
        if text == "eos" || text == "rest" { return .rest }
        if let number = Self.integer(text) {
            guard (0...Int64(BluetoothPacketDecoder.Limits.packetBytes)).contains(number) else {
                throw Failure(line: line, message: "\(label) \(text) is larger than any Bluetooth value")
            }
            return .fixed(Int(number))
        }
        guard integerFields.contains(text) else {
            throw Failure(line: line, message: "\(label): '\(text)' must be a number, rest, or an earlier integer field of the same type")
        }
        return .field(text)
    }

    private func typeRef(
        _ node: YAMLNode, context: Context, what: String, earlier: [Definitions.Field] = []
    ) throws -> Definitions.TypeRef {
        if let name = scalar(node) {
            if let primitive = Self.primitive(name) { return .primitive(primitive) }
            guard context.typeNames.contains(name) else {
                throw Failure(line: node.line, message: "\(what): unknown type '\(name)' — use u8…u64, s8…s64, f32, f64, bool, bytes, str, msgpack, or a name under types:")
            }
            return .named(name)
        }
        let entries = try mapping(node, what: what)
        guard entries.contains(where: { $0.key == "switch-on" }) else {
            return .structure(try structure(node, context: context, what: what))
        }
        try rejectUnknown(entries, allowed: Self.switchKeys, in: "\(what) switch")
        guard let on = value("switch-on", in: entries).flatMap(scalar) else {
            throw Failure(line: node.line, message: "\(what): switch-on must name an earlier field of the same type")
        }
        // An earlier field of this type, a `bits:` part of one, or `Characteristic.field`: that
        // characteristic's last value on the same connection.
        let names: Set<String>
        let checksNames: Bool
        if let discriminant = earlier.first(where: { $0.id == on }) {
            guard case .primitive(.integer) = discriminant.type, discriminant.repetition == nil else {
                throw Failure(line: node.line, message: "\(what): switch-on field \(on) must be a single integer")
            }
            names = discriminant.enumName.flatMap { context.enums[$0] }.map { Set($0.values) } ?? []
            checksNames = true
        } else if let dot = on.firstIndex(of: "."), let owner = earlier.first(where: { $0.id == on[..<dot] }),
                  let part = owner.bits.first(where: { $0.name == on[on.index(after: dot)...] }) {
            names = part.enumName.flatMap { context.enums[$0] }.map { Set($0.values) } ?? []
            checksNames = true
        } else if context.contextual(on) != nil {
            names = []
            checksNames = false
        } else {
            throw Failure(line: node.line, message: "\(what): switch-on must name an earlier field of the same type, or Characteristic.field")
        }
        guard let casesNode = value("cases", in: entries) else {
            throw Failure(line: node.line, message: "\(what): switch-on needs cases:")
        }
        var cases: [(key: Definitions.CaseKey, type: Definitions.TypeRef)] = []
        var fallback: Definitions.TypeRef?
        for entry in try mapping(casesNode, what: "\(what) cases") {
            let type = try typeRef(entry.value, context: context, what: "\(what) case \(entry.key)")
            if entry.key == "_" {
                fallback = type
            } else if let number = Self.integer(entry.key) {
                cases.append((.number(number), type))
            } else {
                guard !checksNames || names.contains(entry.key) else {
                    throw Failure(line: entry.line, message: "\(what): case \(entry.key) is neither a number nor a case of \(on)'s enum")
                }
                cases.append((.name(entry.key), type))
            }
        }
        return .switchOn(.init(on: on, cases: cases, fallback: fallback, contextual: !checksNames))
    }

    // MARK: Transactions and streams

    private static let transactionKeys: Set<String> = ["name", "request", "response", "key", "pending", "timeout", "within"]
    private static let streamKeys: Set<String> = ["name", "start", "info", "data", "end", "lines", "levels"]
    private static let endpointKeys: Set<String> = [
        "characteristic", "op", "where", "match", "data", "offset", "total", "key", "crc32", "crc16",
    ]

    private func transaction(_ node: YAMLNode, characteristics: Set<String>) throws -> Definitions.Transaction {
        let fields = try mapping(node, what: "a transaction")
        try rejectUnknown(fields, allowed: Self.transactionKeys, in: "a transaction")
        let name = value("name", in: fields).flatMap(scalar) ?? "transaction"
        let what = "transaction \(name)"
        func line(_ key: String) -> Int { fields.first { $0.key == key }?.line ?? node.line }
        guard let request = value("request", in: fields), let response = value("response", in: fields) else {
            throw Failure(line: node.line, message: "\(what) needs request: and response:")
        }
        var key: (String, String)?
        if let text = value("key", in: fields).flatMap(scalar) {
            let sides = text.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(sides.count), sides.allSatisfy({ !$0.isEmpty }) else {
                throw Failure(line: line("key"), message: "\(what): key is a value name, or request = response")
            }
            key = (sides[0], sides.last!)
        }
        let pending = try value("pending", in: fields).flatMap(scalar).map {
            try messagePackPattern($0, line: line("pending"), what: "\(what) pending")
        }
        let timeout = try value("timeout", in: fields).flatMap(scalar).map { try seconds($0, line: line("timeout"), what: what) }
        let within = try value("within", in: fields).flatMap(scalar).map { try seconds($0, line: line("within"), what: what) }
        return .init(
            name: name,
            request: try endpoint(request, characteristics: characteristics, what: "\(what) request"),
            response: try endpoint(response, characteristics: characteristics, what: "\(what) response"),
            key: key, pending: pending, timeout: timeout, within: within
        )
    }

    private func stream(_ node: YAMLNode, characteristics: Set<String>) throws -> Definitions.Stream {
        let fields = try mapping(node, what: "a stream")
        try rejectUnknown(fields, allowed: Self.streamKeys, in: "a stream")
        let name = value("name", in: fields).flatMap(scalar) ?? "stream"
        let what = "stream \(name)"
        guard let data = value("data", in: fields) else {
            throw Failure(line: node.line, message: "\(what) needs data: naming where its bytes are")
        }
        var levels: [String: BluetoothSeverity] = [:]
        if let node = value("levels", in: fields) {
            for entry in try mapping(node, what: "\(what) levels") {
                guard let level = scalar(entry.value).flatMap(BluetoothSeverity.init(name:)) else {
                    throw Failure(line: entry.line, message: "\(what) levels: \(entry.key) needs debug, info, warning or error")
                }
                levels[entry.key] = level
            }
        }
        return .init(
            name: name,
            start: try value("start", in: fields).map { try endpoint($0, characteristics: characteristics, what: "\(what) start") },
            info: try value("info", in: fields).map { try endpoint($0, characteristics: characteristics, what: "\(what) info") },
            data: try endpoint(data, characteristics: characteristics, what: "\(what) data"),
            end: try value("end", in: fields).map { try endpoint($0, characteristics: characteristics, what: "\(what) end") },
            lines: value("lines", in: fields).flatMap(scalar).map { $0 == "true" || $0 == "yes" } ?? false,
            levels: levels
        )
    }

    private func endpoint(_ node: YAMLNode, characteristics: Set<String>, what: String) throws -> Definitions.Endpoint {
        let fields = try mapping(node, what: what)
        try rejectUnknown(fields, allowed: Self.endpointKeys, in: what)
        func line(_ key: String) -> Int { fields.first { $0.key == key }?.line ?? node.line }
        guard let characteristic = value("characteristic", in: fields).flatMap(scalar) else {
            throw Failure(line: node.line, message: "\(what) needs characteristic: naming one under services:")
        }
        guard characteristics.contains(characteristic) else {
            throw Failure(line: line("characteristic"), message: "\(what): no characteristic named \(characteristic) under services:")
        }
        var operation: Definitions.Operation?
        if let text = value("op", in: fields).flatMap(scalar), text != "any" {
            guard let parsed = Definitions.Operation(rawValue: text) else {
                throw Failure(line: line("op"), message: "\(what): op is write, read, notify, indicate or any")
            }
            operation = parsed
        }
        var conditions: [Definitions.ValueTest] = []
        if let node = value("where", in: fields) {
            for entry in try mapping(node, what: "\(what) where") {
                // `name: VALUE`, `name: [A, B]` (any of them) or `name: "!VALUE"` (anything else).
                var expected: [String]
                switch entry.value.value {
                case .sequence(let items): expected = items.compactMap(scalar)
                default: expected = scalar(entry.value).map { [$0] } ?? []
                }
                guard !expected.isEmpty else {
                    throw Failure(line: entry.line, message: "\(what) where: \(entry.key) needs a value, an enum name or a list of them")
                }
                var negated = false
                if expected.count == 1, expected[0].hasPrefix("!") {
                    negated = true
                    expected = [String(expected[0].dropFirst()).trimmingCharacters(in: .whitespaces)]
                }
                conditions.append(.init(name: entry.key, values: expected, negated: negated))
            }
            guard conditions.count <= Definitions.Limits.conditions else {
                throw Failure(line: line("where"), message: "\(what): more than \(Definitions.Limits.conditions) where: conditions")
            }
        }
        var patterns: [MessagePackPattern] = []
        if let node = value("match", in: fields) {
            let texts: [(String, Int)]
            if case .sequence(let items) = node.value {
                texts = try items.map { item in
                    guard let text = scalar(item) else { throw Failure(line: item.line, message: "\(what) match: a list of patterns") }
                    return (text, item.line)
                }
            } else if let text = scalar(node) {
                texts = [(text, line("match"))]
            } else {
                throw Failure(line: line("match"), message: "\(what) match: a pattern or a list of them")
            }
            guard texts.count <= Definitions.Limits.patterns else {
                throw Failure(line: line("match"), message: "\(what): more than \(Definitions.Limits.patterns) patterns")
            }
            patterns = try texts.map { try messagePackPattern($0.0, line: $0.1, what: "\(what) match") }
        }
        var roles: [String: String] = [:]
        for role in ["data", "offset", "total", "key", "crc32", "crc16"] {
            if let name = value(role, in: fields).flatMap(scalar) { roles[role] = name }
        }
        return .init(characteristic: characteristic, operation: operation, conditions: conditions, patterns: patterns, roles: roles)
    }

    private func logLink(_ node: YAMLNode, characteristics: Set<String>) throws -> BluetoothLogLink {
        let fields = try mapping(node, what: "a logs: rule")
        try rejectUnknown(fields, allowed: ["match", "packet", "within"], in: "a logs: rule")
        func line(_ key: String) -> Int { fields.first { $0.key == key }?.line ?? node.line }
        guard let source = value("match", in: fields).flatMap(scalar), !source.isEmpty,
              source.count <= BluetoothLogLink.Limits.patternCharacters else {
            throw Failure(line: node.line, message: "logs: each rule needs match: a regular expression of at most \(BluetoothLogLink.Limits.patternCharacters) characters")
        }
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: source)
        } catch {
            throw Failure(line: line("match"), message: "logs: match is not a regular expression: \(error.localizedDescription)")
        }
        guard let packetNode = value("packet", in: fields) else {
            throw Failure(line: node.line, message: "logs: each rule needs packet: { characteristic: …, op: …, key: … }")
        }
        let packet = try mapping(packetNode, what: "logs: packet")
        try rejectUnknown(packet, allowed: ["characteristic", "op", "key"], in: "logs: packet")
        guard let characteristic = value("characteristic", in: packet).flatMap(scalar), characteristics.contains(characteristic) else {
            throw Failure(line: line("packet"), message: "logs: packet characteristic must name one under services:")
        }
        var operation: Definitions.Operation?
        if let text = value("op", in: packet).flatMap(scalar), text != "any" {
            guard let parsed = Definitions.Operation(rawValue: text) else {
                throw Failure(line: line("packet"), message: "logs: packet op is write, read, notify, indicate or any")
            }
            operation = parsed
        }
        let key = value("key", in: packet).flatMap(scalar)
        if key != nil, !source.contains("(?<key>") {
            throw Failure(line: line("match"), message: "logs: a rule with key: needs a (?<key>…) group in match:")
        }
        var window = BluetoothLogLink.Limits.defaultWindow
        if let text = value("within", in: fields).flatMap(scalar) {
            window = min(try seconds(text, line: line("within"), what: "logs:"), BluetoothLogLink.Limits.maximumWindow)
        }
        return BluetoothLogLink(expression: expression, source: source, characteristic: characteristic,
                                operation: operation, key: key, window: window)
    }

    /// `30s`, `500ms`, `2 min` or a bare number of seconds.
    private func seconds(_ text: String, line: Int, what: String) throws -> Double {
        let trimmed = text.lowercased().replacingOccurrences(of: " ", with: "")
        for (suffix, scale) in [("ms", 0.001), ("min", 60.0), ("s", 1.0), ("", 1.0)] where trimmed.hasSuffix(suffix) {
            if let number = Double(trimmed.dropLast(suffix.count)), number > 0, number.isFinite { return number * scale }
        }
        throw Failure(line: line, message: "\(what): '\(text)' is not a duration such as 2s or 500ms")
    }

    // MARK: Node helpers

    private func mapping(_ node: YAMLNode, what: String) throws -> [YAMLEntry] {
        if case .mapping(let entries) = node.value { return entries }
        if case .null = node.value { return [] }
        throw Failure(line: node.line, message: "\(what) must be a mapping of key: value")
    }

    private func sequence(_ node: YAMLNode, what: String) throws -> [YAMLNode] {
        if case .sequence(let items) = node.value { return items }
        if case .null = node.value { return [] }
        throw Failure(line: node.line, message: "\(what) must be a list (lines starting with - )")
    }

    private func scalar(_ node: YAMLNode) -> String? {
        switch node.value {
        case .scalar(let text), .quoted(let text): return text
        default: return nil
        }
    }

    private func value(_ key: String, in entries: [YAMLEntry]) -> YAMLNode? {
        entries.first { $0.key == key }?.value
    }

    private func rejectUnknown(_ entries: [YAMLEntry], allowed: Set<String>, in what: String) throws {
        guard let unknown = entries.first(where: { !allowed.contains($0.key) }) else { return }
        throw Failure(
            line: unknown.line,
            message: "\(what): unknown key '\(unknown.key)' (expected \(allowed.sorted().joined(separator: ", ")))"
        )
    }

    private func checkIdentifier(_ text: String, line: Int, what: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(allowed.contains) else {
            throw Failure(line: line, message: "\(what) '\(text)' may only use letters, digits, _ and -")
        }
    }

    static func integer(_ text: String) -> Int64? { Definitions.number(text) }

    static func primitive(_ name: String) -> Definitions.Primitive? {
        switch name {
        case "bool": return .bool
        case "bytes": return .bytes
        case "str": return .string
        case "msgpack": return .msgpack
        default: break
        }
        var body = Substring(name)
        var bigEndian = false
        if body.hasSuffix("be") { bigEndian = true; body = body.dropLast(2) }
        else if body.hasSuffix("le") { body = body.dropLast(2) }
        guard let kind = body.first, let bits = Int(body.dropFirst()) else { return nil }
        switch (kind, bits) {
        case ("u", 8), ("u", 16), ("u", 24), ("u", 32), ("u", 64):
            return .integer(bytes: bits / 8, signed: false, bigEndian: bigEndian)
        case ("s", 8), ("s", 16), ("s", 24), ("s", 32), ("s", 64):
            return .integer(bytes: bits / 8, signed: true, bigEndian: bigEndian)
        case ("f", 32), ("f", 64):
            return .float(bytes: bits / 8, bigEndian: bigEndian)
        default:
            return nil
        }
    }

    static func template(_ text: String) -> [Definitions.SummaryPart] {
        var parts: [Definitions.SummaryPart] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"),
              let close = rest[open...].firstIndex(of: "}") {
            if open > rest.startIndex { parts.append(.text(String(rest[..<open]))) }
            parts.append(.field(String(rest[rest.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { parts.append(.text(String(rest))) }
        return parts
    }
}

// MARK: - UUIDs

enum BluetoothUUID {
    private static let baseSuffix = "-0000-1000-8000-00805F9B34FB"

    /// Four hex digits for an SIG-assigned UUID (including one written out on the base UUID),
    /// otherwise the dashed upper-case 128-bit form.
    static func canonical(_ text: String) -> String? {
        let upper = text.uppercased().trimmingCharacters(in: .whitespaces)
        let hex = upper.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "0X", with: "")
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        switch hex.count {
        case 4: return hex
        case 8 where hex.hasPrefix("0000"): return String(hex.suffix(4))
        case 32:
            let dashed = [8, 4, 4, 4, 12].reduce(into: (parts: [String](), rest: Substring(hex))) {
                $0.parts.append(String($0.rest.prefix($1)))
                $0.rest = $0.rest.dropFirst($1)
            }.parts.joined(separator: "-")
            if dashed.hasPrefix("0000"), dashed.hasSuffix(baseSuffix) {
                return String(dashed.dropFirst(4).prefix(4))
            }
            return dashed
        default: return nil
        }
    }

    /// From ATT's little-endian wire form (2 or 16 bytes).
    static func canonical(wire bytes: ArraySlice<UInt8>) -> String? {
        guard bytes.count == 2 || bytes.count == 16 else { return nil }
        return canonical(bytes.reversed().map { String(format: "%02X", $0) }.joined())
    }
}

// MARK: - Decoding

extension BluetoothPacketDefinitions {
    struct Decoded: Sendable, Equatable {
        /// The rendered value, at most `Limits.renderedCharacters`.
        let text: String
        /// Set when the bytes did not fit the definition, naming where they stopped fitting.
        let problem: String?
        /// Named values the decode read, by field id (`op`), path (`body.index`), `bits:` part
        /// (`cmd.token`) and pattern capture (`cmd`). Bounded by `Limits.values`.
        var values: [String: BluetoothValue] = [:]
        /// The level the definitions give this value: a named enum entry's, else its match rule's.
        var level: BluetoothSeverity? = nil
        /// The value's first MessagePack field, parsed, for endpoint patterns to match again.
        var message: MessagePackValue? = nil
        /// The enums that name that field's words (`live_logs` in `{ live_logs: $data }`).
        var wordEnums: [String] = []
        /// That field's capture → enum bindings, so an endpoint's own `$cmd` is named the same way.
        var captureEnums: [String: String] = [:]
    }

    /// `learned` holds enum entries a device taught in its own traffic; they win over the file's.
    /// `context` holds other characteristics' last values on the same connection, keyed
    /// `Characteristic.field`, for a switch that depends on them.
    func decode(
        _ bytes: [UInt8], as type: TypeRef, learned: [String: [Int64: String]] = [:],
        context: [String: BluetoothValue] = [:]
    ) -> Decoded {
        var reader = ValueReader(definitions: self, bytes: bytes, learned: learned, context: context)
        var text: String
        var problem: String?
        do {
            text = try reader.render(type, path: "", end: bytes.count)
            if reader.offset < bytes.count {
                problem = "\(bytes.count - reader.offset) trailing bytes not described"
            }
        } catch let failure as ValueReader.Failure {
            text = reader.partial
            problem = failure.message
        } catch {
            text = reader.partial
            problem = error.localizedDescription
        }
        if text.count > Limits.renderedCharacters {
            text = String(text.prefix(Limits.renderedCharacters)) + "…"
        }
        return Decoded(
            text: text, problem: problem, values: reader.values, level: reader.entryLevel ?? reader.ruleLevel,
            message: reader.message, wordEnums: reader.wordEnums, captureEnums: reader.captureEnums
        )
    }
}

/// One value's walk. All state is local, so the worker can decode packets without sharing.
private struct ValueReader {
    struct Failure: Error { let message: String }

    /// What an integer field leaves behind for later fields to refer to.
    private struct Scalar {
        let number: Int64
        let enumName: String?
    }

    let definitions: BluetoothPacketDefinitions
    let bytes: [UInt8]
    let learned: [String: [Int64: String]]
    let context: [String: BluetoothValue]
    private(set) var offset = 0
    private var steps = 0
    private var depth = 0
    /// The fields rendered so far at the outermost level, so a failure still shows its progress.
    private(set) var partial = ""
    private(set) var values: [String: BluetoothValue] = [:]
    /// The loudest level an enum entry named in this value carries.
    private(set) var entryLevel: BluetoothSeverity?
    /// The level of the match rule that rendered the value.
    private(set) var ruleLevel: BluetoothSeverity?
    private(set) var message: MessagePackValue?
    private(set) var wordEnums: [String] = []
    private(set) var captureEnums: [String: String] = [:]

    init(
        definitions: BluetoothPacketDefinitions, bytes: [UInt8], learned: [String: [Int64: String]] = [:],
        context: [String: BluetoothValue] = [:]
    ) {
        self.definitions = definitions
        self.bytes = bytes
        self.learned = learned
        self.context = context
    }

    /// An enum case, learned from the device first, then as the file declares it.
    private func name(_ enumName: String, _ number: Int64) -> String? {
        learned[enumName]?[number] ?? definitions.enums[enumName]?[number]
    }

    /// Names an enum case and notes the level its entry carries.
    private mutating func named(_ enumName: String, _ number: Int64) -> String? {
        let found = name(enumName, number)
        if let found, let level = definitions.levels[enumName]?[found] {
            entryLevel = max(entryLevel ?? level, level)
        }
        return found
    }

    /// Keeps a value by path and by its own id, the first of each name winning. Items of a
    /// repeated field are not kept: no single one of them is *the* value.
    private mutating func keep(_ value: BluetoothValue, path: String, id: String) {
        guard !path.contains("["), values.count < BluetoothPacketDefinitions.Limits.values else { return }
        if values[path] == nil { values[path] = value }
        if id != path, values[id] == nil, values.count < BluetoothPacketDefinitions.Limits.values { values[id] = value }
    }

    mutating func render(_ type: BluetoothPacketDefinitions.TypeRef, path: String, end: Int) throws -> String {
        switch type {
        case .primitive(let primitive):
            return try renderPrimitive(primitive, field: nil, path: path, end: end)
        case .named(let name):
            guard let structure = definitions.types[name] else { throw Failure(message: "\(path): no type \(name)") }
            return try renderStructure(structure, path: path, end: end)
        case .structure(let structure):
            return try renderStructure(structure, path: path, end: end)
        case .switchOn(let choice):
            // Only a switch on another characteristic's value can stand alone.
            var scope: [String: Scalar] = [:]
            return try renderSwitch(choice, path: path, end: end, scope: &scope)
        }
    }

    private mutating func renderStructure(
        _ structure: BluetoothPacketDefinitions.StructType, path: String, end: Int
    ) throws -> String {
        depth += 1
        defer { depth -= 1 }
        guard depth <= BluetoothPacketDefinitions.Limits.depth else {
            throw Failure(message: "\(path): nested deeper than \(BluetoothPacketDefinitions.Limits.depth) types")
        }
        let outermost = depth == 1
        var scope: [String: Scalar] = [:]
        var rendered: [(id: String, text: String, hidden: Bool)] = []
        func joined() -> String {
            rendered.filter { !$0.hidden }.map { "\($0.id)=\($0.text)" }.joined(separator: " ")
        }
        for field in structure.fields {
            if let condition = field.condition, !holds(condition, scope: scope) { continue }
            let fieldPath = path.isEmpty ? field.id : "\(path).\(field.id)"
            do {
                let text = try renderField(field, path: fieldPath, end: end, scope: &scope)
                rendered.append((field.id, text, field.hidden))
            } catch {
                if outermost { partial = joined() }
                throw error
            }
            if outermost { partial = joined() }
        }
        guard let summary = structure.summary else {
            let text = joined()
            return depth == 1 ? text : "{\(text)}"
        }
        let values = Dictionary(rendered.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        return summary.map {
            switch $0 {
            case .text(let text): return text
            case .field(let id): return values[id] ?? ""
            }
        }.joined()
    }

    private func holds(_ condition: BluetoothPacketDefinitions.Condition, scope: [String: Scalar]) -> Bool {
        let result: Bool
        switch condition.subject {
        case .flag(let field, let bit):
            result = (scope[field]?.number ?? 0) & (1 << Int64(bit)) != 0
        case .field(let id):
            guard let value = scope[id] else { return false }
            switch condition.equals {
            case .number(let number)?: result = value.number == number
            case .name(let name)?: result = value.enumName == name
            case nil: result = value.number != 0
            }
        }
        return result != condition.negated
    }

    private mutating func renderField(
        _ field: BluetoothPacketDefinitions.Field, path: String, end: Int,
        scope: inout [String: Scalar]
    ) throws -> String {
        func resolve(_ size: BluetoothPacketDefinitions.Size) throws -> Int {
            switch size {
            case .fixed(let count): return count
            case .rest: return end - offset
            case .field(let id):
                guard let value = scope[id]?.number, value >= 0 else {
                    throw Failure(message: "\(path): size field \(id) is negative or missing")
                }
                return Int(clamping: value)
            }
        }
        let fieldEnd: Int
        if let size = field.size {
            let count = try resolve(size)
            guard count <= end - offset else {
                throw Failure(message: "\(path): needs \(count) bytes, \(end - offset) left")
            }
            fieldEnd = offset + count
        } else {
            fieldEnd = end
        }

        guard let repetition = field.repetition else {
            let text = try renderOne(field, path: path, end: fieldEnd, scope: &scope)
            if field.size != nil { offset = fieldEnd }
            return text
        }
        let count: Int?
        switch repetition {
        case .untilEnd: count = nil
        case .count(let fixed): count = fixed
        case .field(let id): count = try resolve(.field(id))
        }
        var items: [String] = []
        var index = 0
        var itemScope: [String: Scalar] = [:]
        while count.map({ index < $0 }) ?? (offset < fieldEnd) {
            guard index < BluetoothPacketDefinitions.Limits.repeatItems else {
                throw Failure(message: "\(path): more than \(BluetoothPacketDefinitions.Limits.repeatItems) items")
            }
            let before = offset
            let text = try renderOne(field, path: "\(path)[\(index)]", end: fieldEnd, scope: &itemScope)
            if items.count < BluetoothPacketDefinitions.Limits.renderedRepeatItems { items.append(text) }
            index += 1
            // A zero-width item repeated until the end would never get there.
            if count == nil, offset == before { break }
        }
        if field.size != nil { offset = fieldEnd }
        let more = index - items.count
        return "[" + items.joined(separator: ", ") + (more > 0 ? ", …+\(more)" : "") + "]"
    }

    private mutating func renderOne(
        _ field: BluetoothPacketDefinitions.Field, path: String, end: Int,
        scope: inout [String: Scalar]
    ) throws -> String {
        steps += 1
        guard steps <= BluetoothPacketDefinitions.Limits.steps else {
            throw Failure(message: "\(path): definition takes more than \(BluetoothPacketDefinitions.Limits.steps) steps")
        }
        switch field.type {
        case .primitive(let primitive):
            if case .integer(let width, let signed, let bigEndian) = primitive {
                let number = try integer(width: width, signed: signed, bigEndian: bigEndian, path: path, end: end)
                let enumName = field.enumName.flatMap { named($0, number) }
                scope[field.id] = Scalar(number: number, enumName: enumName)
                keep(.number(number, name: enumName), path: path, id: field.id)
                guard !field.bits.isEmpty else {
                    return format(number: number, signed: signed, field: field, enumName: enumName)
                }
                var parts: [String] = []
                for part in field.bits {
                    let value = part.extract(number)
                    let partName = part.enumName.flatMap { named($0, value) }
                    scope["\(field.id).\(part.name)"] = Scalar(number: value, enumName: partName)
                    keep(.number(value, name: partName), path: "\(path).\(part.name)", id: part.name)
                    parts.append("\(part.name)=" + (part.enumName == nil ? String(value) : partName ?? "\(value)?"))
                }
                return "{" + parts.joined(separator: " ") + "}"
            }
            return try renderPrimitive(primitive, field: field, path: path, end: end)
        case .switchOn(let choice):
            return try renderSwitch(choice, path: path, end: end, scope: &scope)
        case .named, .structure:
            return try render(field.type, path: path, end: end)
        }
    }

    private mutating func renderSwitch(
        _ choice: BluetoothPacketDefinitions.Switch, path: String, end: Int, scope: inout [String: Scalar]
    ) throws -> String {
        let discriminant: Scalar
        if let local = scope[choice.on] {
            discriminant = local
        } else if case .number(let number, let name)? = context[choice.on] {
            discriminant = Scalar(number: number, enumName: name)
        } else if choice.contextual {
            return "<\(choice.on) not seen yet>" + rest(end: end)
        } else {
            throw Failure(message: "\(path): \(choice.on) was not read before the switch")
        }
        let match = choice.cases.first { key, _ in
            switch key {
            case .number(let number): return number == discriminant.number
            case .name(let name): return name == discriminant.enumName
            }
        }?.type ?? choice.fallback
        guard let match else { return "<no case for \(discriminant.enumName ?? String(discriminant.number))>" + rest(end: end) }
        return try render(match, path: path, end: end)
    }

    /// The bytes a switch left unmatched, consumed so the reader still reaches the end.
    private mutating func rest(end: Int) -> String {
        guard offset < end else { return "" }
        let text = " " + hex(offset..<end)
        offset = end
        return text
    }

    private mutating func renderPrimitive(
        _ primitive: BluetoothPacketDefinitions.Primitive, field: BluetoothPacketDefinitions.Field?,
        path: String, end: Int
    ) throws -> String {
        switch primitive {
        case .integer(let width, let signed, let bigEndian):
            let number = try integer(width: width, signed: signed, bigEndian: bigEndian, path: path, end: end)
            return String(number)
        case .float(let width, let bigEndian):
            let raw = try take(width, path: path, end: end)
            let ordered = bigEndian ? Array(raw) : Array(raw.reversed())
            let bits = ordered.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            var value = width == 4 ? Double(Float(bitPattern: UInt32(bits))) : Double(bitPattern: bits)
            if let scale = field?.scale { value *= scale }
            return Self.decimal(value) + (field?.unit ?? "")
        case .bool:
            return try take(1, path: path, end: end).first == 0 ? "false" : "true"
        case .bytes:
            let range = offset..<end
            offset = end
            if let field { keep(.bytes(Array(bytes[range])), path: path, id: field.id) }
            return range.isEmpty ? "<>" : hex(range)
        case .string:
            let slice = bytes[offset..<end]
            offset = end
            let text = String(decoding: slice, as: UTF8.self)
            if let field { keep(.text(text), path: path, id: field.id) }
            return MessagePack.quoted(text)
        case .msgpack:
            var position = offset
            let value: MessagePackValue
            do {
                value = try MessagePack.parse(bytes, offset: &position, end: end)
            } catch let failure as MessagePack.Failure {
                throw Failure(message: "\(path): \(failure.message)")
            }
            offset = position
            if message == nil {
                message = value
                wordEnums = field.map { field in
                    Array(Set(field.captureEnums.values)).sorted() + (field.enumName.map { [$0] } ?? [])
                } ?? []
                captureEnums = field?.captureEnums ?? [:]
            }
            return renderMessagePack(value, field: field)
        }
    }

    // MARK: MessagePack

    private mutating func renderMessagePack(_ value: MessagePackValue, field: BluetoothPacketDefinitions.Field?) -> String {
        let definitions = self.definitions
        let learned = self.learned
        func lookup(_ enumName: String, _ number: Int64) -> String? {
            learned[enumName]?[number] ?? definitions.enums[enumName]?[number]
        }
        let keyName: ((Int64) -> String?)? = field?.enumName.map { enumName in { lookup(enumName, $0) } }
        guard let field, !field.match.isEmpty else { return MessagePack.render(value, keyName: keyName) }
        // A glob such as `map_*` compares an integer by the name one of the bound enums gives it.
        let enums = field.captureEnums.values.sorted()
        let resolve: (Int64) -> String? = { number in
            for enumName in enums { if let found = lookup(enumName, number) { return found } }
            return nil
        }
        for rule in field.match {
            let bindings = rule.pattern.match(value, name: resolve)
            guard let first = bindings.first else { continue }
            ruleLevel = rule.level
            for id in rule.pattern.captures { keepCapture(id, in: first, field: field) }
            var shown: [String] = []
            for binding in bindings.prefix(MessagePack.Limits.renderedItems) {
                shown.append(render(binding, rule: rule, field: field))
            }
            let more = bindings.count - shown.count
            return shown.joined(separator: ", ") + (more > 0 ? ", …+\(more)" : "")
        }
        return MessagePack.render(value, keyName: keyName)
    }

    /// A capture as a named value, for transactions and streams to refer to.
    private mutating func keepCapture(_ id: String, in binding: MessagePackPattern.Binding, field: BluetoothPacketDefinitions.Field) {
        guard let value = binding[id] else { return }
        let kept: BluetoothValue
        switch value {
        case .string(let text): kept = .text(text)
        case .binary(let data): kept = .bytes(data)
        default:
            if let number = value.integer {
                kept = .number(number, name: field.captureEnums[id].flatMap { name($0, number) })
            } else {
                kept = .text(MessagePack.render(value))
            }
        }
        keep(kept, path: id, id: id)
    }

    private mutating func render(
        _ binding: MessagePackPattern.Binding, rule: BluetoothPacketDefinitions.MatchRule,
        field: BluetoothPacketDefinitions.Field
    ) -> String {
        guard let summary = rule.summary else {
            var parts: [String] = []
            for id in rule.pattern.captures { parts.append("\(id)=\(capture(id, in: binding, field: field))") }
            return parts.joined(separator: " ")
        }
        var text = ""
        for part in summary {
            switch part {
            case .text(let literal): text += literal
            case .field(let id): text += capture(id, in: binding, field: field)
            }
        }
        return text
    }

    /// A bound part: by its enum when it has one, shaped when the binding's enum names a shape.
    private mutating func capture(_ id: String, in binding: MessagePackPattern.Binding, field: BluetoothPacketDefinitions.Field) -> String {
        guard let value = binding[id] else { return "" }
        if let enumName = field.captureEnums[id] {
            if let number = value.integer { return named(enumName, number) ?? "\(number)?" }
            if case .string(let text) = value { return text }
            // A captured map or array: the enum names its integer keys, at any depth.
            return MessagePack.render(value, keyName: { [definitions, learned] number in
                learned[enumName]?[number] ?? definitions.enums[enumName]?[number]
            })
        }
        if let set = field.values.flatMap({ definitions.shapes[$0] }) {
            for (other, enumName) in field.captureEnums.sorted(by: { $0.key < $1.key }) where other != id {
                let shapeName: String?
                switch binding[other] {
                case .string(let text)?: shapeName = text
                case let bound?: shapeName = bound.integer.flatMap { name(enumName, $0) }
                case nil: shapeName = nil
                }
                if let shapeName, let positions = set[shapeName] { return Self.shaped(value, positions) }
            }
        }
        return MessagePack.render(value)
    }

    /// `[2026, 10, 13]` with positions `[year, month, date]` → `{year=2026 month=10 date=13}`.
    /// A trailing `...` repeats the group: `{hours=7 minutes=0}, {hours=9 minutes=30}`.
    private static func shaped(_ value: MessagePackValue, _ positions: [String]) -> String {
        guard case .array(let items) = value else {
            return positions.count == 1 ? "{\(positions[0])=\(MessagePack.render(value))}" : MessagePack.render(value)
        }
        if positions.last == BluetoothPacketDefinitions.repeatGroup {
            let group = Array(positions.dropLast())
            var groups: [String] = []
            var index = 0
            while index < items.count, groups.count < MessagePack.Limits.renderedItems {
                let slice = Array(items[index..<min(index + group.count, items.count)])
                groups.append("{" + zip(group, slice).map { "\($0)=\(MessagePack.render($1))" }.joined(separator: " ") + "}")
                index += group.count
            }
            let more = (items.count - index + group.count - 1) / group.count
            return groups.joined(separator: ", ") + (more > 0 ? ", …+\(more)" : "")
        }
        var parts = zip(positions, items).map { "\($0)=\(MessagePack.render($1))" }
        if items.count > positions.count {
            parts.append("+" + MessagePack.render(.array(Array(items.dropFirst(positions.count)))))
        }
        return "{" + parts.joined(separator: " ") + "}"
    }

    private mutating func integer(width: Int, signed: Bool, bigEndian: Bool, path: String, end: Int) throws -> Int64 {
        let raw = try take(width, path: path, end: end)
        let ordered = bigEndian ? Array(raw) : Array(raw.reversed())
        let bits = ordered.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard signed, width < 8 else { return Int64(bitPattern: bits) }
        let shift = UInt64(64 - width * 8)
        return Int64(bitPattern: bits << shift) >> Int64(shift)
    }

    private mutating func take(_ count: Int, path: String, end: Int) throws -> ArraySlice<UInt8> {
        guard end - offset >= count else {
            throw Failure(message: "\(path): needs \(count) bytes, \(max(0, end - offset)) left")
        }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    private func format(number: Int64, signed: Bool, field: BluetoothPacketDefinitions.Field, enumName: String?) -> String {
        // An unsigned u64 above Int64.max arrives as its bit pattern; print it as the author wrote it.
        let raw = signed || number >= 0 ? String(number) : String(UInt64(bitPattern: number))
        if field.enumName != nil {
            return enumName ?? "\(raw)?"
        }
        if !field.flags.isEmpty {
            let set = field.flags.filter { number & (1 << Int64($0.bit)) != 0 }.map(\.name)
            return set.isEmpty ? "none" : set.joined(separator: "|")
        }
        if let scale = field.scale {
            return Self.decimal(Double(number) * scale) + (field.unit ?? "")
        }
        return raw + (field.unit ?? "")
    }

    private func hex(_ range: Range<Int>) -> String {
        let limit = BluetoothPacketDefinitions.Limits.renderedBytes
        let shown = bytes[range].prefix(limit).map { String(format: "%02x", $0) }.joined()
        return "<" + shown + (range.count > limit ? "…+\(range.count - limit)" : "") + ">"
    }

    private static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        var text = String(format: "%.7f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}
