import Foundation
import Network
import os
import ThreadingRemoteKit

/// Every listener the remote-access server is answering on, and the rules that decide which
/// addresses those are.
///
/// One server, one identity, one authorization path. What changes per door is which addresses get
/// an `NWListener`, each pinned with `requiredLocalEndpoint` so a door can never accidentally
/// answer on another door's network. `0.0.0.0` is never bound: a wildcard bind is exactly the
/// "publishes Threading only inside the owner's tailnet" promise being broken quietly.
///
/// Mutable state belongs to the queue handed in at construction, which is the server's own
/// `RemoteAccessDefaults.queueLabel` queue. `status` and `requestedBindings` are read from other
/// executors and are published under a lock; every mutation happens on the queue.
final class RemoteListenerSet: @unchecked Sendable {

    // MARK: - Types

    /// One `NWListener` and what it was asked to bind.
    ///
    /// Mutable, and owned by the set's queue: every read and write happens there, which is why
    /// it can be handed to a Network.framework callback that runs on the same queue.
    private final class DoorListener: @unchecked Sendable {
        let listener: NWListener
        let door: RemoteAccessDoor
        let address: RemoteNetworkAddress
        let port: UInt16
        var isReady = false
        var failure: RemoteDoorUnreachableReason?

        init(listener: NWListener, door: RemoteAccessDoor, address: RemoteNetworkAddress, port: UInt16) {
            self.listener = listener
            self.door = door
            self.address = address
            self.port = port
        }

        var binding: RemoteListenerBinding {
            RemoteListenerBinding(door: door, address: address, port: port)
        }
    }

    // MARK: - Properties

    /// The loopback address as an interface-shaped value, so every door is stored the same way.
    static let loopbackAddress = RemoteNetworkAddress(
        interfaceName: RemoteInterfaceDefaults.loopbackInterfacePrefix + "0",
        address: RemoteAccessDefaults.host,
        isIPv6: false
    )

    /// Published whenever a door changes state. Called on the owning queue.
    ///
    /// Behind a lock because the coordinator installs it from the main actor while the queue is
    /// already running.
    var onStatusChange: (@Sendable (RemoteListenerStatus) -> Void)? {
        get { statusHandlerStorage.withLock { $0 } }
        set { statusHandlerStorage.withLock { $0 = newValue } }
    }

    /// Where a door transition is written.
    ///
    /// Injectable for the same reason the server's client-diagnostics receiver is: a hosted test
    /// runs inside the shipping app, so a journal call in a test appends to the developer's own
    /// support journal.
    var journal: (@Sendable (RemoteDiagnosticEvent, RemoteDiagnosticLevel, [RemoteDiagnosticField: String]) -> Void) {
        get { journalStorage.withLock { $0 } }
        set { journalStorage.withLock { $0 = newValue } }
    }

    /// Where an accepted socket goes. Installed by the server once it is fully constructed, so
    /// it lives behind a lock like the status handler.
    var onConnection: (@Sendable (NWConnection) -> Void)? {
        get { connectionHandlerStorage.withLock { $0 } }
        set { connectionHandlerStorage.withLock { $0 = newValue } }
    }

    var status: RemoteListenerStatus { statusStorage.withLock { $0 } }

    /// What every live listener was asked to bind, whether or not it is answering.
    ///
    /// `status` reports what is *answering*; this reports what was *asked for*. The difference is
    /// the assertion that keeps one door from binding another door's addresses, which no
    /// readiness-based view can make.
    var requestedBindings: [RemoteListenerBinding] {
        requestedStorage.withLock { $0 }
    }

    /// The object identity of each live listener, keyed by the address it is pinned to.
    ///
    /// Enabling a door must rebuild that door's listeners and leave every other door's alone,
    /// including loopback's. Identity is the only way to tell "left alone" from "torn down and
    /// rebuilt to the same address".
    var listenerIdentities: [RemoteNetworkAddress: ObjectIdentifier] {
        identityStorage.withLock { $0 }
    }

