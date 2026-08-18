import CryptoKit
import Foundation
import Security

/// The shape of the values a pinned host is identified by, in one place because two products and
/// a QR encoder all have to agree on them.
public enum RemoteHostPinningDefaults {

    /// SHA-256 over the DER of the leaf certificate. The whole digest is what `/api/me` carries.
    public static let digestByteCount = 32

    /// What the QR code carries. 128 bits is far beyond what a pinning check needs, and it is
    /// what keeps the pairing payload inside QR's alphanumeric mode at a sane module count.
    public static let pairingCodeByteCount = 16

    /// 16 bytes of base32 with no padding. Exactly 26 characters, always.
    public static let pairingCodeCharacterCount = 26

    /// RFC 4648 base32, upper case. Every character is in QR's alphanumeric charset, and none of
    /// them is `.`, which is what makes `<token>.<fingerprint>` an unambiguous split.
    public static let base32Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
}

// MARK: - Base32

/// RFC 4648 base32, upper case and unpadded, encoding one way and decoding strictly the other.
///
/// Strict on purpose: this codec reads a value photographed off a screen and used to decide
/// whether a TLS certificate is the right one. Accepting lower case, padding, or a length that
/// cannot have come from whole bytes would mean two spellings of the same pin, and the check that
/// compares them is a security decision, not a formatting one.
public enum RemoteBase32 {

    private static let alphabet = Array(RemoteHostPinningDefaults.base32Alphabet.utf8)

    /// Character counts that no whole number of bytes can produce.
    private static let impossibleRemainders: Set<Int> = [1, 3, 6]

    public static func encode(_ bytes: Data) -> String {
        var output = ""
        output.reserveCapacity((bytes.count * 8 + 4) / 5)
        var accumulator = 0
        var bits = 0
        for byte in bytes {
            accumulator = (accumulator << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(Character(UnicodeScalar(alphabet[(accumulator >> bits) & 0x1F])))
            }
        }
        if bits > 0 {
            output.append(Character(UnicodeScalar(alphabet[(accumulator << (5 - bits)) & 0x1F])))
        }
        return output
    }

    /// Decodes upper-case unpadded base32, or returns nil. Padding, lower case, a character
    /// outside the alphabet, an impossible length, and non-zero trailing bits are all refusals.
    public static func decode(_ text: String) -> Data? {
        guard !text.isEmpty, !impossibleRemainders.contains(text.utf8.count % 8) else { return nil }

        var bytes = Data()
        bytes.reserveCapacity(text.utf8.count * 5 / 8)
        var accumulator = 0
        var bits = 0
        for character in text.utf8 {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            accumulator = (accumulator << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((accumulator >> bits) & 0xFF))
            }
        }
        // Whatever is left over is padding bits, and RFC 4648 says they are zero. A value with
        // anything else in them is a different string that would decode to the same bytes.
        guard accumulator & ((1 << bits) - 1) == 0 else { return nil }
        return bytes
    }
}

// MARK: - Fingerprint

/// The SHA-256 of a leaf certificate's DER, in the two spellings that travel: the full digest as
/// lower-case hex on the wire, and its first 128 bits as base32 in a QR code.
public struct RemoteHostFingerprint: Equatable, Hashable, Sendable {

    /// Exactly `RemoteHostPinningDefaults.digestByteCount` bytes.
    public let digest: Data

    public init?(digest: Data) {
        guard digest.count == RemoteHostPinningDefaults.digestByteCount else { return nil }
        self.digest = digest
    }

    /// The fingerprint of a certificate, which is what both ends compute and neither transmits.
    public init(certificateDER: Data) {
        digest = Data(SHA256.hash(data: certificateDER))
    }

    /// Reads the wire spelling. Upper case is accepted because hex is case-insensitive; the
    /// canonical form this build writes is lower case.
    public init?(hex: String) {
        guard hex.utf8.count == RemoteHostPinningDefaults.digestByteCount * 2 else { return nil }
        var bytes = Data()
        bytes.reserveCapacity(RemoteHostPinningDefaults.digestByteCount)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(digest: bytes)
    }

    /// The wire spelling: lower-case hex of the whole digest, 64 characters.
    public var hex: String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The QR spelling: the first 128 bits, base32 upper case, 26 characters.
    public var pairingCode: String {
        RemoteBase32.encode(digest.prefix(RemoteHostPinningDefaults.pairingCodeByteCount))
    }

    /// The same value as the thing a client checks against a certificate.
    public var pin: RemoteHostPin { RemoteHostPin(fingerprint: self) }
}

/// What a client actually holds about one host: either the 128 bits it scanned off the Mac's
/// screen, or the whole digest it later learned over the pinned channel.
///
/// Both are the same check. A pin is compared against the leading bytes of the leaf's SHA-256, so
/// a phone that has only ever seen a QR code pins just as well as one that has read `/api/me`;
/// the longer value simply narrows an already unguessable window.
public struct RemoteHostPin: Equatable, Hashable, Sendable {

