import Foundation
import ThreadingDesignKit

/// Enum entries devices taught in their own traffic, per device, kept across captures.
///
/// A watch may publish its own number → name table (Anima's `map_cmd` pages), and the numbers can
/// differ per firmware. The app caches the table after the first connection, so the exchange
/// crosses the air once; a capture after pairing could not be decoded unless Threading remembers
/// what it saw. The entries belong to one device's firmware rather than to the project, so they
/// live here and never in the YAML.
///
/// A device is identified by the most stable thing the capture says about it: its address from the
/// connection, else its name. A capture that starts mid-connection has neither, so lookups fall
/// back to the device that taught that enum most recently — right for the usual one-watch desk.
///
/// Tables are kept per firmware build, because a build may renumber: a firmware that numbers every
/// name from one counter renumbers whenever a build compiles in a different set of features.
struct BluetoothLearnedEnums: Sendable, Equatable {
    enum Limits {
        static let devices = 64
        /// Firmware builds remembered per device; the oldest is forgotten first.
        static let builds = 4
        static let bytes = 4 * 1_024 * 1_024
    }

    struct Device: Sendable, Equatable {
        var name: String?
        /// The build most recently seen; its tables are the device's current ones.
        var firmware: String?
        var updated: Date
        /// Firmware revision ("" when the capture never read one) → enum → number → name. A new
        /// build may renumber everything, so one build's names never decode another's numbers.
        var builds: [String: [String: [Int64: String]]] = [:]
        var buildOrder: [String] = []

        var enums: [String: [Int64: String]] {
            builds[firmware ?? ""] ?? buildOrder.last.flatMap { builds[$0] } ?? [:]
        }
    }

    private(set) var devices: [String: Device] = [:]

    /// The tables to decode with for a device, falling back as described above. A device on a
    /// firmware it has not taught yet gets none: raw numbers are better than wrong names.
    func tables(for identity: String?, firmware: String? = nil, enums: [String]) -> [String: [Int64: String]] {
        if let identity, let device = devices[identity] {
            if let firmware { return device.builds[firmware] ?? [:] }
            if !device.enums.isEmpty { return device.enums }
        }
        return latest(having: enums)?.enums ?? [:]
    }

    /// Adds entries under the device's firmware (the one it last reported when the capture did
    /// not read it); returns whether anything changed.
    mutating func learn(
        _ entries: [(number: Int64, name: String)], enumName: String, identity: String,
        name: String?, firmware: String?, limit: Int, now: Date = Date()
    ) -> Bool {
        var device = devices[identity] ?? Device(name: name, firmware: firmware, updated: now)
        let build = firmware ?? device.firmware ?? ""
        var tables = device.builds[build] ?? [:]
        var table = tables[enumName] ?? [:]
        var changed = false
        for entry in entries where table[entry.number] != entry.name {
            guard table[entry.number] != nil || table.count < limit else { break }
            table[entry.number] = entry.name
            changed = true
        }
        if let name, device.name != name { device.name = name; changed = true }
        if let firmware, device.firmware != firmware { device.firmware = firmware; changed = true }
        guard changed else { return false }
        tables[enumName] = table
        device.builds[build] = tables
        device.buildOrder.removeAll { $0 == build }
        device.buildOrder.append(build)
        while device.buildOrder.count > Limits.builds { device.builds[device.buildOrder.removeFirst()] = nil }
        device.updated = now
        devices[identity] = device
        if devices.count > Limits.devices, let oldest = devices.min(by: { $0.value.updated < $1.value.updated })?.key {
            devices[oldest] = nil
        }
        return true
    }

    /// Tables learned before the capture read the device's firmware belong to that firmware:
    /// the capture only learns the revision later. Returns whether anything moved.
    mutating func adopt(identity: String, firmware: String) -> Bool {
        guard var device = devices[identity], let unknown = device.builds[""], device.builds[firmware] == nil else {
            return false
        }
        device.builds[""] = nil
        device.builds[firmware] = unknown
        device.buildOrder = device.buildOrder.map { $0 == "" ? firmware : $0 }
        device.firmware = firmware
        devices[identity] = device
        return true
    }

    /// One line for the footer: what the device being captured taught, or — when its firmware
    /// has not taught anything yet — that its numbers show raw until it does.
    func summary(enums: [String], identity: String? = nil, firmware: String? = nil) -> String? {
        if let identity, let firmware, let device = devices[identity], device.builds[firmware] == nil,
           let known = device.buildOrder.last.flatMap({ device.builds[$0] }), !known.isEmpty {
            let names = enums.filter { known[$0] != nil }.joined(separator: ", ")
            return "\(names): nothing learned from fw \(firmware) yet — numbers show raw until the device teaches them"
        }
        let device = identity.flatMap { devices[$0] }.flatMap { $0.enums.isEmpty ? nil : $0 } ?? latest(having: enums)
        guard let device else { return nil }
        let current = device.enums
        let counts = enums.compactMap { name in current[name].map { "\(name): \($0.count) learned" } }
        guard !counts.isEmpty else { return nil }
        let who = [device.name, device.firmware.map { "fw \($0)" }].compactMap { $0 }.joined(separator: ", ")
        return counts.joined(separator: ", ") + (who.isEmpty ? "" : " (\(who))")
    }

