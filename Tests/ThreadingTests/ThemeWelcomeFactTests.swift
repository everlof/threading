import Foundation
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// What a theme's `{fact:KEY}` reads on the Mac (`ThemeWelcomeFacts`): where a value is looked up
/// — the composer's project chain, then the application subject — the application subject living
/// in the registry under the same bounds, freshness and generation lifetime as every other, and
/// how each scalar is worded for a sentence.
@MainActor
final class ThemeWelcomeFactTests: XCTestCase {
    private let status = ExtensionFactKey(id: "ci.status")
    private let weather = ExtensionFactKey(id: "weather.summary")
    private let repository = ExtensionRepositoryKey(host: "github.com", path: "everlof/threading")
    private let project = ProjectID()
    private let source = ComponentCustomizationSource(
        extensionIdentifier: "com.example.welcome",
        processGeneration: "generation-1",
        order: 0
    )

    // MARK: - Lookup

    /// A project reads its own subject, then its repository branch, then its repository — the
    /// navigator's order — and only then the application; no project reads the application alone.
    func testAProjectReadsItsOwnChainBeforeTheApplication() throws {
        let registry = makeRegistry()
        let resolver = ExtensionFactResolver(registry: registry)
        try registry.replaceHostDefinitions(HostFactCatalog.definitions)
        try publishProjectRepository(in: registry, branch: "main")
        try registry.replaceDefinitions([
            definition(status, kinds: [.repository, .repositoryBranch, .application]),
        ], from: source)
        func read(_ project: ProjectID?) -> ExtensionFactValue? {
            ThemeWelcomeFacts.fact(status, project: project, resolver: resolver)?.value
        }

        XCTAssertNil(read(project), "nothing published is nothing read")
        try publish(status, "everywhere", on: .application, in: registry)
        XCTAssertEqual(read(project), .string("everywhere"))
        XCTAssertEqual(read(nil), .string("everywhere"), "no project reads the application alone")

        try publish(status, "repository", on: .repository(repository), in: registry)
        XCTAssertEqual(read(project), .string("repository"))
        XCTAssertEqual(read(nil), .string("everywhere"))

        let main = ExtensionFactSubject.repositoryBranch(repository: repository, branch: "main")
        try publish(status, "main", on: main, in: registry)
        XCTAssertEqual(read(project), .string("main"), "the checkout's branch is the nearest")
        XCTAssertEqual(read(ProjectID()), .string("everywhere"),
                       "a project with no repository falls through to the application")

        try registry.replaceFacts([], replacing: [main], from: source)
        XCTAssertEqual(read(project), .string("repository"))

        XCTAssertEqual(
            ThemeWelcomeFacts.fact(ExtensionHostFactKey.projectBranch, project: project, resolver: resolver)?
                .value,
            .string("main"),
            "a host-owned project fact resolves exactly, so {fact:project.branch} reads the branch"
        )

        let slot = ThemeWelcomeFactSource()
        XCTAssertNil(slot.fact(status, project: project), "no resolver installed, no fact")
        slot.resolver = resolver
        XCTAssertEqual(slot.fact(status, project: project)?.value, .string("repository"))
    }

    // MARK: - The Application Subject

    /// One subject every provider shares: each generation states at most 32 facts for it, and
    /// all of them together resolve at most 128 — the bounds every shared repository subject has.
    func testTheApplicationSubjectIsBoundedAndLivesWithItsGeneration() throws {
        let registry = makeRegistry()
        try registry.replaceDefinitions([definition(weather, kinds: [.application])], from: source)
        try publish(weather, "Sunny", on: .application, in: registry)
        XCTAssertEqual(registry.exactFact(weather, for: .application)?.fact.value, .string("Sunny"))

        let perSubject = ExtensionFactRegistry.maximumFactsPerSourceSubject
        let providers = ExtensionFactRegistry.maximumResolvedFactsPerSubject / perSubject
        for index in 0..<providers {
            let provider = ComponentCustomizationSource(
                extensionIdentifier: "com.example.provider-\(index)",
                processGeneration: "g",
                order: 1
            )
            let keys = (0..<perSubject).map { ExtensionFactKey(id: "p\(index).reading-\($0)") }
            try registry.replaceDefinitions(keys.map { definition($0, kinds: [.application]) }, from: provider)
            let facts = keys.map { fact($0, "x", on: .application) }
            if index == providers - 1 {
                XCTAssertThrowsError(
                    try registry.replaceFacts(facts, replacing: [.application], from: provider),
                    "the shared subject resolves at most \(ExtensionFactRegistry.maximumResolvedFactsPerSubject)"
                ) { error in
                    XCTAssertEqual(
                        error as? ExtensionFactRegistryError,
                        .tooManyResolvedFactsForSubject(
                            maximum: ExtensionFactRegistry.maximumResolvedFactsPerSubject
                        )
                    )
                }
            } else {
                XCTAssertNoThrow(try registry.replaceFacts(facts, replacing: [.application], from: provider))
            }
        }
        XCTAssertEqual(registry.exactFact(weather, for: .application)?.fact.value, .string("Sunny"),
                       "a refused publication leaves the accepted ones")

        registry.removeGeneration(
            extensionIdentifier: source.extensionIdentifier,
            processGeneration: source.processGeneration
        )
        XCTAssertNil(registry.exactFact(weather, for: .application),
                     "an application fact goes with the process generation that published it")
    }

