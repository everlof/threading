import Foundation

// MARK: - Identity

/// The canonical CoreSimulator device identifier.
///
/// Keeping this distinct from session, project and tab UUIDs prevents an agent-facing device
/// argument from being routed through the wrong identity namespace. Decoding re-enters the
/// validating initializer so persisted or wire values cannot bypass the UUID invariant.
struct SimulatorDeviceID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init?(_ rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.rawValue = uuid.uuidString
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = SimulatorDeviceID(rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A simulator device id must be a UUID."
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

enum SimulatorDeviceState: Equatable, Sendable {
    case shutdown
    case booting
    case booted
    case shuttingDown
    case creating
    case unknown(String)

    init(simctlValue: String) {
        switch simctlValue.lowercased() {
        case "shutdown": self = .shutdown
        case "booting": self = .booting
        case "booted": self = .booted
        case "shutting down": self = .shuttingDown
        case "creating": self = .creating
        default: self = .unknown(simctlValue)
        }
    }

    var isBooted: Bool { self == .booted }
}

enum SimulatorDeviceFamily: String, Equatable, Codable, Sendable {
    case iPhone
    case iPad
    case other

    init(deviceTypeIdentifier: String) {
        if deviceTypeIdentifier.contains(".iPhone-") {
            self = .iPhone
        } else if deviceTypeIdentifier.contains(".iPad-") {
            self = .iPad
        } else {
            self = .other
        }
    }
}

struct SimulatorDevice: Equatable, Sendable, Identifiable {
    let id: SimulatorDeviceID
    let name: String
    let runtimeIdentifier: String
    let runtimeName: String
    let deviceTypeIdentifier: String
    let family: SimulatorDeviceFamily
    let state: SimulatorDeviceState
    let lastBootedAt: Date?

    func withState(_ state: SimulatorDeviceState) -> SimulatorDevice {
        SimulatorDevice(
            id: id,
            name: name,
            runtimeIdentifier: runtimeIdentifier,
            runtimeName: runtimeName,
            deviceTypeIdentifier: deviceTypeIdentifier,
            family: family,
            state: state,
            lastBootedAt: lastBootedAt
        )
    }
}

// MARK: - Catalog

/// The bounded translation from `simctl list devices available --json` into app-owned values.
enum SimulatorDeviceCatalog {
    private struct Envelope: Decodable {
        let devices: [String: [WireDevice]]
    }

    private struct WireDevice: Decodable {
        let udid: String
        let isAvailable: Bool
        let deviceTypeIdentifier: String
        let state: String
        let name: String
        let lastBootedAt: String?
    }

    static func decodeAvailableIOSDevices(
        from data: Data,
        maximumDevices: Int = SimulatorControlDefaults.maximumDeviceCount
    ) throws -> [SimulatorDevice] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw SimulatorControlError.invalidResponse(
                "CoreSimulator returned a device list Threading could not read."
            )
        }

        let iosRuntimes = envelope.devices.filter { runtimeIdentifier, _ in
            runtimeIdentifier.hasPrefix(SimulatorControlDefaults.iosRuntimePrefix)
        }
        let deviceCount = iosRuntimes.reduce(into: 0) { count, entry in
            count += entry.value.count
        }
        guard deviceCount <= maximumDevices else {
            throw SimulatorControlError.tooManyDevices(maximum: maximumDevices)
        }

        let dateFormatter = ISO8601DateFormatter()
        var result: [SimulatorDevice] = []
        result.reserveCapacity(deviceCount)

        for (runtimeIdentifier, devices) in iosRuntimes {
            let runtimeName = displayName(forRuntimeIdentifier: runtimeIdentifier)
            for device in devices where device.isAvailable {
                guard let id = SimulatorDeviceID(device.udid),
                      !device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !device.deviceTypeIdentifier.isEmpty else {
                    throw SimulatorControlError.invalidResponse(
                        "CoreSimulator returned an invalid iOS device record."
                    )
                }
                result.append(SimulatorDevice(
                    id: id,
                    name: device.name,
                    runtimeIdentifier: runtimeIdentifier,
                    runtimeName: runtimeName,
                    deviceTypeIdentifier: device.deviceTypeIdentifier,
                    family: SimulatorDeviceFamily(
                        deviceTypeIdentifier: device.deviceTypeIdentifier
                    ),
                    state: SimulatorDeviceState(simctlValue: device.state),
                    lastBootedAt: device.lastBootedAt.flatMap(dateFormatter.date(from:))
                ))
            }
        }

        return result.sorted(by: precedes)
    }

    private static func displayName(forRuntimeIdentifier identifier: String) -> String {
        let suffix = identifier.dropFirst(SimulatorControlDefaults.iosRuntimePrefix.count)
        return "iOS " + suffix.replacingOccurrences(of: "-", with: ".")
    }

    private static func precedes(_ lhs: SimulatorDevice, _ rhs: SimulatorDevice) -> Bool {
        if lhs.state.isBooted != rhs.state.isBooted { return lhs.state.isBooted }
        if lhs.family != rhs.family {
            return familyRank(lhs.family) < familyRank(rhs.family)
        }
        if lhs.lastBootedAt != rhs.lastBootedAt {
            return (lhs.lastBootedAt ?? .distantPast) > (rhs.lastBootedAt ?? .distantPast)
        }
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private static func familyRank(_ family: SimulatorDeviceFamily) -> Int {
        switch family {
        case .iPhone: return 0
        case .iPad: return 1
        case .other: return 2
        }
    }
}
