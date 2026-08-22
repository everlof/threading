import XCTest
@testable import ThreadingRemoteKit

final class RemoteInvitationLinkTests: XCTestCase {
    private let fingerprint = String(repeating: "A", count: 26)

    private func makeLink(
        _ origin: String = "https://192.168.1.181:8760",
        token: String = "bearer-token",
        pinned: Bool = true
    ) -> RemoteConnectionLink {
        guard let url = URL(string: origin),
              let link = RemoteConnectionLink(
                  baseURL: url,
                  token: token,
                  pinnedFingerprintCode: pinned ? fingerprint : nil
              ) else {
            preconditionFailure("fixture origin must parse")
        }
        return link
    }

    // MARK: - One parser

    func testJoinPayloadRoundTripsToTheSameLinkAsTheHTTPSForm() throws {
        let link = makeLink()

        let fromWeb = RemoteInvitation(payload: link.shareURL.absoluteString)
        let fromApp = RemoteInvitation(payload: link.appOpenPayload)

        guard case .connection(let web)? = fromWeb, case .connection(let app)? = fromApp else {
            return XCTFail("both forms must resolve to a connection invitation")
        }
        XCTAssertEqual(web, app)
        XCTAssertEqual(app, link)
        XCTAssertEqual(app.pinnedFingerprintCode, fingerprint)
        XCTAssertEqual(app.token, "bearer-token")
    }

    func testJoinPayloadCarriesTheFragmentAndNotTheBearerInTheClear() {
        let link = makeLink()
        let payload = link.appOpenPayload

        XCTAssertTrue(payload.hasPrefix("threading://join#"))
        XCTAssertFalse(payload.contains("bearer-token"))
        XCTAssertFalse(payload.contains("192.168.1.181"))
    }

    func testUnpinnedInvitationAlsoRoundTrips() throws {
        let link = makeLink(pinned: false)

        guard case .connection(let parsed)? = RemoteInvitation(payload: link.appOpenPayload) else {
            return XCTFail("an unpinned invitation still routes to the app")
        }
        XCTAssertEqual(parsed, link)
        XCTAssertNil(parsed.pinnedFingerprintCode)
    }

    func testHostedPairingPayloadStillResolvesThroughTheSameParser() throws {
        let hosted = try XCTUnwrap(HostedPairingLink(
            serviceURL: try XCTUnwrap(URL(string: "https://rendezvous.example")),
            hostID: "host-1",
            deviceID: "device-1",
            rendezvousCredential: "credential",
            bootstrapToken: "bootstrap",
            // Whole seconds: the payload carries the instant as a JSON number, and a fractional
            // date comes back a few microseconds away from the one that went in.
            expiresAt: Date(
                timeIntervalSince1970: Date().addingTimeInterval(600).timeIntervalSince1970
                    .rounded(.down)
            )
        ))

        guard case .hostedPairing(let parsed)? = RemoteInvitation(
            payload: hosted.scannablePayload
        ) else {
            return XCTFail("the QR pairing payload must still parse")
        }
        XCTAssertEqual(parsed, hosted)
    }

    func testRefusesPayloadsThatAreNotInvitations() {
        XCTAssertNil(RemoteInvitation(payload: ""))
        XCTAssertNil(RemoteInvitation(payload: "   "))
        XCTAssertNil(RemoteInvitation(payload: "https://example.com"))
        XCTAssertNil(RemoteInvitation(payload: "threading://join#not-base64url!!"))
        XCTAssertNil(RemoteInvitation(payload: "threading://join"))
        XCTAssertNil(RemoteInvitation(payload: "threading://elsewhere#abc"))
        XCTAssertNil(RemoteInvitation(payload: "threading://join?x=1#abc"))
    }

    func testRefusesAJoinPayloadWrappingSomethingOtherThanAnInvitation() {
        let wrapped = Data("https://example.com/without-a-fragment".utf8)
            .base64URLEncodedString()
        XCTAssertNil(RemoteInvitation(payload: "threading://join#\(wrapped)"))
    }

    func testRefusesAJoinPayloadLargerThanTheCeiling() {
        let oversized = String(repeating: "A", count: RemoteInvitation.maximumEncodedBytes + 1)
        XCTAssertNil(RemoteInvitation(payload: "threading://join#\(oversized)"))
    }

    func testAppSchemeIsRecognisedInEitherCase() {
        XCTAssertTrue(RemoteInvitation.isAppScheme("threading://join#abc"))
        XCTAssertTrue(RemoteInvitation.isAppScheme("THREADING://PAIR#abc"))
        XCTAssertFalse(RemoteInvitation.isAppScheme("https://192.168.1.181:8760/#abc"))
    }

    // MARK: - One composition

    func testSharedTextCarriesTheSentenceAndBothForms() {
        let link = makeLink()
        let guidance = "Öppna i Threading-appen."

        let text = RemoteInvitationShare.text(for: link, guidance: guidance)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], guidance)
        XCTAssertEqual(lines[1], link.appOpenPayload)
        XCTAssertEqual(lines[2], link.shareURL.absoluteString)
    }

    func testComposingFromAMintedShareURLMatchesComposingFromTheLink() {
        let link = makeLink()
        let guidance = "Open in the Threading app."

        XCTAssertEqual(
            RemoteInvitationShare.text(shareURL: link.shareURL, guidance: guidance),
            RemoteInvitationShare.text(for: link, guidance: guidance)
        )
    }

    func testAShareURLThatCannotBeReadBackIsStillHandedOver() {
        let url = URL(string: "https://example.com/no-fragment")!
        XCTAssertEqual(
            RemoteInvitationShare.text(shareURL: url, guidance: "ignored"),
            url.absoluteString
        )
    }

    func testSharedTextParsesBackIntoTheSameInvitation() throws {
        let link = makeLink()
        let text = RemoteInvitationShare.text(for: link, guidance: "Open in the Threading app.")

        let appLine = try XCTUnwrap(
            text.split(separator: "\n").first { $0.hasPrefix("threading://") }
        )
        guard case .connection(let parsed)? = RemoteInvitation(payload: String(appLine)) else {
            return XCTFail("the app line in a shared message must parse")
        }
        XCTAssertEqual(parsed, link)
    }
}