    /// 16 bytes from a pairing code, or 32 from a full fingerprint.
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == RemoteHostPinningDefaults.pairingCodeByteCount
                || bytes.count == RemoteHostPinningDefaults.digestByteCount else { return nil }
        self.bytes = bytes
    }

    /// A whole fingerprint is always a valid pin, so this one cannot fail.
    public init(fingerprint: RemoteHostFingerprint) {
        bytes = fingerprint.digest
    }

    public init?(pairingCode: String) {
        guard pairingCode.utf8.count == RemoteHostPinningDefaults.pairingCodeCharacterCount,
              let bytes = RemoteBase32.decode(pairingCode),
              bytes.count == RemoteHostPinningDefaults.pairingCodeByteCount else { return nil }
        self.init(bytes: bytes)
    }

    public init?(hex: String) {
        guard let fingerprint = RemoteHostFingerprint(hex: hex) else { return nil }
        self.init(bytes: fingerprint.digest)
    }

    /// Whether a certificate is the one this pin names.
    ///
    /// The comparison is constant time. A byte-at-a-time early return leaks how much of a
    /// candidate digest matched, which is the one measurement an attacker with an oracle would
    /// use to search for a colliding certificate a byte at a time.
    public func matches(certificateDER: Data) -> Bool {
        matches(digest: Data(SHA256.hash(data: certificateDER)))
    }

    public func matches(digest: Data) -> Bool {
        guard digest.count >= bytes.count else { return false }
        var difference: UInt8 = 0
        for (index, byte) in bytes.enumerated() {
            difference |= byte ^ digest[digest.startIndex + index]
        }
        return difference == 0
    }
}

/// The pins a client will accept for one host: the certificate it is paired to, and the successor
/// the Mac has announced over that same pinned channel but not yet started presenting.
///
/// The successor is what makes rotation possible without re-pairing. It is only ever learned over
/// an already pinned connection, so it is the holder of the current private key saying what the
/// next one will be; an announcement arriving any other way is not a pin.
public struct RemoteHostPinSet: Equatable, Hashable, Sendable {
    public let current: RemoteHostPin
    public let next: RemoteHostPin?

    public init(current: RemoteHostPin, next: RemoteHostPin? = nil) {
        self.current = current
        self.next = next
    }

    public func matches(certificateDER: Data) -> Bool {
        let digest = Data(SHA256.hash(data: certificateDER))
        if current.matches(digest: digest) { return true }
        guard let next else { return false }
        return next.matches(digest: digest)
    }
}

// MARK: - Verdict

/// What a pinning check decided, recorded per host because the client cannot read it off the
/// error it gets back.
///
/// A cancelled server-trust challenge surfaces as `URLError(-999)` with no underlying error,
/// which is indistinguishable from a user cancelling a request. So the delegate writes down its
/// own answer and the client reads that. A fingerprint mismatch is the one network failure that
/// deserves its own sentence, and this is the only place it exists.
public enum RemoteTrustVerdict: String, Codable, Equatable, Sendable {
    /// The leaf matched the pin, and the connection was allowed to proceed.
    case accepted
    /// A pin was in force and the leaf did not match it. Nothing connected.
    case rejectedFingerprintMismatch
    /// No pin is held for this host, so stock trust evaluation applied. Hosted and relay
    /// endpoints and every host paired before pinning existed land here.
    case notPinned
}

/// Evaluates a server-trust challenge against a pinned identity.
///
/// **Hostname verification is deliberately not performed for a pinned host, and that is not an
/// oversight.** The certificate is self-signed and covers no name a certificate authority could
/// vouch for; what is being trusted is one public key learned out of band by scanning a code on
/// the Mac's own screen. Checking the name as well would break the property that makes this work:
/// one identity serves every address the Mac ever has, so the same pin keeps working from a VPN,
/// a tailnet, or a new DHCP lease with no re-pairing. Any SANs in the certificate are tidiness.
public enum RemoteCertificatePinning {

    /// The DER of the leaf certificate a server presented, or nil when the trust carries none.
    public static func leafCertificateData(in trust: SecTrust) -> Data? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }

    /// Fail-closed: a host with a pin whose leaf cannot even be read is a mismatch, never an
    /// unpinned host, because "could not read it" must not become "trust it".
    public static func evaluate(_ trust: SecTrust, against pins: RemoteHostPinSet?) -> RemoteTrustVerdict {
        guard let pins else { return .notPinned }
        guard let leaf = leafCertificateData(in: trust) else { return .rejectedFingerprintMismatch }
        return pins.matches(certificateDER: leaf) ? .accepted : .rejectedFingerprintMismatch
    }
}

/// A `URLSessionDelegate` that pins, and remembers what it decided.
///
/// Attach it to the **session**, not to a task: a server-trust challenge goes to the session-level
/// delegate whenever that method exists, which is what makes a `URLSessionWebSocketTask` on the
/// same session go through the same check as every REST call. A socket on an unpinned session
/// silently keeps stock evaluation, and stock evaluation refuses this leaf outright.
public final class RemoteCertificatePinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {

    /// Pins keyed by lower-cased host. Mutable so a client can learn a rotation announcement
    /// without rebuilding its session; guarded by `lock`, which is the only mutable state here.
    private var pinsByHost: [String: RemoteHostPinSet]
    private var verdictsByHost: [String: RemoteTrustVerdict] = [:]
    private let lock = NSLock()

    public init(pins: [String: RemoteHostPinSet] = [:]) {
        pinsByHost = pins.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    }

    public func setPins(_ pins: RemoteHostPinSet?, forHost host: String) {
        lock.lock()
        defer { lock.unlock() }
        pinsByHost[host.lowercased()] = pins
    }

    public func pins(forHost host: String) -> RemoteHostPinSet? {
        lock.lock()
        defer { lock.unlock() }
        return pinsByHost[host.lowercased()]
    }

    /// What the last challenge for this host decided. Nil means no challenge has been seen.
    public func verdict(forHost host: String) -> RemoteTrustVerdict? {
        lock.lock()
        defer { lock.unlock() }
        return verdictsByHost[host.lowercased()]
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host.lowercased()
        let verdict = RemoteCertificatePinning.evaluate(trust, against: pins(forHost: host))
        lock.lock()
        verdictsByHost[host] = verdict
        lock.unlock()

        switch verdict {
        case .accepted:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .rejectedFingerprintMismatch:
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .notPinned:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
