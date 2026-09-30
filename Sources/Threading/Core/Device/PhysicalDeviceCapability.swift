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
