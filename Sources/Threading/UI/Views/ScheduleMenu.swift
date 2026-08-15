import AppKit

// MARK: - Schedule Menu

/// The offers behind the chevron beside a send, assembled in one place for both surfaces.
///
/// The draft view schedules a session start and chat schedules a reply, but the question is the
/// same question and it has to read the same way in both — the reason `AccountUsageMenu` exists
/// one shelf along, for the same reason.
///
/// Nothing here decides anything: it turns `ScheduledTimePresets` and the conversation-finish
/// condition into rows and hands the choice back. The account whose windows are offered is
/// resolved by the caller, because only the caller knows whether it is the composer's current
/// chips or a session's own record.
@MainActor
enum ScheduleMenu {

    /// What a chosen row asks for.
    enum Choice {
        case at(Date, anchor: ScheduledMessage.Anchor)
        case whenConversationFinishes
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
        canWaitForConversation: Bool = false,
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
                title: L10n.string("When a conversation finishes…"),
                subtitle: canWaitForConversation
                    ? nil
                    : L10n.string("No conversations with reliable finish signals are working."),
                isEnabled: canWaitForConversation,
                onChoose: { onChoose(.whenConversationFinishes) }
            )
        ))
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

    /// One offer, with its reading placed by how much of a reading it is.
    ///
    /// **A wall-clock preset's time goes on the title's own line.** `ThemedMenuMetrics.heights`
    /// gives every row in a run the height of the tallest kind in it, deliberately — a group of
    /// logins where three carry a scoped window and two do not otherwise reads as a spacing
    /// defect rather than as rows that differ. That rule was doing the opposite here: "In an
    /// hour" is the only wall-clock offer whose title does not already say the time, so its one
    /// subtitle stretched "Tomorrow at 09:00" and "Monday at 09:00" to 46pt each and left them
    /// looking like rows with a missing second line. `titleDetail` is the mechanism for exactly
    /// this and says so in its own comment: a small qualifier belongs beside the title, because
    /// demoting it to a second line costs a subtitle-height row to every row beside it.
    ///
    /// **A reset preset keeps its subtitle.** "14:30 · resets in 4h 37m" is two facts and a
    /// sentence's worth of them, not a qualifier — and it sits in its own run behind a separator,
    /// which is what makes the change of height legible rather than accidental.
    private static func row(
        _ preset: ScheduledTimePreset,
        onChoose: @escaping (Choice) -> Void
    ) -> ThemedMenuItem {
        var item = ThemedMenuItem(
            title: preset.title,
            subtitle: preset.anchor == .wallClock ? nil : preset.detail,
            representedValue: preset.id,
            onChoose: { onChoose(.at(preset.date, anchor: preset.anchor)) }
        )
        if preset.anchor == .wallClock { item.titleDetail = preset.detail }
        return item
    }
}
