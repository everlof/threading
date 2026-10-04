import Foundation

/// The app moments a custom surface may pulse on, held as the last time each happened.
///
/// `AgentMoodMonitor` already reads the two edges a theme's moments answer — a turn coming
/// back, a session starting to wait — and posts `AgentMomentDidOccur` for each. This reader
/// keeps one timestamp per event on the uptime clock, and `ExtensionHostSignals` turns it into
/// a decaying pulse at draw time. Nothing is scheduled, nothing redraws on an event: a surface
/// is already drawing at its own cadence and reads the pulse with its next frame.
///
/// **Lazy, and only while it is wanted.** The reader listens, and starts the mood monitor,
/// only while at least one surface binding a moment signal is mounted in a window. A Threading
/// with no such surface observes nothing and starts nothing on its behalf; the last surface
/// leaving its window stops the listening and forgets the timestamps, so a surface mounted
/// later never pulses on a stale event. The monitor itself has no stop — once a surface has
/// asked for moments it keeps counting, at O(live sessions) per activity change, which is the
/// cost the mascot and theme moments already pay.
@MainActor
final class ExtensionMomentSignalReader {

    static let shared = ExtensionMomentSignalReader()

    private var occurrences: [ThemeMomentEvent: TimeInterval] = [:]
    private var demand: Set<UUID> = []
    private let appEvents = AppEventObservations()
    private(set) var isListening = false

    /// What starting to listen starts upstream. A seam so a test can count it without a runtime.
    var startMonitor: @MainActor () -> Void = { AgentMoodMonitor.shared.start() }

    init() {}

    // MARK: - Public Methods

    /// When `event` last happened on `ExtensionHostSignals.uptime`, or nil when it has not
    /// happened since the reader began listening.
    func lastOccurrence(of event: ThemeMomentEvent) -> TimeInterval? {
        occurrences[event]
    }

    /// Adds or removes one mounted surface's interest. The first interest starts listening and
    /// the last one leaving stops it.
    func setDemand(_ id: UUID, active: Bool) {
        if active {
            demand.insert(id)
        } else {
            demand.remove(id)
        }
        updateListening()
    }

    /// Records `event` as happening now. Internal so a test can state a moment directly.
    func record(_ event: ThemeMomentEvent) {
        occurrences[event] = ExtensionHostSignals.uptime()
    }

    // MARK: - Private Methods

    private func updateListening() {
        if !demand.isEmpty, !isListening {
            isListening = true
            appEvents.observe(AgentMomentDidOccur.self) { [weak self] event in
                self?.record(event.event)
            }
            startMonitor()
        } else if demand.isEmpty, isListening {
            isListening = false
            appEvents.removeAll()
            occurrences.removeAll()
        }
    }
}

/// One mounted surface's interest in moments. Releasing it — including by the surface going
/// away — cannot leave a dead surface keeping the reader listening.
@MainActor
final class ExtensionMomentDemand {
    private let id = UUID()
    private let reader: ExtensionMomentSignalReader

    init(reader: ExtensionMomentSignalReader = .shared) {
        self.reader = reader
    }

    func setActive(_ active: Bool) {
        reader.setDemand(id, active: active)
    }

    deinit {
        let id = id
        let reader = reader
        Task { @MainActor in reader.setDemand(id, active: false) }
    }
}
