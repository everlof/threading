import Foundation
import IOKit.pwr_mgt
import OSLog

/// The system boundary for preventing idle system sleep.
///
/// The assertion deliberately does not prevent display sleep or the lid-closed sleep path. It
/// names only the idle sleep that would otherwise interrupt an active agent turn while the Mac
/// is left unattended.
@MainActor
protocol IdleSystemSleepAsserting: AnyObject {
    func acquire() -> Bool
    func release() -> Bool
}

/// Owns the one process-wide IOKit assertion.
///
/// IOKit releases assertions when their process exits, but Threading still releases explicitly:
/// changing the preference or finishing the last turn must give macOS its ordinary idle policy
/// back immediately rather than waiting for application termination.
@MainActor
final class SystemIdleSleepAssertion: IdleSystemSleepAsserting {
    private var assertionID: IOPMAssertionID?

    func acquire() -> Bool {
        guard assertionID == nil else { return true }

        var createdID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            ActiveTurnSleepInhibitorDefaults.assertionReason as CFString,
            &createdID
        )
        guard result == kIOReturnSuccess else {
            ThreadingLogger.app.warning(
                "Could not prevent idle system sleep, status=\(result, privacy: .public)"
            )
            return false
        }
        assertionID = createdID
        return true
    }

    func release() -> Bool {
        guard let assertionID else { return true }
        let result = IOPMAssertionRelease(assertionID)
        guard result == kIOReturnSuccess else {
            ThreadingLogger.app.warning(
                "Could not release idle system sleep assertion, status=\(result, privacy: .public)"
            )
            return false
        }
        self.assertionID = nil
        return true
    }

    deinit {
        if let assertionID {
            IOPMAssertionRelease(assertionID)
        }
    }
}

/// Prevents idle system sleep while at least one agent turn is unfinished and the user opted in.
///
/// `SessionRuntimeDidChange` is the lifecycle channel for terminal and native sessions. The
/// event carries the session id, so ordinary edges update one set entry in O(1) instead of
/// rescanning every live session. The complete projection is read only once at `start()`, covering
/// sessions that were already working before this observer was installed.
@MainActor
final class ActiveTurnSleepInhibitor {
    private let observations: AppEventObservations
    private let currentInFlightSessionIDs: @MainActor () -> Set<SessionID>
    private let runtime: @MainActor (SessionID) -> SessionRuntimeSnapshot
    private let isEnabled: @MainActor () -> Bool
    private let assertion: any IdleSystemSleepAsserting

    private var inFlightSessionIDs: Set<SessionID> = []
    private var isHoldingAssertion = false
    private var isStarted = false

    init(
        center: NotificationCenter = .default,
        currentInFlightSessionIDs: @escaping @MainActor () -> Set<SessionID>,
        runtime: @escaping @MainActor (SessionID) -> SessionRuntimeSnapshot,
        isEnabled: @escaping @MainActor () -> Bool,
        assertion: any IdleSystemSleepAsserting = SystemIdleSleepAssertion()
    ) {
        observations = AppEventObservations(center: center)
        self.currentInFlightSessionIDs = currentInFlightSessionIDs
        self.runtime = runtime
        self.isEnabled = isEnabled
        self.assertion = assertion
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        observations.observe(SessionRuntimeDidChange.self) { [weak self] event in
            self?.runtimeChanged(for: event.sessionID)
        }
        observations.observe(TerminalSessionDidEnd.self) { [weak self] event in
            self?.sessionEnded(event.sessionID)
        }
        observations.observe(AppSettingsDidChange.self) { [weak self] _ in
            self?.reconcileAssertion()
        }

        inFlightSessionIDs = currentInFlightSessionIDs()
        reconcileAssertion()
    }

    /// Stops observing and releases immediately. The application calls this before it tears down
    /// agent runtimes, so quit never depends on a final activity notification arriving.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        observations.removeAll()
        inFlightSessionIDs.removeAll()
        reconcileAssertion()
    }

    private func runtimeChanged(for sessionID: SessionID) {
        if runtime(sessionID).hasPendingOutcome {
            inFlightSessionIDs.insert(sessionID)
        } else {
            inFlightSessionIDs.remove(sessionID)
        }
        reconcileAssertion()
    }

    private func sessionEnded(_ sessionID: SessionID) {
        inFlightSessionIDs.remove(sessionID)
        reconcileAssertion()
    }

    private func reconcileAssertion() {
        let shouldHold = isStarted && isEnabled() && !inFlightSessionIDs.isEmpty
        if shouldHold, !isHoldingAssertion {
            isHoldingAssertion = assertion.acquire()
        } else if !shouldHold, isHoldingAssertion, assertion.release() {
            isHoldingAssertion = false
        }
    }
}

enum ActiveTurnSleepInhibitorDefaults {
    static let assertionReason = "Threading has an active agent turn"
}