    /// The registry's own freshness applies: fifteen minutes after its observation the value is
    /// gone from what resolves, and the expiry is announced like a publication, which is what
    /// renders a shown welcome line again.
    func testAStaleApplicationFactIsGoneAndItsExpiryIsAnnounced() throws {
        var now = Date(timeIntervalSinceReferenceDate: 10_000)
        let center = NotificationCenter()
        let registry = ExtensionFactRegistry(
            notificationCenter: center,
            now: { now },
            stalenessTimerScheduler: { _, _ in {} }
        )
        let resolver = ExtensionFactResolver(registry: registry)
        try registry.replaceDefinitions([definition(weather, kinds: [.application])], from: source)
        try registry.replaceFacts(
            [ExtensionFact(key: weather, subject: .application, value: .string("Rain"), observedAt: now)],
            replacing: [.application],
            from: source
        )
        let log = ChangeLog()
        let observations = AppEventObservations(center: center)
        observations.observe(ExtensionFactsDidChange.self) { log.changes.append($0.change) }

        now = now.addingTimeInterval(ExtensionFactRegistry.maximumProviderFactAge - 1)
        registry.refreshStaleness()
        XCTAssertEqual(ThemeWelcomeFacts.fact(weather, project: nil, resolver: resolver)?.value, .string("Rain"))
        XCTAssertTrue(log.changes.isEmpty)

        now = now.addingTimeInterval(1)
        registry.refreshStaleness()
        XCTAssertNil(ThemeWelcomeFacts.fact(weather, project: nil, resolver: resolver))
        XCTAssertEqual(log.changes, [.exact([ExtensionFactCell(subject: .application, key: weather)])])
        withExtendedLifetime(observations) {}
    }

    // MARK: - Wording

    /// A string is one trimmed line, capped with an ellipsis; a label, when the provider states
    /// one, is preferred over the raw value.
    func testAStringIsOneLineAndCappedAndALabelIsPreferred() {
        func text(_ value: String, label: String? = nil) -> String? {
            ThemeWelcomeFacts.text(
                for: ExtensionFact(key: status, subject: .application, value: .string(value),
                                   label: label, observedAt: Self.evening),
                at: Self.evening, calendar: Self.calendar, locale: Locale(identifier: "en_GB")
            )
        }
        XCTAssertEqual(text("  Deploy\n  frozen\t\u{0007} until\r\nFriday "), "Deploy frozen until Friday")
        XCTAssertNil(text(" \n\t "), "blank is no value")

        let bound = ThemeWelcomeFacts.maximumLength
        let exact = String(repeating: "a", count: bound)
        XCTAssertEqual(text(exact), exact, "a value at the bound is shown whole")
        XCTAssertEqual(text(exact + "b"), String(repeating: "a", count: bound - 1) + ThemeWelcomeFacts.ellipsis)
        let spaced = String(repeating: "a", count: bound - 2) + " tail"
        XCTAssertEqual(text(spaced), String(repeating: "a", count: bound - 2) + ThemeWelcomeFacts.ellipsis,
                       "the space before the cut is dropped, not left before the ellipsis")
        XCTAssertEqual(text(String(repeating: "é", count: 1_000))?.count, bound)

        XCTAssertEqual(text("success", label: "Passed"), "Passed")
        XCTAssertEqual(text("success", label: " \n "), "success", "a blank label is no label")
        XCTAssertEqual(text("success", label: String(repeating: "b", count: 300))?.count,
                       ThemeWelcomeFacts.maximumLength)
    }

