import Foundation
import Network
import ThreadingRemoteKit

/// Bounds on what browsing may hold, because the input is a network full of strangers.
///
/// A Bonjour browse is one of the few surfaces on this phone whose cardinality is decided by
/// whoever else is on the Wi-Fi. Nothing here grows with that: the tracked set has a ceiling, one
/// service is resolved at a time, and a resolution that does not answer inside its deadline is
/// dropped rather than retried forever.
enum RemoteDiscoveryLimits {

    /// How many advertised services are remembered at once. A café network could advertise
    /// hundreds; none of them can be a paired Mac unless its fingerprint matches a pin this phone
    /// already holds, so there is nothing to gain from keeping more than a handful.
    static let maximumTrackedServices = 16

    /// How many Macs may hold a discovered address. One entry per paired Mac is the real bound;
    /// this is the ceiling that makes it structural.
    static let maximumTrackedHosts = 8

    /// How long resolving one service may take before it is abandoned.
    static let resolveTimeout: TimeInterval = 4
}

/// One Threading service seen on this network, before anything has been decided about it.
struct DiscoveredRemoteService: Equatable {

    /// The Bonjour endpoint, which is what a resolution is performed against. The instance name
    /// inside it is opaque and never rendered or recorded.
    let endpoint: NWEndpoint
    /// The three values the TXT record carried.
    let advertisement: RemoteHostAdvertisement

    /// The opaque instance name, used only to tell one tracked service from another.
    var instanceName: String? {
        guard case .service(let name, _, _, _) = endpoint else { return nil }
        return name
    }
}

/// Which paired Mac a discovered service is, if it is one at all.
///
/// **Discovery matches; it never trusts.** The only question asked here is whether the advertised
/// fingerprint is one this phone already accepts for a Mac it has already paired with, and the
/// answer can only ever be "this is that Mac's current address". Nothing in this file can create
/// a pairing, learn a pin, or widen one: a service whose fingerprint matches nothing held is
/// ignored, and an unpaired Mac advertising the same service type is exactly that case.
///
/// The fingerprint is also not a substitute for the TLS check. A service can claim any
/// fingerprint it likes; claiming one it cannot present buys an attempt against a pinned
/// connection that then refuses it, which is the same refusal any wrong certificate gets.
enum RemoteDiscoveryMatch {

    /// The paired record a service belongs to, or nil.
    ///
    /// A guest capability is never a match: a one-chat token is not the owner of the Mac, holds
    /// no pin, and must not be given an address on the word of a broadcast.
    static func pairedHost(
        for advertisement: RemoteHostAdvertisement,
        in hosts: [PairedRemoteHost]
    ) -> PairedRemoteHost? {
        let matching = hosts.filter { host in
            guard host.isOwnerDevice, let pins = host.pinSet else { return false }
            return pins.matches(digest: advertisement.fingerprint.digest)
        }
        // The host id decides between two records that pin the same certificate, which is what
        // one Mac present as several records looks like. The fingerprint is what makes any of
        // them a match at all.
        return matching.first { ($0.hostID ?? $0.id) == advertisement.hostID } ?? matching.first
    }
}

/// The addresses paired Macs were last found at on this network.
///
/// **Deliberately not persisted with the pairing.** It is a fact about the network this phone is
/// on right now, and the record it would otherwise be written into is a Keychain item holding a
/// bearer, rewritten on every change. A relaunch re-browses, which is cheaper and more correct
/// than remembering an address from another building.
struct RemoteDiscoveredAddresses: Equatable {

    private var byHostRecordID: [String: URL] = [:]
    /// Insertion order, so the oldest entry is the one dropped at the ceiling.
    private var order: [String] = []

    init() {}

    var count: Int { byHostRecordID.count }

    subscript(hostRecordID: String) -> URL? { byHostRecordID[hostRecordID] }

    /// Records an address for a Mac. Returns whether anything changed, so a caller can stay quiet
    /// when a service is re-announced at the address it already had.
    @discardableResult
    mutating func record(_ url: URL, forHostRecordID id: String) -> Bool {
        guard byHostRecordID[id] != url else { return false }
        if byHostRecordID[id] == nil {
            order.append(id)
            while order.count > RemoteDiscoveryLimits.maximumTrackedHosts {
                byHostRecordID[order.removeFirst()] = nil
            }
        }
        byHostRecordID[id] = url
        return true
    }

