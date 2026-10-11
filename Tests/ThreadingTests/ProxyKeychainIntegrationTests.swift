import XCTest
import Foundation
import Security
@testable import Threading

/// Opt in with TEST_RUNNER_THREADING_PROXY_KEYCHAIN_TEST=1. Creates and removes two uniquely
/// named login-Keychain items; never changes trust or the app's normal inspection identity.
final class ProxyKeychainIntegrationTests: XCTestCase {
    func testPersistentAuthorityReloadsSignsAndRefusesIncompleteIdentity() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THREADING_PROXY_KEYCHAIN_TEST"] == "1")
        let namespace = "codes.threading.proxy.tests.\(UUID().uuidString.lowercased())"
        print("Disposable proxy Keychain namespace: \(namespace)")
        try await Task.detached { try Self.exerciseAuthority(namespace: namespace) }.value
    }

    private static func exerciseAuthority(namespace: String) throws {
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(namespace.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        let certificateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: namespace,
            kSecAttrAccount as String: "public-certificate",
        ]
        let queries = [keyQuery, certificateQuery]
        let unused = KeychainInteractionGate.run(allowingPrompt: false) {
            queries.allSatisfy { SecItemCopyMatching($0 as CFDictionary, nil) == errSecItemNotFound }
        }
        guard unused else { XCTFail("Disposable test namespace already exists; leaving it untouched."); return }
        defer {
            KeychainInteractionGate.run(allowingPrompt: false) {
                for query in queries {
                    let status = SecItemDelete(query as CFDictionary)
                    XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound, "Keychain cleanup: \(status)")
                    XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
                }
            }
        }

        let first = try ProxyCertificateAuthority.loadOrCreate(namespace: namespace)
        let reloaded = try ProxyCertificateAuthority.loadOrCreate(namespace: namespace)
        XCTAssertEqual(first.certificate, reloaded.certificate)
        // Verify the actual OS behavior, not only the requested extractability attribute.
        XCTAssertNil(SecKeyCopyExternalRepresentation(reloaded.key, nil))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, reloaded.certificate as CFData))
        let publicKey = try XCTUnwrap(SecCertificateCopyKey(certificate))
        let challenge = Data("Threading disposable CA persistence test".utf8)
        let signature = try XCTUnwrap(SecKeyCreateSignature(reloaded.key, .ecdsaSignatureMessageX962SHA256, challenge as CFData, nil))
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, challenge as CFData, signature, nil))
        XCTAssertFalse(try reloaded.leaf(for: "localhost").certificate.isEmpty)

        XCTAssertEqual(KeychainInteractionGate.run(allowingPrompt: false) {
            SecItemDelete(certificateQuery as CFDictionary)
        }, errSecSuccess)
        XCTAssertThrowsError(try ProxyCertificateAuthority.loadOrCreate(namespace: namespace)) { error in
            guard case ProxyCertificateAuthority.Failure.incompleteIdentity = error else {
                XCTFail("Expected an incomplete-identity refusal, got \(error)"); return
            }
        }
        XCTAssertEqual(KeychainInteractionGate.run(allowingPrompt: false) {
            SecItemCopyMatching(keyQuery as CFDictionary, nil)
        }, errSecSuccess, "An incomplete pair must not destroy its original signing key")
    }
}
