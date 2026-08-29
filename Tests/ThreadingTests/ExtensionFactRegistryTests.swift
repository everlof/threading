import Foundation
import XCTest
import ThreadingExtensionKit
@testable import Threading

@MainActor
final class ExtensionFactRegistryTests: XCTestCase {
    func testHostFactsAreSynchronouslyReadableWithTheirDefinition() throws {
        let registry = ExtensionFactRegistry()
        let definition = makeDefinition(key: ExtensionHostFactKey.sessionTitle)
        try registry.replaceHostDefinitions([definition])
        let fact = makeFact(
            key: definition.key,
            subject: .session("s1"),
            value: "First"
        )
        try registry.replaceHostFacts([fact], replacing: [.session("s1")])

        XCTAssertEqual(registry.definition(for: definition.key), definition)
        XCTAssertEqual(registry.fact(definition.key, for: .session("s1")), .init(
            fact: fact,
            definition: definition,
            source: .host
        ))
        XCTAssertEqual(registry.facts(for: .session("s1")).count, 1)
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
            registry.fact(definition.key, for: .session("s1"))?.fact.value,
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

        XCTAssertTrue(registry.facts(for: .session("first")).isEmpty)
        XCTAssertTrue(registry.facts(for: .session("second")).isEmpty)
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
            registry.fact(key, for: .session("s1"))?.fact.value,
            .string("first")
        )
        registry.removeGeneration(
            extensionIdentifier: first.extensionIdentifier,
            processGeneration: first.processGeneration
        )
        XCTAssertEqual(
            registry.fact(key, for: .session("s1"))?.fact.value,
            .string("second")
        )
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
            registry.fact(key, for: .session("s1"))?.fact.value,
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
        XCTAssertNil(registry.fact(key, for: .session("s1")))
        XCTAssertEqual(
            registry.fact(key, for: .session("s2"))?.fact.value,
            .string("two")
        )
    }

    func testUnchangedHostFactPreservesObservationAndPostsNoChange() throws {
        let center = NotificationCenter()
        let registry = ExtensionFactRegistry(notificationCenter: center)
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
            registry.fact(definition.key, for: .session("s1"))?.fact.observedAt,
            firstDate
        )
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
            registry.fact(standingHostDefinition.key, for: .session("host-kept"))?.fact.value,
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
            registry.fact(key, for: keptSubject)?.fact.value,
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
        XCTAssertEqual(registry.facts(for: .session("resolved")).count, 128)
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
        XCTAssertTrue(registry.facts(for: .session("overflow")).isEmpty)
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
    observedAt: Date = Date(timeIntervalSinceReferenceDate: 1)
) -> ExtensionFact {
    ExtensionFact(
        key: key,
        subject: subject,
        value: .string(value),
        observedAt: observedAt
    )
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