    mutating func forget(hostRecordID id: String) {
        byHostRecordID[id] = nil
        order.removeAll { $0 == id }
    }

    /// Drops every entry whose Mac is no longer paired, so forgetting a Mac forgets where it was.
    mutating func retain(hostRecordIDs: Set<String>) {
        for id in order where !hostRecordIDs.contains(id) { byHostRecordID[id] = nil }
        order.removeAll { !hostRecordIDs.contains($0) }
    }
}

/// Browses for Threading Macs on this network while the app is in front of somebody.
///
/// Three properties are the whole design:
///
/// - **It runs only when it can do something.** No paired Mac means nothing to match against, so
///   the browser is not started at all, which is also what keeps the Local Network alert from
///   appearing before the app has any reason to ask.
/// - **It stops in the background.** A browse is a multicast listener; leaving one running is
///   asking the network questions nobody is waiting for the answers to.
/// - **Denial degrades rather than fails.** If Local Network access is refused the browser never
///   produces results, and the advertised endpoint list is what the phone falls back to — which
///   is the same list a VPN or tailnet address already arrives on.
@MainActor
final class RemoteHostDiscovery {

    /// What a match produced: which paired record, and where it is right now.
    struct Resolution: Equatable {
        let hostRecordID: String
        let baseURL: URL
    }

    /// Called on the main actor when a discovered service resolved to an address for a paired
    /// Mac. The model decides what to do with it; this type never touches a stored record.
    var onResolved: ((Resolution) -> Void)?

    /// The paired Macs to match against. Set by the model whenever its list changes; an empty
    /// list stops the browse, because there is nothing a discovery could mean.
    private(set) var hosts: [PairedRemoteHost] = []

    private var browser: NWBrowser?
    /// Instance name to what it advertised, bounded by `maximumTrackedServices`. Its only job is
    /// to notice a service that is new or has changed, so one advertisement does not become one
    /// resolution per browse callback.
    private var tracked: [String: RemoteHostAdvertisement] = [:]
    private var trackedOrder: [String] = []
    /// Instance names with a resolution in flight, so a re-announcement does not open a second
    /// connection to the same service.
    private var resolving: Set<String> = []
    private let queue = DispatchQueue(label: "codes.threading.mobile.discovery")

    var isBrowsing: Bool { browser != nil }

    /// How many advertised services are being remembered. Read by the tests that assert the
    /// ceiling holds, because "bounded" is a property nothing else can observe.
    var trackedServiceCount: Int { tracked.count }

    // MARK: - Lifecycle

