import Foundation
import ThreadingExtensionKit
import XCTest
@testable import Threading

private final class FactHostResponseBox: @unchecked Sendable {
    var value: HTTPResponse?
}

@MainActor
final class ExtensionFactProviderHostTests: XCTestCase {
    private let key = ExtensionFactKey(id: "gitlab.merge-request-count")
    private let repository = ExtensionRepositoryKey(host: "gitlab.com", path: "team/app")

    private var subject: ExtensionFactSubject {
        .repository(repository)
    }

    private func definition(
        displayName: String = "Merge requests",
        valueType: ExtensionFactValueType = .integer
    ) -> ExtensionFactDefinition {
        ExtensionFactDefinition(
            key: key,
            displayName: displayName,
            valueType: valueType,
            subjectKinds: [.repository],
            usages: [.filterable, .presentable]
        )
    }

    private func fact(_ count: Int64) -> ExtensionFact {
        ExtensionFact(
            key: key,
            subject: subject,
            value: .integer(count),
            label: "\(count) open",
            status: count == 0 ? .positive : .warning,
            observedAt: Date(timeIntervalSinceReferenceDate: 123)
        )
    }

    private func service(
        factRegistry: ExtensionFactRegistry? = nil,
        componentRegistry: ComponentCustomizationRegistry? = nil
    ) throws -> ExtensionHostService {
        ExtensionHostService(
            registry: componentRegistry,
            factRegistry: factRegistry,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1"))
        )
    }

    private func authorizeFacts(
        _ service: ExtensionHostService,
        identifier: String = "com.example.gitlab",
        generation: String = "one",
        definition: ExtensionFactDefinition? = nil,
        localization: ExtensionLocalizationResolver = .init(strings: [:])
    ) throws -> ExtensionHostAuthorization {
        try XCTUnwrap(try service.authorize(
            extensionIdentifier: identifier,
            processGeneration: generation,
            order: 99,
            capabilities: [.factsProvide],
            factDefinitions: [definition ?? self.definition()],
            localization: localization
        ))
    }

    private func route(
        through service: ExtensionHostService,
        token: String,
        method: String = "PUT",
        contentType: String? = "application/json",
        body: Data
    ) throws -> HTTPResponse {
        var headers = ["authorization": "Bearer \(token)"]
        if let contentType { headers["content-type"] = contentType }
        let response = FactHostResponseBox()
        service.route(HTTPRequest(
            method: method,
            path: "/v1/facts",
            headers: headers,
            body: body
        )) { response.value = $0 }
        return try XCTUnwrap(response.value)
    }

    private func publication(
        facts: [ExtensionFact],
        subjects: [ExtensionFactSubject]? = nil
    ) throws -> Data {
        try JSONEncoder().encode(ExtensionFactPublication(
            replacingSubjects: subjects ?? [subject],
            facts: facts
        ))
    }

    func testFactOnlyAuthorizationInstallsLocalizedDefinitionsWithoutAComponentRegistry() throws {
        let registry = ExtensionFactRegistry()
        let host = try service(factRegistry: registry)

        _ = try authorizeFacts(
            host,
            localization: .init(strings: ["Merge requests": "Merge-förfrågningar"])
        )

        XCTAssertEqual(registry.definition(for: key)?.displayName, "Merge-förfrågningar")
    }

    func testAuthorizationRevalidatesThePublicProviderDeclarationBeforeInstallingIt() throws {
        let registry = ExtensionFactRegistry()
        let host = try service(factRegistry: registry)
        let opaqueDefinition = ExtensionFactDefinition(
            key: key,
            displayName: "Merge requests",
            valueType: .integer,
            subjectKinds: [.session],
            usages: [.filterable]
        )

        XCTAssertThrowsError(try host.authorize(
            extensionIdentifier: "com.example.missing-definitions",
            processGeneration: "one",
            order: 0,
            capabilities: [.factsProvide]
        )) { error in
            XCTAssertTrue(error is ExtensionValidationError)
        }
        XCTAssertThrowsError(try host.authorize(
            extensionIdentifier: "com.example.missing-capability",
            processGeneration: "one",
            order: 0,
            capabilities: [.hostProjectsRead],
            factDefinitions: [definition()]
        )) { error in
            XCTAssertTrue(error is ExtensionValidationError)
        }
        XCTAssertThrowsError(try host.authorize(
            extensionIdentifier: "com.example.opaque-subject",
            processGeneration: "one",
            order: 0,
            capabilities: [.factsProvide],
            factDefinitions: [opaqueDefinition]
        )) { error in
            XCTAssertTrue(error is ExtensionValidationError)
        }
        XCTAssertNil(registry.definition(for: key))
    }

