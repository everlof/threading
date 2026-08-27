import Foundation
import Security
import XCTest
import ThreadingRemoteKit
@testable import Threading

/// The hand-written half of the pinned identity: a DER writer, a self-signed certificate, and the
/// PKCS#12 container that is the only public route from a key plus a certificate to a
/// `SecIdentity`.
///
/// Everything here is checked against something that is not this code. The encoders are pinned to
/// published known answers, the certificate is parsed back by Security.framework, verified by
/// `openssl x509`, and its signature checked with the public key read out of the certificate
/// rather than the one that signed it. A cipher or a KDF that is subtly wrong produces bytes that
/// look exactly as random as correct ones, so agreeing with itself proves nothing.
final class RemoteIdentityCryptoTests: XCTestCase {

    // MARK: - DER

    func testTheDERWriterMatchesPublishedEncodings() {
        XCTAssertEqual(
            hex(RemoteDER.objectIdentifier(RemoteDEROID.ecdsaWithSHA256)),
            "06082a8648ce3d040302",
            "ecdsa-with-SHA256, the algorithm identifier every certificate here is signed with"
        )
        XCTAssertEqual(hex(RemoteDER.objectIdentifier(RemoteDEROID.prime256v1)), "06082a8648ce3d030107")
        XCTAssertEqual(hex(RemoteDER.objectIdentifier(RemoteDEROID.ecPublicKey)), "06072a8648ce3d0201")
        XCTAssertEqual(
            hex(RemoteDER.objectIdentifier([1, 2, 840, 113549, 1, 1, 11])),
            "06092a864886f70d01010b",
            "sha256WithRSAEncryption is here as a check on the base-128 arcs, not because it is used"
        )
        XCTAssertEqual(hex(RemoteDER.objectIdentifier(RemoteDEROID.sha1)), "06052b0e03021a")

        XCTAssertEqual(hex(RemoteDER.integer(0)), "020100")
        XCTAssertEqual(hex(RemoteDER.integer(127)), "02017f")
        XCTAssertEqual(hex(RemoteDER.integer(128)), "02020080", "the top bit is what needs the pad")
        XCTAssertEqual(hex(RemoteDER.integer(bytes: [0x00, 0x00, 0x2a])), "02012a")
        XCTAssertEqual(hex(RemoteDER.integer(bytes: [])), "020100")

        XCTAssertEqual(hex(RemoteDER.length(0)), "00")
        XCTAssertEqual(hex(RemoteDER.length(127)), "7f")
        XCTAssertEqual(hex(RemoteDER.length(128)), "8180")
        XCTAssertEqual(hex(RemoteDER.length(300)), "82012c")

        XCTAssertEqual(hex(RemoteDER.null()), "0500")
        XCTAssertEqual(hex(RemoteDER.octetString([0xde, 0xad])), "0402dead")
        XCTAssertEqual(
            hex(RemoteDER.bitString([0x80], unusedBits: 7)),
            "03020780",
            "keyUsage with digitalSignature alone is one bit in a byte with seven unused"
        )
        XCTAssertEqual(hex(RemoteDER.sequence([])), "3000")
        XCTAssertEqual(hex(RemoteDER.explicit(0, RemoteDER.integer(2))), "a003020102")
        XCTAssertEqual(hex(RemoteDER.utf8String("hi")), "0c026869")
        XCTAssertEqual(
            hex(RemoteDER.utcTime(Date(timeIntervalSince1970: 1_700_000_000))),
            "170d3233313131343232313332305a",
            "231114221320Z, which is what UTCTime looks like and where it stops working in 2050"
        )
    }

    // MARK: - Cipher and KDFs

    func testAES256MatchesFIPS197() throws {
        // FIPS-197 appendix C.3: key 000102…1f, plaintext 00112233…ff. A zero IV and one block
        // make CBC's first block ECB, which is what the published answer is.
        let ciphertext = try XCTUnwrap(RemoteAES256.encryptCBC(
            plaintext: Data((0..<16).map { UInt8($0 * 0x11) }),
            key: Data((0..<32).map { UInt8($0) }),
            iv: Data(repeating: 0, count: 16)
        ))
        XCTAssertEqual(hex(Array(ciphertext.prefix(16))), "8ea2b7ca516745bfeafc49904b496089")
        XCTAssertEqual(ciphertext.count, 32, "PKCS#7 adds a whole block when the input is aligned")
    }

    func testAES256ChainsBlocksAndPadsToTheCipherBlock() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let iv = Data((0..<16).map { UInt8(0xF0 &- $0) })
        let repeated = Data(repeating: 0x41, count: 32)
        let ciphertext = try XCTUnwrap(RemoteAES256.encryptCBC(plaintext: repeated, key: key, iv: iv))

