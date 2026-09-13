import XCTest
import ThreadingRemoteKit
@testable import Threading

/// Remote Access ships on every channel; Hosted Direct is development-only.
///
/// Public builds offer the local ways in — This network, Through a VPN, Tailscale and Tailscale
/// Serve — so the Threading iPhone app can pair with a notarized Mac. Hosted Direct needs Sign in
/// with Apple, an entitlement a Developer ID build cannot carry, so only `.dev` offers it. The
/// master switch stays off by default everywhere, and a public build clears a switch it inherited
/// from a development build exactly once.
final class RemoteAccessChannelGateTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    // MARK: - The channel decides

    func testOnlyADevelopmentBuildOffersHostedDirect() {
        XCTAssertTrue(BuildChannel.dev.offersHostedDirect)
        for channel in [BuildChannel.nightly, .beta, .release] {
            XCTAssertFalse(
                channel.offersHostedDirect,
                "\(channel.rawValue) is distributed by Developer ID, which cannot carry the Sign "
                    + "in with Apple entitlement Hosted Direct enrolls this Mac with"
            )
        }
    }

    /// The enum's own default is the development channel. A build made without the release
    /// pipeline's injection is not one it shipped, so no unknown value can reach a public channel.
    func testAnUnknownChannelValueIsTreatedAsDevelopment() {
        XCTAssertEqual(BuildChannel(infoValue: "enterprise"), .dev)
        XCTAssertEqual(BuildChannel(infoValue: ""), .dev)
        XCTAssertEqual(BuildChannel(infoValue: nil), .dev)
    }

    // MARK: - The page is on every channel

    /// Every channel lists the Remote Access page and its local ways in; only the development
    /// channel lists the Hosted Direct sign-in row a public build's page does not contain.
    @MainActor
    func testEveryChannelShowsTheRemoteAccessPageWithItsLocalWaysIn() throws {
        XCTAssertNotNil(SettingsPages.page(id: SettingsPages.remoteAccessID))
        for channel in BuildChannel.allCases {
            let rows = AppSettingDefinitions.definitions(on: channel)
                .flatMap(\.presentations)
                .filter { $0.pageID == SettingsPages.remoteAccessID }
                .map(\.rowAnchor)
            for local in ["Remote Access", "This network", "Tailscale",
                          "Open in a browser on your tailnet"] {
                XCTAssertTrue(rows.contains(local), "\(channel.rawValue) does not list \(local)")
            }
            XCTAssertEqual(
                rows.contains("Hosted Direct"),
                channel.offersHostedDirect,
                "\(channel.rawValue) lists a sign-in row its page does not have"
            )
        }
    }

    /// The page filter is gone rather than widened. A gate that quietly removed a page would be
    /// invisible until somebody went looking for it.
    @MainActor
    func testNoPageIsWithheld() {
        let offered = Set(SettingsPages.all.map(\.id))
        let withheld = SettingsPages.builtIn.map(\.id).filter { !offered.contains($0) }
        XCTAssertEqual(withheld, [])
    }

    // MARK: - The master switch

    /// If this ever became `true` by default, every public install would open a listener nobody
    /// asked for.
    func testRemoteAccessIsOffUntilSomethingTurnsItOn() {
        XCTAssertEqual(AppSettingDefinitions.remoteAccessEnabled.absence.value, false)
        XCTAssertNil(
            AppSettingDefinitions.registeredDefaults[
                AppSettingDefinitions.remoteAccessEnabled.persistenceKey
            ]
        )
    }

    @MainActor
    func testAPublicBuildCanTurnRemoteAccessOn() throws {
        let defaults = try isolatedDefaults("public-opt-in")
        let settings = AppSettings(defaults: defaults, hostedDirectIsOffered: false)

        XCTAssertFalse(settings.remoteAccessEnabled)
        settings.remoteAccessEnabled = true

        XCTAssertTrue(settings.remoteAccessEnabled)
        XCTAssertEqual(storedRemoteAccess(in: defaults), true)
    }

    /// A public build installed over a development build must not open a listener the person
    /// enabled while the feature was development-only — but only the first time. After that the
    /// public build owns the switch, and an opt-in made there survives its next launch.
    @MainActor
    func testAPublicBuildClearsAnInheritedOptInOnceAndKeepsALaterOne() throws {
        let defaults = try isolatedDefaults("inherited")
        defaults.set(true, forKey: AppSettingDefinitions.remoteAccessEnabled.persistenceKey)

        let firstLaunch = AppSettings(defaults: defaults, hostedDirectIsOffered: false)

        XCTAssertFalse(firstLaunch.remoteAccessEnabled, "the inherited opt-in survived")
        XCTAssertEqual(storedRemoteAccess(in: defaults), false)
        XCTAssertTrue(
            AppSettingDefinitions.remoteAccessPublicChannelMigration.containsValue(in: defaults)
        )

        firstLaunch.remoteAccessEnabled = true
        let secondLaunch = AppSettings(defaults: defaults, hostedDirectIsOffered: false)

        XCTAssertTrue(
            secondLaunch.remoteAccessEnabled,
            "an opt-in made in the public build was undone at its next launch"
        )
    }

    /// A fresh public install has nothing to clear, and still records that it has taken the
    /// switch over — otherwise its own first opt-in would be cleared at the next launch.
    @MainActor
    func testAFreshPublicInstallRecordsTheMarkerWithoutWritingTheSwitch() throws {
        let defaults = try isolatedDefaults("fresh")

        let settings = AppSettings(defaults: defaults, hostedDirectIsOffered: false)

        XCTAssertFalse(settings.remoteAccessEnabled)
        XCTAssertNil(storedRemoteAccess(in: defaults))
        XCTAssertTrue(
            AppSettingDefinitions.remoteAccessPublicChannelMigration.containsValue(in: defaults)
        )
    }

    @MainActor
    func testADevelopmentBuildKeepsItsOptInAndWritesNoMarker() throws {
        let defaults = try isolatedDefaults("development")
        defaults.set(true, forKey: AppSettingDefinitions.remoteAccessEnabled.persistenceKey)

        let settings = AppSettings(defaults: defaults, hostedDirectIsOffered: true)

        XCTAssertTrue(settings.remoteAccessEnabled)
        XCTAssertFalse(
            AppSettingDefinitions.remoteAccessPublicChannelMigration.containsValue(in: defaults),
            "a development build took the switch over for a public build it is not"
        )
    }

    // MARK: - Helpers

    private func isolatedDefaults(_ label: String) throws -> UserDefaults {
        let name = "RemoteAccessChannelGateTests.\(label).\(UUID().uuidString)"
        suiteNames.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func storedRemoteAccess(in defaults: UserDefaults) -> Bool? {
        defaults.object(forKey: AppSettingDefinitions.remoteAccessEnabled.persistenceKey) as? Bool
    }
}

