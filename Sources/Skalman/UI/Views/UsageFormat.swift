import AppKit

/// Display vocabulary shared by the usage pill and its popover.
enum UsageFormat {

    /// Compact time until a reset: `47m`, `2h 14m`, `3d 4h`.
    static func remaining(until date: Date, from now: Date = Date()) -> String {
        let interval = max(0, date.timeIntervalSince(now))
        let minutes = Int(interval / 60)

        if minutes < 60 {
            return "\(max(minutes, 1))m"
        }

        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h"
        }

        let days = hours / 24
        let rest = hours % 24
        return rest > 0 ? "\(days)d \(rest)h" : "\(days)d"
    }

    /// How stale a reading is: `just now`, `4m ago`.
    static func age(of date: Date, at now: Date = Date()) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

// MARK: - Severity Colours

extension UsageSeverity {

    /// Tint for the ring, percent text and bars. Normal stays monochrome in glyph contexts
    /// and takes the user's accent in bar fills; pressure escalates through the system's
    /// own warning colours, so light and dark both work.
    var glyphColor: NSColor {
        switch self {
        case .normal: return .secondaryLabelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    var barColor: NSColor {
        switch self {
        case .normal: return .controlAccentColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}
