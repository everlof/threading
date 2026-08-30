import Foundation
import ThreadingExtensionKit
import XCTest
@testable import Threading

@MainActor
final class ExtensionFactResolverTests: XCTestCase {
    private let key = ExtensionFactKey(id: "gitlab.mr.state")
    private let repository = ExtensionRepositoryKey(host: "gitlab.com", path: "group/repo")
    private let source = ComponentCustomizationSource(
        extensionIdentifier: "com.example.gitlab-state",
        processGeneration: "generation-1",
        order: 0
    )

    func testExactThenBranchThenRepositoryPrecedence() throws {
        let registry = ExtensionFactRegistry()
        let resolver = ExtensionFactResolver(registry: registry)
        try installHostCatalog(in: registry)
        try registry.replaceDefinitions([
            definition(subjectKinds: [.session, .project, .repository, .repositoryBranch]),
        ], from: source)

        try publishLinks(
            in: registry,
            projectID: "project-1",
            projectBranch: "main",
            sessions: [("session-1", "release"), ("session-2", nil)]
        )
        try registry.replaceFacts([
            fact(subject: .repository(repository), value: "repository"),
            fact(
                subject: .repositoryBranch(repository: repository, branch: "main"),
                value: "main"
            ),
            fact(
                subject: .repositoryBranch(repository: repository, branch: "release"),
                value: "release"
            ),
            fact(subject: .project("project-1"), value: "exact-project"),
            fact(subject: .session("session-1"), value: "exact-session"),
        ], replacing: [
            .repository(repository),
            .repositoryBranch(repository: repository, branch: "main"),
            .repositoryBranch(repository: repository, branch: "release"),
            .project("project-1"),
            .session("session-1"),
        ], from: source)

        XCTAssertEqual(
            resolver.fact(key, for: .project("project-1"))?.fact.value,
            .string("exact-project")
        )
        XCTAssertEqual(
            resolver.fact(key, for: .session("session-1"))?.fact.value,
            .string("exact-session")
        )

        try registry.replaceFacts(
            [],
            replacing: [.session("session-1")],
            from: source
        )

        XCTAssertEqual(
            resolver.fact(key, for: .session("session-1"))?.fact.value,
            .string("release"),
            "project-scoped facts must not inherit to sessions"
        )
        XCTAssertEqual(
            resolver.fact(key, for: .session("session-2"))?.fact.value,
            .string("repository"),
            "project-scoped facts must not inherit to sessions"
        )

        try registry.replaceFacts(
            [],
            replacing: [.project("project-1")],
            from: source
        )
        XCTAssertEqual(
            resolver.fact(key, for: .project("project-1"))?.fact.value,
            .string("main")
        )
    }

    func testSessionBranchMoveImmediatelyUsesNewDomainFact() throws {
        let registry = ExtensionFactRegistry()
        let resolver = ExtensionFactResolver(registry: registry)
        try installHostCatalog(in: registry)
        try registry.replaceDefinitions([definition()], from: source)
        try publishLinks(
            in: registry,
            projectID: "project-1",
            projectBranch: "main",
            sessions: [("session-1", "release")]
        )
        try registry.replaceFacts([
            fact(
                subject: .repositoryBranch(repository: repository, branch: "main"),
                value: "main"
            ),
            fact(
                subject: .repositoryBranch(repository: repository, branch: "release"),
                value: "release"
            ),
        ], replacing: [
            .repositoryBranch(repository: repository, branch: "main"),
            .repositoryBranch(repository: repository, branch: "release"),
        ], from: source)

        XCTAssertEqual(
            resolver.fact(key, for: .session("session-1"))?.fact.value,
            .string("release")
        )

        try registry.replaceHostFacts([
            hostFact(
                ExtensionHostFactKey.sessionProjectID,
                subject: .session("session-1"),
                value: "project-1"
            ),
            hostFact(
                ExtensionHostFactKey.sessionBranch,
                subject: .session("session-1"),
                value: "main"
            ),
        ], replacing: [.session("session-1")])

        XCTAssertEqual(
            resolver.fact(key, for: .session("session-1"))?.fact.value,
            .string("main")
        )
    }

    func testRepositoryFactReachesEveryCheckoutButNotUnknownOrTerminalSubjects() throws {
        let registry = ExtensionFactRegistry()
        let resolver = ExtensionFactResolver(registry: registry)
        try installHostCatalog(in: registry)
        try registry.replaceDefinitions([definition()], from: source)
        try publishLinks(
            in: registry,
            projectID: "project-1",
            projectBranch: nil,
            sessions: [("session-1", nil)]
        )
        try publishLinks(
            in: registry,
            projectID: "project-2",
            projectBranch: nil,
            sessions: [("session-2", nil)]
        )
        try registry.replaceFacts([
            fact(subject: .repository(repository), value: "opened"),
        ], replacing: [.repository(repository)], from: source)

        for subject: ExtensionFactSubject in [
            .project("project-1"), .project("project-2"),
            .session("session-1"), .session("session-2"),
        ] {
            XCTAssertEqual(resolver.fact(key, for: subject)?.fact.value, .string("opened"))
        }
        XCTAssertNil(resolver.fact(key, for: .project("unknown")))
        XCTAssertNil(resolver.fact(key, for: .session("unknown")))
        XCTAssertNil(resolver.fact(key, for: .terminal("terminal-1")))
    }

