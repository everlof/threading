import Foundation
import XCTest
import ThreadingExtensionKit
@testable import Threading

@MainActor
final class ExtensionFactRegistryTests: XCTestCase {
    func testHostFactsAreSynchronouslyReadableWithTheirDefinition() throws {
        let receivedAt = Date(timeIntervalSinceReferenceDate: 2)
        let registry = ExtensionFactRegistry(now: { receivedAt })
        let definition = makeDefinition(key: ExtensionHostFactKey.sessionTitle)
        try registry.replaceHostDefinitions([definition])
        let fact = makeFact(
            key: definition.key,
            subject: .session("s1"),
            value: "First"
        )
        try registry.replaceHostFacts([fact], replacing: [.session("s1")])

        XCTAssertEqual(registry.definition(for: definition.key), definition)
        XCTAssertEqual(registry.exactFact(definition.key, for: .session("s1")), .init(
            fact: fact,
            definition: definition,
            source: .host,
            receivedAt: receivedAt
        ))
        XCTAssertEqual(registry.exactFacts(for: .session("s1")).count, 1)
    }

    func testInvalidReplacementIsAtomic() throws {
        let registry = ExtensionFactRegistry()
        let definition = makeDefinition(key: ExtensionHostFactKey.sessionTitle)
        try registry.replaceHostDefinitions([definition])
        let original = makeFact(
            key: definition.key,
            subject: .session("s1"),
            value: "Original"
        )
        try registry.replaceHostFacts([original], replacing: [.session("s1")])

        let invalid = ExtensionFact(
            key: definition.key,
            subject: .session("s1"),
            value: .boolean(true),
            observedAt: Date()
        )
        XCTAssertThrowsError(try registry.replaceHostFacts(
            [invalid],
            replacing: [.session("s1")]
        )) { error in
            XCTAssertEqual(
                error as? ExtensionFactRegistryError,
                .incompatibleFact(definition.key)
            )
        }
        XCTAssertEqual(
            registry.exactFact(definition.key, for: .session("s1"))?.fact.value,
            .string("Original")
        )
    }

