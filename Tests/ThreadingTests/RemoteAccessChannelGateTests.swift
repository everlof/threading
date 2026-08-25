import XCTest
@testable import Threading

/// Remote Access is present in the source but withheld from distributed builds.
///
/// The whole gate rests on one fact: `AppSettings.remoteAccessEnabled` is `absence: .falseValue`
/// and every runtime path guards on it, so withholding the single surface that can turn it on
/// withholds the feature. These tests pin both halves of that, because either one drifting alone
/// ships a door that opens onto nothing or a feature nobody meant to distribute.
final class RemoteAccessChannelGateTests: XCTestCase {

    // MARK: - The channel decides

    func testOnlyADevelopmentBuildOffersRemoteAccess() {
        XCTAssertTrue(BuildChannel.dev.offersRemoteAccess)
        for channel in [BuildChannel.nightly, .beta, .release] {
            XCTAssertFalse(
                channel.offersRemoteAccess,
                "\(channel.rawValue) is distributed, and a distributed build cannot complete the "
                    + "feature: Hosted Direct needs an entitlement Developer ID cannot carry"
            )
        }
    }

    /// The enum's own default is the safe one. A build made without the release pipeline's
    /// injection lands on `.dev`, which is the case that *offers* the feature — so the safety
    /// here is not the default itself but that no unknown value can reach a distributed channel.
    func testAnUnknownChannelValueIsTreatedAsDevelopment() {
        XCTAssertEqual(BuildChannel(infoValue: "enterprise"), .dev)
        XCTAssertEqual(BuildChannel(infoValue: ""), .dev)
        XCTAssertEqual(BuildChannel(infoValue: nil), .dev)
    }

    // MARK: - The page follows the channel

    @MainActor
    func testAShippingChannelWithholdsTheRemoteAccessPage() throws {
        let remoteAccess = try XCTUnwrap(
            SettingsPages.builtIn.first { $0.id == SettingsPages.remoteAccessID },
            "the Remote Access page is missing entirely"
        )
        XCTAssertTrue(SettingsPages.isOffered(remoteAccess, on: .dev))
        for channel in [BuildChannel.nightly, .beta, .release] {
            XCTAssertFalse(SettingsPages.isOffered(remoteAccess, on: channel))
        }
    }

    /// The filter must take exactly one page and no others. A gate that quietly removed a second
    /// page would be invisible until somebody went looking for it.
    @MainActor
    func testNoOtherPageIsWithheld() {
        let withheld = SettingsPages.builtIn
            .filter { !SettingsPages.isOffered($0, on: .release) }
            .map(\.id)
        XCTAssertEqual(withheld, [SettingsPages.remoteAccessID])
    }

    // MARK: - The setting the page would have written

    /// The other half of the gate. If this ever became `true` by default, hiding the page would
    /// stop withholding anything: the feature would simply be on, with no way to turn it off.
    func testRemoteAccessIsOffUntilSomethingTurnsItOn() {
        XCTAssertEqual(AppSettingDefinitions.remoteAccessEnabled.absence.value, false)
    }
}
