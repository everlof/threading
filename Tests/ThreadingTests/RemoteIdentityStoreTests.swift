import Foundation
import Security
import XCTest
import ThreadingRemoteKit
@testable import Threading

/// Where the trust root lives, what happens when it is not there, and what happens when somebody
/// asks for a new one.
///
/// The rule this file exists to hold: **a missing or unreadable identity is a named state, never
/// a silent regenerate.** Minting a fresh certificate over an unreadable file would unpair every
/// device on the network to hide a bug, and it would look like success while doing it.
final class RemoteIdentityStoreTests: XCTestCase {

    private var directory: URL!

    override func tearDown() {
        RemoteIdentityTestStore.erase(directory)
        directory = nil
        super.tearDown()
    }

    // MARK: - Files

    func testTheIdentityIsOwnerOnlyFilesAndRebuildsTheSameFingerprintNextLaunch() throws {
        let made = RemoteIdentityTestStore.make()
        directory = made.directory
        let minted = try made.store.currentIdentity().get()

        let file = directory.appendingPathComponent("current.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600,
            "the mode is the whole of what stops another user on this Mac reading the key"
        )
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((directoryMode[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        // The second store is the next launch: same files, no minting, same certificate.
        let next = RemoteAccessIdentityStore(directory: directory)
        next.journal = { _, _, _ in }
        let rebuilt = try next.currentIdentity().get()
        XCTAssertEqual(
            rebuilt.fingerprint,
            minted.fingerprint,
            "the SecIdentity is rebuilt from the files, so a restart does not unpair anything"
        )
        XCTAssertEqual(rebuilt.certificateDER, minted.certificateDER)
        XCTAssertEqual(next.snapshot.fingerprint, minted.fingerprint)
        XCTAssertNil(next.snapshot.failure)
        XCTAssertNil(next.snapshot.nextFingerprint)
    }

    func testTheCertificateOnDiskIsTheOneClientsArePinnedTo() throws {
        let made = RemoteIdentityTestStore.make()
        directory = made.directory
        let identity = try made.store.currentIdentity().get()

        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(identity.secIdentity, &certificate), errSecSuccess)
        let presented = SecCertificateCopyData(try XCTUnwrap(certificate)) as Data
        XCTAssertEqual(presented, identity.certificateDER)
        XCTAssertEqual(
            identity.fingerprint,
            RemoteHostFingerprint(certificateDER: presented),
            "the advertised fingerprint is the SHA-256 of what the listener actually presents"
        )
        XCTAssertEqual(
            identity.fingerprint.pairingCode.count,
            RemoteHostPinningDefaults.pairingCodeCharacterCount
        )
    }

    // MARK: - Named states

    func testAnUnreadableIdentityIsANamedStateAndIsNotMintedOver() throws {
        let made = RemoteIdentityTestStore.make()
        directory = made.directory
        _ = try made.store.currentIdentity().get()
        let file = directory.appendingPathComponent("current.json")
        let damaged = Data("this is not an identity".utf8)
        try damaged.write(to: file)

        let store = RemoteAccessIdentityStore(directory: directory)
        store.journal = { _, _, _ in }
        XCTAssertEqual(store.currentIdentity().failure, .corrupt)
        XCTAssertEqual(store.snapshot.failure, .corrupt)
        XCTAssertNil(store.snapshot.fingerprint)
        XCTAssertEqual(
            try Data(contentsOf: file),
            damaged,
            "the bytes stay exactly as they are: replacing them would unpair every device"
        )
    }

    func testARecordFromANewerBuildIsLeftAloneAndNamed() throws {
        let made = RemoteIdentityTestStore.make()
        directory = made.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("current.json")
        let future = Data(#"{"version":999,"createdAt":0,"privateKey":"","certificate":""}"#.utf8)
        try future.write(to: file)

        XCTAssertEqual(made.store.currentIdentity().failure, .unsupportedVersion)
        XCTAssertEqual(made.store.snapshot.failure, .unsupportedVersion)
        XCTAssertEqual(
            try Data(contentsOf: file),
            future,
            "a downgrade must not confiscate the trust root it merely cannot read"
        )
    }

    func testHalvesThatDoNotBelongTogetherAreRefused() throws {
        let made = RemoteIdentityTestStore.make()
        directory = made.directory
        _ = try made.store.currentIdentity().get()
        let file = directory.appendingPathComponent("current.json")

        // A certificate from a different key, which is what a half-restored backup looks like.
        let stranger = try RemoteIdentityCertificateBuilder.makeKey()
        let strangerCertificate = try RemoteIdentityCertificateBuilder.makeCertificate(
            key: stranger,
            hostIdentifier: "mac-other",
            subjectAlternativeNames: []
        )
        var record = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        record["certificate"] = strangerCertificate.base64EncodedString()
        try JSONSerialization.data(withJSONObject: record).write(to: file)

        let store = RemoteAccessIdentityStore(directory: directory)
        store.journal = { _, _, _ in }
        XCTAssertEqual(
            store.currentIdentity().failure,
            .corrupt,
            "a key and a certificate that do not match must fail here, not at a TLS handshake"
        )
    }

    func testAnIdentityIsMintedOnlyWhenThereIsNone() throws {
        let made = RemoteIdentityTestStore.make()
        directory = made.directory
        var events: [RemoteDiagnosticEvent] = []
        made.store.journal = { event, _, fields in
            events.append(event)
            // A report carries a short hash of the fingerprint and nothing else about it.
            XCTAssertEqual(fields[.detail]?.hasPrefix("fp-"), true)
            XCTAssertNil(fields[.origin])
        }

        let first = try made.store.currentIdentity().get()
        let second = try made.store.currentIdentity().get()
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(events, [.hostIdentityCreated], "asking twice does not mint twice")
    }

    // MARK: - Reset

    func testResetMintsANewIdentityAndSaysSo() throws {
        let made = RemoteIdentityTestStore.make()
        directory = made.directory
        let original = try made.store.currentIdentity().get()
        var events: [RemoteDiagnosticEvent] = []
        made.store.journal = { event, _, _ in events.append(event) }

        let replacement = try made.store.reset().get()
        XCTAssertNotEqual(
            replacement.fingerprint,
            original.fingerprint,
            "reset is the path for a lost key, and it is what unpairs every device"
        )
        XCTAssertEqual(made.store.snapshot.fingerprint, replacement.fingerprint)
        XCTAssertEqual(events, [.hostIdentityReset])
        XCTAssertEqual(try made.store.currentIdentity().get().fingerprint, replacement.fingerprint)
    }

    func testResetDropsAPreparedSuccessorToo() throws {
        let made = RemoteIdentityTestStore.make()
        directory = made.directory
        _ = try made.store.currentIdentity().get()
        _ = try made.store.prepareRotation().get()
        XCTAssertNotNil(made.store.snapshot.nextFingerprint)

        _ = try made.store.reset().get()
        XCTAssertNil(
            made.store.snapshot.nextFingerprint,
            "a successor announced under the old identity means nothing under the new one"
        )
    }

    // MARK: - Rotation

    func testRotationKeepsBothIdentitiesUntilTheSuccessorIsActivated() throws {
        let made = RemoteIdentityTestStore.make()
        directory = made.directory
        let original = try made.store.currentIdentity().get()

        let successor = try made.store.prepareRotation().get()
        XCTAssertNotEqual(successor, original.fingerprint)
        XCTAssertEqual(made.store.snapshot.fingerprint, original.fingerprint)
        XCTAssertEqual(
            made.store.snapshot.nextFingerprint,
            successor,
            "the successor is announced before it is presented, which is what makes rotation free"
        )
        XCTAssertEqual(
            try made.store.currentIdentity().get().fingerprint,
            original.fingerprint,
            "preparing changes nothing about what the listeners present"
        )

        var events: [RemoteDiagnosticEvent] = []
        made.store.journal = { event, _, _ in events.append(event) }
        let activated = try made.store.activateRotation().get()
        XCTAssertEqual(activated.fingerprint, successor)
        XCTAssertEqual(made.store.snapshot.fingerprint, successor)
        XCTAssertNil(made.store.snapshot.nextFingerprint)
        XCTAssertEqual(events, [.hostIdentityRotated])

        // And the successor survives the next launch as the ordinary identity.
        let relaunched = RemoteAccessIdentityStore(directory: directory)
        relaunched.journal = { _, _, _ in }
        XCTAssertEqual(try relaunched.currentIdentity().get().fingerprint, successor)
    }

    func testActivatingWithoutPreparingIsRefused() throws {
        let made = RemoteIdentityTestStore.make()
        directory = made.directory
        let original = try made.store.currentIdentity().get()

        XCTAssertEqual(made.store.activateRotation().failure, .noRotationPrepared)
        XCTAssertEqual(made.store.snapshot.fingerprint, original.fingerprint)
    }

    func testPreparingTwiceReplacesTheUnannouncedSuccessor() throws {
        let made = RemoteIdentityTestStore.make()
        directory = made.directory
        _ = try made.store.currentIdentity().get()
        let first = try made.store.prepareRotation().get()
        let second = try made.store.prepareRotation().get()

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(made.store.snapshot.nextFingerprint, second)
        XCTAssertEqual(try made.store.activateRotation().get().fingerprint, second)
    }

    // MARK: - What the phone is told

    func testTheOwnerHostCarriesFingerprintsOnlyWhenSomethingPinnedIsOnOffer() throws {
        let made = RemoteIdentityTestStore.make()
        directory = made.directory
        let identity = try made.store.currentIdentity().get()
        _ = try made.store.prepareRotation().get()
        let snapshot = made.store.snapshot

        let lan = RemoteHostEndpointDTO(
            kind: RemoteHostEndpointKind.lan,
            baseURL: try XCTUnwrap(URL(string: "https://192.168.1.42:8760/")),
            isStable: true,
            identity: RemoteHostEndpointIdentity.pinned
        )
        let serve = RemoteHostEndpointDTO(
            kind: RemoteHostEndpointKind.tailscale,
            baseURL: try XCTUnwrap(URL(string: "https://mac.example.ts.net:8443/")),
            isStable: true
        )

        let pinned = RemoteAccessCoordinator.ownerHost(
            RemoteHostDTO(id: "mac-1", name: "Studio"),
            endpoints: [lan, serve],
            policy: .privateOnly,
            identity: snapshot
        )
        XCTAssertEqual(pinned.pinnedFingerprint, identity.fingerprint.hex)
        XCTAssertEqual(pinned.nextPinnedFingerprint, snapshot.nextFingerprint?.hex)
        let pins = try XCTUnwrap(pinned.pinSet)
        XCTAssertTrue(pins.matches(certificateDER: identity.certificateDER))

        let unpinned = RemoteAccessCoordinator.ownerHost(
            RemoteHostDTO(id: "mac-1", name: "Studio"),
            endpoints: [serve],
            policy: .privateOnly,
            identity: snapshot
        )
        XCTAssertNil(
            unpinned.pinnedFingerprint,
            "a phone that pinned this would refuse the Serve certificate it is actually using"
        )
        XCTAssertNil(unpinned.nextPinnedFingerprint)
    }

    // MARK: - Isolation

    func testTheDefaultDirectoryIsRedirectedUnderAHostedTest() {
        // The same tripwire `HostedStoreTestCase` keeps over the projects database: this bundle
        // runs inside the shipping app, so a build that undid the redirect would mint over the
        // identity of the app the developer is running and unpair their phone.
        XCTAssertTrue(RemoteIdentityLocations.isHostedTest)
        let directory = RemoteIdentityLocations.directory()
        XCTAssertTrue(
            directory.path.hasPrefix(FileManager.default.temporaryDirectory.path),
            "the identity a test mints must never be the user's own: \(directory.path)"
        )
        XCTAssertTrue(
            directory.lastPathComponent.contains(String(ProcessInfo.processInfo.processIdentifier)),
            "keyed by pid, because concurrent runs share this machine"
        )
    }
}

private extension Result {
    /// The named failure, for a test that is about the name rather than the value.
    var failure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}