    func testBulkHostReplacementRejectsEveryBatchAtomically() throws {
        let center = NotificationCenter()
        let registry = ExtensionFactRegistry(notificationCenter: center)
        let definition = makeDefinition(key: ExtensionHostFactKey.sessionTitle)
        try registry.replaceHostDefinitions([definition])
        var changes: [ExtensionFactChange] = []
        let token = center.addObserver(
            forName: ExtensionFactsDidChange.name,
            object: nil,
            queue: nil
        ) { notification in
            if let event = notification.object as? ExtensionFactsDidChange {
                changes.append(event.change)
            }
        }
        defer { center.removeObserver(token) }

        let first = makeFact(
            key: definition.key,
            subject: .session("first"),
            value: "would-have-committed"
        )
        let invalid = ExtensionFact(
            key: definition.key,
            subject: .session("second"),
            value: .boolean(true),
            observedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        XCTAssertThrowsError(try registry.replaceHostFacts([
            .init(facts: [first], subjects: [.session("first")]),
            .init(facts: [invalid], subjects: [.session("second")]),
        ])) { error in
            XCTAssertEqual(
                error as? ExtensionFactRegistryError,
                .incompatibleFact(definition.key)
            )
        }

        XCTAssertTrue(registry.exactFacts(for: .session("first")).isEmpty)
        XCTAssertTrue(registry.exactFacts(for: .session("second")).isEmpty)
        XCTAssertTrue(changes.isEmpty)
    }

    func testDuplicateCellsAndOutsideScopeAreRejected() throws {
        let registry = ExtensionFactRegistry()
        let definition = makeDefinition(key: ExtensionHostFactKey.sessionTitle)
        try registry.replaceHostDefinitions([definition])
        let fact = makeFact(key: definition.key, subject: .session("s1"), value: "A")

        XCTAssertThrowsError(try registry.replaceHostFacts(
            [fact, fact],
            replacing: [.session("s1")]
        )) { error in
            XCTAssertEqual(
                error as? ExtensionFactRegistryError,
                .duplicateFact(.init(subject: .session("s1"), key: definition.key))
            )
        }
        XCTAssertThrowsError(try registry.replaceHostFacts(
            [fact],
            replacing: [.session("other")]
        )) { error in
            XCTAssertEqual(
                error as? ExtensionFactRegistryError,
                .factOutsideReplacementScope(.session("s1"))
            )
        }
    }

    func testHostAndExtensionNamespacesCannotBeSquatted() throws {
        let registry = ExtensionFactRegistry()
        let source = makeSource("com.example.provider", generation: "g1", order: 0)
        XCTAssertThrowsError(try registry.replaceDefinitions(
            [makeDefinition(key: .init(id: "session.future", version: 9))],
            from: source
        )) { error in
            XCTAssertEqual(
                error as? ExtensionFactRegistryError,
                .reservedHostKey(.init(id: "session.future", version: 9))
            )
        }
        XCTAssertThrowsError(try registry.replaceHostDefinitions([
            makeDefinition(key: .init(id: "com.example.fact")),
        ])) { error in
            XCTAssertEqual(
                error as? ExtensionFactRegistryError,
                .hostKeyRequired(.init(id: "com.example.fact"))
            )
        }
    }

    func testConflictingLiveDefinitionsAreRejected() throws {
        let registry = ExtensionFactRegistry()
        let key = ExtensionFactKey(id: "gitlab.mr.state")
        let first = makeSource("com.example.first", generation: "g1", order: 0)
        let second = makeSource("com.example.second", generation: "g1", order: 1)
        try registry.replaceDefinitions([makeDefinition(key: key)], from: first)

        let conflict = ExtensionFactDefinition(
            key: key,
            displayName: "State",
            valueType: .boolean,
            subjectKinds: [.session],
            usages: [.filterable]
        )
        XCTAssertThrowsError(try registry.replaceDefinitions([conflict], from: second)) {
            error in
            XCTAssertEqual(
                error as? ExtensionFactRegistryError,
                .conflictingDefinition(key)
            )
        }
        XCTAssertEqual(registry.definition(for: key)?.valueType, .string)
    }

    func testStableSourceOrderWinsAndRemovalFallsBack() throws {
        let registry = ExtensionFactRegistry()
        let key = ExtensionFactKey(id: "gitlab.mr.state")
        let first = makeSource("com.example.first", generation: "g1", order: 0)
        let second = makeSource("com.example.second", generation: "g1", order: 1)
        let definition = makeDefinition(key: key)
        try registry.replaceDefinitions([definition], from: second)
        try registry.replaceFacts(
            [makeFact(key: key, subject: .session("s1"), value: "second")],
            replacing: [.session("s1")],
            from: second
        )
        try registry.replaceDefinitions([definition], from: first)
        try registry.replaceFacts(
            [makeFact(key: key, subject: .session("s1"), value: "first")],
            replacing: [.session("s1")],
            from: first
        )

        XCTAssertEqual(
            registry.exactFact(key, for: .session("s1"))?.fact.value,
            .string("first")
        )
        registry.removeGeneration(
            extensionIdentifier: first.extensionIdentifier,
            processGeneration: first.processGeneration
        )
        XCTAssertEqual(
            registry.exactFact(key, for: .session("s1"))?.fact.value,
            .string("second")
        )
    }

    func testRegisteredFactCatalogUsesOnlyWinningMetadataAndFallsBackOnRemoval() throws {
        let registry = ExtensionFactRegistry()
        let key = ExtensionFactKey(id: "example.shared-state")
        let first = makeSource("com.example.first", generation: "g1", order: 0)
        let second = makeSource("com.example.second", generation: "g1", order: 1)
        let winner = ExtensionFactDefinition(
            key: key,
            displayName: "Winner Group",
            valueType: .string,
            subjectKinds: [.session],
            usages: [.groupable]
        )
        let fallback = ExtensionFactDefinition(
            key: key,
            displayName: "Fallback Sort",
            valueType: .string,
            subjectKinds: [.session],
            usages: [.sortable]
        )
        try registry.replaceDefinitions([fallback], from: second)
        try registry.replaceDefinitions([winner], from: first)

        XCTAssertEqual(registry.definition(for: key), winner)
        XCTAssertEqual(registry.registeredFactChoices(
            for: .groupable,
            selectedKey: nil
        ), [.available(winner)])
        XCTAssertTrue(registry.registeredFactChoices(
            for: .sortable,
            selectedKey: nil
        ).isEmpty, "Losing-provider usages must not be merged into the winning definition")

        registry.removeGeneration(
            extensionIdentifier: first.extensionIdentifier,
            processGeneration: first.processGeneration
        )
        XCTAssertEqual(registry.definition(for: key), fallback)
        XCTAssertEqual(registry.registeredFactChoices(
            for: .sortable,
            selectedKey: nil
        ), [.available(fallback)])
    }

    func testRegisteredFactCatalogIsBoundedAndKeepsEverySelectionClearable() throws {
        let registry = ExtensionFactRegistry()
        let first = makeSource("com.example.catalog-a", generation: "g1", order: 0)
        let second = makeSource("com.example.catalog-b", generation: "g1", order: 1)
        let definitions = (0..<130).map { index in
            ExtensionFactDefinition(
                key: .init(id: String(format: "example.fact.%03d", index)),
                displayName: String(format: "Fact %03d", index),
                valueType: .string,
                subjectKinds: [.session],
                usages: [.groupable, .sortable]
            )
        }
        try registry.replaceDefinitions(Array(definitions.prefix(128)), from: first)
        try registry.replaceDefinitions(Array(definitions.suffix(2)), from: second)

        let ordinary = registry.registeredFactChoices(for: .groupable, selectedKey: nil)
        XCTAssertEqual(ordinary.count, 128)
        XCTAssertEqual(ordinary.first?.key, definitions[0].key)
        XCTAssertEqual(ordinary.last?.key, definitions[127].key)

        let outside = registry.registeredFactChoices(
            for: .groupable,
            selectedKey: definitions[129].key
        )
        XCTAssertEqual(outside.count, 128)
        XCTAssertTrue(outside.contains { $0.key == definitions[129].key })
        XCTAssertFalse(outside.contains { $0.key == definitions[127].key })

        let missing = ExtensionFactKey(id: "example.removed-selection")
        let unavailable = registry.registeredFactChoices(
            for: .groupable,
            selectedKey: missing
        )
        XCTAssertEqual(unavailable.count, 128)
        XCTAssertEqual(unavailable.last, .unavailable(missing))
        XCTAssertEqual(unavailable.dropLast().count, 127)
    }

    func testRegisteredFactCatalogFiltersUnsupportedKindsAndIneligibleSelection() throws {
        let registry = ExtensionFactRegistry()
        let source = makeSource("com.example.eligibility", generation: "g1", order: 0)
        let projectOnly = ExtensionFactDefinition(
            key: .init(id: "example.project-only"),
            displayName: "Project only",
            valueType: .string,
            subjectKinds: [.project],
            usages: [.groupable]
        )
        let terminalOnly = ExtensionFactDefinition(
            key: .init(id: "example.terminal-only"),
            displayName: "Terminal only",
            valueType: .string,
            subjectKinds: [.terminal],
            usages: [.groupable]
        )
        let repository = ExtensionFactDefinition(
            key: .init(id: "example.repository"),
            displayName: "Repository",
            valueType: .string,
            subjectKinds: [.repository],
            usages: [.groupable]
        )
        try registry.replaceDefinitions([projectOnly, terminalOnly, repository], from: source)

        XCTAssertEqual(
            registry.registeredFactChoices(for: .groupable, selectedKey: nil),
            [.available(repository)]
        )
        XCTAssertEqual(
            registry.registeredFactChoices(
                for: .groupable,
                selectedKey: projectOnly.key
            ),
            [.available(repository), .unavailable(projectOnly.key)]
        )
    }

    func testRegisteredFactSelectionSurvivesEmptyStaleRemovedAndReturningProvider() throws {
        var referenceDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let registry = ExtensionFactRegistry(now: { referenceDate })
        let key = ExtensionFactKey(id: "example.returning-state", version: 1)
        let definition = ExtensionFactDefinition(
            key: key,
            displayName: "Returning State",
            valueType: .string,
            subjectKinds: [.session],
            usages: [.groupable]
        )
        let first = makeSource("com.example.returning", generation: "g1", order: 0)
        try registry.replaceDefinitions([definition], from: first)
        XCTAssertEqual(
            registry.registeredFactChoices(for: .groupable, selectedKey: key),
            [.available(definition)],
            "A live definition is selectable before it has any values"
        )

        let subject = ExtensionFactSubject.session("session")
        try registry.replaceFacts(
            [makeFact(key: key, subject: subject, value: "open", observedAt: referenceDate)],
            replacing: [subject],
            from: first
        )
        referenceDate = referenceDate.addingTimeInterval(
            ExtensionFactRegistry.maximumProviderFactAge
        )
        registry.refreshStaleness()
        XCTAssertNil(registry.exactFact(key, for: subject))
        XCTAssertEqual(
            registry.registeredFactChoices(for: .groupable, selectedKey: key),
            [.available(definition)],
            "Value expiry must not remove a live provider definition from the picker"
        )

        registry.removeGeneration(
            extensionIdentifier: first.extensionIdentifier,
            processGeneration: first.processGeneration
        )
        XCTAssertEqual(
            registry.registeredFactChoices(for: .groupable, selectedKey: key),
            [.unavailable(key)]
        )

        let returning = makeSource("com.example.returning", generation: "g2", order: 0)
        try registry.replaceDefinitions([definition], from: returning)
        XCTAssertEqual(
            registry.registeredFactChoices(for: .groupable, selectedKey: key),
            [.available(definition)]
        )
    }

    /// Scaling gate: ordinary installs expose tens or hundreds of definitions. This fixture
    /// registers 5,000 winning definitions across realistic bounded providers, then measures the
    /// user-frequency paths: opening the 128-row catalog and snapshotting one selected key.
    func testStressRegisteredFactCatalogWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment[
            "THREADING_NAVIGATOR_FACT_CATALOG_STRESS"
        ] == "1" else {
            throw XCTSkip(
                "Set THREADING_NAVIGATOR_FACT_CATALOG_STRESS=1 for the 5,000-definition fixture"
            )
        }

        let definitionCount = ExtensionFactRegistry.registeredFactCatalogStressDefinitionCount
        let definitionsPerProvider = 125
        XCTAssertEqual(definitionCount % definitionsPerProvider, 0)
        let registry = ExtensionFactRegistry()
        var selectedDefinition: ExtensionFactDefinition?
        let registrationStart = CFAbsoluteTimeGetCurrent()
        for providerIndex in 0..<(definitionCount / definitionsPerProvider) {
            let definitions = (0..<definitionsPerProvider).map { localIndex in
                let index = providerIndex * definitionsPerProvider + localIndex
                return ExtensionFactDefinition(
                    key: .init(id: String(format: "example.stress.fact-%04d", index)),
                    displayName: String(format: "Stress Fact %04d", index),
                    valueType: .string,
                    subjectKinds: [.session],
                    usages: [.groupable, .sortable]
                )
            }
            selectedDefinition = definitions.last
            try registry.replaceDefinitions(
                definitions,
                from: makeSource(
                    String(format: "com.example.stress.provider-%02d", providerIndex),
                    generation: "g1",
                    order: providerIndex
                )
            )
        }
        let registrationMilliseconds = (CFAbsoluteTimeGetCurrent() - registrationStart) * 1_000
        let selected = try XCTUnwrap(selectedDefinition)

        let catalogStart = CFAbsoluteTimeGetCurrent()
        let choices = registry.registeredFactChoices(
            for: .groupable,
            selectedKey: selected.key
        )
        let catalogMilliseconds = (CFAbsoluteTimeGetCurrent() - catalogStart) * 1_000
        let snapshotStart = CFAbsoluteTimeGetCurrent()
        let snapshot = registry.snapshot(consuming: [selected.key])
        let snapshotMilliseconds = (CFAbsoluteTimeGetCurrent() - snapshotStart) * 1_000

        XCTAssertEqual(choices.count, 128)
        XCTAssertTrue(choices.contains { $0.key == selected.key })
        XCTAssertEqual(snapshot.definition(for: selected.key), selected)
        XCTAssertTrue(snapshot.hasProvider(for: selected.key))
        print(String(
            format: "THREADING_PERF navigator-registered-facts definitions=%d choices=%d "
                + "registration_ms=%.3f catalog_ms=%.3f snapshot_ms=%.3f",
            definitionCount,
            choices.count,
            registrationMilliseconds,
            catalogMilliseconds,
            snapshotMilliseconds
        ))
    }

