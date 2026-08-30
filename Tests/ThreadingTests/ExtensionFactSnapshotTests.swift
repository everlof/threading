import Foundation
@testable import Threading
import ThreadingExtensionKit
import XCTest

@MainActor
final class ExtensionFactSnapshotTests: XCTestCase {
    private let extensionKey = ExtensionFactKey(id: "gitlab.mr.state")
    private let source = ComponentCustomizationSource(
        extensionIdentifier: "com.example.gitlab",
        processGeneration: "generation-1",
        order: 0
    )

    func testSnapshotFreezesValuesProvidersAndSubjectsAtOneRevision() throws {
        let registry = ExtensionFactRegistry()
        try registry.replaceHostDefinitions(HostFactCatalog.definitions)
        try registry.replaceDefinitions([extensionDefinition()], from: source)
        try registry.replaceHostFacts([
            hostFact(
                ExtensionHostFactKey.sessionTitle,
                subject: .session("session-2"),
                value: .string("Second")
            ),
            hostFact(
                ExtensionHostFactKey.sessionTitle,
                subject: .session("session-1"),
                value: .string("First")
            ),
        ], replacing: [.session("session-1"), .session("session-2")])
        try registry.replaceFacts([
            extensionFact(subject: .session("session-1"), value: "opened"),
        ], replacing: [.session("session-1")], from: source)

        let frozen = registry.snapshot(consuming: [
            ExtensionHostFactKey.sessionTitle,
            extensionKey,
        ])
        XCTAssertEqual(frozen.sessionSubjects, [.session("session-1"), .session("session-2")])
        XCTAssertTrue(frozen.hasProvider(for: extensionKey))
        XCTAssertEqual(
            frozen.providers(for: extensionKey),
            [.extension(identifier: source.extensionIdentifier, processGeneration: source.processGeneration)]
        )
        XCTAssertEqual(
            frozen.exactFact(extensionKey, for: .session("session-1"))?.fact.value,
            .string("opened")
        )

        registry.removeGeneration(
            extensionIdentifier: source.extensionIdentifier,
            processGeneration: source.processGeneration
        )
        try registry.replaceHostFacts([], replacing: [.session("session-2")])
        let current = registry.snapshot(consuming: [
            ExtensionHostFactKey.sessionTitle,
            extensionKey,
        ])

        XCTAssertGreaterThan(current.revision, frozen.revision)
        XCTAssertFalse(current.hasProvider(for: extensionKey))
        XCTAssertEqual(current.sessionSubjects, [.session("session-1")])
        XCTAssertTrue(frozen.hasProvider(for: extensionKey))
        XCTAssertEqual(frozen.sessionSubjects, [.session("session-1"), .session("session-2")])
        XCTAssertEqual(
            frozen.exactFact(extensionKey, for: .session("session-1"))?.fact.value,
            .string("opened")
        )
    }

    func testDefinitionMakesProviderReadyBeforeAnySubjectValueExists() throws {
        let registry = ExtensionFactRegistry()
        let empty = registry.snapshot(consuming: [extensionKey])
        try registry.replaceDefinitions([extensionDefinition()], from: source)
        let ready = registry.snapshot(consuming: [extensionKey])

        XCTAssertGreaterThan(ready.revision, empty.revision)
        XCTAssertTrue(ready.hasProvider(for: extensionKey))
        XCTAssertEqual(ready.definition(for: extensionKey), extensionDefinition())
        XCTAssertNil(ready.exactFact(extensionKey, for: .session("missing")))
    }

    func testExtensionFactCannotInventASourceSession() throws {
        let registry = ExtensionFactRegistry()
        try registry.replaceHostDefinitions(HostFactCatalog.definitions)
        try registry.replaceDefinitions([extensionDefinition()], from: source)
        try registry.replaceHostFacts([
            hostFact(
                ExtensionHostFactKey.sessionTitle,
                subject: .session("host-session"),
                value: .string("Host session")
            ),
        ], replacing: [.session("host-session")])
        try registry.replaceFacts([
            extensionFact(subject: .session("invented-session"), value: "opened"),
        ], replacing: [.session("invented-session")], from: source)

        let snapshot = registry.snapshot(consuming: [extensionKey])

        XCTAssertEqual(snapshot.sessionSubjects, [.session("host-session")])
        XCTAssertNil(snapshot.exactFact(extensionKey, for: .session("invented-session")))
    }

