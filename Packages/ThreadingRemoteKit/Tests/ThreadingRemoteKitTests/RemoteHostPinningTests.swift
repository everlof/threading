import CryptoKit
import Foundation
import XCTest
@testable import ThreadingRemoteKit

/// The half of the pinned-identity contract both products share: the codec that turns a
/// certificate into something a camera can read, the two forms of the pairing payload, and the
/// endpoint policy that decides which of a Mac's addresses a phone is allowed to try.
final class RemoteHostPinningTests: XCTestCase {

    /// QR's alphanumeric mode: 5.5 bits a character against byte mode's 8, and this is the whole
    /// charset. Note `.` is in it, which is what makes the fragment separator free.
    private static let qrAlphanumeric = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")

    private static let certificate = Data("a certificate that is not really a certificate".utf8)

    // MARK: - Base32

    func testBase32MatchesRFC4648AndRoundTrips() {
        // RFC 4648 §10, minus the padding this codec deliberately does not write.
        let vectors: [(String, String)] = [
            ("f", "MY"),
            ("fo", "MZXQ"),
            ("foo", "MZXW6"),
            ("foob", "MZXW6YQ"),
            ("fooba", "MZXW6YTB"),
            ("foobar", "MZXW6YTBOI"),
        ]
        for (plain, encoded) in vectors {
            XCTAssertEqual(RemoteBase32.encode(Data(plain.utf8)), encoded)
            XCTAssertEqual(RemoteBase32.decode(encoded), Data(plain.utf8))
        }

        for length in 1...40 {
            let bytes = Data((0..<length).map { _ in UInt8.random(in: .min ... .max) })
            XCTAssertEqual(RemoteBase32.decode(RemoteBase32.encode(bytes)), bytes)
        }
    }

    func testBase32DecodingRefusesEverySpellingThatIsNotTheCanonicalOne() {
        XCTAssertNil(RemoteBase32.decode(""), "empty is not a value")
        XCTAssertNil(RemoteBase32.decode("mzxw6ytboi"), "lower case is a second spelling")
        XCTAssertNil(RemoteBase32.decode("MZXW6YTBOI=="), "padding is not written and not read")
        XCTAssertNil(RemoteBase32.decode("MZXW6YTB01"), "0 and 1 are outside the alphabet")
        XCTAssertNil(RemoteBase32.decode("MZXW6YTB I"), "a space is not a separator")
        XCTAssertNil(RemoteBase32.decode("A"), "one character cannot be a whole byte")
        XCTAssertNil(RemoteBase32.decode("MZX"), "three cannot either")
        XCTAssertNil(RemoteBase32.decode("MZXW6Y"), "nor six")
        XCTAssertNil(
            RemoteBase32.decode("MZXW6YTBOJ"),
            "trailing bits are zero, so the same bytes must not have two encodings"
        )
    }

    // MARK: - Fingerprint