    private let queue: DispatchQueue
    private let addressSource: RemoteNetworkAddressSource
    private let connectionHandlerStorage =
        OSAllocatedUnfairLock<(@Sendable (NWConnection) -> Void)?>(initialState: nil)
    private let journalStorage = OSAllocatedUnfairLock<
        @Sendable (RemoteDiagnosticEvent, RemoteDiagnosticLevel, [RemoteDiagnosticField: String]) -> Void
    >(initialState: { event, level, fields in
        MacRemoteDiagnostics.record(event, level: level, fields: fields)
    })
    private let statusStorage = OSAllocatedUnfairLock<RemoteListenerStatus>(initialState: .idle)
    private let statusHandlerStorage =
        OSAllocatedUnfairLock<(@Sendable (RemoteListenerStatus) -> Void)?>(initialState: nil)
    private let requestedStorage = OSAllocatedUnfairLock<[RemoteListenerBinding]>(initialState: [])
    private let identityStorage =
        OSAllocatedUnfairLock<[RemoteNetworkAddress: ObjectIdentifier]>(initialState: [:])

    /// Queue-owned state.
    private var listeners: [RemoteAccessDoor: [RemoteNetworkAddress: DoorListener]] = [:]
    private var configuration = RemoteListenerConfiguration()
    private var resolvedPort: UInt16?
    private var firewall: RemoteFirewallHint = .unknown
    private var pathMonitor: NWPathMonitor?
    private var pendingRebuild = false
    private var startCompletion: (@Sendable (RemoteListenerStartOutcome) -> Void)?
    /// Which start a deadline belongs to. Without it, a stop-and-start inside the deadline
    /// window lets the old start's timer fail the new one.
    private var startGeneration = 0
    private var isRunning = false

    // MARK: - Initialization

    init(
        queue: DispatchQueue,
        addressSource: @escaping RemoteNetworkAddressSource = RemoteNetworkInterfaces.current
    ) {
        self.queue = queue
        self.addressSource = addressSource
    }

    // MARK: - Lifecycle

