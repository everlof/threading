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

    /// A token count at a glance: 45.5M rather than 45,491,203. The exact figure is never the
    /// point on a page comparing one checkout against another.
    static func tokens(_ count: Int64) -> String {
        let value = Double(count)
        if value >= 1_000_000_000 { return String(format: "%.2fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", value / 1_000) }
        return "\(count)"
    }

    /// Banked rate-limit resets, each of which clears a spent window early.
    ///
    /// Only ever shown when there are some: an account with none should say nothing rather
    /// than announce a zero.
    static func resetCredits(_ count: Int) -> String {
        count == 1 ? "1 limit reset banked" : "\(count) limit resets banked"
    }

    static func age(of date: Date, at now: Date = Date()) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// The reset as an absolute local moment, to sit beside the countdown so a reset reads as both
    /// "in 3h" and "at 3:45": the time alone when it is today, `tomorrow 3:45 PM`, a weekday within
    /// the week, else a dated form. Respects the user's 12/24-hour locale.
    static func absolute(_ date: Date, from now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = timeFormatter.string(from: date)

        if calendar.isDate(date, inSameDayAs: now) {
            return time
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }

        // Within the coming week, name the weekday; beyond that, a dated form.
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        if (2...6).contains(days) {
            return "\(weekdayFormatter.string(from: date)) \(time)"
        }
        return "\(dayFormatter.string(from: date)), \(time)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

// MARK: - Severity Colours

extension UsageSeverity {

    /// Tint for the ring, percent text and bars. Normal stays monochrome in glyph contexts
    /// and takes the user's accent in bar fills; pressure escalates through the system's
    /// own warning colours, so light and dark both work.
    var glyphColor: NSColor {
        switch self {
        case .normal: return Design.Text.secondary
        case .warning: return Design.Status.warning
        case .critical: return Design.Status.negative
        }
    }

    var barColor: NSColor {
        switch self {
        case .normal: return Design.Surface.accent
        case .warning: return Design.Status.warning
        case .critical: return Design.Status.negative
        }
    }
}
