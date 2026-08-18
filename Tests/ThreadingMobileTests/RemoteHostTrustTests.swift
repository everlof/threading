import Foundation
import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

/// The phone's half of the pinned identity: where a pin may come from, where it may not, what it
/// is applied to, that it survives a relaunch, and what a refusal is called.
final class RemoteHostTrustTests: XCTestCase {

    private static let bearer = String(repeating: "a", count: 43)
    private static let certificate = Data("this Mac's certificate".utf8)
    private static let successor = Data("the certificate this Mac will present next".utf8)

    private var fingerprint: RemoteHostFingerprint { RemoteHostFingerprint(certificateDER: Self.certificate) }
    private var nextFingerprint: RemoteHostFingerprint { RemoteHostFingerprint(certificateDER: Self.successor) }

    // MARK: - One delegate, both sessions

    /// The socket path is the half that silently keeps stock evaluation when it is forgotten, and
    /// stock evaluation refuses a Mac's self-signed leaf outright. Two sessions configured alike
    /// would not be enough: a server-trust challenge goes to the session-level delegate, so the
    /// pin a request learned is only in force on the socket if it is the *same object*.
    func testTheRequestSessionAndTheSocketSessionShareOnePinningDelegate() {
        let request = RemoteClient.requestSessionDelegate
        let socket = RemoteClient.socketSessionDelegate

        XCTAssertNotNil(request, "a session with no delegate cannot pin at all")
        XCTAssertTrue(
            request as AnyObject === socket as AnyObject,
            "the socket must go through the same pinning delegate as every REST call"
        )
        XCTAssertTrue(request as AnyObject === RemoteClient.pinningDelegate)
    }

    // MARK: - Where a pin comes from