    /// Every enum case name the file declares plus what the most recent device taught, bounded.
    func names(definitions: BluetoothPacketDefinitions?) -> Set<String> {
        guard let definitions else { return [] }
        var names = Set(definitions.enums.values.flatMap(\.values))
        if let device = latest(having: definitions.learnedEnumNames) {
            for table in device.enums.values { names.formUnion(table.values) }
        }
        return names.count <= BluetoothPacketDefinitions.Limits.enumCases * 2 ? names : []
    }

    private func latest(having enums: [String]) -> Device? {
        devices.values
            .filter { device in enums.contains { device.enums[$0]?.isEmpty == false } }
            .max { $0.updated < $1.updated }
    }

    // MARK: Disk

    /// Application Support rather than Caches: unlike a log, this cannot be rebuilt by watching
    /// again — the device only sends its table while pairing.
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("codes.threading", isDirectory: true)
            .appendingPathComponent("DeviceLogs", isDirectory: true)
            .appendingPathComponent("bluetooth-learned-enums.json")
    }

    /// Enum → number (as text, so the file reads as a table) → name.
    private typealias FileTables = [String: [String: String]]

    private struct File: Codable {
        struct Device: Codable {
            var name: String?
            var firmware: String?
            var updated: Date
            /// Version 2: per firmware, oldest first.
            var builds: [Build]?
            /// Version 1: one set of tables, read as the device's current firmware's.
            var enums: FileTables?
        }
        struct Build: Codable {
            var firmware: String
            var enums: FileTables
        }
        var version = 2
        var devices: [String: Device]
    }

    /// Reads the store; a missing or unreadable file is an empty store, never a failed capture.
    static func load(from url: URL = defaultURL) -> BluetoothLearnedEnums {
        guard let data = try? BoundedFileReader.read(url, maximumBytes: Limits.bytes),
              let file = try? decoder.decode(File.self, from: data) else { return .init() }
        func tables(_ file: FileTables) -> [String: [Int64: String]] {
            var enums: [String: [Int64: String]] = [:]
            for (name, table) in file.prefix(BluetoothPacketDefinitions.Limits.learners) {
                var entries: [Int64: String] = [:]
                for (number, value) in table.prefix(BluetoothPacketDefinitions.Limits.enumCases) {
                    if let number = Int64(number) { entries[number] = value }
                }
                enums[name] = entries
            }
            return enums
        }
        var store = BluetoothLearnedEnums()
        for (identity, saved) in file.devices.prefix(Limits.devices) {
            var device = Device(name: saved.name, firmware: saved.firmware, updated: saved.updated)
            let builds = saved.builds ?? saved.enums.map { [File.Build(firmware: saved.firmware ?? "", enums: $0)] } ?? []
            for build in builds.suffix(Limits.builds) {
                device.builds[build.firmware] = tables(build.enums)
                device.buildOrder.append(build.firmware)
            }
            store.devices[identity] = device
        }
        return store
    }

    func save(to url: URL = defaultURL) throws {
        let file = File(devices: devices.mapValues { device in
            File.Device(
                name: device.name, firmware: device.firmware, updated: device.updated,
                builds: device.buildOrder.compactMap { firmware in
                    device.builds[firmware].map { tables in
                        File.Build(firmware: firmware, enums: tables.mapValues { table in
                            Dictionary(uniqueKeysWithValues: table.map { (String($0.key), $0.value) })
                        })
                    }
                }
            )
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url, options: .atomic)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension BluetoothPacketDefinitions {
    /// The enums a device can teach, by name.
    var learnedEnumNames: [String] { learners.map(\.enumName) }

    /// Entries a received value teaches, per enum. Only a value of a characteristic named in a
    /// `learn: from:`, parsed as one MessagePack value; a binary table is not learnable yet.
    func lessons(
        from characteristic: String, value: [UInt8], known: [String: [Int64: String]]
    ) -> [(enumName: String, entries: [(number: Int64, name: String)])] {
        var lessons: [(String, [(Int64, String)])] = []
        let relevant = learners.filter { $0.from == characteristic }
        guard !relevant.isEmpty else { return [] }
        var offset = 0
        guard let parsed = try? MessagePack.parse(value, offset: &offset, end: value.count) else { return [] }
        // Learners run in file order over one shared view, so entries one learns from this value
        // already name the words of the next — the command map names the settings map.
        var current = known
        for learner in relevant {
            var table = current[learner.enumName] ?? [:]
            let bindings = learner.pattern.match(parsed) { number in
                current[learner.names]?[number] ?? enums[learner.names]?[number]
            }
            var entries: [(Int64, String)] = []
            for binding in bindings {
                guard let number = binding["number"]?.integer, case .string(let name)? = binding["name"],
                      !name.isEmpty, name.count <= Limits.learnedNameCharacters,
                      name.allSatisfy({ !$0.isNewline && !$0.isWhitespace }) else { continue }
                entries.append((number, name))
                table[number] = name
            }
            current[learner.enumName] = table
            if !entries.isEmpty { lessons.append((learner.enumName, entries)) }
        }
        return lessons
    }
}