    func testEqualSourceOrdersResolveByIdentifierRegardlessOfPublicationOrder() throws {
        let registry = ExtensionFactRegistry()
        let key = ExtensionFactKey(id: "gitlab.mr.state")
        let alphabeticallyFirst = makeSource("com.example.alpha", generation: "g1", order: 7)
        let alphabeticallySecond = makeSource("com.example.zulu", generation: "g1", order: 7)
        let definition = makeDefinition(key: key)

        try registry.replaceDefinitions([definition], from: alphabeticallySecond)
        try registry.replaceFacts(
            [makeFact(key: key, subject: .session("s1"), value: "zulu")],
            replacing: [.session("s1")],
            from: alphabeticallySecond
        )
        try registry.replaceDefinitions([definition], from: alphabeticallyFirst)
        try registry.replaceFacts(
            [makeFact(key: key, subject: .session("s1"), value: "alpha")],
            replacing: [.session("s1")],
            from: alphabeticallyFirst
        )

        XCTAssertEqual(
            registry.exactFact(key, for: .session("s1"))?.fact.value,
            .string("alpha")
        )
    }

    func testEmptyScopedReplacementRemovesOnlyThatSubject() throws {
        let registry = ExtensionFactRegistry()
        let source = makeSource("com.example.provider", generation: "g1", order: 0)
        let key = ExtensionFactKey(id: "gitlab.mr.state")
        try registry.replaceDefinitions([makeDefinition(key: key)], from: source)
        try registry.replaceFacts([
            makeFact(key: key, subject: .session("s1"), value: "one"),
            makeFact(key: key, subject: .session("s2"), value: "two"),
        ], replacing: [.session("s1"), .session("s2")], from: source)

        try registry.replaceFacts([], replacing: [.session("s1")], from: source)
        XCTAssertNil(registry.exactFact(key, for: .session("s1")))
        XCTAssertEqual(
            registry.exactFact(key, for: .session("s2"))?.fact.value,
            .string("two")
        )
    }

