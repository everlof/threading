import Foundation
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

    func testTheSharedTextCarriesTheSentenceAndBothForms() throws {
        let link = try makeLink()

        let text = SharedSessionLinkCopy.sharedText(for: link.shareURL)
        let lines = text.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], SharedSessionLinkCopy.guidance)
        XCTAssertEqual(lines[1], link.appOpenPayload)
        XCTAssertEqual(
            lines[2],
            link.shareURL.absoluteString,
            "the https line stays as the carrier for clients that will not linkify a scheme"
        )
        XCTAssertTrue(
            SharedSessionLinkCopy.guidance.contains("Threading"),
            "the sentence has to say which app opens it"
        )
    }

    func testTheAppLineInASharedMessageParsesBackIntoTheSameInvitation() throws {
        let link = try makeLink()
        let text = SharedSessionLinkCopy.sharedText(for: link.shareURL)

        let appLine = try XCTUnwrap(
            text.split(separator: "\n").map(String.init).first { $0.hasPrefix("threading://") }
        )
        guard case .connection(let parsed)? = MobileInvitationRoute(payload: appLine) else {
            return XCTFail("what we send has to be what we can read")
        }
        XCTAssertEqual(parsed, link)
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
            "Choose what this person can do in this chat.",
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
                capability: RemoteCapability.view.rawValue,
                canApprovePermissions: false
            ).contains("LANDING")
        )
        XCTAssertNotEqual(
            SharedSessionLinkCopy.grant(
                chatTitle: "LANDING",
                capability: RemoteCapability.interact.rawValue,
                canApprovePermissions: true
            ),
            SharedSessionLinkCopy.grant(
                chatTitle: "LANDING",
                capability: RemoteCapability.interact.rawValue,
                canApprovePermissions: false
            ),
            "approval is a separate right and the sheet has to say so"
        )
    }
}
