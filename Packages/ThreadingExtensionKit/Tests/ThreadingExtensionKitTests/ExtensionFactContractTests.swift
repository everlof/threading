import Foundation
import XCTest
@testable import ThreadingExtensionKit

final class ExtensionFactContractTests: XCTestCase {
    func testFactKeyVersionIsASeparateWireField() throws {
        let data = try sortedEncoder().encode(ExtensionFactKey(id: "gitlab.mr.state", version: 3))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"id\":\"gitlab.mr.state\",\"version\":3}")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "gitlab.mr.state")
        XCTAssertEqual(object["version"] as? Int, 3)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionFactKey.self, from: data), .init(
            id: "gitlab.mr.state",
            version: 3
        ))
    }

    func testEverySubjectHasAnExplicitStableWireShape() throws {
        let repository = ExtensionRepositoryKey(host: "gitlab.example", path: "group/project")
        let fixtures: [(ExtensionFactSubject, String)] = [
            (.session("s1"), "{\"id\":\"s1\",\"type\":\"session\"}"),
            (.project("p1"), "{\"id\":\"p1\",\"type\":\"project\"}"),
            (.terminal("t1"), "{\"id\":\"t1\",\"type\":\"terminal\"}"),
            (
                .repository(repository),
                "{\"repository\":{\"host\":\"gitlab.example\",\"path\":\"group\\/project\"},\"type\":\"repository\"}"
            ),
            (
                .repositoryBranch(repository: repository, branch: "release/1"),
                "{\"branch\":\"release\\/1\",\"repository\":{\"host\":\"gitlab.example\",\"path\":\"group\\/project\"},\"type\":\"repositoryBranch\"}"
            ),
        ]

        for (subject, expectedJSON) in fixtures {
            let data = try sortedEncoder().encode(subject)
            XCTAssertEqual(try JSONDecoder().decode(ExtensionFactSubject.self, from: data), subject)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), expectedJSON)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["type"] as? String, subject.kind.rawValue)
        }
    }

    func testEveryScalarHasAnExplicitStableWireShape() throws {
        let fixtures: [(ExtensionFactValue, String)] = [
            (.string("merged"), "{\"type\":\"string\",\"value\":\"merged\"}"),
            (.boolean(true), "{\"type\":\"boolean\",\"value\":true}"),
            (.integer(42), "{\"type\":\"integer\",\"value\":42}"),
            (.number(4.5), "{\"type\":\"number\",\"value\":4.5}"),
            (.date(Date(timeIntervalSinceReferenceDate: 123)), "{\"type\":\"date\",\"value\":123}"),
        ]
        for (value, expectedJSON) in fixtures {
            let data = try sortedEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(ExtensionFactValue.self, from: data), value)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), expectedJSON)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["type"] as? String, value.type.rawValue)
            XCTAssertNotNil(object["value"])
        }
    }

    func testFactRoundTripsPresentationWithoutChangingTheScalar() throws {
        let fact = ExtensionFact(
            key: .init(id: "gitlab.mr.state", version: 1),
            subject: .repositoryBranch(
                repository: .init(host: "gitlab.example", path: "group/project"),
                branch: "main"
            ),
            value: .string("merged"),
            label: "Merged",
            status: .positive,
            icon: .systemSymbol("checkmark.circle"),
            observedAt: Date(timeIntervalSinceReferenceDate: 456)
        )
        try fact.validate()
        let data = try JSONEncoder().encode(fact)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionFact.self, from: data), fact)
        XCTAssertEqual(fact.value, .string("merged"))
    }

    func testDefinitionDescribesTypeSubjectsAndUsages() throws {
        let definition = ExtensionFactDefinition(
            key: .init(id: "gitlab.mr.state"),
            displayName: "Merge request state",
            valueType: .string,
            subjectKinds: [.repositoryBranch],
            usages: [.filterable, .groupable, .presentable]
        )
        XCTAssertNoThrow(try definition.validate())
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionFactDefinition.self,
                from: JSONEncoder().encode(definition)
            ),
            definition
        )
    }

    func testContractBoundsUseUTF8BytesAndRejectNonFiniteValues() {
        XCTAssertThrowsError(try ExtensionFactKey(
            id: String(repeating: "é", count: 65),
            version: 0
        ).validationIssues().throwingIfPresent())
        XCTAssertFalse(ExtensionFactValue.string(
            String(repeating: "é", count: 513)
        ).validationIssues().isEmpty)
        XCTAssertFalse(ExtensionFactValue.number(.infinity).validationIssues().isEmpty)
        XCTAssertFalse(ExtensionFactValue.date(
            Date(timeIntervalSinceReferenceDate: .infinity)
        ).validationIssues().isEmpty)
    }

    func testRepositoryIdentityRequiresTheCanonicalCredentialFreeJoinForm() {
        let invalid: [ExtensionRepositoryKey] = [
            .init(host: "https://gitlab.example", path: "group/repo"),
            .init(host: "user:secret@gitlab.example", path: "group/repo"),
            .init(host: "GitLab.example", path: "group/repo"),
            .init(host: "gitlab.example:8443", path: "group/repo"),
            .init(host: "gitlab.example", path: "../private"),
            .init(host: "gitlab.example", path: "/tmp/repo"),
            .init(host: "gitlab.example", path: "group/repo.git"),
            .init(host: "gitlab.example", path: "group/repo?token=secret"),
            .init(host: "gitlab.example", path: "group/repo#fragment"),
        ]
        for repository in invalid {
            XCTAssertFalse(
                ExtensionFactSubject.repository(repository).validationIssues().isEmpty,
                "unexpectedly accepted \(repository)"
            )
        }
        XCTAssertTrue(ExtensionFactSubject.repository(.init(
            host: "gitlab.example",
            path: "group/repo"
        )).validationIssues().isEmpty)

        XCTAssertFalse(ExtensionFactSubject.repositoryBranch(
            repository: .init(host: "gitlab.example", path: "group/repo"),
            branch: String(repeating: "b", count: 513)
        ).validationIssues().isEmpty)
    }

    func testPresentationIconReferencesAreBoundedAndTrimmed() {
        let oversized = String(repeating: "x", count: ExtensionFact.maximumIconReferenceBytes + 1)
        for icon: ExtensionImageReference in [
            .hostAsset(oversized),
            .extensionResource(oversized),
            .systemSymbol(oversized),
            .hostAsset(" "),
            .extensionResource("../icon.png"),
            .systemSymbol(" symbol "),
        ] {
            let fact = ExtensionFact(
                key: .init(id: "gitlab.mr.state"),
                subject: .session("s1"),
                value: .string("merged"),
                icon: icon,
                observedAt: Date()
            )
            XCTAssertThrowsError(try fact.validate(), "unexpectedly accepted \(icon)")
        }
    }

    func testHostFactVocabularyIsPinnedUniqueAndReservedAcrossVersions() {
        let expectedIDs: Set<String> = [
            "session.project-id", "session.checkout-id", "session.title",
            "session.provider-id", "session.account-id", "session.activity",
            "session.activity.detailed", "session.branch", "session.parent-id",
            "session.is-side-chat", "session.is-archived", "session.uses-native-ui",
            "session.is-pinned", "session.is-snoozed", "session.snoozed-at",
            "session.snoozed-until", "session.wake-reason", "session.woke-at",
            "session.created-at", "session.last-active-at", "session.last-turn-at",
            "session.last-used-at", "session.manual-order", "session.model",
            "session.manager-id", "session.is-manager", "session.has-custom-conduct",
            "session.has-scheduled-start", "session.scheduled-start-at",
            "project.name", "project.manual-order", "project.is-scratchpad",
            "project.created-at", "project.repository-host", "project.repository-path",
            "project.branch", "terminal.project-id", "terminal.title", "terminal.branch",
            "terminal.manual-order", "terminal.created-at",
        ]
        XCTAssertEqual(Set(ExtensionHostFactKey.all).count, ExtensionHostFactKey.all.count)
        XCTAssertEqual(Set(ExtensionHostFactKey.all.map(\.id)), expectedIDs)
        XCTAssertTrue(ExtensionHostFactKey.all.allSatisfy { $0.version == 1 })
        XCTAssertTrue(ExtensionHostFactKey.all.allSatisfy { $0.validationIssues().isEmpty })
        XCTAssertTrue(ExtensionHostFactKey.isReserved(.init(id: "session.title", version: 2)))
        XCTAssertTrue(ExtensionHostFactKey.isReserved(.init(id: "project.future", version: 1)))
        XCTAssertTrue(ExtensionHostFactKey.isReserved(.init(id: "repository.host", version: 1)))
        XCTAssertFalse(ExtensionHostFactKey.isReserved(.init(id: "gitlab.mr.state", version: 1)))
    }
}

private func sortedEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

private extension Array where Element == ExtensionValidationIssue {
    func throwingIfPresent() throws {
        if !isEmpty { throw ExtensionValidationError(issues: self) }
    }
}
