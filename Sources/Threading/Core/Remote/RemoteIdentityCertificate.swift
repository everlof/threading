import Foundation
import Security

/// What went wrong minting or rebuilding this Mac's remote-access identity.
///
/// A code rather than a sentence, for the reason `RemoteDoorUnreachableReason` is one: the status
/// line a person reads is localised elsewhere, and a support report has to group by cause. Every
/// case here is a **named state**: a missing or unreadable identity never silently mints a new
/// one, because that would invalidate every paired device without anybody asking for it.
enum RemoteIdentityFailure: String, Equatable, Sendable {
    /// No identity has been minted yet. The one case that is allowed to lead to minting.
    case absent
    /// The directory the identity lives in could not be created or read.
    case directoryUnavailable
    /// The file is there and cannot be read, or its permissions could not be set.
    case unreadable
    /// The file is a record from a build that writes a shape this one does not know.
    case unsupportedVersion
    /// The file decoded and its contents are not an identity.
    case corrupt
    /// `SecKeyCreateRandomKey` refused.
    case keyGenerationFailed
    /// The certificate could not be signed or did not parse back.
    case certificateGenerationFailed
    /// `SecPKCS12Import` refused, or returned success with no identity in it.
    case identityImportFailed
    /// The throwaway keychain the macOS 13/14 path imports through could not be created.
    case keychainUnavailable
    /// No successor has been prepared, so there is nothing to activate.
    case noRotationPrepared
}

extension RemoteIdentityFailure: Error {}

/// One name a certificate claims, for tidiness only.
///
/// **The client does not check these**, and cannot: the certificate has to keep working from a
/// LAN address, a VPN address and a tailnet address, and those are not known when it is minted.
/// They are written because a person running `openssl x509 -text` on a support artifact should
/// see something recognisable, and because a browser's interstitial reads better with them.
enum RemoteSubjectAlternativeName: Equatable, Sendable {
    case dnsName(String)
    case ipAddress(Data)

    /// Parses a numeric address into the 4 or 16 bytes an `iPAddress` GeneralName carries.
    static func ipAddress(parsing text: String) -> RemoteSubjectAlternativeName? {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            return .ipAddress(withUnsafeBytes(of: &v4.s_addr) { Data($0) })
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            return .ipAddress(withUnsafeBytes(of: &v6) { Data($0) })
        }
        return nil
    }

    var der: [UInt8] {
        switch self {
        case .dnsName(let name):
            // GeneralName ::= [2] IMPLICIT IA5String
            return RemoteDER.implicitPrimitive(2, Array(name.utf8))
        case .ipAddress(let bytes):
            // GeneralName ::= [7] IMPLICIT OCTET STRING
            return RemoteDER.implicitPrimitive(7, Array(bytes))
        }
    }
}

/// Fixed facts about the certificate this Mac signs for itself.
enum RemoteIdentityDefaults {

    /// The subject and issuer are the same string, because the certificate is its own issuer.
    static let commonName = "Threading Remote Access"

    /// Twenty years. The client ignores expiry — it pins a key, and a key does not expire — so a
    /// short window would only produce a browser interstitial that says something even less
    /// helpful than the one it already shows.
    static let validityYears = 20

    /// A day of slack before `notBefore`, so a Mac whose clock is behind its own certificate does
    /// not spend the first minutes of its life presenting one that is not valid yet.
    static let notBeforeBackdate: TimeInterval = -24 * 60 * 60

    /// 20 bytes, which is the ceiling RFC 5280 puts on a serial number.
    static let serialByteCount = 20

    /// How many names the certificate will carry. Enumeration is bounded by the interface list,
    /// but the list comes from outside this code and a certificate is not a place to put an
    /// unbounded collection.
    static let maximumSubjectAlternativeNames = 16

    /// P-256. Bigger buys nothing here and costs a longer handshake on a phone.
    static let keySizeInBits = 256

    /// The directory under this app's Application Support folder that holds the identity.
    static let directoryName = "RemoteIdentity"

    /// The shape of the record on disk. A file with another version is left alone and named,
    /// never overwritten.
    static let recordVersion = 1