    func testAFingerprintIsTheSHA256AndItsTwoSpellingsAgree() throws {
        let fingerprint = RemoteHostFingerprint(certificateDER: Self.certificate)
        let digest = Data(SHA256.hash(data: Self.certificate))

        XCTAssertEqual(fingerprint.digest, digest)
        XCTAssertEqual(fingerprint.hex.count, 64)
        XCTAssertEqual(fingerprint.hex, digest.map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(RemoteHostFingerprint(hex: fingerprint.hex), fingerprint)
        XCTAssertEqual(
            RemoteHostFingerprint(hex: fingerprint.hex.uppercased()),
            fingerprint,
            "hex is case-insensitive on the way in, and lower case on the way out"
        )

        XCTAssertEqual(
            fingerprint.pairingCode.count,
            RemoteHostPinningDefaults.pairingCodeCharacterCount
        )
        XCTAssertEqual(
            RemoteBase32.decode(fingerprint.pairingCode),
            digest.prefix(RemoteHostPinningDefaults.pairingCodeByteCount),
            "the code is the first 128 bits of the same digest, not a second value"
        )
        XCTAssertTrue(
            fingerprint.pairingCode.allSatisfy { Self.qrAlphanumeric.contains($0) },
            "a pairing code that leaves alphanumeric mode makes the symbol denser for nothing"
        )
    }

    func testFingerprintRefusesAnythingThatIsNotOne() {
        XCTAssertNil(RemoteHostFingerprint(digest: Data(repeating: 0, count: 31)))
        XCTAssertNil(RemoteHostFingerprint(digest: Data()))
        XCTAssertNil(RemoteHostFingerprint(hex: "abcd"))
        XCTAssertNil(RemoteHostFingerprint(hex: String(repeating: "z", count: 64)))
    }

    // MARK: - Pin

    func testAScannedPinAndAFullFingerprintCheckTheSameCertificate() throws {
        let fingerprint = RemoteHostFingerprint(certificateDER: Self.certificate)
        let scanned = try XCTUnwrap(RemoteHostPin(pairingCode: fingerprint.pairingCode))
        let learned = try XCTUnwrap(RemoteHostPin(hex: fingerprint.hex))

        XCTAssertEqual(scanned.bytes.count, RemoteHostPinningDefaults.pairingCodeByteCount)
        XCTAssertEqual(learned.bytes.count, RemoteHostPinningDefaults.digestByteCount)
        XCTAssertTrue(scanned.matches(certificateDER: Self.certificate))
        XCTAssertTrue(learned.matches(certificateDER: Self.certificate))

        let other = Data("a different certificate".utf8)
        XCTAssertFalse(scanned.matches(certificateDER: other))
        XCTAssertFalse(learned.matches(certificateDER: other))
    }

    func testAPinSetAcceptsTheAnnouncedSuccessorAndNothingElse() throws {
        let current = RemoteHostFingerprint(certificateDER: Self.certificate)
        let successorDER = Data("the successor certificate".utf8)
        let successor = RemoteHostFingerprint(certificateDER: successorDER)
        let strangerDER = Data("somebody else entirely".utf8)

        let onlyCurrent = RemoteHostPinSet(current: current.pin)
        XCTAssertTrue(onlyCurrent.matches(certificateDER: Self.certificate))
        XCTAssertFalse(
            onlyCurrent.matches(certificateDER: successorDER),
            "a successor that was never announced is a stranger"
        )

        let rotating = RemoteHostPinSet(current: current.pin, next: successor.pin)
        XCTAssertTrue(rotating.matches(certificateDER: Self.certificate))
        XCTAssertTrue(
            rotating.matches(certificateDER: successorDER),
            "pinning the successor before it goes live is what makes rotation free of re-pairing"
        )
        XCTAssertFalse(rotating.matches(certificateDER: strangerDER))
    }

    func testPinRefusesACodeThatIsNotAPairingCode() {
        XCTAssertNil(RemoteHostPin(pairingCode: ""))
        XCTAssertNil(RemoteHostPin(pairingCode: "TOOSHORT"))
        XCTAssertNil(
            RemoteHostPin(pairingCode: String(repeating: "A", count: 32)),
            "a 32-character base32 value is 20 bytes, not the 16 a pairing code carries"
        )
        XCTAssertNil(RemoteHostPin(pairingCode: String(repeating: "a", count: 26)))
        XCTAssertNil(RemoteHostPin(bytes: Data(repeating: 0, count: 20)))
    }

    // MARK: - Host DTO

    func testAHostAdvertisesItsFingerprintsAndAnOlderOneStillDecodes() throws {
        let current = RemoteHostFingerprint(certificateDER: Self.certificate)
        let successor = RemoteHostFingerprint(certificateDER: Data("next".utf8))
        let host = RemoteHostDTO(
            id: "mac-1",
            name: "Studio Mac",
            endpoints: [],
            connectionPolicy: .privateOnly,
            pinnedFingerprint: current.hex,
            nextPinnedFingerprint: successor.hex
        )

        let encoded = try JSONEncoder().encode(host)
        XCTAssertEqual(try JSONDecoder().decode(RemoteHostDTO.self, from: encoded), host)

        let pins = try XCTUnwrap(host.pinSet)
        XCTAssertTrue(pins.matches(certificateDER: Self.certificate))
        XCTAssertTrue(pins.matches(certificateDER: Data("next".utf8)))

        let older = try JSONDecoder().decode(
            RemoteHostDTO.self,
            from: Data(#"{"id":"mac-1","name":"Studio Mac","platform":"macOS"}"#.utf8)
        )
        XCTAssertNil(older.pinnedFingerprint)
        XCTAssertNil(older.nextPinnedFingerprint)
        XCTAssertNil(older.pinSet, "a host with no fingerprint keeps stock trust evaluation")

        let unpinned = RemoteHostDTO(id: "mac-1", name: "Studio Mac")
        let unpinnedJSON = try XCTUnwrap(String(data: try JSONEncoder().encode(unpinned), encoding: .utf8))
        XCTAssertFalse(
            unpinnedJSON.contains("pinnedFingerprint"),
            "an absent fingerprint is absent on the wire, not a null an old client has to skip"
        )
    }

    // MARK: - Endpoints

    func testAnEndpointSaysWhetherItPresentsThisMacsOwnIdentity() throws {
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

        XCTAssertTrue(lan.expectsPinnedIdentity)
        XCTAssertFalse(
            serve.expectsPinnedIdentity,
            "Serve holds a real certificate for that name; pinning it would break on renewal"
        )

        let encoded = try JSONEncoder().encode([lan, serve])
        XCTAssertEqual(try JSONDecoder().decode([RemoteHostEndpointDTO].self, from: encoded), [lan, serve])

        let older = try JSONDecoder().decode(
            RemoteHostEndpointDTO.self,
            from: Data(#"{"kind":"tailscale","baseURL":"https://mac.example.ts.net:8443/","isStable":true}"#.utf8)
        )
        XCTAssertNil(older.identity)
        XCTAssertFalse(older.expectsPinnedIdentity)
    }

    func testPrivateOnlyAdmitsEveryPrivateNetworkKindAndStillRefusesCleartext() throws {
        let lan = RemoteHostEndpointDTO(
            kind: RemoteHostEndpointKind.lan,
            baseURL: try XCTUnwrap(URL(string: "https://192.168.1.42:8760/")),
            isStable: true,
            identity: RemoteHostEndpointIdentity.pinned
        )
        let vpn = RemoteHostEndpointDTO(
            kind: RemoteHostEndpointKind.vpn,
            baseURL: try XCTUnwrap(URL(string: "https://10.8.0.2:8760/")),
            isStable: true,
            identity: RemoteHostEndpointIdentity.pinned
        )
        let tailnet = RemoteHostEndpointDTO(
            kind: RemoteHostEndpointKind.tailscale,
            baseURL: try XCTUnwrap(URL(string: "https://mac.example.ts.net:8443/")),
            isStable: true
        )
        let relay = RemoteHostEndpointDTO(
            kind: RemoteHostEndpointKind.relay,
            baseURL: try XCTUnwrap(URL(string: "https://quick.trycloudflare.com/")),
            isStable: false
        )
        let cleartextLAN = RemoteHostEndpointDTO(
            kind: RemoteHostEndpointKind.lan,
            baseURL: try XCTUnwrap(URL(string: "http://192.168.1.42:8760/")),
            isStable: true
        )
        let loopback = RemoteHostEndpointDTO(
            kind: RemoteHostEndpointKind.loopback,
            baseURL: try XCTUnwrap(URL(string: "https://127.0.0.1:8760/")),
            isStable: true
        )

        XCTAssertEqual(
            Set(RemoteHostEndpointSelection.ordered(
                [relay, cleartextLAN, lan, tailnet, vpn, loopback],
                policy: .privateOnly
            )),
            [lan, vpn, tailnet],
            "a door on a network the user is already on is private, whichever network that is"
        )
        XCTAssertEqual(
            RemoteHostEndpointSelection.ordered([cleartextLAN], policy: .privateOnly),
            [],
            "a cleartext candidate is dropped whatever its kind"
        )

        let preferred = RemoteHostEndpointSelection.ordered(
            [relay, lan, tailnet],
            policy: .preferPrivate
        )
        XCTAssertEqual(preferred.last, relay, "a relay is the last thing to try, never the first")
        XCTAssertEqual(Set(preferred.dropLast()), [lan, tailnet])
    }

    // MARK: - Pairing payload

    func testAPairingPayloadCarriesTheFingerprintAndTheOldFormStillParses() throws {
        let fingerprint = RemoteHostFingerprint(certificateDER: Self.certificate)
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: "https://192.168.1.42:8760/")),
            token: "MFRGGZDFMZTWQ2LK",
            pinnedFingerprintCode: fingerprint.pairingCode
        ))

