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

    func testSharedTextIsOnePublicHTTPSLink() throws {
        let link = makeLink()
        let text = RemoteInvitationShare.text(for: link, guidance: "ignored")
        let url = try XCTUnwrap(URL(string: text))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "remote.threading.codes")
        XCTAssertEqual(url.path, "/join")
        XCTAssertNil(url.query)
        XCTAssertFalse(text.contains("\n"))
        XCTAssertEqual(RemoteInvitation(payload: text), .connection(link))
    }

    func testHostedGuestInvitationRoundTripsOnBothAssociatedDomains() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for origin in [RemoteInvitationWebLink.productionOrigin, RemoteInvitationWebLink.developmentOrigin] {
            let hosted = try XCTUnwrap(HostedPairingLink(serviceURL: origin, hostID: "host",
                deviceID: "invite-123", rendezvousCredential: "transport-secret",
                bootstrapToken: "one-chat-secret", expiresAt: now.addingTimeInterval(3600), now: now))
            let url = try XCTUnwrap(RemoteInvitationWebLink.url(appPayload: hosted.scannablePayload, origin: origin))
            XCTAssertEqual(RemoteInvitation(payload: url.absoluteString, now: now), .hostedPairing(hosted))
            XCTAssertNil(RemoteInvitation(payload: url.absoluteString, now: now.addingTimeInterval(3601)))
            XCTAssertEqual(RemoteInvitationShare.text(shareURL: url, guidance: "ignored"), url.absoluteString)
        }
    }

    func testPublicWrapperRejectsUnknownDomainsCredentialsQueriesAndOversizedInput() throws {
        let url = try XCTUnwrap(RemoteInvitationWebLink.url(appPayload: makeLink().appOpenPayload))
        for bad in [
            url.absoluteString.replacingOccurrences(of: "remote.threading.codes", with: "evil.example"),
            url.absoluteString.replacingOccurrences(of: "https://", with: "https://user@"),
            url.absoluteString.replacingOccurrences(of: "/join#", with: "/join?token=bad#"),
            url.absoluteString.replacingOccurrences(of: "/join#", with: ":443/join#"),
            "https://remote.threading.codes/join#" + String(repeating: "A", count: 8192)
        ] { XCTAssertNil(RemoteInvitationWebLink.appPayload(from: bad)) }
        XCTAssertNil(RemoteInvitation(payload: "https://remote.threading.codes/join#broken"))
        XCTAssertNil(RemoteInvitationWebLink.url(appPayload: "javascript:alert(1)"))
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

        guard case .connection(let parsed)? = RemoteInvitation(payload: text) else {
            return XCTFail("the shared link must parse")
        }
        XCTAssertEqual(parsed, link)
    }
}