    /// Owner read and write, and nothing else. The trust root is a file, so the mode is the
    /// whole of what stops another user on this Mac from reading it.
    static let filePermissions = 0o600
    static let directoryPermissions = 0o700

    /// The serial queue that owns the identity files and the import.
    static let queueLabel = "codes.threading.remote.identity"
}

/// Mints the self-signed certificate the routable listeners present.
///
/// Security.framework has no public API that produces one, so the encoding is ours. The route was
/// settled by a standalone spike and is recorded in the transport plan: `SecKeyCreateRandomKey`
/// for a non-permanent P-256 key, a hand-rolled X.509 v3 body, and
/// `SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256)` over its DER.
enum RemoteIdentityCertificateBuilder {

    /// A freshly generated key pair that lives only in this process until somebody writes it down.
    static func makeKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: RemoteIdentityDefaults.keySizeInBits,
            // Not permanent, and deliberately not in any keychain: the durable copy is a 0600
            // file this app owns, because an agent's shell can delete a login-keychain item
            // without a prompt and that would invalidate every pairing silently.
            kSecAttrIsPermanent as String: false,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw RemoteIdentityFailure.keyGenerationFailed
        }
        return key
    }

    /// Rebuilds the key from the bytes on disk. The private key's external representation is
    /// ANSI X9.63 `04 || X || Y || K`.
    static func makeKey(privateKeyData: Data) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: RemoteIdentityDefaults.keySizeInBits,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            privateKeyData as CFData,
            attributes as CFDictionary,
            &error
        ) else {
            throw RemoteIdentityFailure.corrupt
        }
        return key
    }

    static func privateKeyData(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw RemoteIdentityFailure.keyGenerationFailed
        }
        return data
    }

    /// The DER of a self-signed X.509 v3 certificate for `key`.
    static func makeCertificate(
        key: SecKey,
        hostIdentifier: String,
        subjectAlternativeNames: [RemoteSubjectAlternativeName],
        now: Date = Date(),
        serial: [UInt8]? = nil
    ) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(key) else {
            throw RemoteIdentityFailure.certificateGenerationFailed
        }
        var error: Unmanaged<CFError>?
        guard let publicKeyBytes = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw RemoteIdentityFailure.certificateGenerationFailed
        }

        let notBefore = now.addingTimeInterval(RemoteIdentityDefaults.notBeforeBackdate)
        guard let notAfter = Calendar(identifier: .gregorian).date(
            byAdding: .year,
            value: RemoteIdentityDefaults.validityYears,
            to: now
        ) else {
            throw RemoteIdentityFailure.certificateGenerationFailed
        }

        let tbs = tbsCertificate(
            publicKeyBytes: Array(publicKeyBytes),
            hostIdentifier: hostIdentifier,
            subjectAlternativeNames: Array(
                subjectAlternativeNames.prefix(RemoteIdentityDefaults.maximumSubjectAlternativeNames)
            ),
            notBefore: notBefore,
            notAfter: notAfter,
            serial: serial ?? randomSerial()
        )

        guard let signature = SecKeyCreateSignature(
            key,
            .ecdsaSignatureMessageX962SHA256,
            Data(tbs) as CFData,
            &error
        ) as Data? else {
            throw RemoteIdentityFailure.certificateGenerationFailed
        }

        return Data(RemoteDER.sequence([
            tbs,
            signatureAlgorithm(),
            RemoteDER.bitString(Array(signature)),
        ]))
    }

    // MARK: - Body

    private static func tbsCertificate(
        publicKeyBytes: [UInt8],
        hostIdentifier: String,
        subjectAlternativeNames: [RemoteSubjectAlternativeName],
        notBefore: Date,
        notAfter: Date,
        serial: [UInt8]
    ) -> [UInt8] {
        let name = distinguishedName(hostIdentifier: hostIdentifier)
        var items: [[UInt8]] = [
            // Version ::= [0] EXPLICIT INTEGER { v3(2) }
            RemoteDER.explicit(0, RemoteDER.integer(2)),
            RemoteDER.integer(bytes: serial),
            signatureAlgorithm(),
            name,
            RemoteDER.sequence([RemoteDER.utcTime(notBefore), RemoteDER.utcTime(notAfter)]),
            // Issuer and subject are the same name: this certificate issues itself.
            name,
            subjectPublicKeyInfo(publicKeyBytes: publicKeyBytes),
        ]
        items.append(RemoteDER.explicit(3, RemoteDER.sequence(
            extensions(subjectAlternativeNames: subjectAlternativeNames)
        )))
        return RemoteDER.sequence(items)
    }

    /// `ecdsa-with-SHA256` and **no parameters field**. RFC 5758 says the field is absent, not
    /// NULL, and Security.framework agrees.
    private static func signatureAlgorithm() -> [UInt8] {
        RemoteDER.sequence([RemoteDER.objectIdentifier(RemoteDEROID.ecdsaWithSHA256)])
    }

    private static func distinguishedName(hostIdentifier: String) -> [UInt8] {
        RemoteDER.sequence([
            RemoteDER.set([RemoteDER.sequence([
                RemoteDER.objectIdentifier(RemoteDEROID.commonName),
                RemoteDER.utf8String(RemoteIdentityDefaults.commonName),
            ])]),
            // This Mac's own stable id, so two Macs in one household are told apart by a person
            // reading the certificate. It is the id the phone already stores for the host.
            RemoteDER.set([RemoteDER.sequence([
                RemoteDER.objectIdentifier(RemoteDEROID.organizationalUnit),
                RemoteDER.utf8String(hostIdentifier),
            ])]),
        ])
    }

    private static func subjectPublicKeyInfo(publicKeyBytes: [UInt8]) -> [UInt8] {
        RemoteDER.sequence([
            RemoteDER.sequence([
                RemoteDER.objectIdentifier(RemoteDEROID.ecPublicKey),
                RemoteDER.objectIdentifier(RemoteDEROID.prime256v1),
            ]),
            RemoteDER.bitString(publicKeyBytes),
        ])
    }

    private static func extensions(
        subjectAlternativeNames: [RemoteSubjectAlternativeName]
    ) -> [[UInt8]] {
        var result: [[UInt8]] = [
            // basicConstraints, critical, CA:FALSE. `cA` defaults to false, so an empty SEQUENCE
            // is exactly that statement.
            extensionEntry(
                oid: RemoteDEROID.basicConstraints,
                isCritical: true,
                value: RemoteDER.sequence([])
            ),
            // keyUsage, critical, digitalSignature only. Only `openssl verify` cares about
            // keyCertSign on a self-signed leaf, and nothing in this trust path does.
            extensionEntry(
                oid: RemoteDEROID.keyUsage,
                isCritical: true,
                value: RemoteDER.bitString([0x80], unusedBits: 7)
            ),
        ]
        if !subjectAlternativeNames.isEmpty {
            result.append(extensionEntry(
                oid: RemoteDEROID.subjectAltName,
                isCritical: false,
                value: RemoteDER.sequence(subjectAlternativeNames.map(\.der))
            ))
        }
        return result
    }

    private static func extensionEntry(
        oid: [UInt],
        isCritical: Bool,
        value: [UInt8]
    ) -> [UInt8] {
        var items: [[UInt8]] = [RemoteDER.objectIdentifier(oid)]
        // DER omits a BOOLEAN at its default, so `critical` is written only when it is true.
        if isCritical { items.append([0x01, 0x01, 0xFF]) }
        items.append(RemoteDER.octetString(value))
        return RemoteDER.sequence(items)
    }

    /// 20 random bytes with the top bit cleared, so the INTEGER is positive without the leading
    /// zero byte that would make it 21.
    private static func randomSerial() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: RemoteIdentityDefaults.serialByteCount)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<RemoteIdentityDefaults.serialByteCount).map { _ in
                UInt8.random(in: .min ... .max)
            }
        }
        bytes[0] &= 0x7F
        if bytes[0] == 0 { bytes[0] = 0x01 }
        return bytes
    }
}
