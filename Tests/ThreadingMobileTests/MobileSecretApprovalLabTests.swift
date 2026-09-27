#if DEBUG
import Foundation
import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

final class MobileSecretApprovalLabTests: XCTestCase {
    func testRegistrationReportsMissingPairingAndPreviewInsteadOfIgnoringTheTap() throws {
        for (isDemo, expected) in [(false, MobileSecretApprovalFailure.pairFirst), (true, .preview)] {
            XCTAssertThrowsError(try MobileSecretApprovalEnrollment.validate(
                code: "12345678", client: nil, hostID: nil, isDemo: isDemo
            )) { XCTAssertEqual($0 as? MobileSecretApprovalFailure, expected) }
        }
    }

    func testRegistrationAcceptsTheStoredPinAfterPairingReplacesTheQRLink() throws {
        let fingerprint = RemoteHostFingerprint(certificateDER: Data("test Mac certificate".utf8))
        for kind in [RemoteHostEndpointKind.lan, .tailscale, .vpn] {
            let scanned = try makeLink(pinnedFingerprintCode: fingerprint.pairingCode)
            let endpoint = RemoteHostEndpointDTO(
                kind: kind, baseURL: scanned.baseURL, isStable: true, identity: .pinned
            )
            var host = PairedRemoteHost(
                id: "mac", hostID: "mac", shareID: "my-devices", scope: "all", name: "Mac",
                link: scanned, lastConnectedAt: Date(), endpoints: [endpoint], connectionPolicy: .privateOnly
            )
            RemoteHostTrust.register(link: scanned)
            let connected = try XCTUnwrap(RemoteConnectionLink(baseURL: scanned.baseURL, token: "test"))
            let identity = RemoteHostDTO(
                id: "mac", name: "Mac", endpoints: [endpoint], connectionPolicy: .privateOnly,
                pinnedFingerprint: fingerprint.hex
            )
            XCTAssertEqual(host.merge(identity: identity, successfulLink: connected, overPinnedChannel: true), .adopted)
            RemoteHostTrust.register([host])
            let route = MobileLiveRoutePolicy.route(for: host, lastConnection: nil, hostedLink: nil)
            XCTAssertNil(route.link.pinnedFingerprintCode, "The successful route no longer carries a QR pin")
            XCTAssertEqual(host.pinnedFingerprint, fingerprint.hex)
            let client = RemoteClient(link: route.link, endpointKind: route.kind)
            XCTAssertEqual(try MobileSecretApprovalEnrollment.validate(
                code: "12345678", client: client, hostID: host.id, isDemo: false
            ), "12345678")
        }
    }

    func testRegistrationRefusesNonDirectRoutesEvenWithARegisteredPin() throws {
        let link = try makeLink(pinnedFingerprintCode: String(repeating: "A", count: 26))
        RemoteHostTrust.register(link: link)
        for kind in [RemoteHostEndpointKind.hosted, .loopback, .relay, .unknown("future")] {
            XCTAssertThrowsError(try MobileSecretApprovalEnrollment.validate(
                code: "12345678", client: RemoteClient(link: link, endpointKind: kind), hostID: "mac", isDemo: false
            )) { XCTAssertEqual($0 as? MobileSecretApprovalFailure, .directConnectionRequired) }
        }
        let httpURL = try XCTUnwrap(URL(string: "http://\(try XCTUnwrap(link.baseURL.host))"))
        let insecure = try XCTUnwrap(RemoteConnectionLink(baseURL: httpURL, token: "test"))
        XCTAssertThrowsError(try RemoteClient(link: insecure, endpointKind: .lan).validateSecretApprovalTransport()) {
            XCTAssertEqual($0 as? MobileSecretApprovalFailure, .directConnectionRequired)
        }
    }

    func testRegistrationRequiresAPinForTheActualRequestHost() throws {
        let pinned = try makeLink(pinnedFingerprintCode: String(repeating: "A", count: 26))
        RemoteHostTrust.register(link: pinned)
        let otherHost = try makeLink()
        XCTAssertThrowsError(try MobileSecretApprovalEnrollment.validate(
            code: "12345678", client: RemoteClient(link: otherHost, endpointKind: .lan), hostID: "mac", isDemo: false
        )) { XCTAssertEqual($0 as? MobileSecretApprovalFailure, .pinnedConnectionRequired) }
    }

    func testAnOldQRFragmentCannotReplaceARevokedSessionPin() async throws {
        let link = try makeLink(pinnedFingerprintCode: String(repeating: "A", count: 26))
        RemoteHostTrust.register(link: link)
        let client = RemoteClient(link: link, endpointKind: .lan)
        XCTAssertNoThrow(try client.validateSecretApprovalTransport())
        RemoteClient.pinningDelegate.setPins(nil, forHost: try XCTUnwrap(link.baseURL.host))
        XCTAssertThrowsError(try MobileSecretApprovalEnrollment.validate(
            code: "12345678", client: client, hostID: "mac", isDemo: false
        )) { XCTAssertEqual($0 as? MobileSecretApprovalFailure, .pinnedConnectionRequired) }
        // Recheck at the request boundary too: a previously accepted screen cannot send after
        // its Mac's pin has been forgotten. This must fail before any network request starts.
        do {
            _ = try await client.secretApprovalLab(.init(action: .challenge))
            XCTFail("A stale QR fragment must not authorize an unpinned request")
        } catch let failure as MobileSecretApprovalFailure {
            XCTAssertEqual(failure, .pinnedConnectionRequired)
        }
    }

