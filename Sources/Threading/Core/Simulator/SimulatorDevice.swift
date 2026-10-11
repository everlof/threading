import Foundation

// MARK: - Identity

/// The exact identity of one device a Simulator workspace can adopt.
///
/// An iOS Simulator is its canonical CoreSimulator UUID, stored bare so every value persisted
/// before Android existed still decodes to the same device. An Android emulator is its AVD name
/// (`android-avd:<name>`), which is stable across boots the way a UDID is, while its adb serial
/// is not; a USB Android device is its adb serial (`android-usb:<serial>`).
///
/// Keeping this distinct from session, project and tab UUIDs prevents an agent-facing device
/// argument from being routed through the wrong identity namespace. Decoding re-enters the
/// validating initializer so persisted or wire values cannot bypass the invariant.
struct SimulatorDeviceID: Hashable, Codable, Sendable, CustomStringConvertible {
    static let androidEmulatorPrefix = "android-avd:"
    static let androidDevicePrefix = "android-usb:"
    /// AVD names and adb serials are short ASCII tokens; anything else is not one we produced.
    static let maximumAndroidNameLength = 128

    let rawValue: String

    init?(_ rawValue: String) {
        if let uuid = UUID(uuidString: rawValue) {
            self.rawValue = uuid.uuidString
            return
        }
        for prefix in [Self.androidEmulatorPrefix, Self.androidDevicePrefix]
        where rawValue.hasPrefix(prefix) {
            guard Self.isValidAndroidName(String(rawValue.dropFirst(prefix.count))) else { return nil }
            self.rawValue = rawValue
            return
        }
        return nil
    }

    static func androidEmulator(avdName: String) -> SimulatorDeviceID? {
        SimulatorDeviceID(androidEmulatorPrefix + avdName)
    }

    static func androidDevice(serial: String) -> SimulatorDeviceID? {
        SimulatorDeviceID(androidDevicePrefix + serial)
    }

    var platform: SimulatorDevicePlatform {
        if rawValue.hasPrefix(Self.androidEmulatorPrefix) { return .androidEmulator }
        if rawValue.hasPrefix(Self.androidDevicePrefix) { return .androidDevice }
        return .iOSSimulator
    }

    /// The AVD name or adb serial for an Android identity; nil for an iOS Simulator.
    var androidName: String? {
        switch platform {
        case .iOSSimulator: return nil
        case .androidEmulator: return String(rawValue.dropFirst(Self.androidEmulatorPrefix.count))
        case .androidDevice: return String(rawValue.dropFirst(Self.androidDevicePrefix.count))
        }
    }

    private static func isValidAndroidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maximumAndroidNameLength else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._:-".unicodeScalars.contains(scalar))
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = SimulatorDeviceID(rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A simulator device id must be a UUID or an Android device id."
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

/// Which control plane owns a device. Derived from the identity, never stored beside it, so the
/// two cannot disagree.
enum SimulatorDevicePlatform: String, Equatable, Codable, Sendable, CaseIterable {
    case iOSSimulator = "ios"
    case androidEmulator = "android-emulator"
    case androidDevice = "android-device"

    var isAndroid: Bool { self != .iOSSimulator }
}

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
    case androidPhone
    case androidTablet
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
    /// Why a listed device cannot be adopted (an Android phone that has not authorized this Mac's
    /// debugging key, say). Nil for a device that can be prepared.
    var unavailableReason: String? = nil

    var platform: SimulatorDevicePlatform { id.platform }
    var isAdoptable: Bool { unavailableReason == nil }

    func withState(_ state: SimulatorDeviceState) -> SimulatorDevice {
        SimulatorDevice(
            id: id,
            name: name,
            runtimeIdentifier: runtimeIdentifier,
            runtimeName: runtimeName,
            deviceTypeIdentifier: deviceTypeIdentifier,
            family: family,
            state: state,
            lastBootedAt: lastBootedAt,
            unavailableReason: unavailableReason
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
        case .androidPhone: return 2
        case .androidTablet: return 3
        case .other: return 4
        }
    }
}
