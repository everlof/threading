import CryptoKit
import Foundation
import Security

/// Fixed facts about the PKCS#12 container this app writes and immediately reads back.
///
/// The container never touches disk and never leaves the process. It exists because
/// `SecPKCS12Import` is the only public route from a key plus a certificate to a `SecIdentity`,
/// and every value here is the shape that importer accepts, measured rather than guessed:
///
/// - **MacData is required.** A container without it is `errSecDecode`.
/// - **An unencrypted key bag is silently dropped**: `errSecSuccess`, and no identity in the
///   result. That is the expensive failure, and the tripwire test exists so nobody simplifies
///   this code back into it.
/// - **An empty passphrase is refused** with `errSecAuthFailed`.
enum RemotePKCS12Defaults {

    /// Iterations for the PBES2 key.
    ///
    /// Deliberately not the six figures a password-derived key would take. **There is no
    /// password here**: the passphrase is 256 bits of fresh entropy, generated per import,
    /// never stored, and never seen outside this process, so iteration count buys nothing
    /// against the only attack it defends against. What it costs is real, because the KDF is
    /// hand-written: measured on this machine, 100,000 iterations is 243 ms in a Release build
    /// and about 700 ms in Debug, once per launch on the listener's queue, against 11 ms at
    /// this count. The transport plan suggested 100,000 as an example; this is the measurement
    /// that answered it.
    static let derivationIterations = 4_096

    /// RFC 7292 fixes the MAC iteration count at nothing in particular, and 2048 is what every
    /// producer writes.
    static let macIterations = 2048

    static let saltByteCount = 8
    static let passphraseByteCount = 32
    static let localKeyIDByteCount = 20
    static let version = 3
}

/// Writes the one-shot PKCS#12 container that turns a key and a certificate into a `SecIdentity`.
enum RemotePKCS12Writer {

    /// The container, plus the passphrase needed to open it. Both are used once, by the caller,
    /// and then dropped.
    struct Container {
        let data: Data
        let passphrase: String
    }

    /// Builds a container holding one shrouded key bag and one certificate bag, paired by
    /// `localKeyId`.
    ///
    /// `entropy` is injectable so the encoder can be checked against a stated salt, IV and
    /// passphrase rather than only against itself.
    static func makeContainer(
        privateKeyPKCS8: Data,
        certificateDER: Data,
        entropy: (Int) -> Data = RemotePKCS12Writer.randomBytes,
        shroudsPrivateKey: Bool = true
    ) -> Container? {
        let passphrase = base64URL(entropy(RemotePKCS12Defaults.passphraseByteCount))
        guard !passphrase.isEmpty else { return nil }
        let localKeyID = entropy(RemotePKCS12Defaults.localKeyIDByteCount)

        let keyBagValue: [UInt8]
        let keyBagOID: [UInt]
        if shroudsPrivateKey {
            guard let shrouded = shroud(
                privateKeyPKCS8: privateKeyPKCS8,
                passphrase: passphrase,
                entropy: entropy
            ) else { return nil }
            keyBagValue = shrouded
            keyBagOID = RemoteDEROID.pkcs8ShroudedKeyBag
        } else {
            // Only a test asks for this: an unencrypted key bag is the shape `SecPKCS12Import`
            // accepts and then quietly discards.
            keyBagValue = Array(privateKeyPKCS8)
            keyBagOID = [1, 2, 840, 113549, 1, 12, 10, 1, 1]
        }

        let keyBag = safeBag(oid: keyBagOID, value: keyBagValue, localKeyID: localKeyID)
        let certificateBag = safeBag(
            oid: RemoteDEROID.certBag,
            value: RemoteDER.sequence([
                RemoteDER.objectIdentifier(RemoteDEROID.x509Certificate),
                RemoteDER.explicit(0, RemoteDER.octetString(Array(certificateDER))),
            ]),
            localKeyID: localKeyID
        )

        // Two ContentInfos, both plain `data`: the certificate bag needs no encryption of its
        // own, and the key bag carries its own.
        let authenticatedSafe = RemoteDER.sequence([
            dataContentInfo(RemoteDER.sequence([keyBag])),
            dataContentInfo(RemoteDER.sequence([certificateBag])),
        ])

        let macSalt = entropy(RemotePKCS12Defaults.saltByteCount)
        let macKey = RemotePKCS12KDF.derive(
            password: passphrase,
            salt: macSalt,
            iterations: RemotePKCS12Defaults.macIterations,
            purpose: .mac,
            length: 20
        )
        let mac = Data(HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(authenticatedSafe),
            using: SymmetricKey(data: macKey)
        ))