        XCTAssertEqual(link.token, "MFRGGZDFMZTWQ2LK")
        XCTAssertEqual(link.pinnedFingerprintCode, fingerprint.pairingCode)
        XCTAssertEqual(
            link.shareURL.absoluteString,
            "https://192.168.1.42:8760/#MFRGGZDFMZTWQ2LK.\(fingerprint.pairingCode)"
        )

        let payload = link.scannablePayload
        XCTAssertEqual(
            payload,
            "HTTPS://192.168.1.42:8760/#MFRGGZDFMZTWQ2LK.\(fingerprint.pairingCode)"
        )
        let afterHash = try XCTUnwrap(payload.split(separator: "#", maxSplits: 1).last)
        XCTAssertTrue(
            afterHash.allSatisfy { Self.qrAlphanumeric.contains($0) },
            "the fragment is the part this trade was made for; a byte-mode segment here undoes it"
        )
        XCTAssertEqual(RemoteConnectionLink(string: payload), link, "and it reads back identically")

        let old = try XCTUnwrap(RemoteConnectionLink(string: "HTTPS://EXAMPLE.COM/#PLAINTOKEN"))
        XCTAssertEqual(old.token, "PLAINTOKEN")
        XCTAssertNil(old.pinnedFingerprintCode, "a code from before this existed is not pinned")
        XCTAssertEqual(old.shareURL.absoluteString, "https://example.com/#PLAINTOKEN")
    }

    func testAnIPv6LanOriginIsAUsableLink() throws {
        let fingerprint = RemoteHostFingerprint(certificateDER: Self.certificate)
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: "https://[fd00::4]:8760/")),
            token: "MFRGGZDFMZTWQ2LK",
            pinnedFingerprintCode: fingerprint.pairingCode
        ))

        XCTAssertEqual(link.baseURL.absoluteString, "https://[fd00::4]:8760/")
        XCTAssertEqual(link.meURL.absoluteString, "https://[fd00::4]:8760/api/me")
        XCTAssertEqual(
            link.eventsWebSocketURL?.absoluteString,
            "wss://[fd00::4]:8760/ws/events"
        )
        XCTAssertEqual(
            RemoteConnectionLink(string: link.scannablePayload),
            link,
            "the brackets survive the upper-casing that makes the QR payload cheap"
        )

        let endpoint = RemoteHostEndpointDTO(
            kind: RemoteHostEndpointKind.lan,
            baseURL: try XCTUnwrap(URL(string: "https://[fd00::4]:8760/")),
            isStable: true,
            identity: RemoteHostEndpointIdentity.pinned
        )
        XCTAssertEqual(
            RemoteHostEndpointSelection.ordered([endpoint], policy: .privateOnly),
            [endpoint],
            "a dual-stack network advertises half its LAN addresses as IPv6, and selection "
                + "validates candidates by building a link from them"
        )
    }

    func testAPairingPayloadWithABrokenFingerprintIsRefusedRatherThanUnpinned() throws {
        let origin = try XCTUnwrap(URL(string: "https://192.168.1.42:8760/"))
        XCTAssertNil(
            RemoteConnectionLink(baseURL: origin, token: "TOKEN", pinnedFingerprintCode: "SHORT"),
            "pairing without the pin would silently trust whatever answered"
        )
        XCTAssertNil(RemoteConnectionLink(string: "https://192.168.1.42:8760/#TOKEN.SHORT"))
        XCTAssertNil(RemoteConnectionLink(string: "https://192.168.1.42:8760/#TOKEN.A.B"))
        XCTAssertNil(RemoteConnectionLink(string: "https://192.168.1.42:8760/#.\(String(repeating: "A", count: 26))"))
    }

    func testAPinnedLinkSurvivesBeingPersistedAndAnOlderRecordStillDecodes() throws {
        let fingerprint = RemoteHostFingerprint(certificateDER: Self.certificate)
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: "https://192.168.1.42:8760/")),
            token: "MFRGGZDFMZTWQ2LK",
            pinnedFingerprintCode: fingerprint.pairingCode
        ))

        let encoded = try JSONEncoder().encode(link)
        XCTAssertEqual(try JSONDecoder().decode(RemoteConnectionLink.self, from: encoded), link)

        let older = try JSONDecoder().decode(
            RemoteConnectionLink.self,
            from: Data(#"{"baseURL":"https://example.com/","token":"bearer"}"#.utf8)
        )
        XCTAssertNil(older.pinnedFingerprintCode)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RemoteConnectionLink.self,
                from: Data(#"{"baseURL":"https://example.com/","token":"bearer","pinnedFingerprintCode":"nope"}"#.utf8)
            ),
            "decoding re-enters the failable initializer, so a broken pin cannot be persisted in"
        )
    }
}

