import AppKit
import Foundation

/// Schedules the passive agent-tool check and holds a found result until it can be seen.
///
/// The application composition root owns this object because its two sides belong in different
/// layers: `AgentCLIUpdateChecker` knows only processes and release metadata, while the window
/// decides where a receipt appears. A background answer never starts a toast clock while the app
/// is behind another application or while first-launch onboarding still covers the main window.
@MainActor
final class AgentCLIUpdateCoordinator {

    typealias Check = @Sendable () async -> AgentCLIUpdateReport
    /// The window is handed the updates and a way to say the user's run actually began. The
    /// second half is what makes the notice durable-deduplicated on the action rather than on
    /// the mere attempt to show it.
    typealias Present = @MainActor ([AgentCLIUpdate], @escaping @MainActor () -> Void) -> Void

    private let defaults: UserDefaults
    private let automaticChecksEnabled: @MainActor () -> Bool
    private let check: Check
    private let canPresent: @MainActor () -> Bool
    private let present: Present
    private let now: @MainActor () -> Date
    private let pollInterval: TimeInterval
    private let appEvents: AppEventObservations
    private let pollTimer = MainRunLoopTimer()

    private var started = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var pendingUpdates: [AgentCLIUpdate] = []

    init(
        defaults: UserDefaults = .standard,
        automaticChecksEnabled: @escaping @MainActor () -> Bool = {
            AppSettings.shared.automaticUpdateChecksEnabled
        },
        check: Check? = nil,
        canPresent: @escaping @MainActor () -> Bool,
        present: @escaping Present,
        now: @escaping @MainActor () -> Date = Date.init,
        pollInterval: TimeInterval = AgentCLIUpdateSchedule.pollInterval,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.automaticChecksEnabled = automaticChecksEnabled
        if let check {
            self.check = check
        } else {
            let checker = AgentCLIUpdateChecker.live(shell: AgentLauncher.loginShellPath)
            self.check = { await checker.check() }
        }
        self.canPresent = canPresent
        self.present = present
        self.now = now
        self.pollInterval = pollInterval
        self.appEvents = AppEventObservations(center: notificationCenter)
    }

    deinit {
        task?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true

        appEvents.observe(AppSettingsDidChange.self) { [weak self] _ in
            self?.settingDidChange()
        }
        appEvents.observe(NSApplication.didBecomeActiveNotification) { [weak self] in
            guard let self else { return }
            // Coming back to the app is both the moment a receipt can be seen and the cheapest
            // moment to notice the day has turned over.
            self.checkIfDue()
            self.presentationMayBeReady()
        }

        // Threading is left running for days: `applicationShouldTerminateAfterLastWindowClosed`
        // is false and sessions outlive their terminals. Without a timer the "once a day" the
        // Privacy page promises would mean "once per launch", and a machine that never quits the
        // app would check once and never again. The tick is far shorter than the interval it
        // serves so that a laptop waking from sleep does not have to wait a whole extra day.
        pollTimer.install(Timer.scheduledTimer(
            withTimeInterval: pollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkIfDue()
            }
        })

        checkIfDue()
    }

    /// Called when a non-notification gate changed — first-launch onboarding just left, today.
    func presentationMayBeReady() {
        guard automaticChecksEnabled(), canPresent(), !pendingUpdates.isEmpty else { return }

        let updates = pendingUpdates
        pendingUpdates = []
        let fingerprint = AgentCLIUpdateSchedule.fingerprint(for: updates)
        present(updates) { [weak self] in
            // Recorded here, not above: a band that dwells for fourteen seconds behind another
            // window, or one whose terminal refused to open, was never an answer from the user.
            // Burning the fingerprint on presentation is how the same versions would go
            // unmentioned for ever after a receipt nobody saw.
            self?.defaults.set(fingerprint, forKey: AgentCLIUpdateSchedule.lastNotificationKey)
        }
    }

    /// The timer's and the activation's entry point, and the one place that decides the day has
    /// turned over. Separate from `start()` so a test can advance the schedule without a clock.
    func checkIfDue() {
        guard task == nil, AgentCLIUpdateSchedule.shouldCheck(
            enabled: automaticChecksEnabled(),
            lastAttempt: defaults.object(
                forKey: AgentCLIUpdateSchedule.lastAttemptKey
            ) as? Date,
            now: now()
        ) else { return }

        let activeGeneration = UUID()
        generation = activeGeneration
        let check = self.check

        task = Task { [weak self] in
            let report = await check()
            guard !Task.isCancelled else { return }
            self?.received(report, generation: activeGeneration)
        }
    }

    private func settingDidChange() {
        guard automaticChecksEnabled() else {
            generation = UUID()
            task?.cancel()
            task = nil
            pendingUpdates = []
            return
        }
        // Deliberately not `presentationMayBeReady()`: `AppSettingsDidChange` is the shared
        // app-settings notification, so flushing a held receipt here would drop the band over
        // the Settings pane the user is working in. Showing it is the window's and the
        // activation's business.
        checkIfDue()
    }

    private func received(_ report: AgentCLIUpdateReport, generation: UUID) {
        guard generation == self.generation else { return }
        task = nil

        // Stamped on the answer rather than on the intent. Writing it before the work meant a
        // check cancelled seconds later — by switching the setting off and on again — had
        // already spent the day's attempt, and the user's toggle appeared to do nothing.
        defaults.set(now(), forKey: AgentCLIUpdateSchedule.lastAttemptKey)

        ThreadingLogger.updates.info(
            "Agent CLI update check completed installed=\(report.installed.count, privacy: .public) checked=\(report.checkedSourceCount, privacy: .public) updates=\(report.updates.count, privacy: .public) missing=\(report.missingCount, privacy: .public) failures=\(report.failures.count, privacy: .public)"
        )
        for failure in report.failures {
            ThreadingLogger.updates.warning(
                "Agent CLI update check failed tool=\(failure.toolID, privacy: .public) stage=\(failure.stage.rawValue, privacy: .public) reason=\(failure.reason.logValue, privacy: .public)"
            )
        }

        guard automaticChecksEnabled(), !report.updates.isEmpty else { return }
        guard defaults.string(forKey: AgentCLIUpdateSchedule.lastNotificationKey)
            != AgentCLIUpdateSchedule.fingerprint(for: report.updates) else { return }
        pendingUpdates = report.updates
        presentationMayBeReady()
    }
}

enum AgentCLIUpdateSchedule {
    static let lastAttemptKey = "AgentCLIUpdate.lastAttemptAt"
    static let lastNotificationKey = "AgentCLIUpdate.lastNotification"
    static let interval: TimeInterval = 24 * 60 * 60
    /// How often the running app asks whether `interval` has elapsed. Cheap: it reads one date.
    static let pollInterval: TimeInterval = 60 * 60

    static func shouldCheck(enabled: Bool, lastAttempt: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        // A clock correction into the past must not suppress checks until that future date.
        return elapsed < 0 || elapsed >= interval
    }

    static func fingerprint(for updates: [AgentCLIUpdate]) -> String {
        updates.map {
            [$0.id, $0.installedVersion, $0.latestVersion].joined(separator: "|")
        }.joined(separator: "\n")
    }
}