    /// Binds loopback, then every enabled door, and reports the port actually taken.
    ///
    /// The completion runs exactly once, on the owning queue.
    func start(
        configuration: RemoteListenerConfiguration,
        completion: @escaping @Sendable (RemoteListenerStartOutcome) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning else {
                if let port = self.resolvedPort {
                    completion(.listening(port: port))
                } else {
                    completion(.failed(.loopbackUnavailable))
                }
                return
            }
            self.isRunning = true
            self.startGeneration += 1
            self.configuration = configuration
            self.startCompletion = completion
            self.armStartDeadline(generation: self.startGeneration)
            self.bindLoopback(candidates: configuration.portCandidates, index: 0)
        }
    }

    /// Rebuilds only the doors whose selection changed. Loopback and unaffected doors keep the
    /// listeners they already have, so turning one door on does not interrupt another.
    func update(doors: Set<RemoteAccessDoor>) {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            guard doors != self.configuration.doors else { return }
            self.configuration.doors = doors
            self.rebuildRoutableDoors()
        }
    }

    /// Re-reads the interface list and applies the difference. Cheap enough for a path callback:
    /// one `getifaddrs` over the configured interfaces, and listeners that are still correct are
    /// left alone rather than recreated.
    func refreshAddresses() {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.rebuildRoutableDoors()
        }
    }

    /// Cancels every listener and does not return until the kernel has actually let go of the
    /// port.
    ///
    /// The wait is the difference between a sticky port and a nearly sticky one. `cancel()` is
    /// asynchronous, and a listener that is still cancelling still owns `127.0.0.1:<port>`, so an
    /// immediate restart — which is exactly what turning Remote Access off and on again does —
    /// hit `EADDRINUSE` and walked to the next port in the range. Measured: without this, one
    /// restart in three moved the port.
    func stop() {
        let cancelled = DispatchSemaphore(value: 0)
        var pending = 0
        queue.sync {
            isRunning = false
            pathMonitor?.cancel()
            pathMonitor = nil
            let entries = listeners.values.flatMap { $0.values }
            pending = entries.count
            for entry in entries {
                entry.listener.stateUpdateHandler = { state in
                    guard case .cancelled = state else { return }
                    cancelled.signal()
                }
                entry.listener.cancel()
            }
            listeners.removeAll()
            resolvedPort = nil
            configuration = RemoteListenerConfiguration()
            firewall = .unknown
            finishStart(.failed(.loopbackUnavailable))
            publish()
        }
        // Outside the queue on purpose: the cancellation callbacks run on it, so waiting inside
        // would wait for a queue this thread is holding. Bounded by one shared deadline rather
        // than one per listener, so a wedged listener cannot multiply the wait.
        let deadline = DispatchTime.now() + RemoteAccessDefaults.listenerCancelTimeout
        for _ in 0..<pending where cancelled.wait(timeout: deadline) == .timedOut {
            ThreadingLogger.remote.error("Remote access listener did not report cancellation")
            break
        }
    }

    // MARK: - Loopback

    /// Walks the candidate ports in order until one binds on loopback.
    ///
    /// Loopback decides the port for every door on purpose. A door listener that cannot take the
    /// resolved port reports itself unreachable rather than moving the port, because a port that
    /// moves when an interface appears is not sticky, and stickiness is the whole point.
    private func bindLoopback(candidates: [UInt16], index: Int) {
        guard index < candidates.count else {
            ThreadingLogger.remote.error(
                "Remote access listener found no free port in its range"
            )
            failStart(.portRangeInUse)
            return
        }

        let port = candidates[index]
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(RemoteAccessDefaults.host),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        // Reuse recovers a sticky port from a previous run's lingering sockets. It does not let
        // two listeners share the exact same address and port: that still fails with
        // `EADDRINUSE`, which is what makes the walk below detect a real collision.
        parameters.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: parameters) else {
            failStart(.loopbackUnavailable)
            return
        }

        let entry = DoorListener(
            listener: listener,
            door: .loopback,
            address: Self.loopbackAddress,
            port: port
        )
        listeners[.loopback] = [Self.loopbackAddress: entry]
        publish()

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard self.listeners[.loopback]?[Self.loopbackAddress] === entry else { return }
                entry.isReady = true
                self.resolvedPort = port
                ThreadingLogger.remote.info(
                    "Remote access server listening on port \(port, privacy: .public)"
                )
                self.rebuildRoutableDoors()
                self.readFirewallHint()
                self.publish()
                self.finishStart(.listening(port: port))
            case .waiting(let error) where Self.isAddressInUse(error):
                self.retryLoopback(entry: entry, candidates: candidates, index: index)
            case .failed(let error):
                if Self.isAddressInUse(error) {
                    self.retryLoopback(entry: entry, candidates: candidates, index: index)
                } else {
                    ThreadingLogger.remote.error(
                        "Remote access listener failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                    self.failStart(.loopbackUnavailable)
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let handler = self?.onConnection else {
                connection.cancel()
                return
            }
            handler(connection)
        }
        listener.start(queue: queue)
    }

    private func retryLoopback(entry: DoorListener, candidates: [UInt16], index: Int) {
        guard listeners[.loopback]?[Self.loopbackAddress] === entry else { return }
        cancel(entry)
        listeners[.loopback] = nil
        bindLoopback(candidates: candidates, index: index + 1)
    }

    // MARK: - Routable doors

    /// Applies the current door selection and interface list to the listener set.
    ///
    /// Deliberately a diff rather than a teardown: a listener whose door is still enabled and
    /// whose address is still held stays exactly as it is, so a Wi-Fi change does not drop a
    /// live connection on Ethernet, and turning one door on does not touch another.
    private func rebuildRoutableDoors() {
        guard let port = resolvedPort else { return }
        let enabled = configuration.bindableDoors
        let classified = RemoteDoorClassification.doors(for: addressSource())

        for door in RemoteAccessDoor.allCases where door != .loopback {
            let wanted: [RemoteNetworkAddress] = enabled.contains(door)
                ? (classified[door] ?? [])
                : []
            var existing = listeners[door] ?? [:]

            for (address, entry) in existing where !wanted.contains(address) {
                cancel(entry)
                existing[address] = nil
            }
            for address in wanted where existing[address] == nil {
                guard let entry = makeListener(door: door, address: address, port: port) else {
                    continue
                }
                existing[address] = entry
            }
            listeners[door] = existing.isEmpty ? nil : existing
        }

        updatePathMonitor()
        publish()
    }

    private func makeListener(
        door: RemoteAccessDoor,
        address: RemoteNetworkAddress,
        port: UInt16
    ) -> DoorListener? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(address.address),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        parameters.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: parameters) else { return nil }
        let entry = DoorListener(listener: listener, door: door, address: address, port: port)

        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.listeners[door]?[address] === entry else { return }
            switch state {
            case .ready:
                entry.isReady = true
                entry.failure = nil
                self.publish()
            case .waiting(let error):
                entry.isReady = false
                entry.failure = Self.reason(for: error)
                self.publish()
            case .failed(let error):
                entry.isReady = false
                entry.failure = Self.reason(for: error)
                // A failed listener stays in the set holding its reason. The next path change
                // rebuilds it; leaving it out would report the door as merely "no interface"
                // when something is actually sitting on its port.
                listener.cancel()
                self.publish()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let handler = self?.onConnection else {
                connection.cancel()
                return
            }
            handler(connection)
        }
        listener.start(queue: queue)
        return entry
    }

    private func cancel(_ entry: DoorListener) {
        entry.listener.stateUpdateHandler = nil
        entry.listener.cancel()
    }

    /// The path monitor only runs while a routable door is selected, so the shipped default
    /// (no routable doors) costs nothing.
    private func updatePathMonitor() {
        let needsMonitor = !configuration.bindableDoors.subtracting([.loopback]).isEmpty
        if needsMonitor, pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in
                self?.scheduleRebuild()
            }
            monitor.start(queue: queue)
            pathMonitor = monitor
        } else if !needsMonitor, let monitor = pathMonitor {
            monitor.cancel()
            pathMonitor = nil
        }
    }

    /// A path change arrives several times while an interface settles, and each one would
    /// otherwise re-enumerate. One coalesced rebuild per burst is enough.
    private func scheduleRebuild() {
        guard isRunning, !pendingRebuild else { return }
        pendingRebuild = true
        queue.asyncAfter(deadline: .now() + RemoteAccessDefaults.pathChangeCoalescing) {
            [weak self] in
            guard let self else { return }
            self.pendingRebuild = false
            guard self.isRunning else { return }
            self.rebuildRoutableDoors()
        }
    }

    // MARK: - Status

    private func publish() {
        let previous = statusStorage.withLock { $0.doors }
        var doors: [RemoteAccessDoor: RemoteAccessDoorState] = [:]
        for door in RemoteAccessDoor.allCases {
            doors[door] = state(of: door)
        }
        let status = RemoteListenerStatus(port: resolvedPort, doors: doors, firewall: firewall)
        statusStorage.withLock { $0 = status }
        requestedStorage.withLock { current in
            current = RemoteAccessDoor.allCases.flatMap { door in
                (listeners[door] ?? [:]).values.map(\.binding).sorted { $0.address < $1.address }
            }
        }
        identityStorage.withLock { current in
            var identities: [RemoteNetworkAddress: ObjectIdentifier] = [:]
            for entry in listeners.values.flatMap({ $0.values }) {
                identities[entry.address] = ObjectIdentifier(entry.listener)
            }
            current = identities
        }
        journalDoorTransitions(to: doors, from: previous)
        onStatusChange?(status)
    }

    private func state(of door: RemoteAccessDoor) -> RemoteAccessDoorState {
        if door == .loopback {
            guard let entry = listeners[.loopback]?[Self.loopbackAddress] else { return .off }
            return entry.isReady ? .bound([entry.binding]) : .binding
        }
        guard configuration.doors.contains(door) else { return .off }
        guard door.isBindable else { return .notReachable(.notAvailableYet) }
        guard resolvedPort != nil else { return .binding }

        let entries = (listeners[door] ?? [:]).values
        guard !entries.isEmpty else { return .notReachable(.noInterface) }
        let ready = entries.filter(\.isReady).map(\.binding).sorted { $0.address < $1.address }
        if !ready.isEmpty { return .bound(ready) }
        // Something holding the port is the more actionable answer, so it wins over an address
        // that simply is not here.
        let failures = Set(entries.compactMap(\.failure))
        for reason in RemoteDoorUnreachableReason.reportingPriority where failures.contains(reason) {
            return .notReachable(reason)
        }
        return .binding
    }

    // MARK: - Deadlines

    /// A listener that never answers is a state, not a wait. Without this the coordinator would
    /// sit in Starting forever, which is the failure shape the relay already taught us to name.
    private func armStartDeadline(generation: Int) {
        queue.asyncAfter(deadline: .now() + RemoteAccessDefaults.listenerStartTimeout) {
            [weak self] in
            guard let self,
                  self.startGeneration == generation,
                  self.startCompletion != nil else { return }
            ThreadingLogger.remote.error("Remote access listener did not become ready in time")
            self.failStart(.loopbackUnavailable)
        }
    }

    /// Ends a start that cannot produce a listener: nothing stays bound, and the set is idle
    /// again so the user's retry is a real retry rather than a replay of this answer.
    private func failStart(_ failure: RemoteListenerFailure) {
        for entry in listeners.values.flatMap({ $0.values }) { cancel(entry) }
        listeners.removeAll()
        resolvedPort = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        isRunning = false
        publish()
        finishStart(.failed(failure))
    }

    private func finishStart(_ outcome: RemoteListenerStartOutcome) {
        guard let completion = startCompletion else { return }
        startCompletion = nil
        completion(outcome)
    }

    // MARK: - Firewall

    /// Read once per successful start, off this queue and off the main actor, because it spawns
    /// two child processes. The answer is a hint that is allowed to stay unknown.
    private func readFirewallHint() {
        let executableURL = Bundle.main.executableURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let hint = RemoteFirewallProbe.read(executableURL: executableURL)
            self?.queue.async {
                guard let self, self.isRunning else { return }
                self.firewall = hint
                self.publish()
            }
        }
    }

    // MARK: - Diagnostics

    /// A door transition, without the address it happened at.
    ///
    /// Door granularity rather than per address: what a support report needs is "the LAN door
    /// stopped answering and here is why", not a line per interface. The origin travels as a
    /// truncated hash so two events about the same addresses can be joined without disclosing
    /// where the Mac lives.
    ///
    /// Three states are deliberately not recorded. Loopback is bound whenever Remote Access is
    /// on and has no transition worth a record; `off` is the settings write that caused it; and
    /// `binding` is the moment before an answer, not an answer.
    private func journalDoorTransitions(
        to current: [RemoteAccessDoor: RemoteAccessDoorState],
        from previous: [RemoteAccessDoor: RemoteAccessDoorState]
    ) {
        for door in RemoteAccessDoor.allCases where door != .loopback {
            let now = current[door] ?? .off
            guard now != (previous[door] ?? .off) else { continue }
            var fields: [RemoteDiagnosticField: String] = [
                .transport: door.rawValue,
                .result: now.diagnosticResult
            ]
            let event: RemoteDiagnosticEvent
            let level: RemoteDiagnosticLevel
            switch now {
            case .bound(let bindings):
                event = .hostDoorBound
                level = .info
                let addresses = bindings
                    .map { "\($0.address.interfaceName)|\($0.address.address)" }
                    .joined(separator: ",")
                fields[.origin] = MacRemoteDiagnostics.pseudonym(addresses, prefix: "origin")
            case .notReachable(let reason):
                event = .hostDoorUnreachable
                level = .warning
                fields[.reason] = reason.rawValue
            case .off, .binding:
                continue
            }
            journal(event, level, fields)
        }
    }

    // MARK: - Errors

    private static func isAddressInUse(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return code == .EADDRINUSE
    }

    private static func reason(for error: NWError) -> RemoteDoorUnreachableReason {
        guard case .posix(let code) = error else { return .noInterface }
        switch code {
        case .EADDRINUSE:
            return .portInUse
        default:
            // `EADDRNOTAVAIL` is what an address that has gone away reports, and it is by far
            // the common case here: the interface list moved between enumeration and bind.
            return .noInterface
        }
    }
}