/// The sticky port contract, which both ends walk in the same order.
final class RemoteListenerPortsTests: XCTestCase {

    func testTheRememberedPortIsTriedFirstAndTheRangeFollowsItExactlyOnce() {
        XCTAssertEqual(
            RemoteListenerPorts.candidates(preferred: 8760),
            [8760, 8761, 8762, 8763, 8764, 8765, 8766, 8767, 8768, 8769]
        )
        XCTAssertEqual(
            RemoteListenerPorts.candidates(preferred: 8765),
            [8765, 8760, 8761, 8762, 8763, 8764, 8766, 8767, 8768, 8769]
        )
    }

    /// A port the Mac was configured onto is outside the range and still comes first: it is what
    /// the Mac last reported, and the range is where a collision moved it, not a replacement.
    func testAPortOutsideTheRangeLeadsAndTheRangeStillFollows() {
        let candidates = RemoteListenerPorts.candidates(preferred: 9100)
        XCTAssertEqual(candidates.first, 9100)
        XCTAssertEqual(candidates.count, 11)
        XCTAssertEqual(Array(candidates.dropFirst()), Array(RemoteListenerPorts.fallbackRange))
    }

    func testTheWalkIsBoundedByTheRange() {
        XCTAssertEqual(RemoteListenerPorts.fallbackRange, 8760...8769)
        XCTAssertEqual(RemoteListenerPorts.defaultPort, RemoteListenerPorts.fallbackRange.lowerBound)
        XCTAssertEqual(RemoteListenerPorts.candidates(preferred: 8760).count, 10)
    }
}
