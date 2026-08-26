import Foundation

/// Keeps the launchd registration aligned with `AppSettings.ptyHostEnabled`, and asks a stale
/// daemon to stand down at launch or as soon as the work that blocked it has ended.
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
    private let upgradeMonitor: PTYHostUpgradeMonitor
    private let eventLog: EventLog
    private let registeredProcessProbe: PTYHostRegisteredProcessProbe
    private let newSessionAdmission: PTYHostNewSessionAdmission
    private let appEvents = AppEventObservations()

    /// The enablement this coordinator last acted on. A settings change that did not move this
    /// key must not cost an XPC round trip: `AppSettingsDidChange` is posted for every setting in
    /// the app.
    private var appliedEnablement: Bool?

    /// Whether `start` has already installed the observation.
    private var hasStarted = false

    // MARK: - Initialization

    init(
        registration: PTYHostRegistration = PTYHostRegistration(),
        eventLog: EventLog = .shared,
        queue: DispatchQueue = DispatchQueue(
            label: PTYHostRegistrationDefaults.queueLabel,
            qos: .utility
        ),
        upgradeMonitor: PTYHostUpgradeMonitor? = nil,
        registeredProcessProbe: PTYHostRegisteredProcessProbe = .live(),
        newSessionAdmission: PTYHostNewSessionAdmission = .shared
    ) {
        self.registration = registration
        self.eventLog = eventLog
        self.queue = queue
        self.registeredProcessProbe = registeredProcessProbe
        self.newSessionAdmission = newSessionAdmission
        self.upgradeMonitor = upgradeMonitor ?? PTYHostUpgradeMonitor(
            probe: .live(eventLog: eventLog),
            scheduleRetry: { delay, work in
                queue.asyncAfter(deadline: .now() + delay, execute: work)
            },
            registeredProcessProbe: registeredProcessProbe,
            refreshRegistration: { request in
                switch registration.replaceAfterDaemonExited(request) {
                case .registered, .awaitingApproval, .skipped(.alreadySettled):
                    return true
                case .replacementRequired, .unregistered, .skipped,
                     .leftForRunningSessions, .leftForUnansweredDaemon, .failed, .refused:
                    return false
                }
            },
            setNewSessionAdmission: { newSessionAdmission.resolve($0) }
        )
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
        appEvents.observe(PTYHostMayHaveDrained.self) { [weak self] _ in
            guard let self else { return }
            let upgradeMonitor = self.upgradeMonitor
            self.queue.async { upgradeMonitor.hostMayHaveDrained() }
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
        // Synchronous with the setting edge, and *unresolved* rather than refused: no new spawn
        // enters a daemon while the serial queue is still deciding whether its registration or
        // generation has to be replaced, and a launch that lands in that window is told the
        // honest reason — nobody has asked yet. See `PTYHostNewSessionAdmission.State`.
        newSessionAdmission.resolve(.unresolved)

        let registration = self.registration
        let eventLog = self.eventLog
        let upgradeMonitor = self.upgradeMonitor
        let registeredProcessProbe = self.registeredProcessProbe
        queue.async {
            if enabled {
                let outcome = registration.register(request)
                guard let socketPath = request.decision.socketPath else {
                    return
                }
                // P2: launchd binds a registration to a path, so a replaced bundle leaves the old
                // daemon running the deleted binary. Nothing in the OS ends it; this is the ask.
                upgradeMonitor.begin(PTYHostUpgradeRequest(
                    socketPath: socketPath,
                    ownBuild: request.decision.build,
                    registrationRequest: outcome == .replacementRequired ? request : nil,
                    allowsNewSessionsWhenCurrent: outcome == .registered
                        || outcome == .skipped(.alreadySettled)
                ))
            } else {
                upgradeMonitor.cancel()
                // Nothing registered is the common case — the key ships off — and it must not
                // cost a connect attempt on every launch.
                guard registration.status.isRegistered else { return }

                // How many sessions would die with the helper. A silent socket is not proof of
                // zero: a retiring daemon unlinks it while its children continue. `launchctl`
                // provides the independent absence proof for a job that is registered but has no
                // process (for example a deleted DerivedData bundle).
                var held = request.decision.socketPath.flatMap { socketPath in
                    PTYHostUpgradeCheck.activeSessions(
                        socketPath: socketPath,
                        ownBuild: request.decision.build,
                        eventLog: eventLog
                    )
                }
                if held == nil, registeredProcessProbe.state() == .notRunning {
                    held = 0
                }
                registration.unregister(request, heldSessions: held)
            }
        }
    }
}
