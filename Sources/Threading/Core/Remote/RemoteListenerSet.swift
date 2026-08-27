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
        /// The bound port as Network.framework's own type. It arrives already valid from
        /// `RemoteListenerPortPlan`, so nothing below has to reconstruct — or default — one.
        let port: NWEndpoint.Port
        var isReady = false
        var failure: RemoteDoorUnreachableReason?

        /// A listener that is not answering and has said why is not going to recover on its own:
        /// a `.failed` listener is already cancelled, and a `.waiting` one is only retried by
        /// Network.framework on its own terms. The next rebuild replaces it rather than trusting
        /// its presence in the set as proof that the address is covered.
        var isStale: Bool { !isReady && failure != nil }

        init(
            listener: NWListener,
            door: RemoteAccessDoor,
            address: RemoteNetworkAddress,
            port: NWEndpoint.Port
        ) {
            self.listener = listener
            self.door = door
            self.address = address
            self.port = port
        }

        var binding: RemoteListenerBinding {
            RemoteListenerBinding(door: door, address: address, port: port.rawValue)
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

    /// What this Mac is currently broadcasting over Bonjour, if anything.
    ///
    /// Published rather than inferred: "the LAN door is bound" and "the LAN door is advertised"
    /// are different facts, and only this one says which name and which TXT record left the
    /// machine.
    var advertisedService: RemoteServiceRegistration? {
        advertisementStorage.withLock { $0 }
    }

    private let queue: DispatchQueue
    private let addressSource: RemoteNetworkAddressSource
    /// Where a Bonjour registration is performed. Injected so a hosted test cannot broadcast the
    /// developer's Mac, and so a test can assert on what was registered.
    private let advertiser: any RemoteServiceAdvertising
    /// This Mac's stable id, which the advertisement names. A closure rather than a global read
    /// so a test can state an id instead of borrowing the developer's own.
    private let hostIDSource: @Sendable () -> String
    /// What a routable listener presents. Asked for on this queue, once per rebuild, and never
    /// on the main actor: resolving it reads files and imports a PKCS#12 container.
    private let identityProvider: any RemoteAccessIdentityProviding
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
    private let advertisementStorage =
        OSAllocatedUnfairLock<RemoteServiceRegistration?>(initialState: nil)

    /// Queue-owned state.
    private var listeners: [RemoteAccessDoor: [RemoteNetworkAddress: DoorListener]] = [:]
    private var configuration = RemoteListenerConfiguration()
    private var resolvedPort: NWEndpoint.Port?
    private var firewall: RemoteFirewallHint = .unknown
    private var pathMonitor: NWPathMonitor?
    private var pendingRebuild = false
    /// Why the routable doors have nothing to present, when they have nothing to present.
    /// Queue-owned like every other listener fact.
    private var identityFailure: RemoteIdentityFailure?
    /// The fingerprint the routable listeners are presenting, kept so the advertisement can be
    /// recomputed on a readiness change without asking the identity store again. Queue-owned.
    private var advertisedFingerprint: RemoteHostFingerprint?
    /// Which listener currently carries the registration. Queue-owned, and part of what decides
    /// whether the advertisement has to be re-applied: the registration lives on a socket, so a
    /// rebuilt listener needs it again even when nothing about the value changed.
    private var advertisedCarrier: ObjectIdentifier?
    private var startCompletion: (@Sendable (RemoteListenerStartOutcome) -> Void)?
    /// Which start a deadline belongs to. Without it, a stop-and-start inside the deadline
    /// window lets the old start's timer fail the new one.
    private var startGeneration = 0
    private var isRunning = false

    // MARK: - Initialization

    init(
        queue: DispatchQueue,
        addressSource: @escaping RemoteNetworkAddressSource = RemoteNetworkInterfaces.current,
        identityProvider: any RemoteAccessIdentityProviding = RemoteAccessIdentityStore.shared,
        advertiser: any RemoteServiceAdvertising = RemoteServiceAdvertisers.standard(),
        hostIDSource: @escaping @Sendable () -> String = { RemoteHostIdentity.current.id }
    ) {
        self.queue = queue
        self.addressSource = addressSource
        self.identityProvider = identityProvider
        self.advertiser = advertiser
        self.hostIDSource = hostIDSource
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
                    completion(.listening(port: port.rawValue))
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

    /// Turns the Bonjour advertisement on or off without touching a listener.
    ///
    /// Separate from `update(doors:)` because it is a separate decision: the door is whether this
    /// Mac answers on the network, and this is whether it says so out loud.
    func update(isDiscoveryEnabled: Bool) {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            guard isDiscoveryEnabled != self.configuration.isDiscoveryEnabled else { return }
            self.configuration.isDiscoveryEnabled = isDiscoveryEnabled
            self.updateAdvertisement()
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
            // Before the listeners go: a registration outliving the socket behind it would leave
            // the network being told about a door that is closed.
            withdrawAdvertisement()
            advertisedFingerprint = nil
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
    private func bindLoopback(candidates: [NWEndpoint.Port], index: Int) {
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
            port: port
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
                    "Remote access server listening on port \(port.rawValue, privacy: .public)"
                )
                self.rebuildRoutableDoors()
                self.readFirewallHint()
                self.publish()
                self.finishStart(.listening(port: port.rawValue))
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

    private func retryLoopback(entry: DoorListener, candidates: [NWEndpoint.Port], index: Int) {
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

        // One resolution per rebuild, and only when a door that needs one is enabled: the
        // shipped default binds loopback alone and must not mint a certificate for it.
        var identity: RemoteAccessIdentity?
        identityFailure = nil
        if enabled.contains(where: { $0.requiresTLS && !(classified[$0] ?? []).isEmpty }) {
            switch identityProvider.currentIdentity() {
            case .success(let resolved):
                identity = resolved
            case .failure(let failure):
                identityFailure = failure
                ThreadingLogger.remote.error(
                    "Remote access identity unavailable: \(failure.rawValue, privacy: .public)"
                )
            }
        }
        // The advertisement names the certificate the doors present, so it follows a rotation for
        // free: `reloadIdentity` rebuilds the routable listeners, this reads the promoted
        // identity, and `publish` re-registers with the new fingerprint on the same port.
        advertisedFingerprint = identity?.fingerprint

        for door in RemoteAccessDoor.allCases where door != .loopback {
            let wanted: [RemoteNetworkAddress] = enabled.contains(door)
                ? (classified[door] ?? [])
                : []
            var existing = listeners[door] ?? [:]

            // An address that is no longer wanted goes; so does one whose listener has failed,
            // so that a port freed since the last pass, or an address that had not finished
            // configuring, is bound again on this pass rather than reported dead until the door
            // is toggled.
            for (address, entry) in existing where !wanted.contains(address) || entry.isStale {
                cancel(entry)
                existing[address] = nil
            }
            for address in wanted where existing[address] == nil {
                guard let entry = makeListener(
                    door: door,
                    address: address,
                    port: port,
                    identity: identity
                ) else { continue }
                existing[address] = entry
            }
            listeners[door] = existing.isEmpty ? nil : existing
        }

        updatePathMonitor()
        publish()
    }

    /// One listener, pinned to one address, presenting this Mac's identity when the door is a
    /// routable one.
    ///
    /// A door that needs an identity and has none binds **nothing**. There is no cleartext
    /// fallback on purpose: falling back would put a bearer token on the network the identity
    /// exists to protect, and it would do it silently.
    private func makeListener(
        door: RemoteAccessDoor,
        address: RemoteNetworkAddress,
        port: NWEndpoint.Port,
        identity: RemoteAccessIdentity?
    ) -> DoorListener? {
        let parameters: NWParameters
        if door.requiresTLS {
            guard let identity, let options = Self.tlsOptions(for: identity) else { return nil }
            // The HTTP and WebSocket phases above this are unchanged: `NWConnection` hands them
            // the decrypted stream, so TLS is a property of the parameters and of nothing else.
            parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters.tcp
        }
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(address.address),
            port: port
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
                entry.failure = Self.reason(for: error, door: door)
                self.publish()
            case .failed(let error):
                entry.isReady = false
                entry.failure = Self.reason(for: error, door: door)
                // A failed listener stays in the set holding its reason until the next rebuild,
                // which replaces it (see `isStale`); leaving it out would report the door as
                // merely "no interface" when something is actually sitting on its port.
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

    /// The security parameters a routable listener answers with.
    ///
    /// TLS 1.2 is the floor rather than the negotiated version: a current phone and this Mac
    /// settle on TLS 1.3 with `TLS_AES_256_GCM_SHA384` and ECDSA P-256, which is what the spike
    /// measured, and stating a floor keeps that from silently becoming something older.
    private static func tlsOptions(for identity: RemoteAccessIdentity) -> NWProtocolTLS.Options? {
        guard let secIdentity = sec_identity_create(identity.secIdentity) else { return nil }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(
            options.securityProtocolOptions,
            .TLSv12
        )
        return options
    }

    /// Rebuilds every routable listener so it presents whatever the identity store now holds.
    ///
    /// This is the second half of a rotation: the store has already promoted the successor, and
    /// the sockets have to be replaced to present it. The port does not move and loopback is not
    /// touched, so the Hosted bridge and Serve carry on through the change.
    func reloadIdentity() {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            for (door, entries) in self.listeners where door != .loopback {
                for entry in entries.values { self.cancel(entry) }
                self.listeners[door] = nil
            }
            self.rebuildRoutableDoors()
        }
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
        let status = RemoteListenerStatus(
            port: resolvedPort?.rawValue,
            doors: doors,
            firewall: firewall
        )
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
        updateAdvertisement()
        onStatusChange?(status)
    }

    // MARK: - Discovery

    /// Publishes, replaces or withdraws the Bonjour advertisement to match what is bound.
    ///
    /// Called from `publish`, so the advertisement follows readiness rather than intent: a LAN
    /// door that is selected but has no address answering announces nothing, and the moment its
    /// listener is ready the announcement goes out. The identity is required as well, because the
    /// TXT record's whole purpose is to say which certificate the port behind it presents.
    private func updateAdvertisement() {
        let desired = desiredAdvertisement()
        let current = advertisementStorage.withLock { $0 }
        let carrier = desired == nil ? nil : advertisementCarrier()
        let carrierID = carrier.map(ObjectIdentifier.init)
        // The carrier is part of the state, not just the value. A Wi-Fi change rebuilds the LAN
        // listeners, and a registration left on the cancelled one disappears with it: the value
        // would still look current while nothing on the network could hear it.
        guard desired != current || carrierID != advertisedCarrier else { return }

        guard let desired, let carrier else {
            withdrawAdvertisement()
            return
        }
        advertiser.apply(desired, to: carrier)
        advertisementStorage.withLock { $0 = desired }
        advertisedCarrier = carrierID
        journal(.hostDiscoveryRegistered, .info, [
            .transport: RemoteAccessDoor.lan.rawValue,
            .origin: advertisedOriginPseudonym(),
        ])
    }

    private func withdrawAdvertisement() {
        advertisedCarrier = nil
        guard advertisementStorage.withLock({ $0 }) != nil else { return }
        advertiser.apply(nil, to: nil)
        advertisementStorage.withLock { $0 = nil }
        journal(.hostDiscoveryWithdrawn, .info, [.transport: RemoteAccessDoor.lan.rawValue])
    }

    /// What should be advertised right now, or nil when nothing should be.
    private func desiredAdvertisement() -> RemoteServiceRegistration? {
        guard isRunning, configuration.isDiscoveryEnabled else { return nil }
        guard let fingerprint = advertisedFingerprint else { return nil }
        let advertised = RemoteAccessDoor.allCases.filter(\.isAdvertisedOverBonjour)
        let bindings = advertised
            .flatMap { (listeners[$0] ?? [:]).values }
            .filter(\.isReady)
            .map(\.binding)
        guard let port = bindings.map(\.port).min() else { return nil }
        let advertisement = RemoteHostAdvertisement(
            hostID: hostIDSource(),
            protocolVersion: RemoteProtocol.current,
            fingerprint: fingerprint
        )
        // A record that cannot be carried in one response is a record nobody reads reliably. The
        // three values are far inside the limits, so this refuses rather than truncates: a
        // truncated fingerprint would be a pin that matches something it should not.
        guard advertisement.fitsTXTLimits else {
            ThreadingLogger.remote.error("Remote access advertisement exceeds the TXT limits")
            return nil
        }
        return RemoteServiceRegistration(advertisement: advertisement, port: port)
    }

    /// The listener that carries the registration.
    ///
    /// One, deterministically the lowest-sorted ready LAN address, because Bonjour advertises a
    /// host rather than an address: the SRV record names this Mac's `.local` name and the address
    /// records behind it already cover every interface. A second registration of the same name
    /// and port is a conflict the platform resolves by renaming one of them.
    private func advertisementCarrier() -> NWListener? {
        RemoteAccessDoor.allCases
            .filter(\.isAdvertisedOverBonjour)
            .flatMap { (listeners[$0] ?? [:]).values }
            .filter(\.isReady)
            .sorted { $0.address < $1.address }
            .first?
            .listener
    }

    /// The addresses behind the advertisement, as a hash. The instance name and the addresses
    /// themselves are exactly what an advertisement discloses to the network; a support report
    /// carries neither.
    private func advertisedOriginPseudonym() -> String {
        let addresses = RemoteAccessDoor.allCases
            .filter(\.isAdvertisedOverBonjour)
            .flatMap { (listeners[$0] ?? [:]).values }
            .filter(\.isReady)
            .map(\.address)
            .sorted()
            .map { "\($0.interfaceName)|\($0.address)" }
            .joined(separator: ",")
        return MacRemoteDiagnostics.pseudonym(addresses, prefix: "origin")
    }

    private func state(of door: RemoteAccessDoor) -> RemoteAccessDoorState {
        if door == .loopback {
            guard let entry = listeners[.loopback]?[Self.loopbackAddress] else { return .off }
            return entry.isReady ? .bound([entry.binding]) : .binding
        }
        guard configuration.doors.contains(door) else { return .off }
        guard door.isBindable else { return .notReachable(.notAvailableYet) }
        guard resolvedPort != nil else { return .binding }
        if door.requiresTLS, identityFailure != nil {
            return .notReachable(.identityUnavailable)
        }

        let entries = (listeners[door] ?? [:]).values
        guard !entries.isEmpty else { return .notReachable(door.absentInterfaceReason) }
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

    private static func reason(
        for error: NWError,
        door: RemoteAccessDoor
    ) -> RemoteDoorUnreachableReason {
        guard case .posix(let code) = error else { return door.absentInterfaceReason }
        switch code {
        case .EADDRINUSE:
            return .portInUse
        default:
            // `EADDRNOTAVAIL` is what an address that has gone away reports, and it is by far
            // the common case here: the interface list moved between enumeration and bind. The
            // door decides how that reads, because a tailnet address vanishing is `tailscaled`
            // going away rather than a network cable.
            return door.absentInterfaceReason
        }
    }
}
