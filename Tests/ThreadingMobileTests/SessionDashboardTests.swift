import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

final class SessionDashboardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    /// The age is one narrow unit, and never a signed quantity: `RelativeDateTimeFormatter`'s
    /// abbreviated Swedish wrote yesterday as `−1 d`, which is what a duration can never do.
    func testSwedishAgeIsOneNarrowUnitWithoutAMinusSign() {
        let age = MobileSessionAgeFormat.string(
            since: now.addingTimeInterval(-24 * 60 * 60),
            relativeTo: now,
            locale: Locale(identifier: "sv_SE")
        )

        // Swedish sets the unit off with a narrow no-break space; the digits and the unit are
        // the assertion, not which space stands between them.
        XCTAssertEqual(age.filter { !$0.isWhitespace }, "1d")
        XCTAssertFalse(age.contains("−"), age)
        XCTAssertFalse(age.contains("-"), age)
    }

    func testEnglishAgeIsOneNarrowUnitWithoutADirectionWord() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(
            MobileSessionAgeFormat.string(
                since: now.addingTimeInterval(-6 * 60), relativeTo: now, locale: english
            ),
            "6m"
        )
        XCTAssertEqual(
            MobileSessionAgeFormat.string(
                since: now.addingTimeInterval(-3 * 60 * 60), relativeTo: now, locale: english
            ),
            "3h"
        )
        XCTAssertEqual(
            MobileSessionAgeFormat.string(
                since: now.addingTimeInterval(-24 * 60 * 60), relativeTo: now, locale: english
            ),
            "1d"
        )
    }

    /// Past a week the age stops counting and names the day, in the reader's own calendar order.
    func testAWeekOldSessionShowsItsDate() {
        let age = MobileSessionAgeFormat.string(
            since: now.addingTimeInterval(-8 * 24 * 60 * 60),
            relativeTo: now,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertFalse(age.contains("d"), age)
        XCTAssertTrue(age.contains("Jan"), age)
    }

    func testFutureClockSkewDoesNotProduceANegativeAge() {
        XCTAssertEqual(
            MobileSessionAgeFormat.string(
                since: now.addingTimeInterval(60 * 60),
                relativeTo: now,
                locale: Locale(identifier: "sv_SE")
            ),
            MobileL10n.string("now")
        )
    }

    func testRootNavigationTitleNamesTheConnectedMac() {
        XCTAssertEqual(
            MobileDashboardChrome.title(
                projectName: nil,
                activeHostName: "David’s MacBook Pro"
            ),
            "David’s MacBook Pro"
        )
    }

    func testProjectNavigationTitleNamesTheProject() {
        XCTAssertEqual(
            MobileDashboardChrome.title(
                projectName: "AnotherTerminal",
                activeHostName: "David’s MacBook Pro"
            ),
            "AnotherTerminal"
        )
    }

    func testConnectedNavigationStatusIncludesTheActiveRoute() {
        XCTAssertEqual(
            MobileDashboardChrome.connectionStatus(
                phase: .online,
                connectionLabel: "Tailscale"
            ),
            MobileL10n.string("Connected · %@", "Tailscale")
        )
    }

    func testOfflineNavigationStatusDoesNotPutATransportErrorInTheTitleBar() {
        XCTAssertEqual(
            MobileDashboardChrome.connectionStatus(
                phase: .offline(.transport("The operation timed out after 60 seconds")),
                connectionLabel: "Relay"
            ),
            MobileL10n.string("Not connected")
        )
    }

    /// A route failure must replace the indeterminate loading card with an actionable state. The
    /// useful network facts are semantic route names; the address, port and raw timeout stay in
    /// diagnostics where they cannot turn the dashboard into a network inspector.
    func testOfflineRecoveryNamesRoutesAndIdentityWithoutAnAddressOrPort() throws {
        let host = try pairedHost()
        let presentation = MobileConnectionRecoveryPresentation.resolve(
            failure: .transport(
                URLError(.timedOut),
                host: "david-mac.tailnet.example"
            ),
            host: host
        )

        XCTAssertEqual(presentation.title, MobileL10n.string("Can’t reach this Mac"))
        XCTAssertEqual(presentation.primaryRecovery, .reconnect)
        XCTAssertTrue(presentation.offersPairAgain)
        XCTAssertEqual(presentation.lastConnection, MobileL10n.string("Tailscale"))
        XCTAssertEqual(
            Set(presentation.routesTried),
            Set([MobileL10n.string("Tailscale"), MobileL10n.string("This network")])
        )
        XCTAssertEqual(
            presentation.identityCode?.count,
            RemoteHostPinningDefaults.pairingCodeCharacterCount
        )
        let visibleNetworkText = ([presentation.lastConnection].compactMap { $0 }
            + presentation.routesTried).joined(separator: " ")
        XCTAssertFalse(visibleNetworkText.contains("8760"))
        XCTAssertFalse(visibleNetworkText.contains("192.168"))
        XCTAssertFalse(
            presentation.message.contains("timed out"),
            "Foundation's transport prose leaked into the recovery card"
        )
    }

    /// An identity refusal never becomes a one-tap trust override. The action opens the scanner,
    /// where the code is learned from the Mac's screen again, and the saved code remains visible
    /// for the comparison that should happen first.
    func testIdentityMismatchKeepsTheScanAsTheOnlyTrustRecovery() throws {
        let host = try pairedHost()
        let presentation = MobileConnectionRecoveryPresentation.resolve(
            failure: .pinnedIdentityMismatch(),
            host: host
        )

        XCTAssertEqual(
            presentation.title,
            MobileL10n.string("Check this Mac’s identity")
        )
        XCTAssertEqual(presentation.primaryRecovery, .pairAgain)
        XCTAssertFalse(presentation.offersPairAgain)
        XCTAssertEqual(presentation.identityCode, host.pinnedFingerprintCode)
    }

    private func pairedHost() throws -> PairedRemoteHost {
        let fingerprint = RemoteHostFingerprint(
            certificateDER: Data("dashboard recovery certificate".utf8)
        )
        let tailnet = try XCTUnwrap(URL(string: "https://david-mac.tailnet.example:8760/"))
        let local = try XCTUnwrap(URL(string: "https://192.168.1.42:8760/"))
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: tailnet,
            token: String(repeating: "a", count: 43),
            pinnedFingerprintCode: fingerprint.pairingCode
        ))
        return PairedRemoteHost(
            id: "mac-1",
            hostID: "mac-1",
            shareID: "my-devices",
            scope: "all",
            name: "David’s MacBook Pro",
            link: link,
            lastConnectedAt: Date(),
            endpoints: [
                RemoteHostEndpointDTO(kind: "tailscale", baseURL: tailnet, isStable: true),
                RemoteHostEndpointDTO(kind: "lan", baseURL: local, isStable: true),
            ],
            connectionPolicy: .privateOnly,
            activeEndpointKind: "tailscale",
            pinnedFingerprint: fingerprint.hex
        )
    }
}
