import Foundation

enum PhysicalDeviceControlSupport: Equatable, Sendable {
    case unknown(PhysicalDeviceControlSupportUnknownReason)
    case unavailable(PhysicalDeviceControlLimitation)
    case available(supportedMediaFeatures: UInt64)
}

enum PhysicalDeviceControlSupportUnknownReason: Equatable, Sendable {
    case probeToolUnavailable
    case probeVersionUnsupported
    case probeFailed
}

enum PhysicalDeviceControlLimitation: Equatable, Sendable {
    case mediaStreamingUnavailable
    case mainTouchscreenUnavailable
}

enum PhysicalDeviceInput: Equatable, Sendable {
    case tap(x: Double, y: Double)
    case drag(fromX: Double, fromY: Double, toX: Double, toY: Double)
    case touchDown(x: Double, y: Double)
    case touchMove(x: Double, y: Double)
    case touchUp(x: Double, y: Double)
    /// One USB HID keyboard usage. Text is translated before it reaches the helper, so the
    /// private pipe never carries the characters the user typed or accepts command-shaped text.
    case key(usage: UInt8, shift: Bool)
}

/// The virtual keyboard currently models the printable US HID layout plus editing keys that
/// `SimulatorScreenView` emits directly. Unsupported Unicode fails as one event instead of
/// partially typing a composed character into hardware.
enum PhysicalDeviceKeyboard {
    static func inputs(for text: String) throws -> [PhysicalDeviceInput] {
        try text.unicodeScalars.map { scalar in
            let value = scalar.value
            switch value {
            case 8: return .key(usage: 0x2A, shift: false) // Backspace
            case 9: return .key(usage: 0x2B, shift: false) // Tab
            case 10, 13: return .key(usage: 0x28, shift: false) // Return
            case 32: return .key(usage: 0x2C, shift: false) // Space
            case 65...90: return .key(usage: UInt8(value - 65 + 0x04), shift: true)
            case 97...122: return .key(usage: UInt8(value - 97 + 0x04), shift: false)
            case 49...57: return .key(usage: UInt8(value - 49 + 0x1E), shift: false)
            case 48: return .key(usage: 0x27, shift: false)
            default:
                guard let mapped = punctuation[value] else {
                    throw PhysicalDeviceControlError.invalidInput
                }
                return .key(usage: mapped.usage, shift: mapped.shift)
            }
        }
    }

    private static let punctuation: [UInt32: (usage: UInt8, shift: Bool)] = [
        33: (0x1E, true), 64: (0x1F, true), 35: (0x20, true), 36: (0x21, true),
        37: (0x22, true), 94: (0x23, true), 38: (0x24, true), 42: (0x25, true),
        40: (0x26, true), 41: (0x27, true),
        45: (0x2D, false), 95: (0x2D, true), 61: (0x2E, false), 43: (0x2E, true),
        91: (0x2F, false), 123: (0x2F, true), 93: (0x30, false), 125: (0x30, true),
        92: (0x31, false), 124: (0x31, true), 59: (0x33, false), 58: (0x33, true),
        39: (0x34, false), 34: (0x34, true), 96: (0x35, false), 126: (0x35, true),
        44: (0x36, false), 60: (0x36, true), 46: (0x37, false), 62: (0x37, true),
        47: (0x38, false), 63: (0x38, true),
    ]
}

/// Pure parsing for the bounded `pymobiledevice3` probe outputs.
///
/// Capability checks call the concrete DisplayService and Universal HID operations instead of
/// inferring support from RSD's advertised service-name dictionary. iOS 27 can provide the
/// operations without listing the legacy raw names that older probes expected.
enum PhysicalDeviceCapabilityProbe {
    static let minimumToolVersion = [11, 13, 1]
    static let mainTouchscreenServiceID: UInt64 = 257

    private struct MediaSupportResponse: Decodable {
        let supportedFeatures: UInt64
    }

    static func toolVersionIsSupported(_ data: Data) -> Bool? {
        let rawVersion = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = rawVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= minimumToolVersion.count else { return nil }

        let numericComponents = components.prefix(minimumToolVersion.count).map { component in
            Int(component.prefix(while: \Character.isNumber))
        }
        guard numericComponents.allSatisfy({ $0 != nil }) else { return nil }
        let version = numericComponents.compactMap { $0 }
        return version.lexicographicallyPrecedes(minimumToolVersion) == false
    }

    static func supportedMediaFeatures(from data: Data) throws -> UInt64 {
        try JSONDecoder().decode(MediaSupportResponse.self, from: data).supportedFeatures
    }

    static func hasMainTouchscreen(from data: Data) throws -> Bool {
        let object = try JSONSerialization.jsonObject(with: data)
        return containsMainTouchscreen(in: object)
    }

    private static func containsMainTouchscreen(in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let serviceID = dictionary["_ServiceID"] as? NSNumber,
               serviceID.uint64Value == mainTouchscreenServiceID {
                return true
            }
            return dictionary.values.contains(where: containsMainTouchscreen)
        }
        if let values = value as? [Any] {
            return values.contains(where: containsMainTouchscreen)
        }
        return false
    }
}
