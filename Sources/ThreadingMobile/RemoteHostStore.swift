import Foundation
import Security
import ThreadingPeerTransport
import ThreadingRemoteKit

struct PairedRemoteHost: Codable, Hashable, Identifiable, Sendable {
    let id: String
    /// Stable Mac identity, separate from `id` because one Mac may have an owner pairing and
    /// several one-chat guest capabilities without either overwriting another in Keychain.
    var hostID: String?
    var shareID: String?
    var scope: String?
    var name: String
    var link: RemoteConnectionLink
    var lastConnectedAt: Date
    /// Owner hosts can advertise more than one route without duplicating the Mac in the device
    /// picker. Optional fields keep Keychain records written by older versions decodable.
    var endpoints: [RemoteHostEndpointDTO]? = nil
    var connectionPolicy: RemoteHostConnectionPolicy? = nil
    var activeEndpointKind: RemoteHostEndpointKind? = nil
    /// Optional zero-setup direct route. It is protected by the same Keychain item as the
    /// Mac-issued remote capability and never copied into an ordinary share link.
    var hostedServiceURL: URL? = nil
    var hostedCredential: PeerDeviceServiceCredential? = nil
    /// The certificate this Mac's pinned doors present, as the 64 lower-case hex characters
    /// `/api/me` carries. Persisted so the pin is in force on the first request after a relaunch
    /// rather than only after a successful `/api/me`, which is the request that would need it.
    var pinnedFingerprint: String? = nil
    /// The successor the Mac has announced but not yet started presenting. Held beside the
    /// current one so a certificate can be replaced without this phone scanning a code again.
    var nextPinnedFingerprint: String? = nil

    var displayAddress: String {
        link.baseURL.host ?? link.baseURL.absoluteString
    }

    /// The pins learned over a trusted channel, if any. A record that has only ever seen a QR
    /// code has none of these and pins from `link.pinnedFingerprintCode` instead.
    var storedPinSet: RemoteHostPinSet? {
        guard let pinnedFingerprint, let current = RemoteHostPin(hex: pinnedFingerprint) else {
            return nil
        }
        return RemoteHostPinSet(
            current: current,
            next: nextPinnedFingerprint.flatMap(RemoteHostPin.init(hex:))
        )
    }

    /// The pin this record shows a person, in the spelling printed on the Mac's settings page.
    ///
    /// The stored fingerprint leads because it follows a rotation; the scanned code is what a
    /// record has before its first `/api/me`.
    var pinnedFingerprintCode: String? {
        if let pinnedFingerprint, let fingerprint = RemoteHostFingerprint(hex: pinnedFingerprint) {
            return fingerprint.pairingCode
        }
        return link.pinnedFingerprintCode
    }

    /// The pins this record accepts for the Mac itself, whatever address it is reached at.
    ///
    /// One value with two sources, in the order that keeps a rotation working: what the Mac said
    /// over a channel that had already proved its key, and otherwise the 128 bits photographed
    /// off its screen. A record with neither has never been given anything to check, which is
    /// what an older pairing looks like.
    ///
    /// Separate from `pinnedHosts` because that answers "which *names* does this record pin",
    /// which is a question about addresses. This answers "which certificate is this Mac", which
    /// is what a fingerprint seen on the network is compared against.
    var pinSet: RemoteHostPinSet? {
        if let storedPinSet { return storedPinSet }
        guard let code = link.pinnedFingerprintCode,
              let scanned = RemoteHostPin(pairingCode: code) else { return nil }
        return RemoteHostPinSet(current: scanned)
    }

    /// Every host name this record pins, with the pins it accepts for it.
    ///
    /// Two sources and no others. The scanned link pins **its own host**, because that is the
    /// address whose code was photographed. An advertised endpoint pins its host only when the
    /// Mac flagged it `pinned`; an endpoint without the flag is somebody else's TLS (Tailscale
    /// Serve holds a real certificate for its `*.ts.net` name) and must keep stock evaluation,
    /// or the phone would refuse the very endpoint that works.
    var pinnedHosts: [String: RemoteHostPinSet] {
        var result: [String: RemoteHostPinSet] = [:]
        let learned = storedPinSet
        if let code = link.pinnedFingerprintCode,
           let scanned = RemoteHostPin(pairingCode: code),
           let host = link.baseURL.host {
            result[host.lowercased()] = learned ?? RemoteHostPinSet(current: scanned)
        }
        guard let learned else { return result }
        for endpoint in endpoints ?? [] where endpoint.expectsPinnedIdentity {
            guard let host = endpoint.baseURL.host else { continue }
            result[host.lowercased()] = learned
        }
        return result
    }