    func testRevisionAdvancesOnlyForSemanticRegistryChanges() throws {
        let registry = ExtensionFactRegistry(now: {
            Date(timeIntervalSinceReferenceDate: 10)
        })
        let definition = hostDefinition(
            key: ExtensionHostFactKey.sessionTitle,
            type: .string,
            kinds: [.session],
            usages: [.searchable, .presentable]
        )
        try registry.replaceHostDefinitions([definition])
        let afterDefinition = registry.snapshot(consuming: []).revision
        try registry.replaceHostDefinitions([definition])
        XCTAssertEqual(registry.snapshot(consuming: []).revision, afterDefinition)

        let fact = hostFact(
            ExtensionHostFactKey.sessionTitle,
            subject: .session("session-1"),
            value: .string("Same")
        )
        try registry.replaceHostFacts([fact], replacing: [.session("session-1")])
        let afterFact = registry.snapshot(consuming: []).revision
        try registry.replaceHostFacts([fact], replacing: [.session("session-1")])
        XCTAssertEqual(registry.snapshot(consuming: []).revision, afterFact)

        try registry.replaceHostFacts([
            hostFact(
                ExtensionHostFactKey.sessionTitle,
                subject: .session("session-1"),
                value: .string("Changed")
            ),
        ], replacing: [.session("session-1")])
        XCTAssertGreaterThan(registry.snapshot(consuming: []).revision, afterFact)
    }

    func testSnapshotResolvesExplicitProjectScopeAndDomainInheritance() throws {
        let registry = ExtensionFactRegistry()
        let repository = ExtensionRepositoryKey(host: "gitlab.com", path: "group/repo")
        try registry.replaceHostDefinitions(HostFactCatalog.definitions)
        try registry.replaceDefinitions([extensionDefinition(
            subjectKinds: [.session, .project, .repository, .repositoryBranch]
        )], from: source)
        try registry.replaceHostFacts([
            hostFact(
                ExtensionHostFactKey.sessionProjectID,
                subject: .session("session-1"),
                value: .string("project-1")
            ),
            hostFact(
                ExtensionHostFactKey.sessionBranch,
                subject: .session("session-1"),
                value: .string("release")
            ),
            hostFact(
                ExtensionHostFactKey.projectRepositoryHost,
                subject: .project("project-1"),
                value: .string(repository.host)
            ),
            hostFact(
                ExtensionHostFactKey.projectRepositoryPath,
                subject: .project("project-1"),
                value: .string(repository.path)
            ),
            hostFact(
                ExtensionHostFactKey.projectName,
                subject: .project("project-1"),
                value: .string("Project One")
            ),
        ], replacing: [.session("session-1"), .project("project-1")])
        try registry.replaceFacts([
            extensionFact(
                subject: .repositoryBranch(repository: repository, branch: "release"),
                value: "merged"
            ),
        ], replacing: [
            .repositoryBranch(repository: repository, branch: "release"),
        ], from: source)

        let snapshot = registry.snapshot(consuming: [
            ExtensionHostFactKey.projectName,
            extensionKey,
        ])
        let project = snapshot.projectSubject(for: .session("session-1"))
        XCTAssertEqual(project, .project("project-1"))
        guard let project else {
            return XCTFail("Expected the session's project join")
        }
        XCTAssertEqual(
            snapshot.fact(ExtensionHostFactKey.projectName, for: project)?.fact.value,
            .string("Project One")
        )
        XCTAssertEqual(
            snapshot.fact(extensionKey, for: .session("session-1"))?.fact.value,
            .string("merged")
        )
        XCTAssertNil(snapshot.projectSubject(for: .session("unknown")))
        XCTAssertNil(snapshot.projectSubject(for: .project("project-1")))
    }