    func testUnchangedHostFactPreservesObservationAndPostsNoChange() throws {
        let center = NotificationCenter()
        var receipt = Date(timeIntervalSinceReferenceDate: 10)
        let registry = ExtensionFactRegistry(
            notificationCenter: center,
            now: { receipt }
        )
        let definition = makeDefinition(key: ExtensionHostFactKey.sessionTitle)
        try registry.replaceHostDefinitions([definition])
        let firstDate = Date(timeIntervalSinceReferenceDate: 1)
        try registry.replaceHostFacts([
            makeFact(
                key: definition.key,
                subject: .session("s1"),
                value: "Same",
                observedAt: firstDate
            ),
        ], replacing: [.session("s1")])

        var events: [ExtensionFactChange] = []
        let token = center.addObserver(
            forName: ExtensionFactsDidChange.name,
            object: nil,
            queue: nil
        ) { notification in
            if let event = notification.object as? ExtensionFactsDidChange {
                events.append(event.change)
            }
        }
        defer { center.removeObserver(token) }

        receipt = Date(timeIntervalSinceReferenceDate: 20)
        try registry.replaceHostFacts([
            makeFact(
                key: definition.key,
                subject: .session("s1"),
                value: "Same",
                observedAt: Date(timeIntervalSinceReferenceDate: 2)
            ),
        ], replacing: [.session("s1")])
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(
            registry.exactFact(definition.key, for: .session("s1"))?.fact.observedAt,
            firstDate
        )
        XCTAssertEqual(
            registry.exactFact(definition.key, for: .session("s1"))?.receivedAt,
            Date(timeIntervalSinceReferenceDate: 10)
        )
    }

    func testProviderReceiptBoundsFreshnessAndAdvancesOnRepublish() throws {
        let center = NotificationCenter()
        var receipt = Date(timeIntervalSinceReferenceDate: 10)
        let registry = ExtensionFactRegistry(
            notificationCenter: center,
            now: { receipt }
        )
        let source = makeSource("com.example.provider", generation: "g1", order: 0)
        let key = ExtensionFactKey(id: "gitlab.mr.state")
        let subject = ExtensionFactSubject.repository(
            .init(host: "gitlab.com", path: "group/repo")
        )
        let definition = makeDefinition(
            key: key,
            subjectKinds: [.repository]
        )
        let providerFuture = Date(timeIntervalSinceReferenceDate: 1_000)
        let fact = makeFact(
            key: key,
            subject: subject,
            value: "opened",
            observedAt: providerFuture
        )
        try registry.replaceDefinitions([definition], from: source)
        try registry.replaceFacts([fact], replacing: [subject], from: source)

        XCTAssertEqual(registry.exactFact(key, for: subject)?.receivedAt, receipt)
        XCTAssertEqual(registry.exactFact(key, for: subject)?.freshnessDate, receipt)

        var changes: [ExtensionFactChange] = []
        let token = center.addObserver(
            forName: ExtensionFactsDidChange.name,
            object: nil,
            queue: nil
        ) { notification in
            if let event = notification.object as? ExtensionFactsDidChange {
                changes.append(event.change)
            }
        }
        defer { center.removeObserver(token) }

        receipt = Date(timeIntervalSinceReferenceDate: 20)
        try registry.replaceFacts([fact], replacing: [subject], from: source)

        XCTAssertEqual(registry.exactFact(key, for: subject)?.receivedAt, receipt)
        XCTAssertEqual(registry.exactFact(key, for: subject)?.freshnessDate, receipt)
        XCTAssertEqual(changes, [.exact([.init(subject: subject, key: key)])])
    }

    func testProviderObservationAlreadyOutsideHostFreshnessWindowResolvesMissing() throws {
        let referenceDate = Date(timeIntervalSinceReferenceDate: 10_000)
        let registry = ExtensionFactRegistry(now: { referenceDate })
        let source = makeSource("com.example.provider", generation: "g1", order: 0)
        let key = ExtensionFactKey(id: "gitlab.mr.state")
        let subject = ExtensionFactSubject.session("s1")
        try registry.replaceDefinitions([makeDefinition(key: key)], from: source)
        try registry.replaceFacts([
            makeFact(
                key: key,
                subject: subject,
                value: "opened",
                observedAt: referenceDate.addingTimeInterval(
                    -ExtensionFactRegistry.maximumProviderFactAge
                )
            ),
        ], replacing: [subject], from: source)

        XCTAssertNil(registry.exactFact(key, for: subject))
        XCTAssertTrue(
            registry.snapshot(consuming: [key]).hasProvider(for: key),
            "staleness removes one value, not its live provider definition"
        )
    }