    var hostedDeviceID: String? {
        if isOwnerDevice { return RemoteDeviceIdentity.current }
        return shareID.map { RemoteInvitationWebLink.guestDeviceID(shareID: $0) }
    }

    var isOwnerDevice: Bool { scope == nil || scope == "all" }

    var candidateLinks: [RemoteConnectionLink] {
        candidates.map(\.link)
    }

    /// The addresses to try, with the one this Mac was just found at on this network first.
    ///
    /// Discovery answers a question the advertised list cannot: the list is what the Mac last
    /// said about itself, and after a DHCP move that is an address nothing answers on any more.
    /// A discovered address is where it is *now*, so it leads, and the rest of the list follows
    /// unchanged as the fallback.
    ///
    /// Leading also makes it the address that carries its route's sticky-port walk, which is the
    /// right one to carry it for the same reason: the walk asks which port the Mac's listener
    /// took, and the address it was just found at is the one that can answer.
    ///
    /// **The policy still decides.** The discovered address goes through the same fail-closed
    /// endpoint selection as an advertised one, as the `lan` kind it is, so a record that admits
    /// no private-network endpoint does not acquire one because something answered a broadcast.
    func candidates(preferring discovered: URL?) -> [RemoteHostConnectionCandidate] {
        guard let discovered, admitsLAN(discovered) else { return candidates }
        return Self.candidates(
            forAddressesInOrder: [(RemoteHostEndpointKind.lan, discovered)] + advertisedAddresses,
            token: link.token
        )
    }

    /// Whether this record's connection policy admits a `lan` address at all.
    private func admitsLAN(_ baseURL: URL) -> Bool {
        !RemoteHostEndpointSelection.ordered(
            [RemoteHostEndpointDTO(
                kind: RemoteHostEndpointKind.lan,
                baseURL: baseURL,
                isStable: true,
                identity: RemoteHostEndpointIdentity.pinned
            )],
            policy: connectionPolicy ?? .privateOnly,
            currentBaseURL: link.baseURL
        ).isEmpty
    }

    /// Every address this phone will try for this Mac, in order.
    ///
    /// One entry per attempt, and each one names the door it belongs to. The door matters
    /// because of the port walk: a `lan` address on the sticky range contributes the remaining
    /// ports of that range as further attempts, and an answer from any of them (an HTTP status,
    /// an authentication refusal, a certificate that is not the pinned one) ends that door.
    /// Continuing to knock on nine more ports after the Mac has spoken finds nothing.
    ///
    /// The order across doors is `RemoteRouteWave`'s, not the endpoint list's: every route gets
    /// its own address tried before any route gets a second attempt.
    var candidates: [RemoteHostConnectionCandidate] {
        Self.candidates(forAddressesInOrder: advertisedAddresses, token: link.token)
    }

    /// The addresses this record admits, in the policy's deterministic order.
    ///
    /// `nil` endpoints is a legacy record from before hosts advertised routes, and it is also what
    /// a guest capability holds: a one-chat share is told the door it was minted against and no
    /// others. An explicitly empty list is different: the Mac currently authorizes no endpoint
    /// under its policy, so falling back to a remembered address here would violate it.
    private var advertisedAddresses: [(kind: RemoteHostEndpointKind, baseURL: URL)] {
        guard let endpoints else {
            return [(Self.endpointKind(for: link.baseURL), link.baseURL)]
        }
        guard !endpoints.isEmpty else { return [] }
        return RemoteHostEndpointSelection.ordered(
            endpoints,
            policy: connectionPolicy ?? .privateOnly,
            currentBaseURL: link.baseURL
        ).map { ($0.kind, $0.baseURL) }
    }

    /// Turns an ordered list of addresses into the attempts they contribute, wave by wave.
    ///
    /// The first address of each route leads it: that address is the one whose attempt answers
    /// "does this way in exist at all", and it is the one that carries the route's sticky-port
    /// walk. Every other address of a route already represented contributes itself and nothing
    /// else. Each address is still attempted exactly once, whichever wave first claimed it.
    private static func candidates(
        forAddressesInOrder addresses: [(kind: RemoteHostEndpointKind, baseURL: URL)],
        token: String
    ) -> [RemoteHostConnectionCandidate] {
        var leadingKinds: Set<RemoteHostEndpointKind> = []
        var seen: Set<URL> = []
        var byWave: [RemoteRouteWave: [RemoteHostConnectionCandidate]] = [:]
        for address in addresses {
            let leads = leadingKinds.insert(address.kind).inserted
            for candidate in RemoteHostConnectionCandidate.attempts(
                baseURL: address.baseURL,
                kind: address.kind,
                token: token,
                doorID: address.baseURL.absoluteString,
                wave: leads ? .route : .address,
                walksStickyPorts: leads
            ) where seen.insert(candidate.link.baseURL).inserted {
                byWave[candidate.wave, default: []].append(candidate)
            }
        }
        return RemoteRouteWave.allCases.flatMap { byWave[$0] ?? [] }
    }