    /// Numbers in the locale's own digits, booleans in the app's words, dates as a time today and
    /// a short date otherwise.
    func testNumbersBooleansAndDatesAreWordedForTheLocale() throws {
        func text(_ value: ExtensionFactValue, _ locale: String = "en_GB") -> String? {
            ThemeWelcomeFacts.text(
                for: value, at: Self.evening, calendar: Self.calendar, locale: Locale(identifier: locale)
            )
        }
        XCTAssertEqual(text(.integer(12_345), "en_US"), "12,345")
        let swedish = try XCTUnwrap(text(.integer(12_345), "sv_SE"))
        XCTAssertNotEqual(swedish, "12,345")
        XCTAssertEqual(swedish.filter(\.isNumber), "12345")
        XCTAssertEqual(text(.integer(-3)), "-3")
        XCTAssertEqual(text(.number(4.256), "en_US"), "4.26")
        XCTAssertEqual(text(.number(4.256), "sv_SE"), "4,26")
        XCTAssertEqual(text(.number(3)), "3")

        XCTAssertEqual(text(.boolean(true)), L10n.string("yes"))
        XCTAssertEqual(text(.boolean(false)), L10n.string("no"))
        XCTAssertNotEqual(L10n.string("yes"), L10n.string("no"))

        let today = try XCTUnwrap(Self.calendar.date(byAdding: .minute, value: -337, to: Self.evening))
        XCTAssertEqual(text(.date(today)), "14:05", "today reads as a time")
        let earlier = try XCTUnwrap(Self.calendar.date(byAdding: .day, value: -2, to: Self.evening))
        XCTAssertEqual(text(.date(earlier)), "3 Oct")
        let lastYear = try XCTUnwrap(Self.calendar.date(byAdding: .year, value: -1, to: earlier))
        XCTAssertEqual(text(.date(lastYear)), "3 Oct 2025")
    }

    // MARK: - Fixtures

    @MainActor
    private final class ChangeLog {
        var changes: [ExtensionFactChange] = []
    }

    private static var calendar: Calendar { ThemeWelcomeFixtures.calendar }
    /// Monday 5 October 2026, 19:42:30 UTC.
    private static var evening: Date { ThemeWelcomeFixtures.evening }

    private func makeRegistry() -> ExtensionFactRegistry {
        ExtensionFactRegistry(stalenessTimerScheduler: { _, _ in {} })
    }

    private func definition(
        _ key: ExtensionFactKey,
        kinds: Set<ExtensionFactSubjectKind>
    ) -> ExtensionFactDefinition {
        ExtensionFactDefinition(
            key: key,
            displayName: key.id,
            valueType: .string,
            subjectKinds: kinds,
            usages: [.presentable]
        )
    }

    private func fact(_ key: ExtensionFactKey, _ value: String, on subject: ExtensionFactSubject) -> ExtensionFact {
        ExtensionFact(key: key, subject: subject, value: .string(value), observedAt: .distantFuture)
    }

    private func publish(
        _ key: ExtensionFactKey,
        _ value: String,
        on subject: ExtensionFactSubject,
        in registry: ExtensionFactRegistry
    ) throws {
        try registry.replaceFacts([fact(key, value, on: subject)], replacing: [subject], from: source)
    }

    /// The host facts that join a project to its repository and branch, as the publisher states.
    private func publishProjectRepository(in registry: ExtensionFactRegistry, branch: String) throws {
        let subject = ExtensionFactSubject.project(HostFactPublisher.opaqueID(project))
        let facts = [
            (ExtensionHostFactKey.projectRepositoryHost, repository.host),
            (ExtensionHostFactKey.projectRepositoryPath, repository.path),
            (ExtensionHostFactKey.projectBranch, branch),
        ].map { key, value in
            ExtensionFact(
                key: key,
                subject: subject,
                value: .string(value),
                observedAt: Date(timeIntervalSinceReferenceDate: 1)
            )
        }
        try registry.replaceHostFacts(facts, replacing: [subject])
    }
}