    func testProviderExpiryFallsThroughToNextFreshProviderThenBecomesMissing() throws {
        let center = NotificationCenter()
        var referenceDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let registry = ExtensionFactRegistry(
            notificationCenter: center,
            now: { referenceDate }
        )
        let key = ExtensionFactKey(id: "gitlab.mr.state")
        let subject = ExtensionFactSubject.session("s1")
        let definition = makeDefinition(key: key)
        let first = makeSource("com.example.first", generation: "g1", order: 0)
        let second = makeSource("com.example.second", generation: "g1", order: 1)
        try registry.replaceDefinitions([definition], from: first)
        try registry.replaceFacts([
            makeFact(
                key: key,
                subject: subject,
                value: "first",
                observedAt: referenceDate
            ),
        ], replacing: [subject], from: first)

        referenceDate = referenceDate.addingTimeInterval(100)
        try registry.replaceDefinitions([definition], from: second)
        try registry.replaceFacts([
            makeFact(
                key: key,
                subject: subject,
                value: "second",
                observedAt: referenceDate
            ),
        ], replacing: [subject], from: second)

        var changes: [ExtensionFactChange] = []
        let token = center.addObserver(
            forName: ExtensionFactsDidChange.name,
            object: nil,
            queue: nil
        ) { notification in
            if let event = notification.object as? ExtensionFactsDidChange {
                changes.append(event.change)
            }
        }
        defer { center.removeObserver(token) }

        referenceDate = Date(timeIntervalSinceReferenceDate: 1_000)
            .addingTimeInterval(ExtensionFactRegistry.maximumProviderFactAge)
        registry.refreshStaleness()
        XCTAssertEqual(
            registry.exactFact(key, for: subject)?.fact.value,
            .string("second")
        )

        referenceDate = referenceDate.addingTimeInterval(100)
        registry.refreshStaleness()
        XCTAssertNil(registry.exactFact(key, for: subject))
        XCTAssertEqual(changes, [
            .exact([.init(subject: subject, key: key)]),
            .exact([.init(subject: subject, key: key)]),
        ])
    }

    func testFreshRepublishRestoresAnExpiredProviderFact() throws {
        let center = NotificationCenter()
        var referenceDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let registry = ExtensionFactRegistry(
            notificationCenter: center,
            now: { referenceDate }
        )
        let source = makeSource("com.example.provider", generation: "g1", order: 0)
        let key = ExtensionFactKey(id: "gitlab.mr.state")
        let subject = ExtensionFactSubject.session("s1")
        try registry.replaceDefinitions([makeDefinition(key: key)], from: source)
        try registry.replaceFacts([
            makeFact(
                key: key,
                subject: subject,
                value: "opened",
                observedAt: referenceDate
            ),
        ], replacing: [subject], from: source)

        referenceDate = referenceDate.addingTimeInterval(
            ExtensionFactRegistry.maximumProviderFactAge
        )
        registry.refreshStaleness()
        XCTAssertNil(registry.exactFact(key, for: subject))

        referenceDate = referenceDate.addingTimeInterval(1)
        try registry.replaceFacts([
            makeFact(
                key: key,
                subject: subject,
                value: "opened",
                observedAt: referenceDate
            ),
        ], replacing: [subject], from: source)
        XCTAssertEqual(
            registry.exactFact(key, for: subject)?.fact.value,
            .string("opened")
        )
    }

    func testLargeExpiryBatchCollapsesToOneAllChange() throws {
        let center = NotificationCenter()
        var referenceDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let registry = ExtensionFactRegistry(
            notificationCenter: center,
            now: { referenceDate }
        )
        let source = makeSource("com.example.provider", generation: "g1", order: 0)
        let key = ExtensionFactKey(id: "gitlab.mr.state")
        try registry.replaceDefinitions([makeDefinition(key: key)], from: source)
        let subjects = (0...ExtensionFactRegistry.maximumExactNotificationCells).map {
            ExtensionFactSubject.session("s\($0)")
        }
        for batch in stride(from: 0, to: subjects.count, by: 128) {
            let admitted = Array(subjects[batch..<min(batch + 128, subjects.count)])
            try registry.replaceFacts(admitted.map { subject in
                makeFact(
                    key: key,
                    subject: subject,
                    value: "opened",
                    observedAt: referenceDate
                )
            }, replacing: Set(admitted), from: source)
        }

        var changes: [ExtensionFactChange] = []
        let token = center.addObserver(
            forName: ExtensionFactsDidChange.name,
            object: nil,
            queue: nil
        ) { notification in
            if let event = notification.object as? ExtensionFactsDidChange {
                changes.append(event.change)
            }
        }
        defer { center.removeObserver(token) }

        referenceDate = referenceDate.addingTimeInterval(
            ExtensionFactRegistry.maximumProviderFactAge
        )
        registry.refreshStaleness()

        XCTAssertEqual(changes, [.all])
        XCTAssertTrue(registry.exactFacts(for: subjects[0]).isEmpty)
        XCTAssertTrue(registry.exactFacts(for: subjects.last!).isEmpty)
    }

    func testScheduledDeadlineExpiresWithoutAnInterveningRead() throws {
        let center = NotificationCenter()
        let scheduler = ManualFactStalenessScheduler()
        var referenceDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let registry = ExtensionFactRegistry(
            notificationCenter: center,
            now: { referenceDate },
            stalenessTimerScheduler: scheduler.schedule
        )
        let source = makeSource("com.example.provider", generation: "g1", order: 0)
        let key = ExtensionFactKey(id: "gitlab.mr.state")
        let subject = ExtensionFactSubject.session("s1")
        try registry.replaceDefinitions([makeDefinition(key: key)], from: source)
        try registry.replaceFacts([
            makeFact(
                key: key,
                subject: subject,
                value: "opened",
                observedAt: referenceDate
            ),
        ], replacing: [subject], from: source)
        XCTAssertEqual(scheduler.scheduledIntervals, [
            ExtensionFactRegistry.maximumProviderFactAge,
        ])

        var changes: [ExtensionFactChange] = []
        let token = center.addObserver(
            forName: ExtensionFactsDidChange.name,
            object: nil,
            queue: nil
        ) { notification in
            if let event = notification.object as? ExtensionFactsDidChange {
                changes.append(event.change)
            }
        }
        defer { center.removeObserver(token) }

        referenceDate = referenceDate.addingTimeInterval(
            ExtensionFactRegistry.maximumProviderFactAge
        )
        scheduler.fire()

        XCTAssertEqual(changes, [.exact([.init(subject: subject, key: key)])])
        XCTAssertNil(registry.exactFact(key, for: subject))
    }