    func testRegistrationAllowsPastedSpacingButRejectsMissingOrNonNumericDigits() throws {
        let link = try makeLink(pinnedFingerprintCode: String(repeating: "A", count: 26))
        RemoteHostTrust.register(link: link)
        let client = RemoteClient(link: link, endpointKind: .lan)
        XCTAssertEqual(try MobileSecretApprovalEnrollment.validate(
            code: " 1234 5678\n", client: client, hostID: "mac", isDemo: false
        ), "12345678")
        for code in ["1234567", "123456789", "1234567x"] {
            XCTAssertThrowsError(try MobileSecretApprovalEnrollment.validate(
                code: code, client: client, hostID: "mac", isDemo: false
            )) { XCTAssertEqual($0 as? MobileSecretApprovalFailure, .invalidCode) }
        }
    }

    func testRegistrationExplainsMacRefusalWithoutDisplayingServerDetail() {
        let refusal = RemoteClientError.server(status: 403, detail: "untrusted server detail")
        let message = MobileSecretApprovalFailure.message(for: refusal, enrolling: true)
        XCTAssertEqual(message, MobileL10n.string("The Mac refused registration. Stop and start the experiment on the Mac, then enter its new code within five minutes."))
        XCTAssertFalse(message.contains("untrusted server detail"))
        XCTAssertNotEqual(message, MobileSecretApprovalFailure.message(for: refusal, enrolling: false))
    }

    private func makeLink(pinnedFingerprintCode: String? = nil) throws -> RemoteConnectionLink {
        // Each test owns its hostname and clears only that pin in the real session delegate.
        let host = "faceid-\(UUID().uuidString.lowercased()).test"
        addTeardownBlock { RemoteClient.pinningDelegate.setPins(nil, forHost: host) }
        return try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: "https://\(host)")), token: "test",
            pinnedFingerprintCode: pinnedFingerprintCode
        ))
    }

    func testBuiltAppDeclaresFaceIDUse() {
        XCTAssertEqual(Bundle.main.infoDictionary?["NSFaceIDUsageDescription"] as? String,
                       "Approve one credential operation on your paired Mac.")
    }

    func testGitHubApprovalBindsMethodDestinationAndCredentialBeforeFaceID() async throws {
        let offered = RemoteSecretApprovalLab.Challenge(experimentID: UUID(), id: UUID(), deviceID: "phone",
            expiresAt: Int64(Date().timeIntervalSince1970) + 60, githubProfile: true)
        XCTAssertTrue(offered.isGitHubProfile)
        let original = try JSONEncoder().encode(offered)
        for (field, value) in [("destination", "https://other.test/user"), ("destination", "https://api.github.com/repos"),
                               ("method", "POST"), ("credential", "Another token"), ("operation", "arbitrary-command")] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            object[field] = value
            let altered = try JSONDecoder().decode(RemoteSecretApprovalLab.Challenge.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertFalse(altered.isSupported)
            XCTAssertNotEqual(try altered.signingData(), try offered.signingData())
            do {
                _ = try await MobileSecretApprovalSigner().sign(altered, deviceID: "phone")
                XCTFail("A changed request must be refused before authentication")
            } catch MobileSecretApprovalSigner.Failure.invalidChallenge { }
        }
    }

    func testUnenrolledPhoneCannotSign() async throws {
        let signer = MobileSecretApprovalSigner()
        let offered = RemoteSecretApprovalLab.Challenge(
            experimentID: UUID(), id: UUID(), deviceID: "phone",
            expiresAt: Int64(Date().timeIntervalSince1970) + 60
        )
        do {
            _ = try await signer.sign(offered, deviceID: "phone")
            XCTFail("There must be no implicit enrollment or software key")
        } catch MobileSecretApprovalSigner.Failure.notEnrolled { }
    }

    func testExpiredAndOtherDeviceRequestsAreRejectedBeforeAuthentication() async throws {
        let signer = MobileSecretApprovalSigner()
        for offered in [
            RemoteSecretApprovalLab.Challenge(experimentID: UUID(), id: UUID(), deviceID: "phone", expiresAt: 0),
            RemoteSecretApprovalLab.Challenge(experimentID: UUID(), id: UUID(), deviceID: "another-phone",
                                             expiresAt: Int64(Date().timeIntervalSince1970) + 60)
        ] {
            do {
                _ = try await signer.sign(offered, deviceID: "phone")
                XCTFail("The wrong operation must never reach Face ID")
            } catch MobileSecretApprovalSigner.Failure.invalidChallenge { }
        }
    }

#if targetEnvironment(simulator)
    func testSimulatorRefusesEnrollmentInsteadOfSubstitutingSoftwareKey() async throws {
        let signer = MobileSecretApprovalSigner()
        do {
            _ = try await signer.enroll()
            XCTFail("Simulator enrollment must stay unavailable")
        } catch MobileSecretApprovalSigner.Failure.faceIDRequired { }
    }
#endif
}
#endif