    func testSnapshotResolutionMatchesLiveResolverPrecedence() throws {
        let registry = ExtensionFactRegistry()
        let repository = ExtensionRepositoryKey(host: "gitlab.com", path: "group/repo")
        try registry.replaceHostDefinitions(HostFactCatalog.definitions)
        try registry.replaceDefinitions([extensionDefinition(
            subjectKinds: [
                .session, .project, .terminal, .repository, .repositoryBranch,
            ]
        )], from: source)
        try registry.replaceHostFacts([
            hostFact(
                ExtensionHostFactKey.projectRepositoryHost,
                subject: .project("project-1"),
                value: .string(repository.host)
            ),
            hostFact(
                ExtensionHostFactKey.projectRepositoryPath,
                subject: .project("project-1"),
                value: .string(repository.path)
            ),
            hostFact(
                ExtensionHostFactKey.sessionProjectID,
                subject: .session("exact-session"),
                value: .string("project-1")
            ),
            hostFact(
                ExtensionHostFactKey.sessionBranch,
                subject: .session("exact-session"),
                value: .string("release")
            ),
            hostFact(
                ExtensionHostFactKey.sessionProjectID,
                subject: .session("branch-session"),
                value: .string("project-1")
            ),
            hostFact(
                ExtensionHostFactKey.sessionBranch,
                subject: .session("branch-session"),
                value: .string("release")
            ),
            hostFact(
                ExtensionHostFactKey.sessionProjectID,
                subject: .session("repository-session"),
                value: .string("project-1")
            ),
        ], replacing: [
            .project("project-1"),
            .session("exact-session"),
            .session("branch-session"),
            .session("repository-session"),
        ])
        try registry.replaceFacts([
            extensionFact(subject: .repository(repository), value: "repository"),
            extensionFact(
                subject: .repositoryBranch(repository: repository, branch: "release"),
                value: "branch"
            ),
            extensionFact(subject: .project("project-1"), value: "project-exact"),
            extensionFact(subject: .session("exact-session"), value: "session-exact"),
            extensionFact(subject: .terminal("terminal-1"), value: "terminal-exact"),
        ], replacing: [
            .repository(repository),
            .repositoryBranch(repository: repository, branch: "release"),
            .project("project-1"),
            .session("exact-session"),
            .terminal("terminal-1"),
        ], from: source)

        let snapshot = registry.snapshot(consuming: [extensionKey])

        XCTAssertEqual(
            snapshot.fact(extensionKey, for: .session("exact-session"))?.fact.value,
            .string("session-exact")
        )
        XCTAssertEqual(
            snapshot.fact(extensionKey, for: .session("branch-session"))?.fact.value,
            .string("branch"),
            "A project's exact fact must not inherit implicitly to its sessions"
        )
        XCTAssertEqual(
            snapshot.fact(extensionKey, for: .session("repository-session"))?.fact.value,
            .string("repository")
        )
        XCTAssertEqual(
            snapshot.fact(extensionKey, for: .project("project-1"))?.fact.value,
            .string("project-exact")
        )
        XCTAssertEqual(
            snapshot.fact(extensionKey, for: .terminal("terminal-1"))?.fact.value,
            .string("terminal-exact")
        )
        XCTAssertNil(snapshot.fact(extensionKey, for: .terminal("terminal-2")))
    }

