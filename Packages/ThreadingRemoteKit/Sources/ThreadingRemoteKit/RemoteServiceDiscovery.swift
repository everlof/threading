import CryptoKit
import Foundation

/// What a Mac broadcasts about itself on the local network, and what a phone reads back.
///
/// This is a contract between two products, like `RemoteListenerPorts`: the Mac writes the TXT
/// record and the phone parses it, so the key names, the value spellings and the instance-name
/// rule live in one place rather than twice.
///
/// **Everything here is a broadcast.** A Bonjour advertisement is visible to everyone on the
/// network, which is why the payload is exactly three values that name a machine's *identity*
/// and nothing about the person using it. In particular the instance name is derived here rather
/// than left to the platform: `NWListener.Service(name: nil, …)` advertises under the computer
/// name, which usually contains the user's own name.
public enum RemoteDiscoveryDefaults {

    /// The service type both ends agree on. Registered nowhere; it is ours by convention, and it
    /// is the value that has to appear in an iOS app's `NSBonjourServices` array or browsing
    /// fails silently.
    public static let serviceType = "_threading._tcp"

    /// The only domain a link-local advertisement lives in.
    public static let serviceDomain = "local."

    /// TXT keys. Short because a TXT record is a DNS payload, and fixed because the phone reads
    /// them.
    public static let hostIDKey = "id"
    public static let protocolVersionKey = "v"
    public static let fingerprintKey = "fp"

    /// The keys a well-formed advertisement carries, and the only ones it may carry.
    public static let expectedKeys: Set<String> = [hostIDKey, protocolVersionKey, fingerprintKey]

    /// How many bytes of the host id's digest become the instance name.
    ///
    /// Ten bytes is 16 base32 characters, far inside the 63-byte ceiling a DNS label has, and far
    /// beyond what two Macs on one network need to avoid colliding. A collision would only cost a
    /// platform rename (`name (2)`), never a wrong match: matching is on the fingerprint.
    public static let instanceNameByteCount = 10

    /// One TXT key/value string is length-prefixed by a single byte, so it cannot exceed 255
    /// bytes. The longest one here is `fp=` plus 64 hex characters, which is 67.
    public static let maximumTXTEntryBytes = 255

    /// What the whole record should stay under. RFC 6763 §6.2 asks for "as small as possible" and
    /// names 200 bytes as the size that keeps a response inside a single packet. The three
    /// entries here total roughly 120 bytes with a UUID host id, so the rule is checked rather
    /// than hoped for.
    public static let recommendedTXTRecordBytes = 200

    /// The opaque instance name for a host id.
    ///
    /// Derived rather than random so it is stable across relaunches and identity rotations: a
    /// name that changed would leave stale registrations on the network and make a moved Mac look
    /// like a new one. Derived rather than *the id itself* only because a DNS label should be
    /// short; the id travels in the TXT record anyway, so this discloses nothing further.
    public static func instanceName(hostID: String) -> String {
        let digest = SHA256.hash(data: Data(hostID.utf8))
        return RemoteBase32.encode(Data(digest.prefix(instanceNameByteCount)))
    }
}

/// One Mac's advertisement, as the values it carries rather than as a DNS record.
///
/// Constructed by the Mac to publish and by the phone to read; both go through the same parser so
/// a malformed record is refused in one place. A phone learns nothing from this except *which*
/// paired Mac it might be: matching is a fingerprint comparison against a pin the phone already
/// holds, and this type deliberately exposes no way to become a pin.
public struct RemoteHostAdvertisement: Equatable, Hashable, Sendable {

    /// The Mac's stable id, the same value `/api/me` reports as the host id.
    public let hostID: String
    /// The wire protocol the Mac speaks, so a phone can tell an incompatible Mac from an
    /// unrecognised one without connecting to it.
    public let protocolVersion: Int
    /// SHA-256 over the DER of the certificate the Mac's routable doors present.
    public let fingerprint: RemoteHostFingerprint

    public init(hostID: String, protocolVersion: Int, fingerprint: RemoteHostFingerprint) {
        self.hostID = hostID
        self.protocolVersion = protocolVersion
        self.fingerprint = fingerprint
    }

    /// The TXT entries to publish, in a stable order.
    ///
    /// An array of pairs rather than a dictionary because a TXT record is ordered bytes and a
    /// test that asserts on the published payload should see what was published.
    public var txtEntries: [(key: String, value: String)] {
        [
            (RemoteDiscoveryDefaults.hostIDKey, hostID),
            (RemoteDiscoveryDefaults.protocolVersionKey, String(protocolVersion)),
            (RemoteDiscoveryDefaults.fingerprintKey, fingerprint.hex),
        ]
    }

    public var txtDictionary: [String: String] {
        txtEntries.reduce(into: [:]) { $0[$1.key] = $1.value }
    }

    /// How many bytes the record weighs on the wire: one length byte per entry plus `key=value`.
    public var txtRecordByteCount: Int {
        txtEntries.reduce(0) { $0 + 1 + "\($1.key)=\($1.value)".utf8.count }
    }

    /// Whether every entry fits a DNS string and the record stays inside one packet.
    public var fitsTXTLimits: Bool {
        let entriesFit = txtEntries.allSatisfy {
            "\($0.key)=\($0.value)".utf8.count <= RemoteDiscoveryDefaults.maximumTXTEntryBytes
        }
        return entriesFit
            && txtRecordByteCount <= RemoteDiscoveryDefaults.recommendedTXTRecordBytes
    }

    /// Reads an advertisement, or refuses it.
    ///
    /// Strict: a record missing a key, carrying an unparseable fingerprint, or carrying anything
    /// beyond the three known keys is not an advertisement this build made. Refusing an unknown
    /// key is deliberate — the payload is the whole disclosure surface, so a future key must be a
    /// decision taken here rather than something a client silently tolerates.
    public static func parse(txt: [String: String]) -> RemoteHostAdvertisement? {
        guard Set(txt.keys) == RemoteDiscoveryDefaults.expectedKeys,
              let hostID = txt[RemoteDiscoveryDefaults.hostIDKey], !hostID.isEmpty,
              let rawVersion = txt[RemoteDiscoveryDefaults.protocolVersionKey],
              let version = Int(rawVersion),
              let hex = txt[RemoteDiscoveryDefaults.fingerprintKey],
              let fingerprint = RemoteHostFingerprint(hex: hex) else { return nil }
        return RemoteHostAdvertisement(
            hostID: hostID,
            protocolVersion: version,
            fingerprint: fingerprint
        )
    }
}
