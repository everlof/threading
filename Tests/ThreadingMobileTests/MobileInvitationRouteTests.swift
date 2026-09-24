import Foundation
import ThreadingPeerTransport
import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

/// A shared chat has to open in the app that holds the pin.
///
/// The invitation points at a private door on somebody's LAN or tailnet and carries this Mac's
/// certificate fingerprint in its fragment. Sent as the bare `https` URL it opened in Safari,
/// which can only offer the certificate interstitial, because the pin lives in this app. These
/// assertions hold the three things that make the app route work: the scheme is registered, the
/// two payload forms mean the same thing, and a delivered URL reaches the accept path.
@MainActor
final class MobileInvitationRouteTests: XCTestCase {
    /// A 26-character base32 pairing code. `A` is zero in that alphabet, so the two bits left
    /// over from 130 are zero and the code decodes to the 16 bytes `RemoteHostPin` requires.
    private let fingerprint = String(repeating: "A", count: 26)

    func testUsedHostedInvitationShowsAnInvitationMessage() {
        for error: Error in [
            PeerRendezvousError.unauthorized,
            PeerRendezvousError.invalidCredential,
            PeerControlPlaneError.invalidCredential,
        ] {
            XCTAssertEqual(
                MobileInvitationFailureMessage.text(for: error, hostedInvitation: true),
                MobileL10n.string("This invitation is expired or already used.")
            )
        }
        XCTAssertEqual(
            MobileInvitationFailureMessage.text(
                for: PeerRendezvousError.hostOffline,
                hostedInvitation: true
            ),
            PeerRendezvousError.hostOffline.localizedDescription
        )
    }

