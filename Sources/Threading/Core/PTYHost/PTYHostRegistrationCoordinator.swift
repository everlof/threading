import Foundation

/// Keeps the launchd registration aligned with `AppSettings.ptyHostEnabled`, and asks a stale
/// daemon to stand down once per launch.
///
/// Started from `AppDelegate.applicationDidFinishLaunching` **after the single-instance lock and
/// after the launch-mode decision**, and never in Recovery Mode: recovery starts no background
/// machinery, and a launch that came up because the last one did not is the worst possible moment
/// to install something that outlives it. Both refusals are enforced inside `PTYHostRegistration`
/// as well, because a guard that only exists at the call site is a guard the next call site does
/// not have.
///
/// **Nothing here blocks the main actor.** The settings read and the mode read are main-actor
/// values, snapshotted into a `PTYHostRegistrationRequest`; `SMAppService.register()` is an XPC
/// round trip and the upgrade check is a socket handshake, and both happen on this type's own
/// serial queue.
///
/// The setting is observed the way every other behavioural key is — `AppSettingsDidChange`,
/// reconciled from the current value rather than from the notification — so turning it off in the
/// middle of a run takes effect without a restart. Turning it *off* does not necessarily
/// unregister: `unregister()` kills the running helper, and the helper may be holding somebody's
/// agents. See `PTYHostRemovalDecision`.
@MainActor
final class PTYHostRegistrationCoordinator {

    // MARK: - Singleton

    static let shared = PTYHostRegistrationCoordinator()

    // MARK: - Properties

    private let registration: PTYHostRegistration
    private let queue: DispatchQueue
    private let eventLog: EventLog
    private let appEvents = AppEventObservations()

    /// The enablement this coordinator last acted on. A settings change that did not move this
    /// key must not cost an XPC round trip: `AppSettingsDidChange` is posted for every setting in
    /// the app.
    private var appliedEnablement: Bool?

    /// The upgrade check is a launch-time question, asked once. A daemon that became stale while
    /// the app was running is a bundle swap under a live app, and the answer there is the same as
    /// it has always been: the running app keeps talking to the daemon it has, and the next
    /// launch does the upgrade.
    private var hasCheckedForUpgrade = false

    /// Whether `start` has already installed the observation.
    private var hasStarted = false

    // MARK: - Initialization

    init(
        registration: PTYHostRegistration = PTYHostRegistration(),
        eventLog: EventLog = .shared,
        queue: DispatchQueue = DispatchQueue(
            label: PTYHostRegistrationDefaults.queueLabel,
            qos: .utility
        )
    ) {
        self.registration = registration
        self.eventLog = eventLog
        self.queue = queue
    }

    // MARK: - Public Methods

    /// Applies the current setting and follows it from here on.
    ///
    /// Called once per launch. Safe to call when the key is off, which is every launch until R1 —
    /// the TCC question in `permissions.md` — has been answered on a SIP-enabled Mac: the whole
    /// path short-circuits on `decision.isEnabled` before it touches launchd or the filesystem.
    func start(settings: AppSettings = .shared) {
        // One launch, one observation. A second `start` would double every later reconcile, and
        // a reconcile is an XPC round trip and a socket handshake rather than a cheap read.
        guard !hasStarted else { return }
        hasStarted = true
        appEvents.observe(AppSettingsDidChange.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile(settings: settings) }
        }
        reconcile(settings: settings)
    }

    /// Aligns the registration with the setting, if the setting moved.
    func reconcile(settings: AppSettings = .shared) {
        let request = PTYHostRegistrationRequest.live(settings: settings)

        // Neither direction touches launchd here. `PTYHostRegistration` refuses both again, and
        // this guard is what stops a hosted test from even *reading* `SMAppService.status` in the
        // developer's own app — the bundle a test runs in is the shipping one.
        if request.isRecovery {
            // Named rather than silent, because the interesting failure is a *missing* refusal: a
            // recovery launch that registered would leave no trace at all.
            RecoveryMode.refuse("registering the PTY host launch agent")
            return
        }
        guard !request.isHostedTest else { return }

        let enabled = request.decision.isEnabled
        guard enabled != appliedEnablement else { return }
        appliedEnablement = enabled

        let shouldCheckForUpgrade = enabled && !hasCheckedForUpgrade
        if shouldCheckForUpgrade { hasCheckedForUpgrade = true }

        let registration = self.registration
        let eventLog = self.eventLog
        queue.async {
            if enabled {
                registration.register(request)
                guard shouldCheckForUpgrade, let socketPath = request.decision.socketPath else {
                    return
                }
                // P2: launchd binds a registration to a path, so a replaced bundle leaves the old
                // daemon running the deleted binary. Nothing in the OS ends it; this is the ask.
                PTYHostUpgradeCheck.run(
                    socketPath: socketPath,
                    ownBuild: request.decision.build,
                    eventLog: eventLog
                )
            } else {
                // Nothing registered is the common case — the key ships off — and it must not
                // cost a connect attempt on every launch.
                guard registration.status.isRegistered else { return }

                // How many sessions would die with the helper. nil — no daemon answered — is the
                // same as none: there is nothing to kill.
                let held = request.decision.socketPath.flatMap { socketPath in
                    PTYHostUpgradeCheck.heldSessions(
                        socketPath: socketPath,
                        ownBuild: request.decision.build,
                        eventLog: eventLog
                    )
                }
                registration.unregister(request, heldSessions: held)
            }
        }
    }
}
