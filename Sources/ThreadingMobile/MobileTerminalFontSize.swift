import CoreGraphics
import Foundation

/// The device-local type-size contract for the iPhone terminal.
///
/// Pinches arrive much more frequently than a terminal grid should be resized. Quantizing the
/// gesture to whole-point steps keeps the interaction responsive while bounding renderer and PTY
/// work to the number of sizes actually crossed.
enum MobileTerminalFontSize {
    static let preferenceKey = "mobileTerminalFontSize"
    static let minimum = 9.0
    static let defaultValue = 13.0
    static let maximum = 24.0

    #if DEBUG
    static let evidenceValue = 20.0
    #endif

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value.rounded(), minimum), maximum)
    }

    static func scaled(from startingValue: Double, by scale: CGFloat) -> Double {
        guard scale.isFinite, scale > 0 else { return normalized(startingValue) }
        return normalized(startingValue * Double(scale))
    }

    static func increased(from value: Double) -> Double {
        normalized(value + 1)
    }

    static func decreased(from value: Double) -> Double {
        normalized(value - 1)
    }

    static func resolvedPreference(_ value: Double) -> Double {
        #if DEBUG
        if ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_ID"]?
            .contains("large-font") == true {
            return evidenceValue
        }
        #endif
        return normalized(value)
    }
}
