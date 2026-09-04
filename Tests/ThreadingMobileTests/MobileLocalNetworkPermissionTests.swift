import Foundation
import XCTest
@testable import ThreadingMobile

/// iOS prompts for Local Network access on the first unicast connection to a same-subnet private
/// address, not only on Bonjour. Without the usage description in the built app's `Info.plist`
/// there is no prompt to answer and the `lan` door is simply unreachable, with an ordinary
/// no-route error as the only symptom.
///
/// The key ships through `INFOPLIST_KEY_NSLocalNetworkUsageDescription` on both configurations,
/// so this reads the built bundle rather than the project file: what matters is that the app a
/// person installs carries it.
final class MobileLocalNetworkPermissionTests: XCTestCase {

    private static let expected =
        "Threading connects to your Mac over Wi-Fi to show and control your chats."

    func testTheBuiltAppDeclaresWhyItReachesTheLocalNetwork() throws {
        let value = try XCTUnwrap(
            Bundle.main.infoDictionary?["NSLocalNetworkUsageDescription"] as? String,
            "without this key iOS never prompts, and every LAN address fails with no route"
        )

        XCTAssertEqual(value, Self.expected)
    }

    /// Browsing for a Bonjour service needs the service type declared as well, and a browse
    /// without it fails **silently** on iOS 14 and later: no results, no error, no prompt. That
    /// is not a symptom anybody debugs quickly, so it is asserted against the built bundle.
    ///
    /// `NSBonjourServices` is an array, which `INFOPLIST_KEY_` cannot express, so this target has
    /// a real `Info.plist` carrying that one key while every other value still comes from the
    /// generated one. The assertion is therefore also the proof that the merge happened.
    func testTheUsageDescriptionsPresentAreTheOnesThisAppActuallyNeeds() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)

        XCTAssertNotNil(info["NSCameraUsageDescription"], "the pairing code is photographed")
        XCTAssertEqual(
            info["NSBonjourServices"] as? [String],
            ["_threading._tcp"],
            "exactly the one service this app browses for, and browsing is silent without it"
        )
        XCTAssertNotNil(
            info["NSLocalNetworkUsageDescription"],
            "the file that carries NSBonjourServices must not have replaced the generated keys"
        )
        XCTAssertEqual(
            info["UIBackgroundModes"] as? [String],
            ["remote-notification"],
            "silent notification retractions need the remote-notification background mode"
        )
    }

    /// A denial is a named state rather than a spinner, and it is reached from the address the
    /// attempt was aimed at: the same POSIX code on a routable address is an absent host, and
    /// telling somebody to turn on a permission that changes nothing is worse than saying
    /// nothing.
    func testALanAddressFailureRoutesThroughTheDenialClassifier() {
        let noRoute = URLError(
            .cannotConnectToHost,
            userInfo: [NSUnderlyingErrorKey: NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EHOSTUNREACH)
            )]
        )

        let denied = RemoteConnectionFailure.transport(
            noRoute,
            host: "192.168.1.42",
            trustVerdict: nil
        )
        XCTAssertEqual(denied.cause, .localNetworkDenied)
        XCTAssertEqual(denied.recovery, .openLocalNetworkSettings)

        XCTAssertEqual(
            RemoteConnectionFailure.transport(
                noRoute,
                host: "mac.tail1234.ts.net",
                trustVerdict: nil
            ).cause,
            .transport,
            "a tailnet name is not a local address, so the permission is not the diagnosis"
        )
    }
}
