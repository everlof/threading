import XCTest
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

    func testDebugEnvironmentChoicePersistsAndDefaultsToProduction() {
        let settings = AppSettings(defaults: defaults, remoteAccessIsOffered: true)

        XCTAssertEqual(settings.remoteHostedServiceEnvironment, .production)
        settings.remoteHostedServiceEnvironment = .development

#if DEBUG
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

#if DEBUG
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

    func testExplicitLaunchOverrideStillWinsInDebugBuilds() throws {
        let override = try XCTUnwrap(URL(string: "https://override.example.test"))
        let endpoint = RemoteHostedServiceController.configuredEndpoint(
            preferredEnvironment: .development,
            environment: ["THREADING_CONTROL_PLANE_URL": override.absoluteString]
        )

#if DEBUG
        XCTAssertEqual(endpoint?.baseURL, override)
        XCTAssertTrue(RemoteHostedServiceController.hasConfiguredEndpointOverride(
            environment: ["THREADING_CONTROL_PLANE_URL": override.absoluteString]
        ))
#else
        XCTAssertNotEqual(endpoint?.baseURL, override)
#endif
    }
}