    func testAScannedCodePinsTheAddressItWasScannedFrom() throws {
        let delegate = RemoteCertificatePinningDelegate()
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: "https://192.168.1.42:8760/")),
            token: Self.bearer,
            pinnedFingerprintCode: fingerprint.pairingCode
        ))

        let pins = RemoteHostTrust.register(link: link, with: delegate)

        XCTAssertNotNil(pins)
        let registered = try XCTUnwrap(delegate.pins(forHost: "192.168.1.42"))
        XCTAssertTrue(registered.matches(certificateDER: Self.certificate))
        XCTAssertFalse(registered.matches(certificateDER: Self.successor))
    }

    func testALinkWithoutACodePinsNothingAndKeepsStockEvaluation() throws {
        let delegate = RemoteCertificatePinningDelegate()
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: "https://mac.tail1234.ts.net/")),
            token: Self.bearer
        ))

        XCTAssertNil(RemoteHostTrust.register(link: link, with: delegate))
        XCTAssertNil(
            delegate.pins(forHost: "mac.tail1234.ts.net"),
            "Serve holds a real certificate for that name, and pinning it would refuse the one endpoint that works"
        )
    }

    /// The rule the wire contract exists for: one Mac advertises both kinds at once, and only the
    /// endpoints it flagged present its own certificate.
    func testOnlyFlaggedEndpointsAreGivenThePinFromApiMe() throws {
        let delegate = RemoteCertificatePinningDelegate()
        var host = ownerHost(endpoints: [
            endpoint(kind: RemoteHostEndpointKind.lan, "https://192.168.1.42:8760/", pinned: true),
            endpoint(kind: RemoteHostEndpointKind.vpn, "https://10.8.0.3:8760/", pinned: true),
            endpoint(kind: RemoteHostEndpointKind.tailscale, "https://mac.tail1234.ts.net:8443/", pinned: false),
        ])
        host.merge(identity: identity(current: fingerprint), successfulLink: host.link)

        RemoteHostTrust.register([host], with: delegate)

        for name in ["192.168.1.42", "10.8.0.3"] {
            let pins = try XCTUnwrap(delegate.pins(forHost: name), name)
            XCTAssertTrue(pins.matches(certificateDER: Self.certificate), name)
        }
        XCTAssertNil(
            delegate.pins(forHost: "mac.tail1234.ts.net"),
            "an endpoint with no identity flag presents somebody else's TLS"
        )
    }

    func testAGuestCapabilityNeverTeachesThisPhoneAPin() throws {
        let delegate = RemoteCertificatePinningDelegate()
        var guest = ownerHost(endpoints: [
            endpoint(kind: RemoteHostEndpointKind.lan, "https://192.168.1.42:8760/", pinned: true),
        ])
        guest.scope = "session"
        guest.merge(identity: identity(current: fingerprint), successfulLink: guest.link)

        XCTAssertNil(guest.pinnedFingerprint, "a one-chat token is not the owner of the Mac")
        RemoteHostTrust.register([guest], with: delegate)
        XCTAssertNil(delegate.pins(forHost: "192.168.1.42"))
    }

    // MARK: - Rotation

    func testTheSuccessorIsAcceptedBesideTheCurrentCertificate() throws {
        let delegate = RemoteCertificatePinningDelegate()
        var host = ownerHost(endpoints: [
            endpoint(kind: RemoteHostEndpointKind.lan, "https://192.168.1.42:8760/", pinned: true),
        ])
        host.merge(
            identity: identity(current: fingerprint, next: nextFingerprint),
            successfulLink: host.link
        )
        RemoteHostTrust.register([host], with: delegate)

        let pins = try XCTUnwrap(delegate.pins(forHost: "192.168.1.42"))
        XCTAssertTrue(pins.matches(certificateDER: Self.certificate), "the identity in use still works")
        XCTAssertTrue(
            pins.matches(certificateDER: Self.successor),
            "the announced successor is accepted before it goes live, which is what makes rotation free"
        )
    }

    func testTheRecordFollowsWhenTheSuccessorBecomesCurrent() throws {
        let delegate = RemoteCertificatePinningDelegate()
        var host = ownerHost(endpoints: [
            endpoint(kind: RemoteHostEndpointKind.lan, "https://192.168.1.42:8760/", pinned: true),
        ])
        host.merge(
            identity: identity(current: fingerprint, next: nextFingerprint),
            successfulLink: host.link
        )

        host.merge(identity: identity(current: nextFingerprint), successfulLink: host.link)
        RemoteHostTrust.register([host], with: delegate)

        XCTAssertEqual(host.pinnedFingerprint, nextFingerprint.hex)
        XCTAssertNil(host.nextPinnedFingerprint)
        let pins = try XCTUnwrap(delegate.pins(forHost: "192.168.1.42"))
        XCTAssertTrue(pins.matches(certificateDER: Self.successor))
        XCTAssertFalse(
            pins.matches(certificateDER: Self.certificate),
            "the retired certificate stops being accepted once the Mac says it has moved on"
        )
    }

    /// A Mac that says nothing about its identity is an older Mac or one whose doors are all
    /// publicly trusted. Reading that as "stop pinning" would turn a downgrade into the quiet
    /// path, and this scheme's whole value is that there is no quiet path.
    func testAResponseWithNoFingerprintDoesNotClearAPin() throws {
        var host = ownerHost(endpoints: [
            endpoint(kind: RemoteHostEndpointKind.lan, "https://192.168.1.42:8760/", pinned: true),
        ])
        host.merge(identity: identity(current: fingerprint), successfulLink: host.link)

        host.merge(identity: RemoteHostDTO(id: "mac", name: "Mac"), successfulLink: host.link)

        XCTAssertEqual(host.pinnedFingerprint, fingerprint.hex)
    }

    // MARK: - Persistence

    func testPinsSurviveARoundTripThroughTheStoresEncoding() throws {
        var host = ownerHost(endpoints: [
            endpoint(kind: RemoteHostEndpointKind.lan, "https://192.168.1.42:8760/", pinned: true),
        ])
        host.merge(
            identity: identity(current: fingerprint, next: nextFingerprint),
            successfulLink: host.link
        )

        let decoded = try JSONDecoder().decode(
            [PairedRemoteHost].self,
            from: try JSONEncoder().encode([host])
        )
        let delegate = RemoteCertificatePinningDelegate()
        RemoteHostTrust.register(decoded, with: delegate)

        XCTAssertEqual(decoded.first?.pinnedFingerprint, fingerprint.hex)
        XCTAssertEqual(decoded.first?.nextPinnedFingerprint, nextFingerprint.hex)
        let pins = try XCTUnwrap(delegate.pins(forHost: "192.168.1.42"))
        XCTAssertTrue(pins.matches(certificateDER: Self.certificate))
        XCTAssertTrue(pins.matches(certificateDER: Self.successor))
    }

    /// The pin has to be in force for the request that would learn it. A phone that has only ever
    /// scanned a code holds it in the link, and a relaunch must not fall back to stock
    /// evaluation, which refuses this certificate outright.
    func testAScannedCodeIsStillPinnedAfterARelaunchWithNoApiMeYet() throws {
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: "https://192.168.1.42:8760/")),
            token: Self.bearer,
            pinnedFingerprintCode: fingerprint.pairingCode
        ))
        let host = PairedRemoteHost(
            id: "mac",
            hostID: "mac",
            shareID: "my-devices",
            scope: "all",
            name: "Mac",
            link: link,
            lastConnectedAt: Date()
        )

        let decoded = try JSONDecoder().decode(
            [PairedRemoteHost].self,
            from: try JSONEncoder().encode([host])
        )
        let delegate = RemoteCertificatePinningDelegate()
        RemoteHostTrust.register(decoded, with: delegate)

        let pins = try XCTUnwrap(delegate.pins(forHost: "192.168.1.42"))
        XCTAssertTrue(pins.matches(certificateDER: Self.certificate))
        XCTAssertEqual(decoded.first?.pinnedFingerprintCode, fingerprint.pairingCode)
    }

    func testARecordWrittenBeforePinningExistedStillDecodes() throws {
        let older = try JSONDecoder().decode(
            [PairedRemoteHost].self,
            from: Data(#"""
            [{"id":"mac","name":"Mac","lastConnectedAt":0,
              "link":{"baseURL":"https://mac.tail1234.ts.net/","token":"bearer"}}]
            """#.utf8)
        )

        XCTAssertEqual(older.count, 1)
        XCTAssertNil(older.first?.pinnedFingerprint)
        XCTAssertTrue(older.first?.pinnedHosts.isEmpty == true)
    }

    // MARK: - The refusal has a name

    func testAFingerprintMismatchIsItsOwnFailureAndAsksForAFreshCode() {
        let failure = RemoteConnectionFailure.transport(
            URLError(.cancelled),
            host: "192.168.1.42",
            trustVerdict: .rejectedFingerprintMismatch
        )

        XCTAssertEqual(failure.cause, .pinnedIdentityMismatch)
        XCTAssertEqual(failure.recovery, .pairAgain)
        XCTAssertEqual(
            failure.message,
            "This Mac’s identity does not match the one you paired with. "
                + "If Remote Access was reset on the Mac, scan its QR code again."
        )
    }

    /// A cancelled challenge is `URLError(-999)` with nothing in it, and a mismatch on a private
    /// address would otherwise be read as a Local Network denial or as a changed address. Both
    /// send the person somewhere that changes nothing.
    func testAMismatchIsNeverReportedAsAChangedAddressOrADeniedPermission() {
        let denial = URLError(
            .cannotConnectToHost,
            userInfo: [NSUnderlyingErrorKey: NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EHOSTUNREACH)
            )]
        )

        XCTAssertEqual(
            RemoteConnectionFailure.transport(
                denial,
                host: "192.168.1.42",
                trustVerdict: .rejectedFingerprintMismatch
            ).cause,
            .pinnedIdentityMismatch
        )
        XCTAssertEqual(
            RemoteConnectionFailure.transport(
                URLError(.badServerResponse),
                host: "192.168.1.42",
                trustVerdict: .rejectedFingerprintMismatch
            ).cause,
            .pinnedIdentityMismatch
        )
    }

    func testAnAcceptedOrUnpinnedVerdictLeavesTheOrdinaryClassificationAlone() {
        let denial = URLError(
            .cannotConnectToHost,
            userInfo: [NSUnderlyingErrorKey: NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EHOSTUNREACH)
            )]
        )

        XCTAssertEqual(
            RemoteConnectionFailure.transport(denial, host: "192.168.1.42", trustVerdict: .accepted).cause,
            .localNetworkDenied
        )
        XCTAssertEqual(
            RemoteConnectionFailure.transport(
                URLError(.badServerResponse),
                host: "abc.trycloudflare.com",
                trustVerdict: .notPinned
            ).cause,
            .addressChanged
        )
    }

    func testTheVerdictReachesAReportAsATokenAndNeverAsAFingerprint() throws {
        let host = ownerHost(endpoints: [
            endpoint(kind: RemoteHostEndpointKind.lan, "https://192.168.1.42:8760/", pinned: true),
            endpoint(kind: RemoteHostEndpointKind.tailscale, "https://mac.tail1234.ts.net:8443/", pinned: false),
        ])
        XCTAssertNil(
            RemoteHostTrust.verdictToken(for: host) { _ in nil },
            "no challenge has been answered, so there is nothing to report"
        )

        let verdicts: [String: RemoteTrustVerdict] = [
            "192.168.1.42": .rejectedFingerprintMismatch,
            "mac.tail1234.ts.net": .notPinned,
        ]
        let token = try XCTUnwrap(RemoteHostTrust.verdictToken(for: host) { verdicts[$0] })

        XCTAssertEqual(token, "trust.rejectedFingerprintMismatch")
        XCTAssertFalse(token.contains(fingerprint.hex))
        XCTAssertFalse(token.contains(fingerprint.pairingCode))
        XCTAssertTrue(RemoteHostTrust.rejectedIdentity(for: host) { verdicts[$0] })
        XCTAssertEqual(token, MobileDiagnostics.machineToken(token), "the journal takes it unchanged")

        XCTAssertEqual(
            RemoteHostTrust.verdictToken(for: host) { _ in .accepted },
            "trust.accepted"
        )
    }

    // MARK: - This Mac needs a newer app

    func testAnUpgradeRefusalNamesTheSideThatIsBehindAndOffersTheDownloadPage() {
        let host = RemoteConnectionFailure.transport(
            RemoteClientError.upgradeRequired(.host),
            host: "192.168.1.42",
            trustVerdict: nil
        )
        XCTAssertEqual(host.cause, .upgradeRequired)
        XCTAssertEqual(
            host.message,
            "This Mac needs a newer version of Threading. Update Threading on the Mac and try again."
        )
        XCTAssertEqual(host.recovery, .openUpdatePage(RemoteUpdateDefaults.downloadPage))

        let client = RemoteConnectionFailure.transport(
            RemoteClientError.upgradeRequired(.client),
            host: "192.168.1.42",
            trustVerdict: nil
        )
        XCTAssertEqual(client.cause, .upgradeRequired)
        XCTAssertEqual(
            client.message,
            "This version of Threading can’t connect to this Mac. Update Threading and try again."
        )
    }

    // MARK: - Fixtures

    private func ownerHost(endpoints: [RemoteHostEndpointDTO]) -> PairedRemoteHost {
        let link = RemoteConnectionLink(
            baseURL: URL(string: "https://192.168.1.42:8760/")!,
            token: Self.bearer
        )!
        return PairedRemoteHost(
            id: "mac",
            hostID: "mac",
            shareID: "my-devices",
            scope: "all",
            name: "Mac",
            link: link,
            lastConnectedAt: Date(),
            endpoints: endpoints,
            connectionPolicy: .privateOnly
        )
    }

    private func endpoint(kind: String, _ url: String, pinned: Bool) -> RemoteHostEndpointDTO {
        RemoteHostEndpointDTO(
            kind: kind,
            baseURL: URL(string: url)!,
            isStable: true,
            identity: pinned ? RemoteHostEndpointIdentity.pinned : nil
        )
    }

    private func identity(
        current: RemoteHostFingerprint,
        next: RemoteHostFingerprint? = nil
    ) -> RemoteHostDTO {
        RemoteHostDTO(
            id: "mac",
            name: "Mac",
            endpoints: nil,
            connectionPolicy: .privateOnly,
            pinnedFingerprint: current.hex,
            nextPinnedFingerprint: next?.hex
        )
    }
}
