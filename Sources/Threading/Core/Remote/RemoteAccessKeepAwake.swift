import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Whether Threading keeps this Mac awake while Remote Access is on.
///
/// A sleeping Mac answers no way in, so a phone away from home reaches it only while it is awake
/// (`RemoteSleepFacts`). macOS decides that from settings that apply to the whole Mac; this is the
/// narrower choice of keeping it awake only while Threading is serving Remote Access. It prevents
/// idle system sleep and nothing else: the display still sleeps, and closing a laptop's lid,
/// choosing Sleep, a critical battery or heat still put the Mac to sleep.
enum RemoteAccessKeepAwake: String, CaseIterable, Sendable {
    /// macOS's own energy settings decide.
    case off
    /// Awake on the power adapter; on battery macOS's settings decide again, so an idle laptop
    /// does not drain.
    case whilePluggedIn
    /// Awake on the adapter and on battery, at the cost of charge while the Mac sits idle.
    case always

    var title: String {
        switch self {
        case .off: return L10n.string("Off")
        case .whilePluggedIn: return L10n.string("Plugged in")
        case .always: return L10n.string("Always")
        }
    }

    /// Whether this choice holds the assertion on the power source this Mac is running from.
    ///
    /// An unknown source does not count as the adapter: holding on a battery that could not be
    /// identified is the one mistake here that costs the person something they did not choose.
    func keepsAwake(isOnExternalPower: Bool?) -> Bool {
        switch self {
        case .off: return false
        case .whilePluggedIn: return isOnExternalPower == true
        case .always: return true
        }
    }
}

enum RemoteAccessKeepAwakeDefaults {
    /// What `pmset -g assertions` shows beside Threading while the choice is holding.
    static let assertionReason = "Threading is keeping this Mac reachable for Remote Access"
}

// MARK: - Power source

/// Which power source this Mac is running from, and when that changes.
@MainActor
protocol PowerSourceObserving: AnyObject {
    /// True on the adapter, false on battery or a UPS, nil when macOS would not say.
    var isOnExternalPower: Bool? { get }
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// Reads the providing power source from IOKit and is told when it changes.
///
/// Power-source notifications are rare — plugging in, unplugging, a UPS taking over — and the
/// read is one call to `powerd`, so it runs where the notification arrives, on the main run loop.
@MainActor
final class SystemPowerSourceObserver: PowerSourceObserving {
    private(set) var isOnExternalPower: Bool?
    private var onChange: (@MainActor () -> Void)?
    // Written on the main actor and read in deinit, which is nonisolated. The run-loop source
    // holds this object unretained, so it must not outlive it.
    nonisolated(unsafe) private var source: CFRunLoopSource?

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        isOnExternalPower = Self.readIsOnExternalPower()
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observer = Unmanaged<SystemPowerSourceObserver>
                .fromOpaque(context)
                .takeUnretainedValue()
            MainActor.assumeIsolated { observer.powerSourceChanged() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
        source = created
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        source = nil
        onChange = nil
    }

    deinit {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func powerSourceChanged() {
        let current = Self.readIsOnExternalPower()
        guard current != isOnExternalPower else { return }
        isOnExternalPower = current
        onChange?()
    }

    private static func readIsOnExternalPower() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
            return nil
        }
        return (type as String) == kIOPMACPowerKey
    }
}

// MARK: - Inhibitor

/// What `RemoteAccessCoordinator` tells about its own lifecycle.
@MainActor
protocol RemoteAccessKeepAwakeManaging: AnyObject {
    /// True from the moment Remote Access starts until it stops or fails, the same window its
    /// process activity covers.
    func setRemoteAccessActive(_ isActive: Bool)
}

/// Holds an idle-sleep assertion while Remote Access is active and the person's choice says to.
///
/// Watches the setting and the power source only while Remote Access is active, so a Mac with
/// Remote Access off pays for nothing, and releases the moment any of the three stops holding:
/// unplugging under "Plugged in" hands idle sleep back to macOS at once rather than at the next
/// settings visit.
@MainActor
final class RemoteAccessKeepAwakeInhibitor: RemoteAccessKeepAwakeManaging {
    private let choice: @MainActor () -> RemoteAccessKeepAwake
    private let powerSource: any PowerSourceObserving
    private let assertion: any IdleSystemSleepAsserting
    private let observations: AppEventObservations

    private var isRemoteAccessActive = false
    private var isHoldingAssertion = false

    init(
        center: NotificationCenter = .default,
        choice: @escaping @MainActor () -> RemoteAccessKeepAwake,
        powerSource: (any PowerSourceObserving)? = nil,
        assertion: (any IdleSystemSleepAsserting)? = nil
    ) {
        observations = AppEventObservations(center: center)
        self.choice = choice
        self.powerSource = powerSource ?? SystemPowerSourceObserver()
        self.assertion = assertion ?? SystemIdleSleepAssertion(
            reason: RemoteAccessKeepAwakeDefaults.assertionReason
        )
    }

    /// Whether the assertion is held right now. For the page and for tests.
    var isKeepingAwake: Bool { isHoldingAssertion }

    func setRemoteAccessActive(_ isActive: Bool) {
        guard isActive != isRemoteAccessActive else { return }
        isRemoteAccessActive = isActive
        if isActive {
            observations.observe(AppSettingsDidChange.self) { [weak self] _ in
                self?.reconcile()
            }
            powerSource.start { [weak self] in
                self?.reconcile()
            }
        } else {
            observations.removeAll()
            powerSource.stop()
        }
        reconcile()
    }

    private func reconcile() {
        let shouldHold = isRemoteAccessActive
            && choice().keepsAwake(isOnExternalPower: powerSource.isOnExternalPower)
        if shouldHold, !isHoldingAssertion {
            isHoldingAssertion = assertion.acquire()
        } else if !shouldHold, isHoldingAssertion, assertion.release() {
            isHoldingAssertion = false
        }
    }
}