    func testCanceledQueuedTimerCannotClearOrDuplicateANewerArm() throws {
        let center = NotificationCenter()
        let scheduler = ManualFactStalenessScheduler()
        var referenceDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let registry = ExtensionFactRegistry(
            notificationCenter: center,
            now: { referenceDate },
            stalenessTimerScheduler: scheduler.schedule
        )
        let source = makeSource("com.example.provider", generation: "g1", order: 0)
        let key = ExtensionFactKey(id: "gitlab.mr.state")
        let subject = ExtensionFactSubject.session("s1")
        try registry.replaceDefinitions([makeDefinition(key: key)], from: source)
        try registry.replaceFacts([
            makeFact(
                key: key,
                subject: subject,
                value: "opened",
                observedAt: referenceDate
            ),
        ], replacing: [subject], from: source)

        referenceDate = referenceDate.addingTimeInterval(100)
        try registry.replaceFacts([
            makeFact(
                key: key,
                subject: subject,
                value: "opened",
                observedAt: referenceDate
            ),
        ], replacing: [subject], from: source)
        XCTAssertEqual(scheduler.scheduledIntervals.count, 2)
        XCTAssertEqual(scheduler.activeCount, 1)

        scheduler.fire(at: 0)
        XCTAssertEqual(scheduler.scheduledIntervals.count, 2)
        XCTAssertEqual(
            scheduler.activeCount,
            1,
            "the canceled callback must not clear or duplicate the newer arm"
        )

        referenceDate = referenceDate.addingTimeInterval(
            ExtensionFactRegistry.maximumProviderFactAge
        )
        scheduler.fire(at: 1)
        XCTAssertNil(registry.exactFact(key, for: subject))
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testDeadlineIndexStaysBoundedAcrossHighRateRetainedSetRefreshes() throws {
        let scheduler = ManualFactStalenessScheduler()
        var referenceDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let registry = ExtensionFactRegistry(
            now: { referenceDate },
            stalenessTimerScheduler: scheduler.schedule
        )
        let source = makeSource("com.example.provider", generation: "g1", order: 0)
        let key = ExtensionFactKey(id: "gitlab.mr.state")
        try registry.replaceDefinitions([makeDefinition(key: key)], from: source)
        let subjects = (0..<ExtensionFactRegistry.maximumFactsPerGeneration).map {
            ExtensionFactSubject.session("s\($0)")
        }
        for batch in stride(from: 0, to: subjects.count, by: 256) {
            let admitted = Array(subjects[batch..<min(batch + 256, subjects.count)])
            try registry.replaceFacts(admitted.map { subject in
                makeFact(
                    key: key,
                    subject: subject,
                    value: "opened",
                    observedAt: referenceDate
                )
            }, replacing: Set(admitted), from: source)
        }
        XCTAssertEqual(scheduler.scheduledIntervals.count, 1)

        for offset in 1...600 {
            referenceDate = Date(timeIntervalSinceReferenceDate: 1_000 + Double(offset) / 10)
            try registry.replaceFacts([
                makeFact(
                    key: key,
                    subject: subjects[0],
                    value: "opened",
                    observedAt: referenceDate
                ),
            ], replacing: [subjects[0]], from: source)
        }

        let counts = registry.stalenessDeadlineIndexCounts
        XCTAssertEqual(counts.active, ExtensionFactRegistry.maximumFactsPerGeneration)
        XCTAssertLessThanOrEqual(counts.indexed, counts.active * 2)
        XCTAssertEqual(
            scheduler.scheduledIntervals.count,
            1,
            "refreshing a non-earliest cell must not reset the process-wide timer"
        )
    }

    func testBulkReplacementUsesOneReceiptTimestamp() throws {
        var clockReads = 0
        let receipt = Date(timeIntervalSinceReferenceDate: 10)
        let registry = ExtensionFactRegistry(now: {
            clockReads += 1
            return receipt
        })
        let definition = makeDefinition(key: ExtensionHostFactKey.sessionTitle)
        try registry.replaceHostDefinitions([definition])
        try registry.replaceHostFacts([
            .init(
                facts: [makeFact(key: definition.key, subject: .session("s1"), value: "One")],
                subjects: [.session("s1")]
            ),
            .init(
                facts: [makeFact(key: definition.key, subject: .session("s2"), value: "Two")],
                subjects: [.session("s2")]
            ),
        ])

        XCTAssertEqual(clockReads, 1)
        XCTAssertEqual(registry.exactFact(definition.key, for: .session("s1"))?.receivedAt, receipt)
        XCTAssertEqual(registry.exactFact(definition.key, for: .session("s2"))?.receivedAt, receipt)
    }

    func testTargetedChangePostsExactCell() throws {
        let center = NotificationCenter()
        let registry = ExtensionFactRegistry(notificationCenter: center)
        let definition = makeDefinition(key: ExtensionHostFactKey.sessionTitle)
        try registry.replaceHostDefinitions([definition])
        var changes: [ExtensionFactChange] = []
        let token = center.addObserver(
            forName: ExtensionFactsDidChange.name,
            object: nil,
            queue: nil
        ) { notification in
            if let event = notification.object as? ExtensionFactsDidChange {
                changes.append(event.change)
            }
        }
        defer { center.removeObserver(token) }

        try registry.replaceHostFacts([
            makeFact(key: definition.key, subject: .session("s1"), value: "New"),
        ], replacing: [.session("s1")])
        XCTAssertEqual(changes, [.exact([
            .init(subject: .session("s1"), key: definition.key),
        ])])
    }

    func testLargeChangeNotificationCollapsesToAll() throws {
        let center = NotificationCenter()
        let registry = ExtensionFactRegistry(notificationCenter: center)
        let source = makeSource("com.example.provider", generation: "g1", order: 0)
        let definitions = (0..<32).map {
            makeDefinition(key: .init(id: "example.fact-\($0)"))
        }
        try registry.replaceDefinitions(definitions, from: source)
        let subjects = Set((0..<9).map { ExtensionFactSubject.session("s\($0)") })
        let initial = subjects.flatMap { subject in
            definitions.map { makeFact(key: $0.key, subject: subject, value: "old") }
        }
        try registry.replaceFacts(initial, replacing: subjects, from: source)

        var changes: [ExtensionFactChange] = []
        let token = center.addObserver(
            forName: ExtensionFactsDidChange.name,
            object: nil,
            queue: nil
        ) { notification in
            if let event = notification.object as? ExtensionFactsDidChange {
                changes.append(event.change)
            }
        }
        defer { center.removeObserver(token) }

        let replacement = subjects.flatMap { subject in
            definitions.map { makeFact(key: $0.key, subject: subject, value: "new") }
        }
        try registry.replaceFacts(replacement, replacing: subjects, from: source)
        XCTAssertEqual(changes, [.all])
    }

    func testNotificationCellBoundaryIsExactAt256AndAllAt257() throws {
        let center = NotificationCenter()
        let registry = ExtensionFactRegistry(notificationCenter: center)
        let source = makeSource("com.example.provider", generation: "g1", order: 0)
        let definitions = (0..<32).map {
            makeDefinition(key: .init(id: "example.fact-\($0)"))
        }
        try registry.replaceDefinitions(definitions, from: source)
        let subjects = (0..<9).map { ExtensionFactSubject.session("s\($0)") }
        let initial = subjects.flatMap { subject in
            definitions.map { makeFact(key: $0.key, subject: subject, value: "old") }
        }
        try registry.replaceFacts(initial, replacing: Set(subjects), from: source)

        var changes: [ExtensionFactChange] = []
        let token = center.addObserver(
            forName: ExtensionFactsDidChange.name,
            object: nil,
            queue: nil
        ) { notification in
            if let event = notification.object as? ExtensionFactsDidChange {
                changes.append(event.change)
            }
        }
        defer { center.removeObserver(token) }

        let firstEight = Array(subjects.prefix(8))
        let exactReplacement = firstEight.flatMap { subject in
            definitions.map { makeFact(key: $0.key, subject: subject, value: "new") }
        }
        try registry.replaceFacts(
            exactReplacement,
            replacing: Set(firstEight),
            from: source
        )
        guard case .exact(let exact)? = changes.first else {
            return XCTFail("Expected the 256-cell boundary to remain exact")
        }
        XCTAssertEqual(exact.count, 256)

        changes.removeAll()
        let overflowReplacement = firstEight.flatMap { subject in
            definitions.map { makeFact(key: $0.key, subject: subject, value: "again") }
        } + definitions.map {
            makeFact(
                key: $0.key,
                subject: subjects[8],
                value: $0.key == definitions[0].key ? "new" : "old"
            )
        }
        try registry.replaceFacts(
            overflowReplacement,
            replacing: Set(subjects),
            from: source
        )
        XCTAssertEqual(changes, [.all])
    }

    func testDefinitionAndPublicationCapsAreEnforced() throws {
        let registry = ExtensionFactRegistry()
        let source = makeSource("com.example.provider", generation: "g1", order: 0)
        let tooManyDefinitions = (0...ExtensionFactRegistry.maximumDefinitionsPerGeneration).map {
            makeDefinition(key: .init(id: "example.fact-\($0)"))
        }
        XCTAssertThrowsError(try registry.replaceDefinitions(tooManyDefinitions, from: source)) {
            error in
            XCTAssertEqual(
                error as? ExtensionFactRegistryError,
                .tooManyDefinitions(maximum: ExtensionFactRegistry.maximumDefinitionsPerGeneration)
            )
        }

        let standingHostDefinition = makeDefinition(key: ExtensionHostFactKey.sessionTitle)
        try registry.replaceHostDefinitions([standingHostDefinition])
        let standingHostFact = makeFact(
            key: standingHostDefinition.key,
            subject: .session("host-kept"),
            value: "Host kept"
        )
        try registry.replaceHostFacts([standingHostFact], replacing: [.session("host-kept")])
        XCTAssertThrowsError(try registry.replaceHostDefinitions(
            (0...ExtensionFactRegistry.maximumDefinitionsPerGeneration).map {
                makeDefinition(key: .init(id: "session.host-fact-\($0)"))
            }
        )) { error in
            XCTAssertEqual(
                error as? ExtensionFactRegistryError,
                .tooManyDefinitions(maximum: ExtensionFactRegistry.maximumDefinitionsPerGeneration)
            )
        }
        XCTAssertEqual(registry.definition(for: standingHostDefinition.key), standingHostDefinition)
        XCTAssertEqual(
            registry.exactFact(
                standingHostDefinition.key,
                for: .session("host-kept")
            )?.fact.value,
            .string("Host kept")
        )

        let key = ExtensionFactKey(id: "example.fact")
        try registry.replaceDefinitions([makeDefinition(key: key)], from: source)
        let tooManyReplacementFacts = (0...ExtensionFactRegistry.maximumFactsPerReplacement).map {
            makeFact(key: key, subject: .session("s\($0)"), value: "x")
        }
        XCTAssertThrowsError(try registry.replaceFacts(
            tooManyReplacementFacts,
            replacing: Set(tooManyReplacementFacts.map(\.subject)),
            from: source
        )) { error in
            XCTAssertEqual(
                error as? ExtensionFactRegistryError,
                .tooManyReplacementFacts(maximum: ExtensionFactRegistry.maximumFactsPerReplacement)
            )
        }


        let tooManySubjects = Set(
            (0...ExtensionFactRegistry.maximumSubjectsPerReplacement).map {
                ExtensionFactSubject.session("scope-\($0)")
            }
        )
        let keptSubject = ExtensionFactSubject.session("scope-0")
        try registry.replaceFacts(
            [makeFact(key: key, subject: keptSubject, value: "kept")],
            replacing: [keptSubject],
            from: source
        )
        XCTAssertThrowsError(try registry.replaceFacts(
            [],
            replacing: tooManySubjects,
            from: source
        )) { error in
            XCTAssertEqual(
                error as? ExtensionFactRegistryError,
                .tooManyReplacementSubjects(
                    maximum: ExtensionFactRegistry.maximumSubjectsPerReplacement
                )
            )
        }
        XCTAssertEqual(
            registry.exactFact(key, for: keptSubject)?.fact.value,
            .string("kept")
        )
    }

    func testPerSubjectAndResolvedCapsAreEnforced() throws {
        let registry = ExtensionFactRegistry()
        let source = makeSource("com.example.provider", generation: "g1", order: 0)
        let definitions = (0...ExtensionFactRegistry.maximumFactsPerSourceSubject).map {
            makeDefinition(key: .init(id: "example.fact-\($0)"))
        }
        try registry.replaceDefinitions(definitions, from: source)
        let tooMany = definitions.map {
            makeFact(key: $0.key, subject: .session("s1"), value: "x")
        }
        XCTAssertThrowsError(try registry.replaceFacts(
            tooMany,
            replacing: [.session("s1")],
            from: source
        )) { error in
            XCTAssertEqual(
                error as? ExtensionFactRegistryError,
                .tooManyFactsForSubject(maximum: ExtensionFactRegistry.maximumFactsPerSourceSubject)
            )
        }

        for sourceIndex in 0..<4 {
            let source = makeSource(
                "com.example.source-\(sourceIndex)",
                generation: "g1",
                order: sourceIndex
            )
            let definitions = (0..<32).map {
                makeDefinition(key: .init(id: "source-\(sourceIndex).fact-\($0)"))
            }
            try registry.replaceDefinitions(definitions, from: source)
            try registry.replaceFacts(
                definitions.map {
                    makeFact(key: $0.key, subject: .session("resolved"), value: "x")
                },
                replacing: [.session("resolved")],
                from: source
            )
        }
        let overflowSource = makeSource("com.example.overflow", generation: "g1", order: 5)
        let overflowDefinition = makeDefinition(key: .init(id: "overflow.fact"))
        try registry.replaceDefinitions([overflowDefinition], from: overflowSource)
        XCTAssertThrowsError(try registry.replaceFacts(
            [makeFact(
                key: overflowDefinition.key,
                subject: .session("resolved"),
                value: "x"
            )],
            replacing: [.session("resolved")],
            from: overflowSource
        )) { error in
            XCTAssertEqual(
                error as? ExtensionFactRegistryError,
                .tooManyResolvedFactsForSubject(
                    maximum: ExtensionFactRegistry.maximumResolvedFactsPerSubject
                )
            )
        }
        XCTAssertEqual(registry.exactFacts(for: .session("resolved")).count, 128)
    }

    func testGenerationTotalCapIsEnforcedAcrossScopedReplacements() throws {
        let registry = ExtensionFactRegistry()
        let source = makeSource("com.example.provider", generation: "g1", order: 0)
        let definitions = (0..<32).map {
            makeDefinition(key: .init(id: "example.fact-\($0)"))
        }
        try registry.replaceDefinitions(definitions, from: source)

        for batch in 0..<8 {
            let subjects = Set((0..<64).map {
                ExtensionFactSubject.session("s\(batch * 64 + $0)")
            })
            let facts = subjects.flatMap { subject in
                definitions.map { makeFact(key: $0.key, subject: subject, value: "x") }
            }
            try registry.replaceFacts(facts, replacing: subjects, from: source)
        }
        XCTAssertThrowsError(try registry.replaceFacts(
            [makeFact(
                key: definitions[0].key,
                subject: .session("overflow"),
                value: "x"
            )],
            replacing: [.session("overflow")],
            from: source
        )) { error in
            XCTAssertEqual(
                error as? ExtensionFactRegistryError,
                .tooManyFactsForGeneration(
                    maximum: ExtensionFactRegistry.maximumFactsPerGeneration
                )
            )
        }
        XCTAssertTrue(registry.exactFacts(for: .session("overflow")).isEmpty)
    }
}

private func makeDefinition(
    key: ExtensionFactKey,
    valueType: ExtensionFactValueType = .string,
    subjectKinds: Set<ExtensionFactSubjectKind> = [.session]
) -> ExtensionFactDefinition {
    ExtensionFactDefinition(
        key: key,
        displayName: key.id,
        valueType: valueType,
        subjectKinds: subjectKinds,
        usages: [.filterable, .sortable, .presentable]
    )
}

private func makeFact(
    key: ExtensionFactKey,
    subject: ExtensionFactSubject,
    value: String,
    observedAt: Date = .distantFuture
) -> ExtensionFact {
    ExtensionFact(
        key: key,
        subject: subject,
        value: .string(value),
        observedAt: observedAt
    )
}

@MainActor
private final class ManualFactStalenessScheduler {
    private(set) var scheduledIntervals: [TimeInterval] = []
    private var actions: [(@MainActor @Sendable () -> Void)?] = []
    private var canceled: Set<Int> = []

    var activeCount: Int {
        actions.indices.count { actions[$0] != nil && !canceled.contains($0) }
    }

    func schedule(
        _ interval: TimeInterval,
        _ fire: @escaping @MainActor @Sendable () -> Void
    ) -> @MainActor @Sendable () -> Void {
        scheduledIntervals.append(interval)
        let index = actions.count
        actions.append(fire)
        return { [weak self] in self?.canceled.insert(index) }
    }

    func fire(at index: Int? = nil) {
        let index = index ?? actions.count - 1
        let action = actions[index]
        actions[index] = nil
        action?()
    }
}

private func makeSource(
    _ identifier: String,
    generation: String,
    order: Int
) -> ComponentCustomizationSource {
    ComponentCustomizationSource(
        extensionIdentifier: identifier,
        processGeneration: generation,
        order: order
    )
}
