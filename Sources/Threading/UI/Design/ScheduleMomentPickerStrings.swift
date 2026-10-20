import Foundation

enum ScheduleMomentPickerStrings {
    static var scheduleMessage: String { L10n.string("Schedule Message") }
    static var cancel: String { L10n.string("Cancel") }
    static var dayCaption: String { L10n.string("Day") }
    static var timeCaption: String { L10n.string("Time") }
    static var nothingToSchedule: String { L10n.string("No time left today.") }

    /// The time zone, then what the caller wanted said. Two facts on one line: a scheduled time
    /// with no zone beside it is ambiguous, and a Mac that is asleep at nine is not a server.
    static func note(_ informativeText: String?, locale: Locale = .current) -> String {
        let zone = L10n.format(
            "Time zone: %@",
            TimeZone.current.localizedName(for: .generic, locale: locale)
                ?? TimeZone.current.identifier
        )
        let detail = informativeText ?? L10n.string("Sends while Threading is running.")
        return L10n.format("%@ · %@", zone, detail)
    }
}