        let pfx = RemoteDER.sequence([
            RemoteDER.integer(RemotePKCS12Defaults.version),
            dataContentInfo(authenticatedSafe),
            RemoteDER.sequence([
                RemoteDER.sequence([
                    RemoteDER.sequence([
                        RemoteDER.objectIdentifier(RemoteDEROID.sha1),
                        RemoteDER.null(),
                    ]),
                    RemoteDER.octetString(Array(mac)),
                ]),
                RemoteDER.octetString(Array(macSalt)),
                RemoteDER.integer(RemotePKCS12Defaults.macIterations),
            ]),
        ])
        return Container(data: Data(pfx), passphrase: passphrase)
    }

    /// PKCS#8 `PrivateKeyInfo` for a P-256 key, built from the ANSI X9.63 representation
    /// Security.framework hands out: `04 || X || Y || K`.
    static func pkcs8PrivateKey(x963: Data) -> Data? {
        let coordinateLength = 32
        guard x963.count == 1 + 3 * coordinateLength, x963.first == 0x04 else { return nil }
        let publicPoint = Array(x963.prefix(1 + 2 * coordinateLength))
        let scalar = Array(x963.suffix(coordinateLength))

        let ecPrivateKey = RemoteDER.sequence([
            RemoteDER.integer(1),
            RemoteDER.octetString(scalar),
            // The curve is already named in the algorithm identifier below, so [0] parameters
            // are omitted; [1] carries the public point so the importer need not derive it.
            RemoteDER.explicit(1, RemoteDER.bitString(publicPoint)),
        ])

        return Data(RemoteDER.sequence([
            RemoteDER.integer(0),
            RemoteDER.sequence([
                RemoteDER.objectIdentifier(RemoteDEROID.ecPublicKey),
                RemoteDER.objectIdentifier(RemoteDEROID.prime256v1),
            ]),
            RemoteDER.octetString(ecPrivateKey),
        ]))
    }

    // MARK: - Bags

    private static func safeBag(oid: [UInt], value: [UInt8], localKeyID: Data) -> [UInt8] {
        RemoteDER.sequence([
            RemoteDER.objectIdentifier(oid),
            RemoteDER.explicit(0, value),
            // `localKeyId` on both bags is what tells the importer the two belong together, and
            // therefore what makes the result an identity rather than a loose key and certificate.
            RemoteDER.set([RemoteDER.sequence([
                RemoteDER.objectIdentifier(RemoteDEROID.localKeyID),
                RemoteDER.set([RemoteDER.octetString(Array(localKeyID))]),
            ])]),
        ])
    }

    private static func dataContentInfo(_ content: [UInt8]) -> [UInt8] {
        RemoteDER.sequence([
            RemoteDER.objectIdentifier(RemoteDEROID.pkcs7Data),
            RemoteDER.explicit(0, RemoteDER.octetString(content)),
        ])
    }

    /// `EncryptedPrivateKeyInfo` under PBES2: PBKDF2-HMAC-SHA256 into AES-256-CBC.
    private static func shroud(
        privateKeyPKCS8: Data,
        passphrase: String,
        entropy: (Int) -> Data
    ) -> [UInt8]? {
        let salt = entropy(RemotePKCS12Defaults.saltByteCount)
        let iv = entropy(RemoteAES256.blockSize)
        // PBES2 inside PKCS#12 takes the password's bytes as they are, unlike the BMPString the
        // MAC key above is derived from. The two conventions live one field apart, which is why
        // both are stated here rather than shared.
        let key = RemotePBKDF2.derive(
            password: Data(passphrase.utf8),
            salt: salt,
            iterations: RemotePKCS12Defaults.derivationIterations,
            length: RemoteAES256.keySize
        )
        guard let ciphertext = RemoteAES256.encryptCBC(
            plaintext: privateKeyPKCS8,
            key: key,
            iv: iv
        ) else { return nil }

        let keyDerivation = RemoteDER.sequence([
            RemoteDER.objectIdentifier(RemoteDEROID.pbkdf2),
            RemoteDER.sequence([
                RemoteDER.octetString(Array(salt)),
                RemoteDER.integer(RemotePKCS12Defaults.derivationIterations),
                RemoteDER.integer(RemoteAES256.keySize),
                RemoteDER.sequence([
                    RemoteDER.objectIdentifier(RemoteDEROID.hmacWithSHA256),
                    RemoteDER.null(),
                ]),
            ]),
        ])
        let encryptionScheme = RemoteDER.sequence([
            RemoteDER.objectIdentifier(RemoteDEROID.aes256CBC),
            RemoteDER.octetString(Array(iv)),
        ])
        return RemoteDER.sequence([
            RemoteDER.sequence([
                RemoteDER.objectIdentifier(RemoteDEROID.pbes2),
                RemoteDER.sequence([keyDerivation, encryptionScheme]),
            ]),
            RemoteDER.octetString(Array(ciphertext)),
        ])
    }

    // MARK: - Entropy

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