    func testRouteIsCapabilityMediaTypeAndBodyBoundedBeforeMutation() throws {
        let registry = ExtensionFactRegistry()
        let componentRegistry = ComponentCustomizationRegistry()
        let host = try service(
            factRegistry: registry,
            componentRegistry: componentRegistry
        )
        let factsToken = try authorizeFacts(host).connection.bearerToken
        let otherToken = try XCTUnwrap(try host.authorize(
            extensionIdentifier: "com.example.components",
            processGeneration: "one",
            order: 0,
            capabilities: [.componentCustomization]
        )).connection.bearerToken
        let valid = try publication(facts: [fact(3)])

        XCTAssertEqual(
            try route(
                through: host,
                token: otherToken,
                contentType: nil,
                body: Data(repeating: 0, count: 1024 * 1024 + 1)
            ).status,
            403,
            "capability refusal must happen before body inspection"
        )
        XCTAssertEqual(
            try route(through: host, token: factsToken, method: "GET", body: valid).status,
            404
        )
        XCTAssertEqual(
            try route(through: host, token: factsToken, method: "POST", body: valid).status,
            405
        )
        XCTAssertEqual(
            try route(
                through: host,
                token: factsToken,
                contentType: "text/plain",
                body: valid
            ).status,
            415
        )
        XCTAssertEqual(
            try route(
                through: host,
                token: factsToken,
                body: Data(repeating: 0, count: 1024 * 1024 + 1)
            ).status,
            413
        )
        XCTAssertEqual(
            try route(through: host, token: factsToken, body: Data("{}".utf8)).status,
            422
        )
        XCTAssertNil(registry.exactFact(key, for: subject))
    }

    func testPublicationIsAtomicSupportsScopedClearingAndRevokesTheExactGeneration() throws {
        let registry = ExtensionFactRegistry()
        let host = try service(factRegistry: registry)
        let authorization = try authorizeFacts(host)
        let token = authorization.connection.bearerToken

        XCTAssertEqual(
            try route(through: host, token: token, body: publication(facts: [fact(3)])).status,
            204
        )
        XCTAssertEqual(registry.exactFact(key, for: subject)?.fact.value, .integer(3))

        let undeclared = ExtensionFact(
            key: .init(id: "gitlab.pipeline-count"),
            subject: subject,
            value: .integer(8),
            observedAt: Date(timeIntervalSinceReferenceDate: 124)
        )
        XCTAssertEqual(
            try route(
                through: host,
                token: token,
                body: publication(facts: [undeclared])
            ).status,
            422
        )
        XCTAssertEqual(
            registry.exactFact(key, for: subject)?.fact.value,
            .integer(3),
            "a rejected replacement must preserve the accepted publication"
        )

        XCTAssertEqual(
            try route(through: host, token: token, body: publication(facts: [])).status,
            204
        )
        XCTAssertNil(registry.exactFact(key, for: subject))

        XCTAssertEqual(
            try route(through: host, token: token, body: publication(facts: [fact(4)])).status,
            204
        )
        host.revoke(
            extensionIdentifier: "com.example.gitlab",
            processGeneration: "one"
        )
        XCTAssertNil(registry.definition(for: key))
        XCTAssertNil(registry.exactFact(key, for: subject))
        XCTAssertEqual(
            try route(through: host, token: token, body: publication(facts: [fact(5)])).status,
            401
        )
    }

    func testProviderPrecedenceIsIndependentOfStartOrderAndRevokeRevealsFallback() throws {
        let registry = ExtensionFactRegistry()
        let host = try service(factRegistry: registry)
        let laterLexical = try authorizeFacts(
            host,
            identifier: "com.example.zulu",
            generation: "zulu-generation"
        )
        let earlierLexical = try authorizeFacts(
            host,
            identifier: "com.example.alpha",
            generation: "alpha-generation"
        )

        XCTAssertEqual(
            try route(
                through: host,
                token: laterLexical.connection.bearerToken,
                body: publication(facts: [fact(9)])
            ).status,
            204
        )
        XCTAssertEqual(
            try route(
                through: host,
                token: earlierLexical.connection.bearerToken,
                body: publication(facts: [fact(1)])
            ).status,
            204
        )
        XCTAssertEqual(registry.exactFact(key, for: subject)?.fact.value, .integer(1))
        XCTAssertEqual(
            registry.exactFact(key, for: subject)?.source,
            .extension(
                identifier: "com.example.alpha",
                processGeneration: "alpha-generation"
            )
        )

        host.revoke(
            extensionIdentifier: "com.example.alpha",
            processGeneration: "alpha-generation"
        )
        XCTAssertEqual(registry.exactFact(key, for: subject)?.fact.value, .integer(9))
        XCTAssertEqual(
            registry.exactFact(key, for: subject)?.source,
            .extension(
                identifier: "com.example.zulu",
                processGeneration: "zulu-generation"
            )
        )

        host.stop()
        XCTAssertNil(registry.definition(for: key))
        XCTAssertNil(registry.exactFact(key, for: subject))
    }
}
