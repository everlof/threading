import Foundation
import Security
import CryptoKit

/// Host-only signing. The portable helper receives public roots and short-lived leaf keys.
/// Call from the proxy worker queue; never from the main actor.
struct ProxyCertificateAuthority {
    let key: SecKey
    let certificate: Data
    private static let commonName = "Threading Inspection CA"

    enum Failure: Error, LocalizedError {
        case security(OSStatus), invalidIdentity, generation, incompleteIdentity
        var errorDescription: String? {
            switch self {
            case .security(let status): "Proxy Keychain operation failed (\(status))."
            case .invalidIdentity: "The inspection CA identity is invalid. It was not replaced."
            case .generation: "Could not generate an inspection certificate."
            case .incompleteIdentity: "The inspection CA Keychain identity is incomplete. It was not replaced."
            }
        }
    }

    static func loadOrCreate() throws -> Self {
        try KeychainInteractionGate.run(allowingPrompt: false) { Result {
            #if DEBUG
            let namespace = "codes.threading.proxy.debug.ca.v1"
            #else
            let namespace = "codes.threading.proxy.ca.v1"
            #endif
            let tag = Data(namespace.utf8)
            let keyQuery: [String: Any] = [
                kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag,
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecReturnRef as String: true,
            ]
            let certQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: namespace,
                kSecAttrAccount as String: "public-certificate", kSecReturnData as String: true,
            ]
            var existingKey: CFTypeRef?, existingCertificate: CFTypeRef?
            let keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &existingKey)
            let certStatus = SecItemCopyMatching(certQuery as CFDictionary, &existingCertificate)
            if keyStatus == errSecSuccess, certStatus == errSecSuccess,
               let certificate = existingCertificate as? Data, let existingKey {
                guard CFGetTypeID(existingKey) == SecKeyGetTypeID() else { throw Failure.invalidIdentity }
                let key = unsafeBitCast(existingKey, to: SecKey.self)
                try validate(key: key, certificate: certificate)
                return Self(key: key, certificate: certificate)
            }
            for status in [keyStatus, certStatus] where status != errSecSuccess && status != errSecItemNotFound {
                throw Failure.security(status)
            }
            guard keyStatus == errSecItemNotFound, certStatus == errSecItemNotFound else { throw Failure.incompleteIdentity }
            var error: Unmanaged<CFError>?
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
                kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: true,
                    kSecAttrIsExtractable as String: false,
                    kSecAttrApplicationTag as String: tag,
                    kSecAttrLabel as String: commonName,
                ],
            ]
            guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw Failure.generation }
            do {
                let certificate = try makeCertificate(subjectKey: key, signingKey: key, host: nil)
                try validate(key: key, certificate: certificate)
                var add = certQuery
                add.removeValue(forKey: kSecReturnData as String)
                add[kSecValueData as String] = certificate
                let status = SecItemAdd(add as CFDictionary, nil)
                guard status == errSecSuccess else { throw Failure.security(status) }
                return Self(key: key, certificate: certificate)
            } catch {
                var remove = keyQuery
                remove.removeValue(forKey: kSecReturnRef as String)
                SecItemDelete(remove as CFDictionary)
                throw error
            }
        } }.get()
    }

    private static func validate(key: SecKey, certificate: Data) throws {
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              attributes[kSecAttrIsExtractable as String] as? Bool == false,
              let cert = SecCertificateCreateWithData(nil, certificate as CFData),
              let certKey = SecCertificateCopyKey(cert), let publicKey = SecKeyCopyPublicKey(key),
              let certificateKeyBytes = SecKeyCopyExternalRepresentation(certKey, nil) as Data?,
              let signingKeyBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              certificateKeyBytes == signingKeyBytes
        else { throw Failure.invalidIdentity }
    }

    func leaf(for host: String) throws -> (certificate: Data, privateKey: Data) {
        let leaf = try RemoteIdentityCertificateBuilder.makeKey()
        let certificate = try Self.makeCertificate(subjectKey: leaf, signingKey: key, host: host)
        guard let bytes = SecKeyCopyExternalRepresentation(leaf, nil) as Data?, bytes.count == 97 else { throw Failure.generation }
        let privateKey = Data(RemoteDER.sequence([
            RemoteDER.integer(1), RemoteDER.octetString(Array(bytes.suffix(32))),
            RemoteDER.explicit(0, RemoteDER.objectIdentifier(RemoteDEROID.prime256v1)),
            RemoteDER.explicit(1, RemoteDER.bitString(Array(bytes.prefix(65)))),
        ]))
        return (certificate, privateKey)
    }

    /// The DER writer is shared with pairing; identity storage and authority are separate.
    static func makeCertificate(subjectKey: SecKey, signingKey: SecKey, host: String?, now: Date = Date()) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(subjectKey),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw Failure.generation }
        let algorithm = RemoteDER.sequence([RemoteDER.objectIdentifier(RemoteDEROID.ecdsaWithSHA256)])
        func name(_ value: String) -> [UInt8] {
            RemoteDER.sequence([RemoteDER.set([RemoteDER.sequence([
                RemoteDER.objectIdentifier(RemoteDEROID.commonName), RemoteDER.utf8String(value),
            ])])])
        }
        func ext(_ oid: [UInt], _ value: [UInt8], critical: Bool = false) -> [UInt8] {
            RemoteDER.sequence([RemoteDER.objectIdentifier(oid)] + (critical ? [[0x01, 0x01, 0xff]] : []) + [RemoteDER.octetString(value)])
        }
        let isRoot = host == nil
        // X.520 commonName is at most 64 characters; the full identity always lives in SAN.
        let subjectName = host.map { $0.utf8.count <= 64 ? $0 : "Threading inspected host" } ?? commonName
        var extensions = [
            ext(RemoteDEROID.basicConstraints, RemoteDER.sequence(isRoot ? [[0x01, 0x01, 0xff], RemoteDER.integer(0)] : []), critical: true),
            ext(RemoteDEROID.keyUsage, RemoteDER.bitString([isRoot ? 0x06 : 0x80], unusedBits: isRoot ? 1 : 7), critical: true),
        ]
        if let host {
            let san = RemoteSubjectAlternativeName.ipAddress(parsing: host) ?? .dnsName(host)
            extensions.append(ext(RemoteDEROID.subjectAltName, RemoteDER.sequence([san.der])))
            extensions.append(ext([2, 5, 29, 37], RemoteDER.sequence([RemoteDER.objectIdentifier([1, 3, 6, 1, 5, 5, 7, 3, 1])])))
        }
        var serial = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else { throw Failure.generation }
        let expiry = now.addingTimeInterval(isRoot ? 3650 * 86400 : 86400)
        guard Calendar(identifier: .gregorian).component(.year, from: expiry) < 2050 else { throw Failure.generation }
        let tbs = RemoteDER.sequence([
            RemoteDER.explicit(0, RemoteDER.integer(2)), RemoteDER.integer(bytes: serial), algorithm,
            name(commonName), RemoteDER.sequence([RemoteDER.utcTime(now.addingTimeInterval(-300)), RemoteDER.utcTime(expiry)]),
            name(subjectName), RemoteDER.sequence([
                RemoteDER.sequence([RemoteDER.objectIdentifier(RemoteDEROID.ecPublicKey), RemoteDER.objectIdentifier(RemoteDEROID.prime256v1)]),
                RemoteDER.bitString(Array(publicBytes)),
            ]), RemoteDER.explicit(3, RemoteDER.sequence(extensions)),
        ])
        guard let signature = SecKeyCreateSignature(signingKey, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, nil) as Data? else { throw Failure.generation }
        return Data(RemoteDER.sequence([tbs, algorithm, RemoteDER.bitString(Array(signature))]))
    }

    static func pem(_ data: Data, label: String) -> Data {
        let base64 = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----\n".utf8)
    }
}
