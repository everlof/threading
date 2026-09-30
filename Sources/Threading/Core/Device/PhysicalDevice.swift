import Foundation

// MARK: - Identity

/// The hardware UDID CoreDevice and libimobiledevice use for one physical Apple device.
///
/// This is deliberately distinct from CoreDevice's own UUID-shaped catalogue identifier. The
/// hardware UDID is accepted by both `devicectl --device` and `idevicescreenshot --udid`, so the
/// pane never translates through a name or another mutable identity before acting on a phone.
struct PhysicalDeviceID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init?(_ rawValue: String) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard (8...128).contains(rawValue.utf8.count),
              rawValue.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = PhysicalDeviceID(rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A physical device id must be a hardware UDID."
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }
}

// MARK: - Device

enum PhysicalDeviceConnection: String, Codable, Sendable {
    case usb
    case localNetwork
    case unknown

    init(devicectlValue: String?) {
        switch devicectlValue?.lowercased() {
        case "usb", "wired": self = .usb
        case "localnetwork", "local_network", "wifi", "wi-fi": self = .localNetwork
        default: self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .usb: return "USB"
        case .localNetwork: return "Wi-Fi"
        case .unknown: return "Paired"
        }
    }
}

struct PhysicalDevice: Equatable, Sendable, Identifiable {
    let id: PhysicalDeviceID
    let coreDeviceIdentifier: UUID
    let name: String
    let productType: String
    let osVersion: String
    let connection: PhysicalDeviceConnection
    let developerModeEnabled: Bool
    let developerServicesAvailable: Bool

    var runtimeName: String {
        osVersion.isEmpty ? "iOS" : "iOS \(osVersion)"
    }
}

// MARK: - CoreDevice catalogue

/// The bounded translation from `xcrun devicectl list devices --json-output` into app-owned
/// values. CoreDevice retains old pairings, so only currently reachable, paired iPhones enter the
/// pane. Today a reachable network device is reported with a disconnected tunnel; unavailable is
/// the historical/offline state.
enum PhysicalDeviceCatalog {
    private struct Envelope: Decodable {
        let result: Result
    }

    private struct Result: Decodable {
        let devices: [WireDevice]
    }

    private struct WireDevice: Decodable {
        let identifier: String
        let connectionProperties: ConnectionProperties
        let deviceProperties: DeviceProperties
        let hardwareProperties: HardwareProperties
    }

    private struct ConnectionProperties: Decodable {
        let pairingState: String?
        let transportType: String?
        let tunnelState: String?
    }

    private struct DeviceProperties: Decodable {
        let name: String
        let osVersionNumber: String?
        let developerModeStatus: String?
        let ddiServicesAvailable: Bool?
    }

    private struct HardwareProperties: Decodable {
        let deviceType: String?
        let platform: String?
        let productType: String?
        let udid: String
    }

    static func decodeAvailableIPhones(
        from data: Data,
        maximumDevices: Int = PhysicalDeviceDefaults.maximumDeviceCount
    ) throws -> [PhysicalDevice] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw PhysicalDeviceControlError.invalidResponse(
                "CoreDevice returned a device list Threading could not read."
            )
        }

        guard envelope.result.devices.count <= maximumDevices else {
            throw PhysicalDeviceControlError.tooManyDevices(maximum: maximumDevices)
        }

        var result: [PhysicalDevice] = []
        result.reserveCapacity(envelope.result.devices.count)
        for wire in envelope.result.devices {
            guard wire.hardwareProperties.deviceType?.lowercased() == "iphone",
                  wire.hardwareProperties.platform?.lowercased() == "ios",
                  wire.connectionProperties.pairingState?.lowercased() == "paired",
                  wire.connectionProperties.tunnelState?.lowercased() != "unavailable"
            else { continue }

            let name = wire.deviceProperties.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  let id = PhysicalDeviceID(wire.hardwareProperties.udid),
                  let coreDeviceIdentifier = UUID(uuidString: wire.identifier)
            else {
                throw PhysicalDeviceControlError.invalidResponse(
                    "CoreDevice returned an invalid iPhone record."
                )
            }

            result.append(PhysicalDevice(
                id: id,
                coreDeviceIdentifier: coreDeviceIdentifier,
                name: name,
                productType: wire.hardwareProperties.productType ?? "iPhone",
                osVersion: wire.deviceProperties.osVersionNumber ?? "",
                connection: PhysicalDeviceConnection(
                    devicectlValue: wire.connectionProperties.transportType
                ),
                developerModeEnabled:
                    wire.deviceProperties.developerModeStatus?.lowercased() == "enabled",
                developerServicesAvailable: wire.deviceProperties.ddiServicesAvailable ?? false
            ))
        }

        return result.sorted(by: precedes)
    }

    private static func precedes(_ lhs: PhysicalDevice, _ rhs: PhysicalDevice) -> Bool {
        if lhs.connection != rhs.connection {
            return connectionRank(lhs.connection) < connectionRank(rhs.connection)
        }
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private static func connectionRank(_ connection: PhysicalDeviceConnection) -> Int {
        switch connection {
        case .usb: return 0
        case .localNetwork: return 1
        case .unknown: return 2
        }
    }
}
