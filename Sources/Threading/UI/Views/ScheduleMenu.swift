import AppKit

// MARK: - Schedule Menu

/// The offers behind the chevron beside a send, assembled in one place for both surfaces.
///
/// The draft view schedules a session start and chat schedules a reply, but the question is the
/// same question and it has to read the same way in both — the reason `AccountUsageMenu` exists
/// one shelf along, for the same reason.
///
/// Nothing here decides anything: it turns `ScheduledTimePresets` into rows and hands the chosen
/// moment back. The account whose windows are offered is resolved by the caller, because only the
/// caller knows whether it is the composer's current chips or a session's own record.
@MainActor
enum ScheduleMenu {

    /// What a chosen row asks for.
    enum Choice {
        case at(Date, anchor: ScheduledMessage.Anchor)
        case custom
    }

    /// Builds the rows.
    ///
    /// `usage` is passed rather than fetched so the menu stays synchronous and testable — the
    /// caller already asked `AccountUsageService` for a cached reading, exactly as
    /// `AccountUsageMenu.decorate` does, and a menu is built in one run-loop pass where a fetch
    /// is a network round trip.
    static func entries(
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        usage: AccountUsage? = nil,
        metering model: String? = nil,
        onChoose: @escaping (Choice) -> Void
    ) -> [ThemedMenuEntry] {
        var entries: [ThemedMenuEntry] = []

        for preset in ScheduledTimePresets.wallClock(now: now, calendar: calendar, locale: locale) {
            entries.append(.item(row(preset, onChoose: onChoose)))
        }

        // The reset offers sit under a rule of their own: they answer a different question from
        // "when suits me" — they answer "when will this stop costing me a wasted turn" — and
        // running the two lists together would read as one list of times, half of which move.
        let resets = ScheduledTimePresets.usageResets(
            usage: usage,
            metering: model,
            now: now,
            locale: locale
        )
        if !resets.isEmpty {
            entries.append(.separator)
            for preset in resets {
                entries.append(.item(row(preset, onChoose: onChoose)))
            }
        }

        entries.append(.separator)
        entries.append(.item(
            ThemedMenuItem(
                title: L10n.string("Custom time…"),
                onChoose: { onChoose(.custom) }
            )
        ))
        return entries
    }

    // MARK: - Private Methods

    private static func row(
        _ preset: ScheduledTimePreset,
        onChoose: @escaping (Choice) -> Void
    ) -> ThemedMenuItem {
        ThemedMenuItem(
            title: preset.title,
            // The reading rides as the row's subtitle, which is the mechanism the account rows
            // already use for exactly this — a fact beside an offer, not a second offer.
            subtitle: preset.detail,
            representedValue: preset.id,
            onChoose: { onChoose(.at(preset.date, anchor: preset.anchor)) }
        )
    }
}
