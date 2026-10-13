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
struct BluetoothLearnedEnums: Sendable, Equatable {
    enum Limits {
        static let devices = 64
        static let bytes = 4 * 1_024 * 1_024
    }

    struct Device: Sendable, Equatable {
        var name: String?
        var firmware: String?
        var updated: Date
        var enums: [String: [Int64: String]] = [:]
    }

    private(set) var devices: [String: Device] = [:]

    /// The tables to decode with for a device, falling back as described above.
    func tables(for identity: String?, enums: [String]) -> [String: [Int64: String]] {
        if let identity, let device = devices[identity], !device.enums.isEmpty { return device.enums }
        return latest(having: enums)?.enums ?? [:]
    }

    /// Adds entries; returns whether anything changed.
    mutating func learn(
        _ entries: [(number: Int64, name: String)], enumName: String, identity: String,
        name: String?, firmware: String?, limit: Int, now: Date = Date()
    ) -> Bool {
        var device = devices[identity] ?? Device(name: name, firmware: firmware, updated: now)
        var table = device.enums[enumName] ?? [:]
        var changed = false
        for entry in entries where table[entry.number] != entry.name {
            guard table[entry.number] != nil || table.count < limit else { break }
            table[entry.number] = entry.name
            changed = true
        }
        if let name, device.name != name { device.name = name; changed = true }
        if let firmware, device.firmware != firmware { device.firmware = firmware; changed = true }
        guard changed else { return false }
        device.enums[enumName] = table
        device.updated = now
        devices[identity] = device
        if devices.count > Limits.devices, let oldest = devices.min(by: { $0.value.updated < $1.value.updated })?.key {
            devices[oldest] = nil
        }
        return true
    }

    /// One line for the footer: what the most recent device taught.
    func summary(enums: [String]) -> String? {
        guard let device = latest(having: enums) else { return nil }
        let counts = enums.compactMap { name in device.enums[name].map { "\(name): \($0.count) learned" } }
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

    private struct File: Codable {
        struct Device: Codable {
            var name: String?
            var firmware: String?
            var updated: Date
            /// Enum → number (as text, so the file reads as a table) → name.
            var enums: [String: [String: String]]
        }
        var version = 1
        var devices: [String: Device]
    }

    /// Reads the store; a missing or unreadable file is an empty store, never a failed capture.
    static func load(from url: URL = defaultURL) -> BluetoothLearnedEnums {
        guard let data = try? BoundedFileReader.read(url, maximumBytes: Limits.bytes),
              let file = try? decoder.decode(File.self, from: data) else { return .init() }
        var store = BluetoothLearnedEnums()
        for (identity, device) in file.devices.prefix(Limits.devices) {
            var enums: [String: [Int64: String]] = [:]
            for (name, table) in device.enums.prefix(BluetoothPacketDefinitions.Limits.learners) {
                var entries: [Int64: String] = [:]
                for (number, value) in table.prefix(BluetoothPacketDefinitions.Limits.enumCases) {
                    if let number = Int64(number) { entries[number] = value }
                }
                enums[name] = entries
            }
            store.devices[identity] = Device(name: device.name, firmware: device.firmware, updated: device.updated, enums: enums)
        }
        return store
    }

    func save(to url: URL = defaultURL) throws {
        let file = File(devices: devices.mapValues { device in
            File.Device(
                name: device.name, firmware: device.firmware, updated: device.updated,
                enums: device.enums.mapValues { table in
                    Dictionary(uniqueKeysWithValues: table.map { (String($0.key), $0.value) })
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