    /// What this connection is called on screen.
    ///
    /// `relay` is still here because a record can still carry it: an older Mac advertises the
    /// kind, and a pairing made against one is not re-labelled by this phone updating. No current
    /// host sends it.
    var connectionLabel: String {
        Self.connectionLabel(forEndpointKind: activeEndpointKind ?? Self.endpointKind(for: link.baseURL))
    }

    /// The user-facing names of the saved doors a refresh walks, once per door rather than once
    /// per fallback port. These are deliberately labels, never addresses or port numbers: the
    /// dashboard needs to say what it tried without turning recovery into a network inspector.
    var connectionOptionLabels: [String] {
        var result: [String] = []
        var seen: Set<String> = []
        if hostedCredential != nil, hostedServiceURL != nil {
            let label = Self.connectionLabel(forEndpointKind: RemoteHostEndpointKind.hosted)
            result.append(label)
            seen.insert(label)
        }
        for candidate in candidates where !candidate.isPortWalk {
            let label = Self.connectionLabel(forEndpointKind: candidate.kind)
            if seen.insert(label).inserted { result.append(label) }
        }
        return result
    }

    static func connectionLabel(forEndpointKind kind: RemoteHostEndpointKind) -> String {
        switch kind {
        case .tailscale: return MobileL10n.string("Tailscale")
        case .relay: return MobileL10n.string("Relay")
        case .lan: return MobileL10n.string("LAN")
        case .vpn: return MobileL10n.string("VPN")
        case .hosted: return MobileL10n.string("Direct")
        default: return MobileL10n.string("Direct")
        }
    }

    /// A route name after a verb. Every route is a compact, established network term, so the
    /// same label works both as a standalone value and inside a status sentence.
    static func connectionLabelInSentence(forEndpointKind kind: RemoteHostEndpointKind) -> String {
        connectionLabel(forEndpointKind: kind)
    }

    var menuTitle: String {
        isOwnerDevice ? name : MobileL10n.string("%@ · Shared chat", name)
    }

    /// What became of the fingerprints an owner response carried.
    enum PinMergeOutcome: Equatable {
        /// Nothing to learn: no fingerprint in the response, or not an owner record.
        case unchanged
        /// The response's identity was adopted (first learn, a refinement of a scanned code, or
        /// a rotation this record had been told about).
        case adopted
        /// The response named an identity that neither matches what is stored nor was announced
        /// as its successor; the stored pin was kept and the caller should say so.
        case refused
    }

    @discardableResult
    mutating func merge(
        identity: RemoteHostDTO?,
        successfulLink: RemoteConnectionLink,
        isHosted: Bool = false,
        overPinnedChannel: Bool = false
    ) -> PinMergeOutcome {
        if !isHosted { link = successfulLink }
        activeEndpointKind = isHosted
            ? RemoteHostEndpointKind.hosted
            : kind(ofAdvertised: successfulLink.baseURL, in: identity?.endpoints ?? endpoints)
        lastConnectedAt = Date()
        guard let identity else { return .unchanged }
        hostID = identity.id
        name = identity.name
        if let advertised = identity.endpoints {
            endpoints = advertised
        }
        if let policy = identity.connectionPolicy {
            connectionPolicy = policy
        }
        return mergePins(from: identity, overPinnedChannel: overPinnedChannel)
    }

