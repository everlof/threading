import Foundation
import XCTest
@testable import ThreadingExtensionKit

final class ExtensionFactPublicationContractTests: XCTestCase {
    private let repository = ExtensionRepositoryKey(
        host: "gitlab.com",
        path: "threading/example"
    )
    private let key = ExtensionFactKey(id: "gitlab.mr.state")

    func testProviderCapabilityAndLimitsArePublicAndPinned() {
        XCTAssertEqual(ExtensionCapability.factsProvide.rawValue, "facts.provide")
        XCTAssertTrue(ThreadingExtensionAPI.safeCapabilities.contains(.factsProvide))
        XCTAssertEqual(ExtensionFactProviderLimits.maximumDefinitions, 128)
        XCTAssertEqual(ExtensionFactProviderLimits.maximumSubjectsPerPublication, 2_048)
        XCTAssertEqual(ExtensionFactProviderLimits.maximumFactsPerPublication, 2_048)
        XCTAssertEqual(ExtensionFactProviderLimits.maximumFactsPerSubject, 32)
        XCTAssertEqual(ExtensionFactProviderLimits.maximumFactsPerGeneration, 16_384)
    }

    func testPublicationHasAnExactVersionedWireShape() throws {
        let subject = ExtensionFactSubject.repositoryBranch(
            repository: repository,
            branch: "main"
        )
        let publication = ExtensionFactPublication(
            replacingSubjects: [subject],
            facts: [fact(subject: subject, value: "merged")]
        )
        try publication.validate()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(publication)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "{\"facts\":[{\"key\":{\"id\":\"gitlab.mr.state\",\"version\":1},"
                + "\"observedAt\":1,\"subject\":{\"branch\":\"main\",\"repository\":{"
                + "\"host\":\"gitlab.com\",\"path\":\"threading\\/example\"},"
                + "\"type\":\"repositoryBranch\"},\"value\":{\"type\":\"string\","
                + "\"value\":\"merged\"}}],\"protocolVersion\":1,\"replacingSubjects\":[{"
                + "\"branch\":\"main\",\"repository\":{\"host\":\"gitlab.com\","
                + "\"path\":\"threading\\/example\"},\"type\":\"repositoryBranch\"}]}"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ExtensionFactPublication.self, from: data),
            publication
        )
    }

    func testManifestAndRegistrationRequireTheSameDomainDefinitions() throws {
        let declaredDefinition = self.definition()
        let manifest = providerManifest(definitions: [declaredDefinition])
        try manifest.validate()
        XCTAssertNoThrow(try ExtensionRegistration(
            factDefinitions: [declaredDefinition]
        ).validate(for: manifest))

        XCTAssertThrowsError(try ExtensionRegistration().validate(for: manifest)) { error in
            XCTAssertTrue(
                (error as? ExtensionValidationError)?.issues.contains {
                    $0.path == "factDefinitions"
                } == true
            )
        }
        XCTAssertThrowsError(try ExtensionRegistration(
            factDefinitions: [definition(key: .init(id: "gitlab.mr.draft"))]
        ).validate(for: manifest))
    }

    func testManifestDefaultsRemainBackwardCompatibleAndCapabilityIsPaired() throws {
        let legacy = Data("""
        {
          "formatVersion": 1,
          "identifier": "com.example.legacy",
          "name": "Legacy",
          "version": "1",
          "runtime": "webAssembly",
          "executable": "bin/legacy.wasm",
          "capabilities": []
        }
        """.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(ExtensionManifest.self, from: legacy).factDefinitions,
            []
        )

        XCTAssertThrowsError(try providerManifest(
            capabilities: [],
            definitions: [definition()]
        ).validate())
        XCTAssertThrowsError(try providerManifest(
            capabilities: [.factsProvide],
            definitions: []
        ).validate())
    }

    func testProviderDefinitionsRejectOpaqueAndReservedSubjectsAndDuplicateKeys() {
        let opaque = definition(subjectKinds: [.session])
        let reserved = definition(key: ExtensionHostFactKey.sessionTitle)
        for definitions in [[opaque], [reserved], [definition(), definition()]] {
            XCTAssertThrowsError(try providerManifest(definitions: definitions).validate())
        }
    }

    func testPublicationRejectsOpaqueDuplicateAndOutOfScopeFacts() {
        let main = ExtensionFactSubject.repositoryBranch(repository: repository, branch: "main")
        let release = ExtensionFactSubject.repositoryBranch(
            repository: repository,
            branch: "release"
        )
        let invalid: [ExtensionFactPublication] = [
            .init(replacingSubjects: [], facts: []),
            .init(replacingSubjects: [main, main], facts: []),
            .init(replacingSubjects: [.session("opaque")], facts: []),
            .init(replacingSubjects: [main], facts: [fact(subject: release)]),
            .init(
                replacingSubjects: [main],
                facts: [fact(key: ExtensionHostFactKey.sessionTitle, subject: main)]
            ),
            .init(
                replacingSubjects: [main],
                facts: [fact(subject: main), fact(subject: main)]
            ),
        ]
        for publication in invalid {
            XCTAssertThrowsError(try publication.validate(), "accepted \(publication)")
        }
    }

    func testPublicationAcceptsExactBoundsAndRejectsLimitPlusOne() throws {
        let subjects = (0..<64).map {
            ExtensionFactSubject.repositoryBranch(
                repository: repository,
                branch: "branch-\($0)"
            )
        }
        let facts: [ExtensionFact] = subjects.reduce(into: []) { result, subject in
            (0..<ExtensionFactProviderLimits.maximumFactsPerSubject).map { index in
                self.fact(
                    key: .init(id: "gitlab.fact-\(index)"),
                    subject: subject
                )
            }.forEach { result.append($0) }
        }
        XCTAssertEqual(facts.count, ExtensionFactProviderLimits.maximumFactsPerPublication)
        XCTAssertNoThrow(try ExtensionFactPublication(
            replacingSubjects: subjects,
            facts: facts
        ).validate())

        let overfullSubject = ExtensionFactSubject.repository(repository)
        let overfull = (0...ExtensionFactProviderLimits.maximumFactsPerSubject).map {
            fact(key: .init(id: "gitlab.overfull-\($0)"), subject: overfullSubject)
        }
        XCTAssertThrowsError(try ExtensionFactPublication(
            replacingSubjects: [overfullSubject],
            facts: overfull
        ).validate())

        let tooManySubjects = (0...ExtensionFactProviderLimits.maximumSubjectsPerPublication)
            .map {
                ExtensionFactSubject.repositoryBranch(
                    repository: repository,
                    branch: "scope-\($0)"
                )
            }
        XCTAssertThrowsError(try ExtensionFactPublication(
            replacingSubjects: tooManySubjects,
            facts: []
        ).validate())
    }

    private func definition(
        key: ExtensionFactKey? = nil,
        subjectKinds: Set<ExtensionFactSubjectKind> = [.repositoryBranch]
    ) -> ExtensionFactDefinition {
        ExtensionFactDefinition(
            key: key ?? self.key,
            displayName: "Merge request state",
            valueType: .string,
            subjectKinds: subjectKinds,
            usages: [.filterable, .groupable, .presentable]
        )
    }

    private func fact(
        key: ExtensionFactKey? = nil,
        subject: ExtensionFactSubject,
        value: String = "opened"
    ) -> ExtensionFact {
        ExtensionFact(
            key: key ?? self.key,
            subject: subject,
            value: .string(value),
            observedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
    }

    private func providerManifest(
        capabilities: Set<ExtensionCapability> = [.factsProvide],
        definitions: [ExtensionFactDefinition]
    ) -> ExtensionManifest {
        ExtensionManifest(
            identifier: "com.example.facts",
            name: "Facts",
            version: "1",
            runtime: .webAssembly,
            executable: "bin/facts.wasm",
            capabilities: capabilities,
            factDefinitions: definitions
        )
    }
}