    /// Starts browsing if there is a paired Mac to browse for.
    ///
    /// Idempotent, and also the way the match list is re-stated: calling it again with a changed
    /// list keeps the browser and re-evaluates what is already on the network, because a Mac
    /// paired *after* its announcement was seen would otherwise wait for the next one.
    func start(hosts: [PairedRemoteHost]) {
        let previousKeys = Self.matchKeys(of: self.hosts)
        self.hosts = hosts
        guard hosts.contains(where: { $0.isOwnerDevice && $0.pinSet != nil }) else {
            stop()
            return
        }
        // Only when what a match *depends on* changed. A reconnect rewrites a record's
        // last-connected date, and re-resolving every service for that would be churn.
        if Self.matchKeys(of: hosts) != previousKeys { forgetTracking() }
        guard browser == nil else { return }

        let browser = NWBrowser(
            for: .bonjour(
                type: RemoteDiscoveryDefaults.serviceType,
                domain: RemoteDiscoveryDefaults.serviceDomain
            ),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            let seen = Self.services(in: results)
            let gone = Self.departedNames(in: changes)
            Task { @MainActor [weak self] in
                self?.forget(gone)
                self?.apply(seen)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in self?.stop() }
            default:
                break
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.browseResultsChangedHandler = nil
        browser?.stateUpdateHandler = nil
        browser?.cancel()
        browser = nil
        tracked.removeAll()
        trackedOrder.removeAll()
        resolving.removeAll()
    }

    // MARK: - Results

    /// Reads the browse results into values, dropping anything that is not a well-formed
    /// Threading advertisement.
    nonisolated static func services(in results: Set<NWBrowser.Result>) -> [DiscoveredRemoteService] {
        results.compactMap { result in
            guard case .bonjour(let txt) = result.metadata,
                  let advertisement = RemoteHostAdvertisement.parse(txt: txt.dictionary) else {
                return nil
            }
            return DiscoveredRemoteService(endpoint: result.endpoint, advertisement: advertisement)
        }
    }

    /// What a match depends on: which owner records exist and which certificates they accept.
    static func matchKeys(of hosts: [PairedRemoteHost]) -> Set<String> {
        Set(hosts.compactMap { host -> String? in
            guard host.isOwnerDevice, let pins = host.pinSet else { return nil }
            let next = pins.next.map { $0.bytes.map { String(format: "%02x", $0) }.joined() } ?? ""
            let current = pins.current.bytes.map { String(format: "%02x", $0) }.joined()
            return "\(host.id)|\(current)|\(next)"
        })
    }

    /// The instance names a change set says have gone away.
    ///
    /// A Mac that moves to another address goes through exactly this: mDNS says goodbye and
    /// announces again. Forgetting the name is what makes the re-announcement a *new* service to
    /// resolve rather than one already tracked at an address that has stopped existing, which is
    /// the whole "move the Mac to a different subnet and do nothing on the phone" case.
    nonisolated static func departedNames(in changes: Set<NWBrowser.Result.Change>) -> [String] {
        changes.compactMap { change in
            guard case .removed(let result) = change,
                  case .service(let name, _, _, _) = result.endpoint else { return nil }
            return name
        }
    }

    /// Drops tracked services so a later announcement of the same name is resolved again.
    func forget(_ names: [String]) {
        for name in names {
            tracked[name] = nil
            trackedOrder.removeAll { $0 == name }
            resolving.remove(name)
        }
    }

    /// Forgets everything currently tracked, so the next announcement of any of it resolves
    /// again. Used when a connection to a remembered address failed: whatever that address was,
    /// it is not answering, and the network is the thing to ask again.
    func forgetTracking() {
        tracked.removeAll()
        trackedOrder.removeAll()
        resolving.removeAll()
    }

    /// Decides what each newly seen service is, and resolves the ones that are a paired Mac.
    func apply(_ services: [DiscoveredRemoteService]) {
        for service in services {
            guard let name = service.instanceName else { continue }
            guard tracked[name] != service.advertisement else { continue }
            remember(name, service.advertisement)

            MobileDiagnostics.recordConnectivity(.hostDiscoveryFound, fields: [
                .peer: MobileDiagnostics.pseudonym(service.advertisement.hostID, prefix: "peer"),
                .phase: "browse",
                .result: "found",
                .protocolVersion: String(service.advertisement.protocolVersion),
            ])

            guard let host = RemoteDiscoveryMatch.pairedHost(
                for: service.advertisement,
                in: hosts
            ) else {
                // Somebody else's Mac, or this phone's own Mac before it was paired. Either way
                // there is nothing to learn: pairing is the QR code and only the QR code.
                MobileDiagnostics.recordConnectivity(.hostDiscoveryIgnored, fields: [
                    .peer: MobileDiagnostics.pseudonym(
                        service.advertisement.hostID,
                        prefix: "peer"
                    ),
                    .phase: "browse",
                    .result: "ignored",
                ])
                continue
            }
            resolve(service, for: host)
        }
    }

    private func remember(_ name: String, _ advertisement: RemoteHostAdvertisement) {
        if tracked[name] == nil {
            trackedOrder.append(name)
            while trackedOrder.count > RemoteDiscoveryLimits.maximumTrackedServices {
                let dropped = trackedOrder.removeFirst()
                tracked[dropped] = nil
                resolving.remove(dropped)
            }
        }
        tracked[name] = advertisement
    }

    // MARK: - Resolution

    /// Turns a matched service into an address.
    ///
    /// `NWBrowser` reports service endpoints, not addresses, and the phone's client is built on
    /// `URLSession`, which needs a URL. A short-lived `NWConnection` to the service endpoint is
    /// what the platform offers for that: the path it reaches carries the resolved host and port,
    /// and the connection is cancelled the moment it has them. It is deliberately plain TCP — the
    /// pinned TLS check belongs to the request that follows, not to a name lookup.
    private func resolve(_ service: DiscoveredRemoteService, for host: PairedRemoteHost) {
        guard let name = service.instanceName, !resolving.contains(name) else { return }
        resolving.insert(name)

        let connection = NWConnection(to: service.endpoint, using: .tcp)
        let hostRecordID = host.id
        let finished = RemoteDiscoveryOnce()
        let trace = MobileDiagnostics.connectivityTrace()
        let startedAt = MobileDiagnostics.monotonicNow()
        let diagnosticFields: [RemoteDiagnosticField: String] = [
            .trace: trace,
            .peer: MobileDiagnostics.pseudonym(host.id, prefix: "peer"),
            .transport: RemoteHostEndpointKind.lan,
            .phase: "discovery.resolve",
            .timeoutMS: MobileDiagnostics.milliseconds(RemoteDiscoveryLimits.resolveTimeout),
        ]
        MobileDiagnostics.recordConnectivity(
            .hostRouteStarted,
            fields: diagnosticFields.merging([.result: "started"]) { _, new in new }
        )

        @Sendable func finish(
            _ endpoint: NWEndpoint?,
            result: String,
            code: String? = nil
        ) {
            guard finished.take() else { return }
            connection.stateUpdateHandler = nil
            connection.cancel()
            Task { @MainActor [weak self] in
                self?.resolving.remove(name)
                var fields = diagnosticFields.merging([
                    .result: result,
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                ]) { _, new in new }
                if let code { fields[.code] = code }
                guard let endpoint, let url = Self.baseURL(for: endpoint) else {
                    fields[.result] = "failed"
                    if fields[.code] == nil {
                        fields[.code] = endpoint == nil
                            ? "discovery.noEndpoint"
                            : "discovery.invalidEndpoint"
                    }
                    MobileDiagnostics.recordConnectivity(
                        .hostRouteEnded,
                        level: .warning,
                        fields: fields
                    )
                    return
                }
                fields[.result] = "succeeded"
                fields[.origin] = MobileDiagnostics.originDigest(url)
                MobileDiagnostics.recordConnectivity(.hostRouteEnded, fields: fields)
                guard let self else { return }
                self.onResolved?(Resolution(hostRecordID: hostRecordID, baseURL: url))
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(connection.currentPath?.remoteEndpoint, result: "succeeded")
            case .failed:
                finish(nil, result: "failed", code: "nw.failed")
            case .cancelled:
                finish(nil, result: "cancelled", code: "nw.cancelled")
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + RemoteDiscoveryLimits.resolveTimeout) {
            finish(nil, result: "failed", code: "nw.timeout")
        }
    }

    /// The origin a resolved endpoint becomes.
    ///
    /// `https` always: a routable door presents this Mac's certificate, and a cleartext candidate
    /// is refused by the endpoint policy anyway. An IPv6 literal is bracketed, or `URLComponents`
    /// returns nil and the discovery is quietly dropped instead of quietly wrong.
    static func baseURL(for endpoint: NWEndpoint) -> URL? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        let literal: String
        switch host {
        case .ipv4(let address):
            literal = "\(address)"
        case .ipv6(let address):
            // A link-local address arrives with its zone (`fe80::1%en0`), which no URL can carry.
            let text = "\(address)".split(separator: "%", maxSplits: 1).first.map(String.init) ?? ""
            guard !text.isEmpty else { return nil }
            literal = "[\(text)]"
        case .name(let name, _):
            literal = name
        @unknown default:
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = literal
        components.port = Int(port.rawValue)
        components.path = "/"
        guard let url = components.url, url.host?.isEmpty == false else { return nil }
        return url
    }
}

/// A one-shot flag several network callbacks race for.
///
/// `NWConnection` can report ready, then failed, and the deadline fires regardless; exactly one
/// of them may finish the resolution. Small enough to live beside its only caller.
final class RemoteDiscoveryOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    /// Claims the one turn, and reports whether this caller got it.
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !taken else { return false }
        taken = true
        return true
    }
}