    /// Adopts the fingerprints an owner response carried, within what a stored pin allows.
    ///
    /// A pin, once held, is only ever *refined* or *followed*, never replaced on a channel's say-so:
    /// the identity a response names is adopted when nothing was pinned yet (the first `/api/me`
    /// after a legacy pairing), when it is the same identity spelled in full (a scanned 128-bit
    /// code becoming the whole digest), or when it is the successor this record was already told
    /// about (a rotation activated). Anything else is a different Mac or a reset one, and the
    /// stored pin stays so the pinned doors refuse it by name and the person scans again. That is
    /// the difference between "the Mac told me" and "something on the path told me": a relay
    /// terminates TLS, and even a public-CA channel authenticates a name, not this key.
    ///
    /// A successor announcement is honoured only over a pinned channel (plan §16): the old key
    /// vouching for the new one is the whole reason no re-pairing is needed, and a channel that
    /// did not prove the old key cannot vouch for anything.
    ///
    /// **Absence never clears a pin.** A host that says nothing about its identity is an older
    /// Mac or one whose doors are all publicly trusted, not an instruction to stop pinning; a
    /// Mac that really did reset its identity produces a named mismatch and a re-scan, which is
    /// the loud path this trades for.
    private mutating func mergePins(
        from identity: RemoteHostDTO,
        overPinnedChannel: Bool
    ) -> PinMergeOutcome {
        // A guest capability never learns an identity. The host does not send one to a guest
        // share, and a phone must not pin a Mac on the word of a one-chat token.
        guard isOwnerDevice,
              let claimedHex = identity.pinnedFingerprint,
              let claimed = RemoteHostFingerprint(hex: claimedHex) else { return .unchanged }

        let held = pinSet

        if let held {
            let sameIdentity = held.current.matches(digest: claimed.digest)
            let announcedSuccessor = held.next?.matches(digest: claimed.digest) ?? false
            guard sameIdentity || announcedSuccessor else { return .refused }
        }

        pinnedFingerprint = claimed.hex
        if overPinnedChannel {
            nextPinnedFingerprint = identity.nextPinnedFingerprint
        } else if held?.next.map({ $0.matches(digest: claimed.digest) }) == true {
            // The successor went live and this response is the first sight of it; whatever this
            // channel is, the announced-then-activated pair is what was vouched for.
            nextPinnedFingerprint = nil
        }
        return .adopted
    }

    /// What the Mac itself calls the address that answered, falling back to the guess.
    ///
    /// The guess reads an address; the advertised list is the Mac saying which door this is.
    /// They differ for exactly the cases that matter: a VPN address is in a private range and a
    /// tailnet address is not `.ts.net` when it is written as `100.x`.
    private func kind(
        ofAdvertised baseURL: URL,
        in advertised: [RemoteHostEndpointDTO]?
    ) -> RemoteHostEndpointKind {
        advertised?.first { $0.baseURL == baseURL }?.kind ?? Self.endpointKind(for: baseURL)
    }

    /// A guess at which door an address belongs to, for a record that has no advertised list to
    /// consult. Used for labels and diagnostics only; nothing is authorized by it.
    ///
    /// A public host answers `relay` because that is what an address outside every private range
    /// used to be. No current Mac has one, so in practice this reaches the last case only for a
    /// record written by an older pairing.
    static func endpointKind(for baseURL: URL) -> RemoteHostEndpointKind {
        guard let host = baseURL.host?.lowercased() else { return .unknown("direct") }
        if host.hasSuffix(".ts.net") { return RemoteHostEndpointKind.tailscale }
        if RemoteLocalNetworkAddress.isPrivate(host) { return RemoteHostEndpointKind.lan }
        return RemoteHostEndpointKind.relay
    }
}

/// Which pass of the route walk one attempt belongs to, and therefore how early it is tried.
///
/// The walk used to be one flat list in endpoint order, and the 2026-08-21 incident is what that
/// costs. A Mac advertising two `lan` addresses contributed twenty attempts — two addresses times
/// the ten sticky ports — and every one of them was tried, at four seconds each, before the
/// tailnet address that was working the whole time. Ninety seconds of bare spinner for a route
/// that answered in 818 ms once it finally got its turn.
///
/// So attempts are ordered by what each one is evidence *about*:
///
/// - `route` — one address per way in. Only this attempt can say whether that way in exists at
///   all from where the phone is standing, so every route contributes one before any route
///   contributes a second.
/// - `address` — the Mac's other addresses on a route already represented. Worth trying, but a
///   second address of a dead LAN is not news while a tailnet address is still untried.
/// - `port` — the sticky-port range. It asks which port the Mac's listener took, which is a fact
///   about the Mac rather than about each of its addresses, so it is carried once per route by
///   the address that leads it.
enum RemoteRouteWave: String, CaseIterable, Comparable, Sendable {
    case route
    case address
    case port

