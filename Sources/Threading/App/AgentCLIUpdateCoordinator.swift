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

    private let defaults: UserDefaults
    private let automaticChecksEnabled: @MainActor () -> Bool
    private let check: Check
    private let canPresent: @MainActor () -> Bool
    private let present: @MainActor ([AgentCLIUpdate]) -> Void
    private let now: @MainActor () -> Date
    private let appEvents: AppEventObservations

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
        present: @escaping @MainActor ([AgentCLIUpdate]) -> Void,
        now: @escaping @MainActor () -> Date = Date.init,
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
            self?.presentationMayBeReady()
        }
        considerCheck()
    }

    /// Called when a non-notification gate changed — first-launch onboarding just left, today.
    func presentationMayBeReady() {
        guard automaticChecksEnabled(), canPresent(), !pendingUpdates.isEmpty else { return }

        let fingerprint = AgentCLIUpdateSchedule.fingerprint(for: pendingUpdates)
        guard defaults.string(forKey: AgentCLIUpdateSchedule.lastNotificationKey) != fingerprint
        else {
            pendingUpdates = []
            return
        }

        defaults.set(fingerprint, forKey: AgentCLIUpdateSchedule.lastNotificationKey)
        let updates = pendingUpdates
        pendingUpdates = []
        present(updates)
    }

    private func settingDidChange() {
        guard automaticChecksEnabled() else {
            generation = UUID()
            task?.cancel()
            task = nil
            pendingUpdates = []
            return
        }
        considerCheck()
        presentationMayBeReady()
    }

    private func considerCheck() {
        guard task == nil, AgentCLIUpdateSchedule.shouldCheck(
            enabled: automaticChecksEnabled(),
            lastAttempt: defaults.object(
                forKey: AgentCLIUpdateSchedule.lastAttemptKey
            ) as? Date,
            now: now()
        ) else { return }

        let attemptDate = now()
        defaults.set(attemptDate, forKey: AgentCLIUpdateSchedule.lastAttemptKey)
        let activeGeneration = UUID()
        generation = activeGeneration
        let check = self.check

        task = Task { [weak self] in
            let report = await check()
            guard !Task.isCancelled else { return }
            self?.received(report, generation: activeGeneration)
        }
    }

    private func received(_ report: AgentCLIUpdateReport, generation: UUID) {
        guard generation == self.generation else { return }
        task = nil

        ThreadingLogger.updates.info(
            "Agent CLI update check completed installed=\(report.installed.count, privacy: .public) checked=\(report.checkedSourceCount, privacy: .public) updates=\(report.updates.count, privacy: .public) missing=\(report.missingCount, privacy: .public) failures=\(report.failures.count, privacy: .public)"
        )
        for failure in report.failures {
            ThreadingLogger.updates.warning(
                "Agent CLI update check failed tool=\(failure.toolID, privacy: .public) stage=\(failure.stage.rawValue, privacy: .public) reason=\(failure.reason.logValue, privacy: .public)"
            )
        }

        guard automaticChecksEnabled(), !report.updates.isEmpty else { return }
        pendingUpdates = report.updates
        presentationMayBeReady()
    }
}

enum AgentCLIUpdateSchedule {
    static let lastAttemptKey = "AgentCLIUpdate.lastAttemptAt"
    static let lastNotificationKey = "AgentCLIUpdate.lastNotification"
    static let interval: TimeInterval = 24 * 60 * 60

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
