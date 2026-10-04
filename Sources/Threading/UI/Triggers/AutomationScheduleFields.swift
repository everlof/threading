import AppKit
import ThreadingDomain

/// The automation editor's schedule controls — repeat choice, time, time zone, weekday toggles
/// and interval — lifted out of `AutomationEditorViewController` unchanged so the probe-source
/// editor states a calendar schedule with the same pieces. The owner lays the controls out; this
/// keeps their state, their enabling and their one parse into an `AutomationSchedule`.
@MainActor
final class AutomationScheduleFields {
    let cadence = ThemedPopUp()
    let time = ThemedTextField()
    let zone = ThemedTextField()
    let interval = ThemedTextField()
    let days = NSStackView()
    private(set) var dayToggles: [ThemedToggle] = []
    /// The trailing non-schedule choice (an event source, or manual) when the owner offers one.
    private let alternativeIndex: Int?
    /// Called after the selection changes, once the controls' enabling is updated.
    var onChange: (() -> Void)?

    /// Index of the alternative choice in `cadence`, after the four schedule kinds.
    static let alternativeChoiceIndex = AutomationSchedule.Kind.allCases.count

    init(schedule: AutomationSchedule?, alternative: String? = nil, selectAlternative: Bool = false) {
        alternativeIndex = alternative == nil ? nil : Self.alternativeChoiceIndex
        let shown = schedule ?? AutomationSchedule(kind: .daily, timeZone: TimeZone.current.identifier)
        for title in ["Daily", "Selected weekdays", "Weekly", "Fixed interval"] { cadence.addItem(withTitle: L10n.string(title)) }
        if let alternative { cadence.addItem(withTitle: alternative) }
        cadence.selectItem(at: AutomationSchedule.Kind.allCases.firstIndex(of: shown.kind) ?? 0)
        if selectAlternative, let alternativeIndex { cadence.selectItem(at: alternativeIndex) }
        time.stringValue = String(format: "%02d:%02d", shown.hour, shown.minute)
        zone.stringValue = shown.timeZone
        interval.stringValue = String(shown.intervalMinutes)
        days.orientation = .horizontal
        days.spacing = Design.Spacing.small
        let calendar = Calendar.current
        for index in 0..<7 {
            let toggle = ThemedToggle()
            toggle.state = shown.days.contains(index + 1) ? .on : .off
            toggle.setAccessibilityLabel(calendar.weekdaySymbols[index])
            let label = NSTextField(labelWithString: calendar.veryShortWeekdaySymbols[index])
            label.applyFont(.detail())
            let day = NSStackView(views: [label, toggle])
            day.orientation = .vertical
            days.addArrangedSubview(day)
            dayToggles.append(toggle)
        }
        cadence.target = self
        cadence.action = #selector(cadenceChanged)
    }

    /// Whether the trailing alternative (not a schedule) is chosen.
    var isAlternativeSelected: Bool { alternativeIndex != nil && cadence.indexOfSelectedItem == alternativeIndex }

    var selectedKind: AutomationSchedule.Kind {
        AutomationSchedule.Kind.allCases[min(AutomationSchedule.Kind.allCases.count - 1, max(0, cadence.indexOfSelectedItem))]
    }

    /// Whether the current choice reads the time of day.
    var readsTime: Bool { !isAlternativeSelected && selectedKind != .interval }
    /// Whether the current choice reads the time zone: every calendar rule does; an interval
    /// advances from its anchor and does not.
    var readsZone: Bool { readsTime }
    /// Whether the current choice reads the weekday toggles.
    var readsDays: Bool { !isAlternativeSelected && (selectedKind == .weekly || selectedKind == .weekdays) }
    /// Whether the current choice reads the interval.
    var readsInterval: Bool { !isAlternativeSelected && selectedKind == .interval }

    /// Enables only the controls the current choice reads. An owner with room to rearrange
    /// hides the rest instead, from the `reads…` answers.
    func updateEnabled() {
        time.isEnabled = readsTime
        zone.isEnabled = readsZone
        interval.isEnabled = readsInterval
        for toggle in dayToggles { toggle.isEnabled = readsDays }
    }

    /// The schedule the controls state. Validation is the caller's: an alternative choice reads
    /// no schedule, so it would refuse a time it does not use.
    func schedule(anchor: Date?) throws -> AutomationSchedule {
        let parts = time.stringValue.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              let minutes = Int(interval.stringValue) else { throw TriggerStore.StoreError.invalidRecord("time or interval") }
        return AutomationSchedule(kind: selectedKind, timeZone: zone.stringValue, hour: hour, minute: minute,
                                  days: dayToggles.enumerated().compactMap { $0.element.state == .on ? $0.offset + 1 : nil },
                                  intervalMinutes: minutes, anchor: anchor ?? Date())
    }

    @objc private func cadenceChanged() {
        updateEnabled()
        onChange?()
    }
}
