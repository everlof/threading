import Foundation
import ThreadingDesignKit

/// One GATT server's attribute table, as discovery revealed it.
///
/// iOS caches the tables of bonded devices and almost never rediscovers them, so a capture that
/// starts after the app connected sees bare handles. Every discovery that passes through is kept
/// here and reused when a later capture has none.
struct BluetoothGATTTable: Sendable, Equatable {
    struct Service: Sendable, Equatable, Codable {
        var start: Int
        var end: Int
        var uuid: String
    }

    struct Characteristic: Sendable, Equatable, Codable {
        var declaration: Int
        var value: Int
        var properties: UInt8
        var uuid: String
    }

    /// What a packet did to an attribute, checked against its declared properties.
    enum Operation: Sendable {
        case read, write, writeWithoutResponse, signedWrite, notify, indicate
    }

    static let attributeLimit = 1_024

    private(set) var services: [Service] = []
    private(set) var characteristics: [Int: Characteristic] = [:]
    private(set) var descriptors: [Int: String] = [:]

    var attributeCount: Int { characteristics.count + descriptors.count }
    var isEmpty: Bool { characteristics.isEmpty && descriptors.isEmpty && services.isEmpty }

    func uuid(for handle: Int) -> String? { characteristics[handle]?.uuid ?? descriptors[handle] }

    /// Whether this table could have produced that operation on that handle.
    func fits(_ handle: Int, _ operation: Operation) -> Bool {
        if let characteristic = characteristics[handle] {
            let properties = characteristic.properties
            switch operation {
            case .read: return properties & 0x02 != 0
            case .write, .writeWithoutResponse: return properties & 0x0c != 0
            case .signedWrite: return properties & 0x40 != 0
            case .notify: return properties & 0x10 != 0
            case .indicate: return properties & 0x20 != 0
            }
        }
        if descriptors[handle] != nil {
            switch operation {
            case .read, .write, .writeWithoutResponse: return true
            default: return false
            }
        }
        return false
    }

    /// A (re)discovered service replaces what was known inside its range, and only that: iOS
    /// often rediscovers a single service.
    mutating func discover(service: Service) {
        drop(service.start...service.end)
        services.removeAll { $0.start <= service.end && service.start <= $0.end }
        services.append(service)
        services.sort { $0.start < $1.start }
    }

    mutating func discover(_ characteristic: Characteristic) {
        guard characteristics[characteristic.value] != nil || attributeCount < Self.attributeLimit else { return }
        characteristics[characteristic.value] = characteristic
        descriptors[characteristic.value] = nil
    }

    mutating func discover(descriptor handle: Int, uuid: String) {
        // Find Information lists every attribute; declarations and values are not descriptors.
        guard characteristics[handle] == nil,
              !characteristics.values.contains(where: { $0.declaration == handle }),
              !services.contains(where: { $0.start == handle }),
              !["2800", "2801", "2802", "2803"].contains(uuid),
              descriptors[handle] != nil || attributeCount < Self.attributeLimit else { return }
        descriptors[handle] = uuid
    }

    /// Service Changed: everything in the range is unknown again.
    mutating func drop(_ range: ClosedRange<Int>) {
        characteristics = characteristics.filter { !range.contains($0.key) && !range.contains($0.value.declaration) }
        descriptors = descriptors.filter { !range.contains($0.key) }
    }

    // MARK: Disk form

    struct File: Codable {
        var services: [Service]
        var characteristics: [Characteristic]
        var descriptors: [Descriptor]
        struct Descriptor: Codable { var handle: Int; var uuid: String }
    }

    var file: File {
        File(services: services,
             characteristics: characteristics.values.sorted { $0.value < $1.value },
             descriptors: descriptors.map { .init(handle: $0.key, uuid: $0.value) }.sorted { $0.handle < $1.handle })
    }

    init() {}

    init(file: File) {
        services = Array(file.services.prefix(Self.attributeLimit))
        for characteristic in file.characteristics.prefix(Self.attributeLimit) { discover(characteristic) }
        for descriptor in file.descriptors.prefix(Self.attributeLimit) where attributeCount < Self.attributeLimit {
            descriptors[descriptor.handle] = descriptor.uuid
        }
    }
}

/// Every remembered table, per device, kept across captures next to the learned enums.
///
/// The peripheral's table is stored under the device's identity; the iPhone's own (ANCS and the
/// like) under the phone being captured, because it is the same for every peer. Bounded like the
/// learned-enum store, and a damaged file reads as empty.
struct BluetoothGATTTables: Sendable, Equatable {
    enum Limits {
        static let devices = 64
        static let bytes = 8 * 1_024 * 1_024
    }

    struct Device: Sendable, Equatable {
        var name: String?
        var firmware: String?
        var databaseHash: String?
        var updated: Date
        /// The firmware changed since the table was recorded; still used until traffic disagrees.
        var stale = false
        var isPhone = false
        var table = BluetoothGATTTable()
    }

    private(set) var devices: [String: Device] = [:]

    subscript(identity: String) -> Device? { devices[identity] }

    /// Changes one device's entry, creating it, and keeps the store bounded.
    mutating func update(_ identity: String, isPhone: Bool = false, now: Date = Date(), _ change: (inout Device) -> Void) {
        var device = devices[identity] ?? Device(updated: now, isPhone: isPhone)
        let before = device
        change(&device)
        guard device != before else { return }
        device.updated = now
        devices[identity] = device
        if devices.count > Limits.devices, let oldest = devices.min(by: { $0.value.updated < $1.value.updated })?.key {
            devices[oldest] = nil
        }
    }

    /// Peripheral tables, most recently updated first: the candidates for a connection that
    /// started before the capture did.
    var peripheralIdentities: [String] {
        devices.filter { !$0.value.isPhone && !$0.value.table.isEmpty }
            .sorted { $0.value.updated > $1.value.updated }
            .map(\.key)
    }

    // MARK: Disk

    static var defaultURL: URL {
        BluetoothLearnedEnums.defaultURL.deletingLastPathComponent().appendingPathComponent("bluetooth-gatt-tables.json")
    }

    private struct File: Codable {
        struct Device: Codable {
            var name: String?
            var firmware: String?
            var databaseHash: String?
            var updated: Date
            var stale: Bool
            var isPhone: Bool
            var table: BluetoothGATTTable.File
        }
        var version = 1
        var devices: [String: Device]
    }

    static func load(from url: URL = defaultURL) -> BluetoothGATTTables {
        guard let data = try? BoundedFileReader.read(url, maximumBytes: Limits.bytes),
              let file = try? decoder.decode(File.self, from: data) else { return .init() }
        var tables = BluetoothGATTTables()
        for (identity, device) in file.devices.prefix(Limits.devices) {
            tables.devices[identity] = Device(
                name: device.name, firmware: device.firmware, databaseHash: device.databaseHash,
                updated: device.updated, stale: device.stale, isPhone: device.isPhone,
                table: BluetoothGATTTable(file: device.table)
            )
        }
        return tables
    }

    func save(to url: URL = defaultURL) throws {
        let file = File(devices: devices.mapValues {
            File.Device(name: $0.name, firmware: $0.firmware, databaseHash: $0.databaseHash, updated: $0.updated,
                        stale: $0.stale, isPhone: $0.isPhone, table: $0.table.file)
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
