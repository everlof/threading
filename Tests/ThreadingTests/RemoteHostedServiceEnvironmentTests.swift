import XCTest
import ThreadingPeerTransport
@testable import Threading

@MainActor
final class RemoteHostedServiceEnvironmentTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "RemoteHostedServiceEnvironmentTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    func testDeveloperEnvironmentChoicePersistsAndDefaultsToProduction() {
        let settings = AppSettings(defaults: defaults, hostedDirectIsOffered: true)

        XCTAssertEqual(settings.remoteHostedServiceEnvironment, .production)
        settings.remoteHostedServiceEnvironment = .development

#if DEBUG || THREADING_INTERNAL
        XCTAssertEqual(settings.remoteHostedServiceEnvironment, .development)
        XCTAssertEqual(
            defaults.string(
                forKey: AppSettingDefinitions.remoteHostedServiceEnvironment.persistenceKey
            ),
            RemoteHostedServiceEnvironment.development.rawValue
        )
#else
        XCTAssertEqual(settings.remoteHostedServiceEnvironment, .production)
#endif
    }

    func testDevelopmentChoiceResolvesTheIsolatedService() throws {
        let endpoint = try XCTUnwrap(RemoteHostedServiceController.configuredEndpoint(
            preferredEnvironment: .development,
            environment: [:]
        ))

#if DEBUG || THREADING_INTERNAL
        XCTAssertEqual(
            endpoint.baseURL,
            RemoteHostedServiceEnvironment.developmentServiceURL
        )
#else
        XCTAssertNotEqual(
            endpoint.baseURL,
            RemoteHostedServiceEnvironment.developmentServiceURL
        )
#endif
    }

    func testUIScenarioCannotResolveAHostedEndpointOrStartBrowserAuthentication() {
        for override in [nil, "https://dev.remote.threading.codes", "http://localhost:8787"] {
            var environment = ["THREADING_UI_SCENARIO_HOME": "/tmp/scenario"]
            environment["THREADING_CONTROL_PLANE_URL"] = override
            let endpoint = RemoteHostedServiceController.configuredEndpoint(
                preferredEnvironment: .development,
                environment: environment
            )
            XCTAssertNil(endpoint)
            let controller = RemoteHostedServiceController(
                endpoint: endpoint,
                hostID: "ui-scenario", hostName: "UI scenario",
                localDevelopmentAuthentication: true,
                developmentBrowserAuthentication: true
            )
            controller.start(targetPort: 12345)
            XCTAssertEqual(controller.state, .notConfigured)
            controller.stop()
        }
    }

    func testExplicitLaunchOverrideStillWinsInDeveloperBuilds() throws {
        let override = try XCTUnwrap(URL(string: "https://override.example.test"))
        let endpoint = RemoteHostedServiceController.configuredEndpoint(
            preferredEnvironment: .development,
            environment: ["THREADING_CONTROL_PLANE_URL": override.absoluteString]
        )

#if DEBUG || THREADING_INTERNAL
        XCTAssertEqual(endpoint?.baseURL, override)
        XCTAssertTrue(RemoteHostedServiceController.hasConfiguredEndpointOverride(
            environment: ["THREADING_CONTROL_PLANE_URL": override.absoluteString]
        ))
#else
        XCTAssertNotEqual(endpoint?.baseURL, override)
#endif
    }

    func testHostedNotificationRejectionPreservesStatusAndServiceCode() {
        let result = RemoteHostedServiceController.notificationDeliveryFailure(
            PeerControlPlaneError.rejected(status: 400, code: "invalidRequest"),
            operation: .push
        )

        XCTAssertEqual(result.statusCode, 400)
        XCTAssertEqual(result.failureCode, "invalidRequest")
        XCTAssertEqual(result.reason, "Hosted push broker refused the request.")
        XCTAssertFalse(result.accepted)
    }

    func testHostedNotificationTransportFailureHasNoHTTPStatus() {
        let result = RemoteHostedServiceController.notificationDeliveryFailure(
            PeerControlPlaneError.transport("connection reset"),
            operation: .retraction
        )

        XCTAssertNil(result.statusCode)
        XCTAssertEqual(result.failureCode, "network")
        XCTAssertEqual(result.reason, "Hosted retraction broker was unavailable.")
        XCTAssertFalse(result.accepted)
    }

    // MARK: - What A Deployed Broker Will Accept

    /// The broker validates a notification against an exact key list, so one field it has not
    /// heard of costs the whole push. A service too old to publish a version answers 0, which is
    /// the same decision as a version below the one that introduced the field.
    func testTurnGenerationIsSentOnlyToABrokerThatPublishesItsVersion() {
        let event = RemoteNotificationEventDTO(
            id: "event-1",
            kind: .turnCompleted,
            hostID: "host",
            sessionID: "session",
            title: "Chat",
            body: "Finished its turn.",
            turnGeneration: 7
        )

        for version in [0, 1] {
            XCTAssertNil(
                RemoteNotificationBrokerCompatibility
                    .payload(event, forBrokerVersion: version).turnGeneration,
                "a broker publishing \(version) refuses the field"
            )
        }
        XCTAssertEqual(
            RemoteNotificationBrokerCompatibility
                .payload(event, forBrokerVersion: RemoteNotificationBrokerCompatibility
                    .turnGenerationVersion).turnGeneration,
            7
        )
    }

    /// Only that field goes. A completion whose body is a consented preview must still arrive as
    /// one, and the identity every retraction matches on cannot move.
    func testOmittingTheGenerationChangesNothingElseAboutTheEvent() {
        let event = RemoteNotificationEventDTO(
            id: "event-1",
            kind: .turnCompleted,
            hostID: "host",
            sessionID: "session",
            title: "Chat",
            body: "Renamed the two callers.",
            destination: .session,
            createdAt: 1_757_000_000,
            turnGeneration: 7
        )

        let reduced = RemoteNotificationBrokerCompatibility.payload(event, forBrokerVersion: 1)

        XCTAssertEqual(reduced.id, event.id)
        XCTAssertEqual(reduced.kind, event.kind)
        XCTAssertEqual(reduced.hostID, event.hostID)
        XCTAssertEqual(reduced.sessionID, event.sessionID)
        XCTAssertEqual(reduced.title, event.title)
        XCTAssertEqual(reduced.body, event.body)
        XCTAssertNil(reduced.bodyLocalization)
        XCTAssertEqual(reduced.destination, event.destination)
        XCTAssertEqual(reduced.createdAt, event.createdAt)
        XCTAssertEqual(
            RemoteAPNSPushSender.collapseIdentifier(for: reduced),
            RemoteAPNSPushSender.collapseIdentifier(for: event)
        )
    }

    /// An event that never carried a generation is returned untouched, so the reduction cannot
    /// re-encode a question or a person-to-person request on its way to an older service.
    func testAnEventWithoutAGenerationIsUnchanged() {
        let event = RemoteNotificationEventDTO(
            kind: .agentQuestion,
            hostID: "host",
            sessionID: "session",
            title: "Chat",
            body: "Open the chat to answer."
        )

        XCTAssertEqual(
            RemoteNotificationBrokerCompatibility.payload(event, forBrokerVersion: 0),
            event
        )
    }

}