/// A public build's coordinator: the listener is the real one, and the hosted half is inert.
///
/// Inherits `HostedStoreTestCase` because starting the listener composes the shipping server
/// services, which reach `ProjectStore.shared`.
@MainActor
final class RemoteAccessPublicBuildCoordinatorTests: HostedStoreTestCase {

    private var suiteNames: [String] = []
    private var coordinators: [RemoteAccessCoordinator] = []

    override func tearDown() async throws {
        await MainActor.run {
            for coordinator in coordinators { coordinator.stop() }
            coordinators.removeAll()
            for name in suiteNames {
                UserDefaults().removePersistentDomain(forName: name)
            }
            suiteNames.removeAll()
        }
        try await super.tearDown()
    }

    func testAPublicBuildReportsNoHostedServiceCredentialsOrPairingLink() throws {
        let settings = try publicBuildSettings()
        let coordinator = makeCoordinator(settings)

        coordinator.setEnabled(true)
        waitForListening(coordinator)

        XCTAssertEqual(
            coordinator.hostedServiceState,
            .notConfigured,
            "a public build's hosted controller has an endpoint to contact"
        )
        XCTAssertFalse(coordinator.canIssueHostedDeviceCredentials)
        if let payload = coordinator.pairingCodePayload,
           case .hostedPairing = RemoteInvitation(payload: payload) {
            XCTFail("a public build put a hosted pairing link in its QR code")
        }
    }

    func testAPublicBuildRefusesHostedAccountOperations() async throws {
        let settings = try publicBuildSettings()
        let coordinator = makeCoordinator(settings)

        do {
            try await coordinator.signInHostedService(
                identityToken: "identity",
                authorizationCode: "code",
                rawNonce: "nonce"
            )
            XCTFail("a public build accepted a Sign in with Apple credential")
        } catch {}
        do {
            try await coordinator.signOutHostedService()
            XCTFail("a public build signed out of a hosted account it cannot have")
        } catch {}
        do {
            try await coordinator.deleteHostedServiceAccount()
            XCTFail("a public build deleted a hosted account it cannot have")
        } catch {}

        coordinator.setHostedServiceEnvironment(.development)
        XCTAssertEqual(settings.remoteHostedServiceEnvironment, .production)
        XCTAssertNotEqual(coordinator.hostedServiceState, .connecting)
    }

    // MARK: - Helpers

    private func publicBuildSettings() throws -> AppSettings {
        let name = "RemoteAccessPublicBuildCoordinatorTests.\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.register(defaults: AppSettingDefinitions.registeredDefaults)
        let settings = AppSettings(defaults: defaults, hostedDirectIsOffered: false)
        // A port nothing else on this machine holds, and no routable door: the listener binds
        // loopback only, so the test publishes nothing on the developer's network.
        settings.remoteAccessListenerPort = try XCTUnwrap(FreeLocalPort.quiet())
        settings.remoteAccessDoors = []
        settings.remoteAccessTailscaleEnabled = false
        return settings
    }

    private func makeCoordinator(_ settings: AppSettings) -> RemoteAccessCoordinator {
        let coordinator = RemoteAccessCoordinator(
            ownerDeviceStore: InMemoryRemoteOwnerDeviceStore(),
            appSettings: settings,
            guestShareStore: InMemoryRemoteGuestShareStore(shares: []),
            tailnetTransport: RecordingTailnetTransport()
        )
        coordinators.append(coordinator)
        return coordinator
    }

    /// Spins the run loop until the listener has answered. `start` completes on main.
    private func waitForListening(
        _ coordinator: RemoteAccessCoordinator,
        timeout: TimeInterval = 5
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .listening = coordinator.status { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("the listener never reported itself listening: \(coordinator.status)")
    }
}