    func testProjectBranchReverseJoinReachesSessionsWhenSessionBranchDiffers() throws {
        let registry = ExtensionFactRegistry()
        let repository = ExtensionRepositoryKey(host: "gitlab.com", path: "group/repo")
        try registry.replaceHostDefinitions(HostFactCatalog.definitions)
        try registry.replaceDefinitions([extensionDefinition(
            subjectKinds: [.repositoryBranch]
        )], from: source)
        try registry.replaceHostFacts([
            hostFact(
                ExtensionHostFactKey.sessionProjectID,
                subject: .session("session-1"),
                value: .string("project-1")
            ),
            hostFact(
                ExtensionHostFactKey.sessionBranch,
                subject: .session("session-1"),
                value: .string("worktree-branch")
            ),
            hostFact(
                ExtensionHostFactKey.projectRepositoryHost,
                subject: .project("project-1"),
                value: .string(repository.host)
            ),
            hostFact(
                ExtensionHostFactKey.projectRepositoryPath,
                subject: .project("project-1"),
                value: .string(repository.path)
            ),
            hostFact(
                ExtensionHostFactKey.projectBranch,
                subject: .project("project-1"),
                value: .string("project-default")
            ),
        ], replacing: [.session("session-1"), .project("project-1")])
        let snapshot = registry.snapshot(consuming: [extensionKey])

        XCTAssertEqual(
            snapshot.affectedSourceSessionIDs(by: [.init(
                subject: .repositoryBranch(
                    repository: repository,
                    branch: "project-default"
                ),
                key: extensionKey
            )]),
            ["session-1"]
        )
        XCTAssertEqual(
            snapshot.affectedSourceSessionIDs(by: [.init(
                subject: .repositoryBranch(
                    repository: repository,
                    branch: "worktree-branch"
                ),
                key: extensionKey
            )]),
            ["session-1"]
        )
    }

    func testExactPatchSharesItsImmutableBaseTable() throws {
        let registry = ExtensionFactRegistry()
        try registry.replaceHostDefinitions(HostFactCatalog.definitions)
        try registry.replaceDefinitions([extensionDefinition()], from: source)
        try registry.replaceHostFacts([
            hostFact(
                ExtensionHostFactKey.sessionTitle,
                subject: .session("session-1"),
                value: .string("Session")
            ),
        ], replacing: [.session("session-1")])
        try registry.replaceFacts([
            extensionFact(subject: .session("session-1"), value: "before"),
        ], replacing: [.session("session-1")], from: source)
        let snapshot = registry.snapshot(consuming: [extensionKey])

        try registry.replaceFacts([
            extensionFact(subject: .session("session-1"), value: "after"),
        ], replacing: [.session("session-1")], from: source)
        let patch = try XCTUnwrap(registry.patch(
            snapshot,
            exactCells: [.init(subject: .session("session-1"), key: extensionKey)],
            consuming: [extensionKey]
        ))

        XCTAssertEqual(
            patch.snapshot.baseStorageIdentityForTesting,
            snapshot.baseStorageIdentityForTesting,
            "an exact patch must path-copy its overlay, not the catalogue fact table"
        )
        XCTAssertEqual(
            snapshot.exactFact(extensionKey, for: .session("session-1"))?.fact.value,
            .string("before")
        )
        XCTAssertEqual(
            patch.snapshot.exactFact(extensionKey, for: .session("session-1"))?.fact.value,
            .string("after")
        )
    }

    private func extensionDefinition(
        subjectKinds: Set<ExtensionFactSubjectKind> = [.session]
    ) -> ExtensionFactDefinition {
        .init(
            key: extensionKey,
            displayName: "Merge request state",
            valueType: .string,
            subjectKinds: subjectKinds,
            usages: [.filterable, .sortable, .groupable, .searchable, .presentable]
        )
    }

    private func hostDefinition(
        key: ExtensionFactKey,
        type: ExtensionFactValueType,
        kinds: Set<ExtensionFactSubjectKind>,
        usages: Set<ExtensionFactUsage>
    ) -> ExtensionFactDefinition {
        .init(
            key: key,
            displayName: "Host fact",
            valueType: type,
            subjectKinds: kinds,
            usages: usages
        )
    }

    private func hostFact(
        _ key: ExtensionFactKey,
        subject: ExtensionFactSubject,
        value: ExtensionFactValue
    ) -> ExtensionFact {
        .init(
            key: key,
            subject: subject,
            value: value,
            observedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
    }

    private func extensionFact(
        subject: ExtensionFactSubject,
        value: String
    ) -> ExtensionFact {
        .init(
            key: extensionKey,
            subject: subject,
            value: .string(value),
            observedAt: .distantFuture
        )
    }
}
