import XCTest
import ThreadingRemoteKit
@testable import Threading

/// What a one-chat invitation is now that there is no public origin to mint one against.
///
/// It used to point at a Cloudflare Quick Tunnel, which is what made a guest anybody with a
/// browser. That origin is gone, so an invitation points at a door of this Mac's own and carries
/// the same fingerprint the owner's pairing code carries. The guest is somebody on your Wi-Fi or
/// on your tailnet running the Threading app; browser guests come back over ICE/TURN.
@MainActor
final class RemoteGuestInvitationTests: HostedStoreTestCase {

    private static let token = "cnrLBpZOe1ZzR6zVoLdWzFRJgN0z0iSwl1KfP1E1hEo"

    private var suiteNames: [String] = []
    private var coordinators: [RemoteAccessCoordinator] = []
    private var transportDoubles: [any RemoteAccessTransport] = []

    override func tearDown() async throws {
        await MainActor.run {
            for coordinator in coordinators { coordinator.stop() }
            coordinators.removeAll()
            transportDoubles.removeAll()
            for name in suiteNames {
                UserDefaults().removePersistentDomain(forName: name)
            }
            suiteNames.removeAll()
        }
        try await super.tearDown()
    }

    // MARK: - The link itself

    /// The guest's phone has to pin, and it has one chance to learn what: the code it was sent.
    ///
    /// `/api/me` never teaches a guest a fingerprint, deliberately, because a one-chat token is
    /// not the owner of the Mac. So a link without the fingerprint half would produce a phone
    /// that meets a self-signed certificate with stock evaluation and refuses it, which is the
    /// whole connection.
    func testAGuestLinkCarriesTheFingerprintOfTheDoorItNames() throws {
        let made = RemoteIdentityTestStore.make(label: "guest-invitation")
        defer { RemoteIdentityTestStore.erase(made.directory) }
        let fingerprint = try made.store.currentIdentity().get().fingerprint
        let origin = try XCTUnwrap(URL(string: "https://192.168.1.42:8760/"))

        let url = try XCTUnwrap(RemoteAccessCoordinator.invitationURL(
            token: Self.token,
            origin: origin,
            pinnedFingerprintCode: fingerprint.pairingCode
        ))

        // The bearer and the fingerprint travel in the fragment, which no request, proxy log or
        // referrer carries, and both halves come back out.
        let parsed = try XCTUnwrap(RemoteConnectionLink(string: url.absoluteString))
        XCTAssertEqual(parsed.baseURL.absoluteString, origin.absoluteString)
        XCTAssertEqual(parsed.token, Self.token)
        XCTAssertEqual(parsed.pinnedFingerprintCode, fingerprint.pairingCode)
        XCTAssertTrue(url.absoluteString.hasSuffix("#\(Self.token).\(fingerprint.pairingCode)"))
    }

    /// The same destination the owner's code names, so a guest link is not a second route with a
    /// second trust story. The preference itself is `pairingDestination`'s, tested beside the
    /// identity it comes from.
    func testAGuestLinkIsMintedAtThePairingDestinationLanFirstThenTheTailnet() throws {
        let made = RemoteIdentityTestStore.make(label: "guest-destination")
        defer { RemoteIdentityTestStore.erase(made.directory) }
        let fingerprint = try made.store.currentIdentity().get().fingerprint
        let lan = RemoteListenerBinding(
            door: .lan,
            address: RemoteNetworkAddress(interfaceName: "en0", address: "192.168.1.42"),
            port: 8760
        )
        let tailnet = RemoteListenerBinding(
            door: .tailscale,
            address: RemoteNetworkAddress(interfaceName: "utun4", address: "100.65.47.126"),
            port: 8760
        )

        func invitation(
            lanBindings: [RemoteListenerBinding],
            tailnetBindings: [RemoteListenerBinding]
        ) -> URL? {
            guard let destination = RemoteAccessCoordinator.pairingDestination(
                lanBindings: lanBindings,
                tailnetBindings: tailnetBindings,
                primaryInterfaceName: "en0",
                pinnedFingerprint: fingerprint
            ) else { return nil }
            return RemoteAccessCoordinator.invitationURL(
                token: Self.token,
                origin: destination.origin,
                pinnedFingerprintCode: destination.pinnedFingerprintCode
            )
        }

        XCTAssertEqual(
            try XCTUnwrap(invitation(lanBindings: [lan], tailnetBindings: [tailnet])),
            URL(string: "https://192.168.1.42:8760/#\(Self.token).\(fingerprint.pairingCode)"),
            "a guest on the Wi-Fi was sent somewhere other than the Wi-Fi address"
        )
        XCTAssertEqual(
            try XCTUnwrap(invitation(lanBindings: [], tailnetBindings: [tailnet])),
            URL(string: "https://100.65.47.126:8760/#\(Self.token).\(fingerprint.pairingCode)"),
            "with no LAN door the tailnet is the invitation's origin"
        )
        XCTAssertNil(
            invitation(lanBindings: [], tailnetBindings: []),
            "an invitation was minted against no door at all"
        )
    }

