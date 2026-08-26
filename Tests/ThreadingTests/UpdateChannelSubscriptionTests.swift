import XCTest
@testable import Threading

/// What a person receives, which is not what their build is.
///
/// Two failures are worth pinning here because both strand somebody silently and neither shows up
/// as a crash or a failed request: a subscription that accepts too much drags a stable user onto a
/// beta, and one that accepts too little leaves a beta user on a build nothing will ever replace.
final class UpdateChannelSubscriptionTests: XCTestCase {

    // MARK: - What each subscription accepts

    /// Stable's empty set is Sparkle's vocabulary for "untagged items only", not "no items".
    /// If this ever became non-empty, every stable user would start seeing prereleases.
    func testStableAcceptsOnlyUntaggedItems() {
        XCTAssertEqual(UpdateChannelSubscription.stable.allowedChannelNames, [])
    }

    func testBetaAcceptsBetaItems() {
        XCTAssertEqual(UpdateChannelSubscription.beta.allowedChannelNames, ["beta"])
    }

    /// Monotonic: every subscription accepts everything more stable than itself. Untagged items
    /// are accepted by all of them, which is what makes "go back to stable" work without a
    /// reinstall — the stable item is visible from the beta subscription too.
    func testEverySubscriptionStillAcceptsStable() {
        for subscription in UpdateChannelSubscription.allCases {
            XCTAssertFalse(
                subscription.allowedChannelNames.contains("stable"),
                "stable is the absence of a tag, never a tag — naming it would filter out the "
                    + "untagged items it is supposed to mean"
            )
        }
    }

    /// Nightly must never be reachable from this control. Its date version outranks every release,
    /// so subscribing would be a door with no way back: Sparkle would find nothing newer on the
    /// stable feed and offer nothing, forever.
    func testNightlyIsNotSubscribable() {
        XCTAssertEqual(UpdateChannelSubscription.allCases.map(\.rawValue), ["stable", "beta"])
        for subscription in UpdateChannelSubscription.allCases {
            XCTAssertFalse(subscription.allowedChannelNames.contains("nightly"))
        }
    }

    // MARK: - The default follows the build

    /// The load-bearing case. A friend handed a beta zip has expressed no preference, and a fixed
    /// "stable" default would filter every beta item away from the very build they are running.
    func testABetaBuildDefaultsToReceivingBetas() {
        XCTAssertEqual(UpdateChannelSubscription.standard(for: .beta), .beta)
    }

    func testEveryOtherChannelDefaultsToStable() {
        for channel in [BuildChannel.dev, .nightly, .release] {
            XCTAssertEqual(
                UpdateChannelSubscription.standard(for: channel), .stable,
                "\(channel.rawValue) must not opt anyone into prereleases by default"
            )
        }
    }

    // MARK: - Persistence contract

    /// The stored value is a choice somebody made; empty means they never made one, which is why
    /// the descriptor accepts it and the accessor resolves it against the build.
    func testTheStoredVocabularyAllowsBothChoicesAndNoChoice() {
        guard case .allowedStrings(let allowed) =
            AppSettingDefinitions.updateChannelSubscription.validation.erased else {
            return XCTFail("the subscription must validate against a fixed vocabulary")
        }
        XCTAssertTrue(allowed.contains("stable"))
        XCTAssertTrue(allowed.contains("beta"))
        XCTAssertTrue(allowed.contains(""), "an unset preference must survive validation")
        XCTAssertFalse(allowed.contains("nightly"))
    }
}