    private func makeLink(
        origin: String = "https://192.168.1.181:8760",
        token: String = "invitation-bearer"
    ) throws -> RemoteConnectionLink {
        try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: origin)),
            token: token,
            pinnedFingerprintCode: fingerprint
        ))
    }

    // MARK: - The scheme the invitation is addressed to

    func testTheBuiltAppRegistersTheThreadingScheme() throws {
        let types = try XCTUnwrap(
            Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]],
            "without a registered scheme a tapped invitation opens nothing"
        )
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }

        XCTAssertTrue(
            schemes.contains("threading"),
            "the QR payloads already say THREADING://PAIR; a tap has to reach the same app"
        )
    }

    // MARK: - One parser, two forms

    func testTheAppFormAndTheWebFormResolveToTheSameInvitation() throws {
        let link = try makeLink()

        let fromWeb = try XCTUnwrap(MobileInvitationRoute(payload: link.shareURL.absoluteString))
        let fromApp = try XCTUnwrap(MobileInvitationRoute(payload: link.appOpenPayload))

        guard case .connection(let web) = fromWeb, case .connection(let app) = fromApp else {
            return XCTFail("both forms name a private door")
        }
        XCTAssertEqual(web, app, "the wrapper carries the same URL, fragment and all")
        XCTAssertEqual(app.pinnedFingerprintCode, fingerprint)
        XCTAssertEqual(app.token, "invitation-bearer")
    }

    func testTheQRPairingPayloadStillReachesTheSameRoute() throws {
        let hosted = try XCTUnwrap(HostedPairingLink(
            serviceURL: try XCTUnwrap(URL(string: "https://rendezvous.example")),
            hostID: "host-1",
            deviceID: "device-1",
            rendezvousCredential: "credential",
            bootstrapToken: "bootstrap",
            expiresAt: Date().addingTimeInterval(600)
        ))

        guard case .hostedPairing? = MobileInvitationRoute(payload: hosted.scannablePayload) else {
            return XCTFail("the scanner and a tapped link share one parser")
        }
    }

    /// The application's own rule, not the wire's: pairing over plain HTTP would hand the bearer
    /// to the network the invitation crossed.
    func testAPlainHTTPDoorIsRefused() throws {
        let insecure = try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: "http://192.168.1.181:8760")),
            token: "invitation-bearer"
        ))

        XCTAssertNil(MobileInvitationRoute(payload: insecure.shareURL.absoluteString))
        XCTAssertNil(MobileInvitationRoute(payload: insecure.appOpenPayload))
    }

    func testSomethingThatIsNotAnInvitationIsNotRouted() throws {
        XCTAssertNil(MobileInvitationRoute(payload: "https://example.com"))
        XCTAssertNil(MobileInvitationRoute(payload: "threading://join#not-base64url!!"))
        XCTAssertNil(MobileInvitationRoute(url: try XCTUnwrap(URL(string: "mailto:a@b.c"))))
    }

    // MARK: - A delivered URL reaches the accept path

    func testADeliveredInvitationOpensThePairingScreenCarryingItsPayload() throws {
        let link = try makeLink()
        let model = RemoteAppModel()
        XCTAssertFalse(model.isPairing)

        let handled = model.open(try XCTUnwrap(URL(string: link.appOpenPayload)))

        XCTAssertTrue(handled, "the scene stops at the first URL that was ours")
        XCTAssertTrue(model.isPairing, "the pairing screen is where an invitation is accepted")
        XCTAssertEqual(
            model.pendingInvitation,
            link.appOpenPayload,
            "the payload waits for the screen rather than being accepted invisibly"
        )
    }

    func testAnInvitationIsHandedOverExactlyOnce() throws {
        let link = try makeLink()
        let model = RemoteAppModel()
        model.open(try XCTUnwrap(URL(string: link.appOpenPayload)))

        XCTAssertEqual(model.takePendingInvitation(), link.appOpenPayload)
        XCTAssertNil(model.takePendingInvitation(), "a consumed invitation is not paired twice")
        XCTAssertNil(model.pendingInvitation)
    }

    func testAURLThatIsNotOursIsLeftAlone() throws {
        let model = RemoteAppModel()

        XCTAssertFalse(model.open(try XCTUnwrap(URL(string: "https://example.com"))))
        XCTAssertFalse(model.isPairing)
        XCTAssertNil(model.pendingInvitation)
    }

    // MARK: - What the recipient is sent

    func testSharedHTTPSLinkOpensThePairingScreenAndPreservesThePin() throws {
        let link = try makeLink()
        let text = SharedSessionLinkCopy.sharedText(for: link.shareURL)
        XCTAssertFalse(text.contains("\n"))
        let url = try XCTUnwrap(URL(string: text))
        XCTAssertEqual(url.scheme, "https")
        guard case .connection(let parsed)? = MobileInvitationRoute(url: url) else {
            return XCTFail("the universal link must resolve to the pinned invitation")
        }
        XCTAssertEqual(parsed, link)
        let model = RemoteAppModel()
        XCTAssertTrue(model.open(url))
        XCTAssertTrue(model.isPairing)
        XCTAssertEqual(model.takePendingInvitation(), text)
        XCTAssertNil(model.takePendingInvitation())
    }

    func testHostedGuestUniversalLinkReachesHostedAcceptance() throws {
        let hosted = try XCTUnwrap(HostedPairingLink(serviceURL: RemoteInvitationWebLink.developmentOrigin,
            hostID: "mac", deviceID: "invite-1", rendezvousCredential: "transport",
            bootstrapToken: "chat-only", expiresAt: Date().addingTimeInterval(600)))
        let url = try XCTUnwrap(RemoteInvitationWebLink.url(appPayload: hosted.scannablePayload,
            origin: RemoteInvitationWebLink.developmentOrigin))
        guard case .hostedPairing(let route)? = MobileInvitationRoute(url: url) else {
            return XCTFail("guest invitations must negotiate Hosted Direct before redeeming")
        }
        XCTAssertEqual(route.bootstrapToken, "chat-only")
        XCTAssertEqual(route.deviceID, "invite-1")
        let model = RemoteAppModel()
        XCTAssertTrue(model.open(url))
        XCTAssertEqual(model.pendingInvitation, url.absoluteString)
    }

    func testGuestTransportIdentitySurvivesPersistenceAndIsSeparatePerMembership() throws {
        let guest = PairedRemoteHost(id: "mac:share:membership", hostID: "mac", shareID: "membership",
            scope: "session", name: "Mac", link: try makeLink(), lastConnectedAt: Date())
        let restored = try JSONDecoder().decode(PairedRemoteHost.self, from: JSONEncoder().encode(guest))
        XCTAssertFalse(restored.isOwnerDevice)
        XCTAssertEqual(restored.hostedDeviceID, "guest-membership")
        var other = restored
        other.shareID = "other"
        XCTAssertNotEqual(other.hostedDeviceID, restored.hostedDeviceID)
        var owner = restored
        owner.scope = "all"
        XCTAssertEqual(owner.hostedDeviceID, RemoteDeviceIdentity.current)
        XCTAssertNotEqual(owner.hostedDeviceID, restored.hostedDeviceID)
    }

    // MARK: - The words on the link-ready sheet

    /// The closing line used to be built by concatenating two literals, which is a `String`
    /// expression rather than a literal, so SwiftUI chose `Text(verbatim:)` and the sentence
    /// appeared in English inside a Swedish app while its translation sat in the catalog unused.
    func testTheSheetsSentencesAreTranslatedRatherThanEnglishSourceText() throws {
        let swedish = try XCTUnwrap(Bundle.main.path(forResource: "sv", ofType: "lproj").map {
            Bundle(path: $0)
        } ?? nil)

        for key in [
            "The invite works once. After acceptance, access lasts until you stop sharing "
                + "and never extends to another chat.",
            "Open in the Threading app. Works for someone on your Wi-Fi or tailnet.",
            "Can view “%@”",
            "Can collaborate in “%@”",
            "Can collaborate in “%@” and approve requests",
        ] {
            let translated = swedish.localizedString(
                forKey: key,
                value: key,
                table: "Localizable"
            )
            XCTAssertNotEqual(translated, key, "missing Swedish for: \(key)")
        }
    }

    func testTheGrantLineNamesTheChatItGrants() {
        XCTAssertTrue(
            SharedSessionLinkCopy.grant(
                chatTitle: "LANDING",
                capability: .view,
                canApprovePermissions: false
            ).contains("LANDING")
        )
        XCTAssertNotEqual(
            SharedSessionLinkCopy.grant(
                chatTitle: "LANDING",
                capability: .interact,
                canApprovePermissions: true
            ),
            SharedSessionLinkCopy.grant(
                chatTitle: "LANDING",
                capability: .interact,
                canApprovePermissions: false
            ),
            "approval is a separate right and the sheet has to say so"
        )
    }
}