        XCTAssertEqual(ciphertext.count, 48)
        XCTAssertNotEqual(
            ciphertext.prefix(16),
            ciphertext.dropFirst(16).prefix(16),
            "identical plaintext blocks that encrypt identically would mean the chaining is not"
        )
        XCTAssertNil(RemoteAES256.encryptCBC(plaintext: repeated, key: Data(), iv: iv))
        XCTAssertNil(RemoteAES256.encryptCBC(plaintext: repeated, key: key, iv: Data()))
    }

    func testPBKDF2MatchesRFC7914Vectors() {
        // RFC 7914 section 11, the PBKDF2-HMAC-SHA256 vectors quoted there for scrypt.
        XCTAssertEqual(
            hex(Array(RemotePBKDF2.derive(
                password: Data("passwd".utf8),
                salt: Data("salt".utf8),
                iterations: 1,
                length: 64
            ))),
            "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc"
                + "49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783"
        )
        XCTAssertEqual(
            hex(Array(RemotePBKDF2.derive(
                password: Data("password".utf8),
                salt: Data("salt".utf8),
                iterations: 4096,
                length: 32
            ))),
            "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a",
            "the iteration count is folded in by XOR, so a wrong one still returns 32 bytes"
        )
    }

    func testThePKCS12PasswordEncodingIsTheOneTheFormatAsksFor() {
        // BMPString: UTF-16 big endian with a two-byte terminator, and the terminator is part of
        // the derivation rather than a detail of how the password is stored.
        XCTAssertEqual(hex(Array(RemotePKCS12KDF.bmpString("abc"))), "006100620063 0000".replacingOccurrences(of: " ", with: ""))
        XCTAssertEqual(hex(Array(RemotePKCS12KDF.bmpString(""))), "0000")

        // RFC 7292 appendix B.2 with the three purposes: same password, same salt, different
        // bytes. A KDF that ignored the identifier would hand the MAC the encryption key.
        let salt = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let mac = RemotePKCS12KDF.derive(
            password: "secret", salt: salt, iterations: 2048, purpose: .mac, length: 20
        )
        let key = RemotePKCS12KDF.derive(
            password: "secret", salt: salt, iterations: 2048, purpose: .key, length: 20
        )
        XCTAssertEqual(mac.count, 20)
        XCTAssertNotEqual(mac, key)
        XCTAssertNotEqual(
            mac,
            RemotePKCS12KDF.derive(
                password: "secret", salt: salt, iterations: 1, purpose: .mac, length: 20
            ),
            "iterations reach the answer"
        )
        XCTAssertEqual(
            RemotePKCS12KDF.derive(
                password: "secret", salt: salt, iterations: 2048, purpose: .mac, length: 40
            ).prefix(20),
            mac,
            "a longer request extends the same output rather than producing a different one"
        )
    }

    // MARK: - Certificate

    func testTheCertificateParsesBackAndCarriesWhatItClaims() throws {
        let key = try RemoteIdentityCertificateBuilder.makeKey()
        let certificateDER = try RemoteIdentityCertificateBuilder.makeCertificate(
            key: key,
            hostIdentifier: "mac-0123456789",
            subjectAlternativeNames: [
                .dnsName("studio.local"),
                try XCTUnwrap(RemoteSubjectAlternativeName.ipAddress(parsing: "192.168.1.42")),
                try XCTUnwrap(RemoteSubjectAlternativeName.ipAddress(parsing: "fd7a:115c:a1e0::cd38:2f7e")),
            ]
        )

        let certificate = try XCTUnwrap(
            SecCertificateCreateWithData(nil, certificateDER as CFData),
            "Security.framework must accept what this writer produces"
        )
        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, "Threading Remote Access")

        let certificateKey = try XCTUnwrap(SecCertificateCopyKey(certificate))
        let generated = try XCTUnwrap(SecKeyCopyPublicKey(key))
        XCTAssertEqual(
            SecKeyCopyExternalRepresentation(certificateKey, nil) as Data?,
            SecKeyCopyExternalRepresentation(generated, nil) as Data?,
            "the key inside the certificate is the key that signed it"
        )

        // Verified with the key read back out of the certificate, not the one held here: this is
        // the check a client's TLS stack will make, and it fails if the signed bytes and the
        // written bytes are not the same bytes.
        let split = try XCTUnwrap(Self.splitCertificate(certificateDER))
        XCTAssertTrue(
            SecKeyVerifySignature(
                certificateKey,
                .ecdsaSignatureMessageX962SHA256,
                split.tbs as CFData,
                split.signature as CFData,
                nil
            )
        )

        XCTAssertNotNil(RemoteSubjectAlternativeName.ipAddress(parsing: "192.168.1.42"))
        XCTAssertNil(RemoteSubjectAlternativeName.ipAddress(parsing: "studio.local"))
    }

    func testOpenSSLReadsTheCertificateTheWayThisCodeMeantIt() throws {
        let executable = URL(fileURLWithPath: "/usr/bin/openssl")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("openssl is not available on this machine")
        }
        let key = try RemoteIdentityCertificateBuilder.makeKey()
        let certificateDER = try RemoteIdentityCertificateBuilder.makeCertificate(
            key: key,
            hostIdentifier: "mac-abcdef",
            subjectAlternativeNames: [.dnsName("studio.local")]
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-identity-\(UUID().uuidString).der")
        try certificateDER.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let described = try Self.run(executable, ["x509", "-inform", "DER", "-in", url.path, "-noout", "-text"])
        // A second opinion on the encoding, from something that has never seen this writer.
        XCTAssertTrue(described.contains("Version: 3"), described)
        XCTAssertTrue(described.contains("ecdsa-with-SHA256"), described)
        XCTAssertTrue(described.contains("CN=Threading Remote Access"), described)
        XCTAssertTrue(described.contains("OU=mac-abcdef"), described)
        XCTAssertTrue(described.contains("NIST CURVE: P-256"), described)
        XCTAssertTrue(described.contains("CA:FALSE"), described)
        XCTAssertTrue(described.contains("Digital Signature"), described)
        XCTAssertTrue(described.contains("DNS:studio.local"), described)
    }

    // MARK: - PKCS#12

    func testAShroudedContainerImportsAsAnIdentity() throws {
        let material = try Self.makeMaterial()
        let container = try XCTUnwrap(RemotePKCS12Writer.makeContainer(
            privateKeyPKCS8: material.pkcs8,
            certificateDER: material.certificateDER
        ))
        XCTAssertFalse(container.passphrase.isEmpty, "an empty passphrase is errSecAuthFailed")

        let identity = try RemoteIdentityImporter.makeIdentity(container: container, strategy: .memoryOnly)
        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(identity, &certificate), errSecSuccess)
        XCTAssertEqual(
            SecCertificateCopyData(try XCTUnwrap(certificate)) as Data,
            material.certificateDER
        )
    }

    /// The tripwire. An unencrypted key bag is not a rejection: `SecPKCS12Import` returns
    /// `errSecSuccess` and hands back a result with no identity in it, which is the expensive
    /// failure this whole file is shaped around. If somebody later "simplifies" the shrouding
    /// away, this fails instead of the listener quietly having nothing to present.
    func testAPlainKeyBagYieldsNoIdentityAtAll() throws {
        let material = try Self.makeMaterial()
        let container = try XCTUnwrap(RemotePKCS12Writer.makeContainer(
            privateKeyPKCS8: material.pkcs8,
            certificateDER: material.certificateDER,
            shroudsPrivateKey: false
        ))
        XCTAssertThrowsError(
            try RemoteIdentityImporter.makeIdentity(container: container, strategy: .memoryOnly)
        ) { error in
            XCTAssertEqual(error as? RemoteIdentityFailure, .identityImportFailed)
        }
    }

    /// What the importer takes out of `SecPKCS12Import`'s result is checked, not assumed.
    ///
    /// `as?` cannot make this check: a conditional downcast to a CoreFoundation type is one the
    /// compiler rejects outright as a cast that "will always succeed", so the pre-existing
    /// `as! SecIdentity` was the only thing standing between an unexpected result and a trap.
    /// The type is compared the way Security names it, and anything else is `nil` — which the
    /// importer turns into the same refusal an empty result gets.
    func testTheIdentityKeyIsCheckedAgainstSecuritysOwnTypeRatherThanForceCast() throws {
        XCTAssertNil(RemoteIdentityImporter.identity(from: nil))
        XCTAssertNil(RemoteIdentityImporter.identity(from: "not an identity" as CFString))
        XCTAssertNil(RemoteIdentityImporter.identity(from: Data([0x30, 0x00]) as CFData))
        // A different Security object is the near miss worth naming: same framework, same
        // CoreFoundation representation, not an identity.
        XCTAssertNil(RemoteIdentityImporter.identity(from: try RemoteIdentityCertificateBuilder.makeKey()))

        let material = try Self.makeMaterial()
        let container = try XCTUnwrap(RemotePKCS12Writer.makeContainer(
            privateKeyPKCS8: material.pkcs8,
            certificateDER: material.certificateDER
        ))
        let identity = try RemoteIdentityImporter.makeIdentity(container: container, strategy: .memoryOnly)
        let accepted = try XCTUnwrap(RemoteIdentityImporter.identity(from: identity))
        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(accepted, &certificate), errSecSuccess)
    }

    /// The macOS 13 and 14 path, exercised on a machine that does not need it.
    ///
    /// `kSecImportToMemoryOnly` is macOS 15 and later, and without it `SecPKCS12Import` lands in
    /// the **default keychain**, which must never happen. The fallback is a keychain file this
    /// app creates, imports through, and deletes. Nothing about it is version-gated, so it can be
    /// asked for directly here rather than only being true on a machine nobody is testing on.
    func testTheKeychainFileFallbackImportsAndLeavesNothingBehind() throws {
        let material = try Self.makeMaterial()
        let container = try XCTUnwrap(RemotePKCS12Writer.makeContainer(
            privateKeyPKCS8: material.pkcs8,
            certificateDER: material.certificateDER
        ))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-identity-keychain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychainURL = directory.appendingPathComponent("import.keychain")

        let identity = try RemoteIdentityImporter.makeIdentity(
            container: container,
            strategy: .keychainFile(keychainURL)
        )
        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(identity, &certificate), errSecSuccess)
        XCTAssertEqual(
            SecCertificateCopyData(try XCTUnwrap(certificate)) as Data,
            material.certificateDER
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: keychainURL.path),
            "the throwaway keychain is deleted rather than reused"
        )
    }

    func testTheImportStrategyIsMemoryOnlyOnThisSystem() {
        // Stated rather than assumed: on macOS 15 and later the container never reaches a
        // keychain at all, and this test is what says so on the machine it ran on.
        let directory = FileManager.default.temporaryDirectory
        if #available(macOS 15.0, *) {
            XCTAssertEqual(RemoteIdentityImportStrategy.preferred(directory: directory), .memoryOnly)
        } else {
            XCTAssertEqual(
                RemoteIdentityImportStrategy.preferred(directory: directory),
                .keychainFile(directory.appendingPathComponent("identity-import.keychain"))
            )
        }
    }

    // MARK: - Helpers

    private struct Material {
        let key: SecKey
        let certificateDER: Data
        let pkcs8: Data
    }

    private static func makeMaterial() throws -> Material {
        let key = try RemoteIdentityCertificateBuilder.makeKey()
        let certificateDER = try RemoteIdentityCertificateBuilder.makeCertificate(
            key: key,
            hostIdentifier: "mac-test",
            subjectAlternativeNames: []
        )
        let x963 = try RemoteIdentityCertificateBuilder.privateKeyData(key)
        let pkcs8 = try XCTUnwrap(RemotePKCS12Writer.pkcs8PrivateKey(x963: x963))
        return Material(key: key, certificateDER: certificateDER, pkcs8: pkcs8)
    }

    /// Pulls the signed body and the signature out of a certificate, so the signature can be
    /// checked independently. A reader of exactly three fields, and only in a test.
    private static func splitCertificate(_ der: Data) -> (tbs: Data, signature: Data)? {
        var cursor = der.startIndex
        func readHeader() -> (tag: UInt8, contentStart: Data.Index, contentLength: Int)? {
            guard cursor < der.endIndex else { return nil }
            let tag = der[cursor]
            cursor = der.index(after: cursor)
            guard cursor < der.endIndex else { return nil }
            var length = Int(der[cursor])
            cursor = der.index(after: cursor)
            if length & 0x80 != 0 {
                let count = length & 0x7F
                length = 0
                for _ in 0..<count {
                    guard cursor < der.endIndex else { return nil }
                    length = (length << 8) | Int(der[cursor])
                    cursor = der.index(after: cursor)
                }
            }
            return (tag, cursor, length)
        }

        guard readHeader() != nil else { return nil }
        let tbsStart = cursor
        guard let tbs = readHeader() else { return nil }
        cursor = der.index(tbs.contentStart, offsetBy: tbs.contentLength)
        let tbsEnd = cursor
        guard let algorithm = readHeader() else { return nil }
        cursor = der.index(algorithm.contentStart, offsetBy: algorithm.contentLength)
        guard let signature = readHeader(), signature.tag == RemoteDER.Tag.bitString else {
            return nil
        }
        // The first content byte of a BIT STRING counts the unused bits, and a signature has none.
        let start = der.index(after: signature.contentStart)
        let end = der.index(signature.contentStart, offsetBy: signature.contentLength)
        return (Data(der[tbsStart..<tbsEnd]), Data(der[start..<end]))
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
