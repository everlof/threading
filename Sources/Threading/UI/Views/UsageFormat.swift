import AppKit
import ThreadingRemoteKit

/// Display vocabulary shared by the usage pill and its popover.
public enum UsageFormat {

    /// Measured spend, exactly: `$531,676.76`.
    ///
    /// One implementation, in `ThreadingRemoteKit`, because the phone renders the same prepared
    /// values and must spell them the same way — and because `.currency(code:)` is
    /// locale-sensitive, so three independent call sites printed `US$…` for every reader
    /// outside `en_US`. See `UsageValueFormat`.
    public static func currency(_ value: Double) -> String {
        UsageValueFormat.currency(value)
    }

    /// The same amount where the slot's width is fixed by something other than the text —
    /// a chart's value axis, a stat in a band: `$25k`, `$1.2M`.
    public static func compactCurrency(_ value: Double) -> String {
        UsageValueFormat.compactCurrency(value)
    }

    /// A share of a total, at one decimal so a column of them stays a column.
    public static func share(_ fraction: Double) -> String {
        UsageValueFormat.share(fraction)
    }

    /// Compact time until a reset: `47m`, `2h 14m`, `3d 4h`.
    ///
    /// Never `0m`: a reset a few seconds away is still one minute's worth of waiting to a reader,
    /// and a countdown that reaches zero and stays there reads as stuck.
    public static func remaining(until date: Date, from now: Date = Date()) -> String {
        let minutes = Int(max(0, date.timeIntervalSince(now)) / 60)
        return span(minutes: max(minutes, 1))
    }

    /// A span of time as text: `12s`, `47m`, `2h 14m`, `3d 4h`.
    ///
    /// The same vocabulary as `remaining`, so "two hours before you start" and "two hours until
    /// the reset" read as the same quantity — but it keeps seconds, because the things measured
    /// this way (how long a poke took) are often shorter than a minute and rounding those up to
    /// `1m` would overstate what they cost.
    public static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        guard seconds >= 60 else { return "\(Int(seconds.rounded()))s" }
        return span(minutes: Int(seconds / 60))
    }

    /// Whole minutes in the largest units that stay readable. Shared so a countdown and a
    /// duration cannot drift into two spellings of the same hour.
    private static func span(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h"
        }

        let days = hours / 24
        let rest = hours % 24
        return rest > 0 ? "\(days)d \(rest)h" : "\(days)d"
    }

    /// `resets in 2d 4h` — the countdown as a phrase, for the readings that set it beside other
    /// segments rather than in a column of its own.
    public static func resets(until date: Date, from now: Date = Date()) -> String {
        "resets in \(remaining(until: date, from: now))"
    }

    /// A token count at a glance: 45.5M rather than 45,491,203. The exact figure is never the
    /// point on a page comparing one checkout against another.
    public static func tokens(_ count: Int64) -> String {
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
    public static func resetCredits(_ count: Int) -> String {
        count == 1 ? "1 limit reset banked" : "\(count) limit resets banked"
    }

    public static func age(of date: Date, at now: Date = Date()) -> String {
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
    public static func absolute(_ date: Date, from now: Date = Date()) -> String {
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

@MainActor
extension UsageSeverity {

    /// Tint for the ring, percent text and bars. Normal stays monochrome in glyph contexts
    /// and takes the user's accent in bar fills; pressure escalates through the system's
    /// own warning colours, so light and dark both work.
    public var glyphColor: NSColor {
        switch self {
        case .normal: return Design.Text.secondary
        case .warning: return Design.Status.warning
        case .critical: return Design.Status.negative
        }
    }

    public var barColor: NSColor {
        switch self {
        case .normal: return Design.Surface.accent
        case .warning: return Design.Status.warning
        case .critical: return Design.Status.negative
        }
    }
}

// MARK: - Forecast Text

extension UsageFormat {

    /// The projection as a sentence, or nil while there is nothing worth claiming.
    ///
    /// Silent on `.unknown` rather than saying "unknown": a line that appears only when it has
    /// something to say is read when it appears, and one that is always there is not read at
    /// all. Silent on a comfortable window too — being told you will not run out is noise.
    // Not published: the forecast is computed from a journal only the application has.
    static func forecast(_ outcome: UsageForecast.Outcome, window: AccountUsage.Window) -> String? {
        switch outcome {
        case .unknown, .withinBudget:
            return nil
        case let .exhausting(at, early):
            let earlyBy = remaining(until: Date().addingTimeInterval(early), from: Date())
            return "\(window.compactName) spent by \(clock.string(from: at)) · \(earlyBy) early"
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