    // MARK: - Refusing, and saying which switch to look at

    /// Two refusals that send a person to two different switches, in the order they are checked.
    func testTheRefusalNamesTheSwitchThatFixesIt() {
        XCTAssertEqual(
            RemoteAccessCoordinator.shareRefusal(
                isSessionShareable: true,
                isListening: false,
                hasPrivateDoor: true
            ),
            .remoteAccessUnavailable
        )
        XCTAssertEqual(
            RemoteAccessCoordinator.shareRefusal(
                isSessionShareable: false,
                isListening: true,
                hasPrivateDoor: true
            ),
            .remoteAccessUnavailable
        )
        XCTAssertEqual(
            RemoteAccessCoordinator.shareRefusal(
                isSessionShareable: true,
                isListening: true,
                hasPrivateDoor: false
            ),
            .noPrivateDoor
        )
        XCTAssertNil(RemoteAccessCoordinator.shareRefusal(
            isSessionShareable: true,
            isListening: true,
            hasPrivateDoor: true
        ))
        XCTAssertEqual(
            RemoteSharePreparationError.noPrivateDoor.errorDescription,
            "Turn on a way in first."
        )
    }

    /// Remote Access on, every way in off: the listener holds loopback alone, which no other
    /// device can reach. The invitation is refused with the reason rather than minted against an
    /// address only this Mac can open.
    func testAMacWithNoWayInRefusesToMintAnInvitationAndPersistsNothing() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guest-invitation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .codex,
            usesNativeUI: false,
            title: "Shareable chat"
        ))

        let store = InMemoryRemoteGuestShareStore(shares: [])
        let settings = isolatedAppSettings()
        settings.remoteAccessListenerPort = try XCTUnwrap(FreeLocalPort.quiet())
        settings.remoteAccessDoors = []
        settings.remoteAccessTailscaleEnabled = false
        let tailnet = RecordingTailnetTransport()
        transportDoubles.append(tailnet)
        let coordinator = RemoteAccessCoordinator(
            ownerDeviceStore: InMemoryRemoteOwnerDeviceStore(),
            appSettings: settings,
            guestShareStore: store,
            tailnetTransport: tailnet
        )
        coordinators.append(coordinator)

        coordinator.setEnabled(true)
        waitForListening(coordinator)

        let outcome = coordinator.createSessionShare(
            for: session.id,
            capability: .interact,
            canApprovePermissions: false
        )
        guard case .failure(let error) = outcome else {
            return XCTFail("an invitation was minted with nothing bound but loopback")
        }
        XCTAssertEqual(error, .noPrivateDoor)
        XCTAssertEqual(error.errorDescription, "Turn on a way in first.")
        XCTAssertTrue(coordinator.access(for: session.id).isEmpty)
        XCTAssertTrue(store.shares.isEmpty, "a refused invitation still wrote a record")
    }

    // MARK: - Fixtures

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

    private func isolatedAppSettings() -> AppSettings {
        let name = "RemoteGuestInvitationTests.\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.register(defaults: AppSettingDefinitions.registeredDefaults)
        return AppSettings(defaults: defaults)
    }
}