    private var order: Int {
        switch self {
        case .route: return 0
        case .address: return 1
        case .port: return 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

/// One address the phone will try, and the door it belongs to.
struct RemoteHostConnectionCandidate: Equatable, Sendable {
    let link: RemoteConnectionLink
    /// The Mac's semantic name for this door. It follows every fallback attempt so presentation
    /// can collapse a sticky-port walk back to one human route such as "LAN".
    let kind: RemoteHostEndpointKind
    /// Attempts sharing this identifier are the same advertised door at another port of the
    /// sticky range. An answer from one of them ends the walk over the rest.
    let doorID: String
    /// Which pass of the walk this attempt belongs to, which is what orders the whole list.
    let wave: RemoteRouteWave

    /// True for the ports the walk added, which is what makes them skippable as a group without
    /// also skipping the address the Mac actually advertised.
    var isPortWalk: Bool { wave == .port }

    /// The attempts one advertised address contributes.
    ///
    /// A `lan` address on the sticky range contributes the rest of that range in the listener's
    /// own order, because the Mac walks the same list when its configured port is taken and a
    /// collision must not cost a re-pair. Bounded by the range and deterministic: ten addresses
    /// tried one after another, never in parallel. Every other kind contributes itself alone,
    /// because a tailnet name and a VPN address are not ports somebody guessed.
    ///
    /// `walksStickyPorts` is how one route pays for that range once rather than once per address.
    /// Ten ports answer "which port did this Mac's listener take", and the answer does not change
    /// between two addresses of the same Mac; the incident paid for it twice and reached the
    /// working route ninety seconds late.
    static func attempts(
        baseURL: URL,
        kind: RemoteHostEndpointKind,
        token: String,
        doorID: String,
        wave: RemoteRouteWave = .route,
        walksStickyPorts: Bool = true
    ) -> [RemoteHostConnectionCandidate] {
        var result: [RemoteHostConnectionCandidate] = []
        if let link = RemoteConnectionLink(baseURL: baseURL, token: token) {
            result.append(
                RemoteHostConnectionCandidate(
                    link: link,
                    kind: kind,
                    doorID: doorID,
                    wave: wave
                )
            )
        }
        guard walksStickyPorts,
              kind == RemoteHostEndpointKind.lan,
              let port = baseURL.port.flatMap({ UInt16(exactly: $0) }),
              RemoteListenerPorts.fallbackRange.contains(port) else {
            return result
        }
        for candidate in RemoteListenerPorts.candidates(preferred: port).dropFirst() {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            components?.port = Int(candidate)
            guard let url = components?.url,
                  let link = RemoteConnectionLink(baseURL: url, token: token) else { continue }
            result.append(
                RemoteHostConnectionCandidate(
                    link: link,
                    kind: kind,
                    doorID: doorID,
                    wave: .port
                )
            )
        }
        return result
    }
}

/// Capability links are credentials, so paired Macs live in Keychain rather than UserDefaults.
final class RemoteHostStore {
    private let service = "codes.threading.mobile.remote-hosts"
    private let account = "paired-hosts-v1"

    enum StoreError: LocalizedError {
        case keychain(OSStatus)
        case unreadable
        case encoding

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return "Paired Macs could not be saved securely (Keychain \(status))."
            case .unreadable:
                return "Saved paired-Mac credentials could not be read."
            case .encoding:
                return "Paired-Mac credentials could not be encoded."
            }
        }
    }

    private(set) var writesAllowed = true

    func load() -> Result<[PairedRemoteHost], StoreError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .success([]) }
        guard status == errSecSuccess, let data = result as? Data else {
            MobileDiagnostics.logFailure(
                .hostStorage,
                domain: .keychain,
                code: Int(status)
            )
            writesAllowed = false
            return .failure(.keychain(status))
        }
        do {
            return .success(try JSONDecoder().decode([PairedRemoteHost].self, from: data))
        } catch {
            MobileDiagnostics.logFailure(.hostStorage, error: error)
            // Keychain is already the protected recovery copy. Refuse future writes so an
            // ordinary pairing cannot replace bytes a newer/older build may still understand.
            writesAllowed = false
            return .failure(.unreadable)
        }
    }

    func save(_ hosts: [PairedRemoteHost]) throws {
        guard writesAllowed else {
            MobileDiagnostics.logFailure(.hostStorage, code: .writeVerification)
            throw StoreError.unreadable
        }
        guard let data = try? JSONEncoder().encode(hosts) else {
            MobileDiagnostics.logFailure(.hostStorage, code: .encode)
            throw StoreError.encoding
        }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // The bearer grants interactive access to agent sessions and the app only needs it
            // while the user is actively using the unlocked device.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            MobileDiagnostics.logFailure(
                .hostStorage,
                domain: .keychain,
                code: Int(status)
            )
            throw StoreError.keychain(status)
        }
        var add = match
        attributes.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            MobileDiagnostics.logFailure(
                .hostStorage,
                domain: .keychain,
                code: Int(addStatus)
            )
            throw StoreError.keychain(addStatus)
        }
    }
}
