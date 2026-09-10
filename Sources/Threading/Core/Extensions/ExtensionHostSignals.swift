import Foundation
import ThreadingExtensionKit

/// The live values a host-owned custom surface may bind to, answered in one place.
///
/// A surface's inputs are declared as `ExtensionSurfaceScalar.signal` bindings, and the host —
/// never the extension — supplies the number at draw time. Two hosts draw such surfaces today,
/// the main window's hook and the sidebar backdrop, and they must agree on every answer, so the
/// answers live here rather than in either. `supported` is the other half of the same promise:
/// `ExtensionHostService` refuses a patch naming a signal this build cannot answer, so an
/// extension built against a newer SDK fails at publication with a reason, rather than drawing
/// its fallback forever and looking merely dull.
///
/// Every reading is cheap and main-actor: the workload monitor's current envelope, an integer,
/// a calendar arithmetic. Nothing here touches a store, a file or a process, because a signal
/// is read once per frame by a surface that may run at 60 fps.
@MainActor
enum ExtensionHostSignals {

    /// Every signal this build answers. Pinned against `ExtensionHostSignal.all` by
    /// `ExtensionHostSignalsTests`, so the SDK cannot name a signal the host forgot.
    nonisolated static let supported: Set<ExtensionHostSignal> = [
        .activeAccountUsageRemaining,
        .workloadIntensity,
        .workloadWorkingCount,
        .timeOfDayFraction
    ]

    /// The one signal only a window can answer. Which account is "active" is the toolbar's
    /// account item's to say, so `MainWindowController` installs the reading when it builds
    /// that item; until then, and in a process with no window, the signal resolves to its
    /// binding's fallback.
    static var activeAccountUsageRemaining: () -> Double? = { nil }

    // MARK: - Seams

    /// The workload monitor's current envelope. A seam so a test can state a fleet without
    /// starting sessions.
    static var intensity: () -> AgentIntensity = { AgentWorkloadMonitor.shared.intensity }
    /// The monotonic clock the envelope decays against.
    static var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The wall clock the day fraction is read from.
    static var now: () -> Date = Date.init
    /// The calendar that decides where the day starts — the user's, so a surface following the
    /// hour follows the hour the user sees.
    static var calendar: () -> Calendar = { Calendar.current }

    // MARK: - Reading

    /// The signal's current value, or nil when the host has nothing to say — which the surface
    /// turns into the binding's fallback. An unsupported signal is nil too, but it never reaches
    /// a surface: publication refused it.
    static func value(_ signal: ExtensionHostSignal) -> Double? {
        switch signal {
        case .activeAccountUsageRemaining:
            return activeAccountUsageRemaining()

        case .workloadIntensity:
            return min(max(intensity().level(at: uptime()), 0), 1)

        case .workloadWorkingCount:
            return Double(max(intensity().workload.workingCount, 0))

        case .timeOfDayFraction:
            return dayFraction(of: now(), in: calendar())

        default:
            return nil
        }
    }

    /// Midnight to midnight as `0...1`, measured against the day's actual length so a daylight
    /// saving change moves the fraction rather than letting it run past one.
    static func dayFraction(of date: Date, in calendar: Calendar) -> Double {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        let length = max(end.timeIntervalSince(start), 1)
        return min(max(date.timeIntervalSince(start) / length, 0), 1)
    }
}