    func testPartialOrNoncanonicalHostIdentityDoesNotJoin() throws {
        let registry = ExtensionFactRegistry()
        let resolver = ExtensionFactResolver(registry: registry)
        try installHostCatalog(in: registry)
        try registry.replaceDefinitions([definition()], from: source)
        try registry.replaceHostFacts([
            hostFact(
                ExtensionHostFactKey.projectRepositoryHost,
                subject: .project("partial"),
                value: repository.host
            ),
            hostFact(
                ExtensionHostFactKey.projectRepositoryHost,
                subject: .project("unsafe"),
                value: "https://gitlab.com/token@example"
            ),
            hostFact(
                ExtensionHostFactKey.projectRepositoryPath,
                subject: .project("unsafe"),
                value: repository.path
            ),
        ], replacing: [.project("partial"), .project("unsafe")])
        try registry.replaceFacts([
            fact(subject: .repository(repository), value: "must-not-leak"),
        ], replacing: [.repository(repository)], from: source)

        XCTAssertNil(resolver.fact(key, for: .project("partial")))
        XCTAssertNil(resolver.fact(key, for: .project("unsafe")))
    }

    func testFiveThousandSessionLookupsUseOnlyBoundedInMemoryFacts() throws {
        var clockReads = 0
        let registry = ExtensionFactRegistry(now: {
            clockReads += 1
            return Date(timeIntervalSinceReferenceDate: 10)
        })
        let resolver = ExtensionFactResolver(registry: registry)
        try installHostCatalog(in: registry)
        try registry.replaceDefinitions([definition()], from: source)

        let project = ExtensionFactSubject.project("project-1")
        var replacements: [ExtensionHostFactReplacement] = [
            .init(facts: [
                hostFact(
                    ExtensionHostFactKey.projectRepositoryHost,
                    subject: project,
                    value: repository.host
                ),
                hostFact(
                    ExtensionHostFactKey.projectRepositoryPath,
                    subject: project,
                    value: repository.path
                ),
            ], subjects: [project]),
        ]
        for batchStart in stride(from: 0, to: 5_000, by: 1_000) {
            let subjects = Set((batchStart..<batchStart + 1_000).map {
                ExtensionFactSubject.session("session-\($0)")
            })
            let facts = subjects.map {
                hostFact(ExtensionHostFactKey.sessionProjectID, subject: $0, value: "project-1")
            }
            replacements.append(.init(facts: facts, subjects: subjects))
        }
        try registry.replaceHostFacts(replacements)
        try registry.replaceFacts([
            fact(subject: .repository(repository), value: "opened"),
        ], replacing: [.repository(repository)], from: source)
        let clockReadsAfterPublication = clockReads

        for index in 0..<5_000 {
            XCTAssertEqual(
                resolver.fact(key, for: .session("session-\(index)"))?.fact.value,
                .string("opened")
            )
        }
        XCTAssertEqual(clockReads, clockReadsAfterPublication)
    }

    private func installHostCatalog(in registry: ExtensionFactRegistry) throws {
        try registry.replaceHostDefinitions(HostFactCatalog.definitions)
    }

    private func publishLinks(
        in registry: ExtensionFactRegistry,
        projectID: String,
        projectBranch: String?,
        sessions: [(String, String?)]
    ) throws {
        let project = ExtensionFactSubject.project(projectID)
        var projectFacts = [
            hostFact(
                ExtensionHostFactKey.projectRepositoryHost,
                subject: project,
                value: repository.host
            ),
            hostFact(
                ExtensionHostFactKey.projectRepositoryPath,
                subject: project,
                value: repository.path
            ),
        ]
        if let projectBranch {
            projectFacts.append(hostFact(
                ExtensionHostFactKey.projectBranch,
                subject: project,
                value: projectBranch
            ))
        }
        try registry.replaceHostFacts(projectFacts, replacing: [project])

        for (sessionID, branch) in sessions {
            let session = ExtensionFactSubject.session(sessionID)
            var sessionFacts = [hostFact(
                ExtensionHostFactKey.sessionProjectID,
                subject: session,
                value: projectID
            )]
            if let branch {
                sessionFacts.append(hostFact(
                    ExtensionHostFactKey.sessionBranch,
                    subject: session,
                    value: branch
                ))
            }
            try registry.replaceHostFacts(sessionFacts, replacing: [session])
        }
    }

    private func definition(
        subjectKinds: Set<ExtensionFactSubjectKind> = [.repository, .repositoryBranch]
    ) -> ExtensionFactDefinition {
        ExtensionFactDefinition(
            key: key,
            displayName: "Merge request state",
            valueType: .string,
            subjectKinds: subjectKinds,
            usages: [.filterable, .groupable, .presentable]
        )
    }

    private func fact(subject: ExtensionFactSubject, value: String) -> ExtensionFact {
        ExtensionFact(
            key: key,
            subject: subject,
            value: .string(value),
            observedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
    }

    private func hostFact(
        _ key: ExtensionFactKey,
        subject: ExtensionFactSubject,
        value: String
    ) -> ExtensionFact {
        ExtensionFact(
            key: key,
            subject: subject,
            value: .string(value),
            observedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
    }
}
