import Foundation
import ThreadingRemoteKit

/// Where this phone's certificate pins come from, and the only thing that writes them.
///
/// Pinning has exactly two sources, and the value of the whole scheme is that it has no third:
///
/// 1. **The code that was photographed.** A pairing link carries the first 128 bits of the Mac's
///    certificate fingerprint, so the phone pins the address it scanned before it has spoken to
///    it once. This is the out-of-band step, and it is the reason there is no certificate
///    authority in the path.
/// 2. **What the Mac says over a channel whose trust was already accepted.** A `/api/me` response
///    exists only because the pin matched or because the system evaluated a publicly issued
///    certificate; a refused challenge produces no response to read. So the fingerprints in an
///    owner response are the Mac's own word about its identity, including the successor it has
///    minted and not yet started presenting.
///
/// Two rules keep that honest, and both are tested:
///
/// - **A pin is only ever applied to a host the Mac flagged.** `identity: "pinned"` means the
///   endpoint presents the Mac's own certificate. An endpoint without it presents somebody
///   else's, and pinning that host would refuse the one endpoint that works: Tailscale Serve
///   holds a real certificate for its `*.ts.net` name, and the phone must keep stock evaluation
///   there.
/// - **A guest never teaches this phone a pin.** A one-chat capability is not the owner of the
///   Mac. The host does not send an identity to a guest share, and this refuses one anyway.
enum RemoteHostTrust {

    /// Puts every pin a paired record holds into force.
    ///
    /// Called on launch, after pairing, and after a refresh that changed the record, so a pin is
    /// in force before the request that needs it rather than after it. Registration is
    /// idempotent: it states the whole of what a record pins, so a rotation replaces rather than
    /// accumulates.
    static func register(
        _ hosts: [PairedRemoteHost],
        with delegate: RemoteCertificatePinningDelegate = RemoteClient.pinningDelegate
    ) {
        for host in hosts {
            for (name, pins) in host.pinnedHosts {
                delegate.setPins(pins, forHost: name)
            }
        }
    }

    /// Puts the pin a scanned link carries into force for that link's own host, before the first
    /// request is made over it.
    ///
    /// Pairing is the one moment a phone has a fingerprint and no connection, which is exactly
    /// the ordering pinning needs: the accept-invitation request that follows is already
    /// checked. A link with no code registers nothing and keeps stock evaluation, which is what
    /// an older Mac and a Serve endpoint both need.
    @discardableResult
    static func register(
        link: RemoteConnectionLink,
        with delegate: RemoteCertificatePinningDelegate = RemoteClient.pinningDelegate
    ) -> RemoteHostPinSet? {
        guard let code = link.pinnedFingerprintCode,
              let pin = RemoteHostPin(pairingCode: code),
              let host = link.baseURL.host else { return nil }
        let pins = RemoteHostPinSet(current: pin)
        delegate.setPins(pins, forHost: host)
        return pins
    }

    /// Drops the pins a forgotten Mac held, then restates what the remaining records pin.
    ///
    /// The second half is not tidiness: one Mac can be present twice, once as an owner pairing
    /// and again through a guest share of one chat, and both records name the same addresses.
    /// Clearing without restating would leave the surviving record unpinned until the next
    /// launch, which is the launch it could not connect to make.
    static func forget(
        _ host: PairedRemoteHost,
        remaining: [PairedRemoteHost],
        with delegate: RemoteCertificatePinningDelegate = RemoteClient.pinningDelegate
    ) {
        for name in host.pinnedHosts.keys {
            delegate.setPins(nil, forHost: name)
        }
        register(remaining, with: delegate)
    }

    /// How the answer to "what did the pin check decide for this host name" is obtained.
    ///
    /// A function rather than the delegate itself because the delegate is deliberately the only
    /// thing that can write a verdict: it records what it decided while answering a real
    /// challenge, and nothing else may. A caller that needs to state a verdict, including a
    /// test, supplies one here instead of being able to put one into the delegate.
    typealias VerdictLookup = (String) -> RemoteTrustVerdict?

    static func liveVerdict(_ host: String) -> RemoteTrustVerdict? {
        RemoteClient.pinningDelegate.verdict(forHost: host)
    }

    /// Whether a pin check refused something at one of the addresses this Mac is reachable at.
    ///
    /// Read from the delegate rather than from the error, because a cancelled server-trust
    /// challenge surfaces as `URLError(-999)` with no underlying error and is indistinguishable
    /// from a user cancelling a request. Every address for the Mac is asked, because a failover
    /// can end on a different one than it started at, and a mismatch anywhere is the fact worth
    /// reporting.
    static func rejectedIdentity(
        for host: PairedRemoteHost,
        verdict: VerdictLookup = liveVerdict
    ) -> Bool {
        hostNames(of: host).contains { verdict($0) == .rejectedFingerprintMismatch }
    }

    /// The verdict to record in a support report for this Mac, as a bounded token.
    ///
    /// A verdict, never a fingerprint: a report says whether the identity check passed, refused,
    /// or never ran, and the certificate itself is not a fact a support bundle carries.
    static func verdictToken(
        for host: PairedRemoteHost,
        verdict: VerdictLookup = liveVerdict
    ) -> String? {
        let verdicts = hostNames(of: host).compactMap(verdict)
        guard !verdicts.isEmpty else { return nil }
        if verdicts.contains(.rejectedFingerprintMismatch) {
            return token(for: .rejectedFingerprintMismatch)
        }
        return token(for: verdicts.contains(.accepted) ? .accepted : .notPinned)
    }

    static func token(for verdict: RemoteTrustVerdict) -> String {
        "trust.\(verdict.rawValue)"
    }

    /// Every host name this Mac answers at, as far as this record knows: the remembered address
    /// and every advertised endpoint, whether pinned or not.
    private static func hostNames(of host: PairedRemoteHost) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        for url in [host.link.baseURL] + (host.endpoints ?? []).map(\.baseURL) {
            guard let name = url.host?.lowercased(), seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names
    }
}
