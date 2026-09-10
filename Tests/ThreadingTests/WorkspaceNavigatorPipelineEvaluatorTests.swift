import Foundation
@testable import Threading
import ThreadingExtensionKit
import XCTest

final class WorkspaceNavigatorPipelineEvaluatorTests: XCTestCase {
    private let titleKey = ExtensionHostFactKey.sessionTitle
    private let projectIDKey = ExtensionHostFactKey.sessionProjectID
    private let projectNameKey = ExtensionHostFactKey.projectName
    private let stateKey = ExtensionFactKey(id: "example.state")
    private let scoreKey = ExtensionFactKey(id: "example.score")
    private let detailKey = ExtensionFactKey(id: "example.detail")

    func testCompilationDisablesRequiredFactsAndDegradesEnhancementsByUnit() throws {
        let missing = ExtensionFactKey(id: "example.optional")
        let snapshot = makeSnapshot(
            sessionIDs: ["session-1"],
            definitions: [titleDefinition],
            facts: [fact(titleKey, .session("session-1"), .string("One"))]
        )
        let unavailable = pipeline(
            consumes: [.init(key: missing, requirement: .required)],
            template: .text(.literal("Row"), role: .body)
        )
        guard case let .unavailable(keys) = WorkspaceNavigatorPipelineCompiler().compile(
            unavailable,
            snapshot: snapshot,
            optionValues: [:]
        ) else {
            return XCTFail("A missing required provider must disable the navigator")
        }
        XCTAssertEqual(keys, [missing])

        let enhanced = pipeline(
            consumes: [
                .init(key: titleKey, requirement: .required),
                .init(key: missing),
            ],
            search: .init(
                placeholder: "Search",
                accessibilityLabel: "Search sessions",
                fields: [.init(titleKey), .init(missing)]
            ),
            filters: [.init(predicate: .isPresent(.init(missing)))],
            buckets: [
                .init(strategy: .fact(.init(.init(missing)), direction: .ascending, explicitOrder: [])),
                .init(strategy: .rules(
                    [.init(id: "missing", title: "Missing", predicate: .isPresent(.init(missing)))],
                    unmatched: .omit
                )),
            ],
            sort: [.init(operand: .init(.init(missing)), direction: .ascending)],
            template: .stack(axis: .horizontal, spacing: .small, children: [
                .text(.fact(.init(titleKey), facet: .value, fallback: nil), role: .body),
                .text(.fact(.init(missing), facet: .value, fallback: "Fallback"), role: .detail),
                .text(.fact(.init(missing), facet: .value, fallback: nil), role: .detail),
                .intent(.pin),
                .conditional(.isPresent(.init(missing)), content: .intent(.archive)),
                .status(
                    .fact(.init(titleKey), facet: .value, fallback: nil),
                    role: .factStatus(.init(missing), fallback: .warning)
                ),
            ])
        )
        let compiled = try ready(enhanced, snapshot: snapshot)

        XCTAssertEqual(
            compiled.search?.fields,
            [ExtensionWorkspaceNavigatorFactReference(titleKey)]
        )
        XCTAssertEqual(compiled.filters.count, 0)
        XCTAssertNil(compiled.bucket)
        XCTAssertEqual(compiled.sort.count, 0)
        let expectedTemplate = ExtensionWorkspaceNavigatorTemplateNode.stack(
            axis: .horizontal,
            spacing: .small,
            children: [
                .text(.fact(.init(titleKey), facet: .value, fallback: nil), role: .body),
                .text(.literal("Fallback"), role: .detail),
                .intent(.pin),
                .status(
                    .fact(.init(titleKey), facet: .value, fallback: nil),
                    role: .literal(.warning)
                ),
            ]
        )
        XCTAssertEqual(compiled.rowTemplate, expectedTemplate)

        let evaluator = WorkspaceNavigatorPipelineEvaluator()
        let item = try XCTUnwrap(evaluator.evaluate(compiled).sections.first?.items.first)
        XCTAssertEqual(evaluator.realizeVisibleRow(item, in: compiled), .stack(
            axis: .horizontal,
            spacing: .small,
            children: [
                .text("One", role: .body),
                .text("Fallback", role: .detail),
                .intent(.pin),
                .status("One", role: .warning),
            ]
        ))
    }

    func testSelectedRegisteredFactBucketReplacesStaticAndUnavailableIsAllUnknown() throws {
        let dynamicDefinition = definition(
            stateKey,
            type: .string,
            kinds: [.session],
            usages: [.groupable]
        )
        let snapshot = makeSnapshot(
            sessionIDs: ["s-b", "s-a", "s-unknown"],
            definitions: [dynamicDefinition],
            facts: [
                fact(stateKey, .session("s-b"), .string("Beta")),
                fact(stateKey, .session("s-a"), .string("Alpha")),
            ]
        )
        let value = pipeline(
            consumes: [.init(key: stateKey, requirement: .required)],
            registeredFactOptions: [
                .init(
                    id: "group-by",
                    title: "Group by",
                    application: .bucket(direction: .ascending, unknownTitle: "Unknown")
                ),
            ],
            buckets: [
                .init(strategy: .fact(
                    .init(.init(stateKey)),
                    direction: .descending,
                    explicitOrder: []
                )),
            ],
            template: .text(.literal("Row"), role: .body)
        )

        let none = try ready(value, snapshot: snapshot)
        XCTAssertEqual(
            WorkspaceNavigatorPipelineEvaluator().evaluate(none).sections.map(\.title),
            ["Beta", "Alpha", nil]
        )

        let selected = try ready(
            value,
            snapshot: snapshot,
            registeredFactSelections: ["group-by": stateKey]
        )
        let sections = WorkspaceNavigatorPipelineEvaluator().evaluate(selected).sections
        XCTAssertEqual(sections.map(\.title), ["Alpha", "Beta", "Unknown"])
        XCTAssertEqual(sections.last?.items.map(\.sourceSessionID), ["s-unknown"])

        let unavailableValue = pipeline(
            consumes: [],
            registeredFactOptions: value.registeredFactOptions,
            template: .text(.literal("Row"), role: .body)
        )
        let unavailableSnapshot = makeSnapshot(
            sessionIDs: ["s-b", "s-a", "s-unknown"],
            definitions: [],
            facts: []
        )
        let unavailable = try ready(
            unavailableValue,
            snapshot: unavailableSnapshot,
            registeredFactSelections: ["group-by": stateKey]
        )
        let unavailableSections = WorkspaceNavigatorPipelineEvaluator()
            .evaluate(unavailable).sections
        XCTAssertEqual(unavailableSections.map(\.title), ["Unknown"])
        XCTAssertEqual(unavailableSections.first?.items.count, 3)
    }

    func testSelectedRegisteredFactSortIsPrimaryMissingLastAndUnavailableIsNoOp() throws {
        let stateDefinition = definition(
            stateKey,
            type: .string,
            kinds: [.session],
            usages: [.sortable]
        )
        let scoreDefinition = definition(
            scoreKey,
            type: .integer,
            kinds: [.session],
            usages: [.sortable]
        )
        let snapshot = makeSnapshot(
            sessionIDs: ["s-beta", "s-alpha", "s-missing"],
            definitions: [stateDefinition, scoreDefinition],
            facts: [
                fact(stateKey, .session("s-beta"), .string("Beta")),
                fact(scoreKey, .session("s-beta"), .integer(0)),
                fact(stateKey, .session("s-alpha"), .string("Alpha")),
                fact(scoreKey, .session("s-alpha"), .integer(10)),
                fact(scoreKey, .session("s-missing"), .integer(-1)),
            ]
        )
        let value = pipeline(
            consumes: [.init(key: scoreKey, requirement: .required)],
            registeredFactOptions: [
                .init(
                    id: "sort-by",
                    title: "Sort by",
                    application: .sort(direction: .ascending)
                ),
            ],
            sort: [.init(
                operand: .init(.init(scoreKey)),
                direction: .ascending
            )],
            template: .text(.literal("Row"), role: .body)
        )
        let selected = try ready(
            value,
            snapshot: snapshot,
            registeredFactSelections: ["sort-by": stateKey]
        )
        XCTAssertEqual(
            WorkspaceNavigatorPipelineEvaluator().evaluate(selected)
                .sections.flatMap(\.items).map(\.sourceSessionID),
            ["s-alpha", "s-beta", "s-missing"]
        )

        let unavailableSnapshot = makeSnapshot(
            sessionIDs: ["s-beta", "s-alpha", "s-missing"],
            definitions: [scoreDefinition],
            facts: [
                fact(scoreKey, .session("s-beta"), .integer(0)),
                fact(scoreKey, .session("s-alpha"), .integer(10)),
                fact(scoreKey, .session("s-missing"), .integer(-1)),
            ]
        )
        let unavailable = try ready(
            value,
            snapshot: unavailableSnapshot,
            registeredFactSelections: ["sort-by": stateKey]
        )
        XCTAssertEqual(
            WorkspaceNavigatorPipelineEvaluator().evaluate(unavailable)
                .sections.flatMap(\.items).map(\.sourceSessionID),
            ["s-missing", "s-beta", "s-alpha"]
        )
    }

    func testCompilationRejectsIncompatibleRuntimeDefinitions() {
        let booleanSearch = definition(
            titleKey,
            type: .boolean,
            kinds: [.session],
            usages: [.searchable, .presentable]
        )
        let snapshot = makeSnapshot(
            sessionIDs: [],
            definitions: [booleanSearch],
            facts: []
        )
        let value = pipeline(
            consumes: [.init(key: titleKey, requirement: .required)],
            search: .init(
                placeholder: "Search",
                accessibilityLabel: "Search",
                fields: [.init(titleKey)]
            ),
            sort: [.init(operand: .init(.init(titleKey)), direction: .ascending)],
            template: .text(.fact(.init(titleKey), facet: .value, fallback: nil), role: .body)
        )

        guard case let .invalid(issues) = WorkspaceNavigatorPipelineCompiler().compile(
            value,
            snapshot: snapshot,
            optionValues: [:]
        ) else {
            return XCTFail("An incompatible live definition must fail closed")
        }
        XCTAssertTrue(issues.contains { $0.message.contains("must have type 'string'") })
        XCTAssertTrue(issues.contains { $0.message.contains("not declared 'sortable'") })
    }

    func testMissingEnhancedProjectJoinDegradesEveryDependentUnit() throws {
        let projectDefinition = definition(
            projectNameKey,
            type: .string,
            kinds: [.project],
            usages: [.searchable, .filterable, .sortable, .groupable, .presentable]
        )
        let snapshot = makeSnapshot(
            sessionIDs: ["session-1"],
            definitions: [titleDefinition, projectDefinition],
            facts: [
                fact(titleKey, .session("session-1"), .string("One")),
                fact(projectNameKey, .project("project-1"), .string("Project")),
            ]
        )
        let projectReference = ExtensionWorkspaceNavigatorFactReference(
            projectNameKey,
            scope: .project
        )
        let value = pipeline(
            consumes: [
                .init(key: titleKey, requirement: .required),
                .init(key: projectNameKey, requirement: .required),
                .init(key: projectIDKey, requirement: .enhances),
            ],
            search: .init(
                placeholder: "Search",
                accessibilityLabel: "Search projects",
                fields: [projectReference]
            ),
            filters: [.init(predicate: .isPresent(projectReference))],
            buckets: [
                .init(strategy: .fact(
                    .init(projectReference),
                    direction: .ascending,
                    explicitOrder: []
                )),
                .init(strategy: .rules(
                    [.init(
                        id: "project",
                        title: "Project",
                        predicate: .isPresent(projectReference)
                    )],
                    unmatched: .omit
                )),
            ],
            sort: [.init(operand: .init(projectReference), direction: .ascending)],
            template: .stack(axis: .vertical, spacing: .small, children: [
                .text(.fact(projectReference, facet: .value, fallback: "No project"), role: .body),
                .image(
                    .factIcon(projectReference, fallback: .systemSymbol("folder")),
                    role: .icon,
                    accessibilityLabel: "Project"
                ),
                .status(
                    .literal("State"),
                    role: .factStatus(projectReference, fallback: .warning)
                ),
                .conditional(.isPresent(projectReference), content: .divider),
            ])
        )

        let compiled = try ready(value, snapshot: snapshot)

        XCTAssertNil(compiled.search)
        XCTAssertTrue(compiled.filters.isEmpty)
        XCTAssertNil(compiled.bucket, "Both fact and rule bucket clauses depend on the join")
        XCTAssertTrue(compiled.sort.isEmpty)
        XCTAssertEqual(compiled.rowTemplate, .stack(
            axis: .vertical,
            spacing: .small,
            children: [
                .text(.literal("No project"), role: .body),
                .image(
                    .literal(.systemSymbol("folder")),
                    role: .icon,
                    accessibilityLabel: "Project"
                ),
                .status(.literal("State"), role: .literal(.warning)),
            ]
        ))
    }

    func testSearchOptionsFiltersAndStableMissingLastSortStayInMemory() throws {
        let pinnedKey = ExtensionFactKey(id: "example.pinned")
        let definitions = [
            titleDefinition,
            definition(
                pinnedKey,
                type: .boolean,
                kinds: [.session],
                usages: [.filterable]
            ),
            scoreDefinition,
        ]
        let snapshot = makeSnapshot(
            sessionIDs: ["a", "b", "c", "d"],
            definitions: definitions,
            facts: [
                fact(titleKey, .session("a"), .string("Café Alpha")),
                fact(titleKey, .session("b"), .string("Cafe Beta")),
                fact(titleKey, .session("c"), .string("Café Gamma")),
                fact(titleKey, .session("d"), .string("Other")),
                fact(pinnedKey, .session("a"), .boolean(true)),
                fact(pinnedKey, .session("b"), .boolean(true)),
                fact(pinnedKey, .session("c"), .boolean(false)),
                fact(pinnedKey, .session("d"), .boolean(true)),
                fact(scoreKey, .session("a"), .integer(10)),
                fact(scoreKey, .session("c"), .integer(20)),
            ]
        )
        let value = pipeline(
            consumes: [
                .init(key: titleKey, requirement: .required),
                .init(key: pinnedKey, requirement: .required),
                .init(key: scoreKey, requirement: .required),
            ],
            search: .init(
                placeholder: "Search",
                accessibilityLabel: "Search sessions",
                fields: [.init(titleKey)]
            ),
            filters: [.init(
                when: [.init(optionID: "pinned-only", equals: .bool(true))],
                predicate: .comparison(.init(.init(pinnedKey)), .equal, .boolean(true))
            )],
            sort: [.init(operand: .init(.init(scoreKey)), direction: .descending)],
            template: titleTemplate
        )
        let compiled = try ready(
            value,
            snapshot: snapshot,
            optionValues: ["pinned-only": .bool(true)]
        )
        let result = WorkspaceNavigatorPipelineEvaluator().evaluate(compiled, query: "cafe")

        XCTAssertEqual(result.sections.flatMap(\.items).map(\.sourceSessionID), ["a", "b"])
        XCTAssertEqual(result.omittedItemCount, 0)
        XCTAssertEqual(result.sections.first?.items.first?.destination, .session(
            id: "a",
            projectID: nil
        ))

        let ascending = pipeline(
            consumes: [.init(key: titleKey), .init(key: scoreKey)],
            sort: [.init(operand: .init(.init(scoreKey)), direction: .ascending)],
            template: titleTemplate
        )
        let descending = pipeline(
            consumes: [.init(key: titleKey), .init(key: scoreKey)],
            sort: [.init(operand: .init(.init(scoreKey)), direction: .descending)],
            template: titleTemplate
        )
        let evaluator = WorkspaceNavigatorPipelineEvaluator()
        XCTAssertEqual(
            try evaluator.evaluate(ready(ascending, snapshot: snapshot))
                .sections.flatMap(\.items).map(\.sourceSessionID),
            ["a", "c", "b", "d"]
        )
        XCTAssertEqual(
            try evaluator.evaluate(ready(descending, snapshot: snapshot))
                .sections.flatMap(\.items).map(\.sourceSessionID),
            ["c", "a", "b", "d"]
        )
    }

    func testPredicatesKeepUnknownDistinctFromFalseAndApplyOperandFallback() throws {
        let snapshot = makeSnapshot(
            sessionIDs: ["has-one", "missing"],
            definitions: [titleDefinition, scoreDefinition],
            facts: [
                fact(titleKey, .session("has-one"), .string("One")),
                fact(titleKey, .session("missing"), .string("Missing")),
                fact(scoreKey, .session("has-one"), .integer(1)),
            ]
        )
        let unknownNot = pipeline(
            consumes: [.init(key: titleKey), .init(key: scoreKey)],
            filters: [.init(predicate: .not(.comparison(
                .init(.init(scoreKey)),
                .equal,
                .integer(2)
            )))],
            template: titleTemplate
        )
        let fallback = pipeline(
            consumes: [.init(key: titleKey), .init(key: scoreKey)],
            filters: [.init(predicate: .comparison(
                .init(.init(scoreKey), fallback: .integer(2)),
                .equal,
                .integer(2)
            ))],
            template: titleTemplate
        )
        let presence = pipeline(
            consumes: [.init(key: titleKey), .init(key: scoreKey)],
            filters: [.init(predicate: .isPresent(.init(scoreKey)))],
            template: titleTemplate
        )
        let evaluator = WorkspaceNavigatorPipelineEvaluator()

        XCTAssertEqual(
            try evaluator.evaluate(ready(unknownNot, snapshot: snapshot))
                .sections.flatMap(\.items).map(\.sourceSessionID),
            ["has-one"],
            "not unknown must remain unknown rather than becoming true"
        )
        XCTAssertEqual(
            try evaluator.evaluate(ready(fallback, snapshot: snapshot))
                .sections.flatMap(\.items).map(\.sourceSessionID),
            ["missing"]
        )
        XCTAssertEqual(
            try evaluator.evaluate(ready(presence, snapshot: snapshot))
                .sections.flatMap(\.items).map(\.sourceSessionID),
            ["has-one"],
            "isPresent has no operand fallback"
        )
    }

    func testFactAndRuleBucketsHaveDeterministicOrderAndUnknownPath() throws {
        let stateDefinition = definition(
            stateKey,
            type: .string,
            kinds: [.session],
            usages: [.groupable, .presentable]
        )
        let snapshot = makeSnapshot(
            sessionIDs: ["blocked", "closed", "missing", "open"],
            definitions: [titleDefinition, stateDefinition],
            facts: [
                fact(titleKey, .session("blocked"), .string("Blocked")),
                fact(titleKey, .session("closed"), .string("Closed")),
                fact(titleKey, .session("missing"), .string("Missing")),
                fact(titleKey, .session("open"), .string("Open")),
                fact(stateKey, .session("blocked"), .string("blocked")),
                fact(stateKey, .session("closed"), .string("closed")),
                fact(stateKey, .session("open"), .string("open"), label: "Open MR"),
            ]
        )
        let factBucket = pipeline(
            consumes: [.init(key: titleKey), .init(key: stateKey)],
            buckets: [.init(strategy: .fact(
                .init(.init(stateKey)),
                direction: .descending,
                explicitOrder: [.string("closed"), .string("open")]
            ))],
            template: titleTemplate
        )
        let result = try WorkspaceNavigatorPipelineEvaluator().evaluate(
            ready(factBucket, snapshot: snapshot)
        )

        XCTAssertEqual(result.sections.map(\.title), ["closed", "Open MR", "blocked", nil])
        XCTAssertEqual(result.sections.map(\.identity), [
            .fact(key: stateKey, value: .string("closed")),
            .fact(key: stateKey, value: .string("open")),
            .fact(key: stateKey, value: .string("blocked")),
            .fact(key: stateKey, value: nil),
        ])

        let rules = pipeline(
            consumes: [.init(key: titleKey), .init(key: stateKey)],
            buckets: [.init(strategy: .rules([
                .init(
                    id: "known",
                    title: "Known",
                    predicate: .isPresent(.init(stateKey))
                ),
                .init(
                    id: "open",
                    title: "Open",
                    predicate: .comparison(
                        .init(.init(stateKey)),
                        .equal,
                        .string("open")
                    )
                ),
            ], unmatched: .bucket(id: "other", title: "Other")))],
            template: titleTemplate
        )
        let ruleResult = try WorkspaceNavigatorPipelineEvaluator().evaluate(
            ready(rules, snapshot: snapshot)
        )
        XCTAssertEqual(ruleResult.sections.map(\.identity), [
            .rule(id: "known"),
            .rule(id: "other"),
        ], "Rule buckets use first-match semantics in declaration order")
        XCTAssertEqual(
            ruleResult.sections[0].items.map(\.sourceSessionID),
            ["blocked", "closed", "open"]
        )
    }

    func testRelativeDateRulesUseInjectedCalendarAcrossDSTAndTimeZones() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = date(2026, 3, 9, 12, 0, calendar: newYork)
        let dateKey = ExtensionFactKey(id: "example.last-used")
        let dateDefinition = definition(
            dateKey,
            type: .date,
            kinds: [.session],
            usages: [.groupable]
        )
        let snapshot = makeSnapshot(
            sessionIDs: ["older", "today", "yesterday"],
            definitions: [titleDefinition, dateDefinition],
            facts: [
                fact(titleKey, .session("older"), .string("Older")),
                fact(titleKey, .session("today"), .string("Today")),
                fact(titleKey, .session("yesterday"), .string("Yesterday")),
                fact(dateKey, .session("today"), .date(date(2026, 3, 9, 0, 30, calendar: newYork))),
                fact(dateKey, .session("yesterday"), .date(date(2026, 3, 8, 1, 30, calendar: newYork))),
                fact(dateKey, .session("older"), .date(date(2026, 3, 7, 23, 30, calendar: newYork))),
            ]
        )
        let value = pipeline(
            consumes: [.init(key: titleKey), .init(key: dateKey)],
            buckets: [.init(strategy: .rules([
                .init(
                    id: "today",
                    title: "Today",
                    predicate: .relativeDate(.init(.init(dateKey)), .today)
                ),
                .init(
                    id: "yesterday",
                    title: "Yesterday",
                    predicate: .relativeDate(.init(.init(dateKey)), .yesterday)
                ),
                .init(
                    id: "week",
                    title: "Last 7 days",
                    predicate: .relativeDate(.init(.init(dateKey)), .lastDays(7))
                ),
            ], unmatched: .omit))],
            template: titleTemplate
        )
        let compiled = try ready(value, snapshot: snapshot)
        let result = WorkspaceNavigatorPipelineEvaluator(
            calendar: newYork,
            now: { now }
        ).evaluate(compiled)

        let expectedSections: [WorkspaceNavigatorPipelineSectionIdentity] = [
            .rule(id: "today"), .rule(id: "yesterday"), .rule(id: "week"),
        ]
        XCTAssertEqual(result.sections.map(\.identity), expectedSections)
        XCTAssertEqual(result.sections.map { section in
            section.items.map { $0.sourceSessionID }
        }, [
            ["today"], ["yesterday"], ["older"],
        ])

        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let westCoast = WorkspaceNavigatorPipelineEvaluator(
            calendar: losAngeles,
            now: { now }
        ).evaluate(compiled)
        XCTAssertEqual(
            westCoast.sections.first?.items.map { $0.sourceSessionID },
            ["today"],
            "The same instant is classified against the host calendar and time zone"
        )
        XCTAssertEqual(westCoast.sections.first?.identity, .rule(id: "yesterday"))
    }

    func testVisibleRowKeepsTheCalendarWhichAdmittedItsRelativeDateConditional() throws {
        let dateKey = ExtensionFactKey(id: "example.visible-date")
        let titleKey = ExtensionHostFactKey.sessionTitle
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let referenceDate = date(2026, 8, 30, 23, 30, calendar: losAngeles)
        let sessionDate = date(2026, 8, 30, 0, 30, calendar: losAngeles)
        let pipeline = pipeline(
            consumes: [
                .init(key: dateKey, requirement: .required),
                .init(key: titleKey, requirement: .required),
            ],
            template: .conditional(
                .relativeDate(.init(.init(dateKey)), .today),
                content: .text(
                    .fact(.init(titleKey), facet: .value, fallback: nil),
                    role: .body
                )
            )
        )
        let snapshot = makeSnapshot(
            sessionIDs: ["session"],
            definitions: [
                definition(
                    dateKey,
                    type: .date,
                    kinds: [.session],
                    usages: [.filterable, .presentable]
                ),
                definition(
                    titleKey,
                    type: .string,
                    kinds: [.session],
                    usages: [.presentable]
                ),
            ],
            facts: [
                fact(dateKey, .session("session"), .date(sessionDate)),
                fact(titleKey, .session("session"), .string("Same host day")),
            ]
        )
        let compiled = try ready(pipeline, snapshot: snapshot)
        let evaluation = WorkspaceNavigatorPipelineEvaluator(
            calendar: losAngeles,
            now: { referenceDate }
        ).evaluate(compiled)
        let item = try XCTUnwrap(evaluation.sections.first?.items.first)

        XCTAssertEqual(item.calendar.timeZone.identifier, losAngeles.timeZone.identifier)
        XCTAssertEqual(
            WorkspaceNavigatorPipelineEvaluator(
                calendar: tokyo,
                now: { referenceDate }
            ).realizeVisibleRow(item, in: compiled),
            .text("Same host day", role: .body),
            "lazy realization must not reclassify the row with a newer system calendar"
        )
    }

    func testActivityInboxKeepsPriorityAheadOfCalendarSectionsAndRealizesWorkingState() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date(2026, 8, 30, 15, 0, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let activityKey = ExtensionHostFactKey.sessionDetailedActivity
        let lastUsedKey = ExtensionHostFactKey.sessionLastUsedAt
        let archivedKey = ExtensionHostFactKey.sessionIsArchived
        let snoozedKey = ExtensionHostFactKey.sessionIsSnoozed
        let definitions = [
            titleDefinition,
            definition(
                activityKey,
                type: .string,
                kinds: [.session],
                usages: [.filterable, .groupable, .presentable]
            ),
            definition(
                lastUsedKey,
                type: .date,
                kinds: [.session],
                usages: [.filterable, .sortable, .groupable]
            ),
            definition(
                archivedKey,
                type: .boolean,
                kinds: [.session],
                usages: [.filterable]
            ),
            definition(
                snoozedKey,
                type: .boolean,
                kinds: [.session],
                usages: [.filterable]
            ),
        ]
        let rows: [(
            id: String,
            title: String,
            activity: String,
            lastUsed: Date,
            archived: Bool,
            snoozed: Bool
        )] = [
            (
                "priority-old",
                "Waiting for approval",
                ExtensionSessionDetailedActivity.awaitingUser.rawValue,
                calendar.date(byAdding: .day, value: -10, to: today)!,
                false,
                false
            ),
            (
                "today-zulu",
                "Zulu working session",
                ExtensionSessionDetailedActivity.working.rawValue,
                calendar.date(byAdding: .hour, value: -1, to: now)!,
                false,
                false
            ),
            (
                "today-alpha",
                "Alpha idle session",
                ExtensionSessionDetailedActivity.idle.rawValue,
                calendar.date(byAdding: .hour, value: -2, to: now)!,
                false,
                false
            ),
            (
                "yesterday",
                "Yesterday session",
                ExtensionSessionDetailedActivity.idle.rawValue,
                calendar.date(byAdding: .hour, value: -12, to: today)!,
                false,
                false
            ),
            (
                "week",
                "Earlier this week",
                ExtensionSessionDetailedActivity.idle.rawValue,
                calendar.date(byAdding: .day, value: -4, to: today)!,
                false,
                false
            ),
            (
                "older",
                "Older session",
                ExtensionSessionDetailedActivity.idle.rawValue,
                calendar.date(byAdding: .day, value: -10, to: today)!,
                false,
                false
            ),
            (
                "archived",
                "Archived today",
                ExtensionSessionDetailedActivity.working.rawValue,
                now,
                true,
                false
            ),
            (
                "snoozed",
                "Snoozed today",
                ExtensionSessionDetailedActivity.idle.rawValue,
                now,
                false,
                true
            ),
        ]
        let facts = rows.flatMap { row in
            let subject = ExtensionFactSubject.session(row.id)
            return [
                fact(titleKey, subject, .string(row.title)),
                fact(activityKey, subject, .string(row.activity)),
                fact(lastUsedKey, subject, .date(row.lastUsed)),
                fact(archivedKey, subject, .boolean(row.archived)),
                fact(snoozedKey, subject, .boolean(row.snoozed)),
            ]
        }
        let snapshot = makeSnapshot(
            sessionIDs: rows.map(\.id),
            definitions: definitions,
            facts: facts
        )
        let declaration = try activityInboxPipelineFromShippedManifest()
        let evaluator = WorkspaceNavigatorPipelineEvaluator(
            calendar: calendar,
            now: { now }
        )
        let recent = try evaluator.evaluate(ready(
            declaration,
            snapshot: snapshot,
            optionValues: ["sort-order": .string("recent")]
        ))

        XCTAssertEqual(recent.sections.map(\.identity), [
            .rule(id: "priority"),
            .rule(id: "today"),
            .rule(id: "yesterday"),
            .rule(id: "last-seven-days"),
        ])
        XCTAssertEqual(recent.sections.map { $0.items.map(\.sourceSessionID) }, [
            ["priority-old"],
            ["today-zulu", "today-alpha"],
            ["yesterday"],
            ["week"],
        ])
        XCTAssertFalse(recent.sections.flatMap(\.items).contains {
            ["archived", "snoozed"].contains($0.sourceSessionID)
        })

        let working = try XCTUnwrap(
            recent.sections.flatMap(\.items).first { $0.sourceSessionID == "today-zulu" }
        )
        let recentProgram = try ready(
            declaration,
            snapshot: snapshot,
            optionValues: ["sort-order": .string("recent")]
        )
        XCTAssertEqual(evaluator.realizeVisibleRow(working, in: recentProgram), .stack(
            axis: .horizontal,
            spacing: .small,
            children: [
                .text("Zulu working session", role: .compactBody),
                .flexibleSpacer,
                .activityIndicator(accessibilityLabel: "Working"),
            ]
        ))

        let named = try evaluator.evaluate(ready(
            declaration,
            snapshot: snapshot,
            optionValues: ["sort-order": .string("name")]
        ))
        XCTAssertEqual(named.sections[1].items.map(\.sourceSessionID), [
            "today-alpha", "today-zulu",
        ])

        let activityChangedFacts = rows.flatMap { row in
            let subject = ExtensionFactSubject.session(row.id)
            let activity = row.id == "today-zulu"
                ? ExtensionSessionDetailedActivity.awaitingUser.rawValue
                : row.activity
            return [
                fact(titleKey, subject, .string(row.title)),
                fact(activityKey, subject, .string(activity)),
                fact(lastUsedKey, subject, .date(row.lastUsed)),
                fact(archivedKey, subject, .boolean(row.archived)),
                fact(snoozedKey, subject, .boolean(row.snoozed)),
            ]
        }
        let activityChangedSnapshot = makeSnapshot(
            sessionIDs: rows.map(\.id),
            definitions: definitions,
            facts: activityChangedFacts,
            revision: 2
        )
        let activityChangedProgram = try ready(
            declaration,
            snapshot: activityChangedSnapshot,
            optionValues: ["sort-order": .string("recent")]
        )
        let activityChanged = evaluator.evaluate(activityChangedProgram)
        XCTAssertEqual(activityChanged.sections[0].items.map(\.sourceSessionID), [
            "today-zulu", "priority-old",
        ])
        XCTAssertEqual(activityChanged.sections[1].items.map(\.sourceSessionID), [
            "today-alpha",
        ])
        let noLongerWorking = try XCTUnwrap(
            activityChanged.sections[0].items.first { $0.sourceSessionID == "today-zulu" }
        )
        XCTAssertEqual(
            evaluator.realizeVisibleRow(noLongerWorking, in: activityChangedProgram),
            .stack(
                axis: .horizontal,
                spacing: .small,
                children: [
                    .text("Zulu working session", role: .compactBody),
                    .flexibleSpacer,
                ]
            )
        )
    }

    @MainActor
    func testShippedNavigatorsUseShippedGitLabFactsWithoutStaticCoupling() throws {
        let activityPipeline = try activityInboxPipelineFromShippedManifest()
        let t3Pipeline = try XCTUnwrap(t3SidebarNavigatorFromShippedManifest().pipeline)
        let gitLabManifest = try shippedManifest(exampleDirectory: "GitLabStateExtension")
        let gitLabDefinition = try XCTUnwrap(gitLabManifest.factDefinitions.first)
        let gitLabKey = ExtensionFactKey(id: "gitlab.mr.state")
        XCTAssertEqual(gitLabManifest.factDefinitions, [gitLabDefinition])
        XCTAssertEqual(gitLabDefinition.key, gitLabKey)

        for (name, pipeline) in [
            ("Activity Inbox", activityPipeline),
            ("T3 Sidebar", t3Pipeline),
        ] {
            XCTAssertFalse(
                pipeline.consumes.contains { $0.key == gitLabKey },
                "\(name) must discover GitLab state through registered-fact options"
            )
            let declaration = String(decoding: try JSONEncoder().encode(pipeline), as: UTF8.self)
            XCTAssertFalse(
                declaration.contains(gitLabKey.id),
                "\(name) must not name the provider-specific fact in its declaration"
            )
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let referenceDate = date(2026, 9, 7, 12, 0, calendar: calendar)
        let projectID = "project-1"
        let projectSubject = ExtensionFactSubject.project(projectID)
        let repository = ExtensionRepositoryKey(host: "gitlab.com", path: "group/repository")
        let rows = [
            (id: "open", title: "Open work", branch: "feature/open"),
            (id: "merged", title: "Merged work", branch: "feature/merged"),
            (id: "unknown", title: "Unknown work", branch: "feature/unknown"),
        ]

        let registry = ExtensionFactRegistry(now: { referenceDate })
        try registry.replaceHostDefinitions(HostFactCatalog.definitions)
        let hostFacts = rows.flatMap { row in
            let subject = ExtensionFactSubject.session(row.id)
            return [
                fact(ExtensionHostFactKey.sessionTitle, subject, .string(row.title)),
                fact(ExtensionHostFactKey.sessionProjectID, subject, .string(projectID)),
                fact(
                    ExtensionHostFactKey.sessionDetailedActivity,
                    subject,
                    .string(ExtensionSessionDetailedActivity.idle.rawValue)
                ),
                fact(ExtensionHostFactKey.sessionBranch, subject, .string(row.branch)),
                fact(ExtensionHostFactKey.sessionIsArchived, subject, .boolean(false)),
                fact(ExtensionHostFactKey.sessionIsSnoozed, subject, .boolean(false)),
                fact(ExtensionHostFactKey.sessionIsPinned, subject, .boolean(false)),
                fact(ExtensionHostFactKey.sessionLastUsedAt, subject, .date(referenceDate)),
                fact(
                    ExtensionHostFactKey.sessionHasScheduledStart,
                    subject,
                    .boolean(false)
                ),
            ]
        } + [
            fact(ExtensionHostFactKey.projectName, projectSubject, .string("Navigator Project")),
            fact(
                ExtensionHostFactKey.projectRepositoryHost,
                projectSubject,
                .string(repository.host)
            ),
            fact(
                ExtensionHostFactKey.projectRepositoryPath,
                projectSubject,
                .string(repository.path)
            ),
        ]
        let hostSubjects = Set(
            rows.map { ExtensionFactSubject.session($0.id) } + [projectSubject]
        )
        try registry.replaceHostFacts(hostFacts, replacing: hostSubjects)

        let gitLabSource = ComponentCustomizationSource(
            extensionIdentifier: gitLabManifest.identifier,
            processGeneration: "generation-1",
            order: 0
        )
        try registry.replaceDefinitions([gitLabDefinition], from: gitLabSource)
        let gitLabFacts = [
            fact(
                gitLabKey,
                .repositoryBranch(repository: repository, branch: "feature/open"),
                .string("opened"),
                label: "Open",
                observedAt: referenceDate
            ),
            fact(
                gitLabKey,
                .repositoryBranch(repository: repository, branch: "feature/merged"),
                .string("merged"),
                label: "Merged",
                observedAt: referenceDate
            ),
        ]
        try registry.replaceFacts(
            gitLabFacts,
            replacing: Set(gitLabFacts.map(\.subject)),
            from: gitLabSource
        )

        let consumedKeys = Set(
            (activityPipeline.consumes + t3Pipeline.consumes).map(\.key)
        ).union([gitLabKey])
        let snapshot = registry.snapshot(consuming: consumedKeys)
        let evaluator = WorkspaceNavigatorPipelineEvaluator(
            calendar: calendar,
            now: { referenceDate }
        )

        // Activity Inbox deliberately exposes the provider-neutral group/sort option. T3 keeps
        // its defining lifecycle buckets and stable manual order; the loop above still proves
        // that neither shipped declaration names or statically couples itself to GitLab.
        let grouped = evaluator.evaluate(try ready(
            activityPipeline,
            snapshot: snapshot,
            optionValues: ["sort-order": .string("recent")],
            registeredFactSelections: ["group-by-fact": gitLabKey]
        ))
        XCTAssertEqual(grouped.sections.map(\.title), ["Merged", "Open", "Unknown"])
        XCTAssertEqual(
            grouped.sections.map { $0.items.map(\.sourceSessionID) },
            [["merged"], ["open"], ["unknown"]]
        )

        let sorted = evaluator.evaluate(try ready(
            activityPipeline,
            snapshot: snapshot,
            optionValues: ["sort-order": .string("recent")],
            registeredFactSelections: ["sort-by-fact": gitLabKey]
        ))
        XCTAssertEqual(sorted.sections.count, 1, "Activity Inbox fixture must stay in one host bucket")
        XCTAssertEqual(
            sorted.sections.flatMap(\.items).map(\.sourceSessionID),
            ["merged", "open", "unknown"],
            "Activity Inbox must sort present values first and keep missing values last"
        )
    }

    func testShippedT3SidebarRealizesLifecycleBucketsMetadataAndAvailableActions() throws {
        let navigator = try t3SidebarNavigatorFromShippedManifest()
        let declaration = try XCTUnwrap(navigator.pipeline)
        let projectID = "project-1"
        let title = ExtensionHostFactKey.sessionTitle
        let sessionProjectID = ExtensionHostFactKey.sessionProjectID
        let projectName = ExtensionHostFactKey.projectName
        let activity = ExtensionHostFactKey.sessionDetailedActivity
        let manualOrder = ExtensionHostFactKey.sessionManualOrder
        let branch = ExtensionHostFactKey.sessionBranch
        let pinned = ExtensionHostFactKey.sessionIsPinned
        let archived = ExtensionHostFactKey.sessionIsArchived
        let snoozed = ExtensionHostFactKey.sessionIsSnoozed
        let scheduled = ExtensionHostFactKey.sessionHasScheduledStart
        let definitions = [
            titleDefinition,
            definition(
                sessionProjectID,
                type: .string,
                kinds: [.session],
                usages: [.presentable]
            ),
            definition(
                projectName,
                type: .string,
                kinds: [.project],
                usages: [.presentable]
            ),
            definition(
                activity,
                type: .string,
                kinds: [.session],
                usages: [.filterable, .presentable]
            ),
            definition(
                manualOrder,
                type: .integer,
                kinds: [.session],
                usages: [.sortable]
            ),
            definition(
                branch,
                type: .string,
                kinds: [.session],
                usages: [.presentable]
            ),
            definition(
                pinned,
                type: .boolean,
                kinds: [.session],
                usages: [.filterable, .groupable]
            ),
            definition(
                archived,
                type: .boolean,
                kinds: [.session],
                usages: [.filterable, .groupable]
            ),
            definition(
                snoozed,
                type: .boolean,
                kinds: [.session],
                usages: [.filterable, .groupable]
            ),
            definition(
                scheduled,
                type: .boolean,
                kinds: [.session],
                usages: [.filterable]
            ),
        ]
        let rows: [(
            id: String,
            name: String,
            isPinned: Bool,
            isArchived: Bool,
            isSnoozed: Bool,
            isScheduled: Bool,
            activity: ExtensionSessionDetailedActivity,
            manualOrder: Int64
        )] = [
            ("z-pinned", "Pinned thread", true, false, false, false, .dormant, 80),
            ("y-ordinary", "Ordinary thread", false, false, false, false, .working, 70),
            ("x-scheduled", "Scheduled thread", false, false, false, true, .awaitingUser, 20),
            ("w-ready", "Ready thread", false, false, false, false, .readyWithBackgroundWork, 40),
            ("v-attention", "Attention thread", false, false, false, false, .needsAttention, 30),
            ("u-snoozed", "Snoozed pinned thread", true, false, true, false, .idle, 60),
            ("t-snoozed-archived", "Snoozed archived thread", true, true, true, false, .limitReached, 10),
            ("s-archived", "Archived pinned thread", true, true, false, false, .idle, 90),
            (
                "r-future",
                "Future activity thread",
                false,
                false,
                false,
                false,
                .init(rawValue: "future-activity"),
                50
            ),
        ]
        var facts = rows.flatMap { row in
            let subject = ExtensionFactSubject.session(row.id)
            return [
                fact(title, subject, .string(row.name)),
                fact(sessionProjectID, subject, .string(projectID)),
                fact(activity, subject, .string(row.activity.rawValue)),
                fact(manualOrder, subject, .integer(row.manualOrder)),
                fact(branch, subject, .string("navigator-pipeline")),
                fact(pinned, subject, .boolean(row.isPinned)),
                fact(archived, subject, .boolean(row.isArchived)),
                fact(snoozed, subject, .boolean(row.isSnoozed)),
                fact(scheduled, subject, .boolean(row.isScheduled)),
            ]
        }
        facts.append(fact(projectName, .project(projectID), .string("Navigator Project")))
        let snapshot = makeSnapshot(
            sessionIDs: rows.map(\.id),
            definitions: definitions,
            facts: facts
        )
        let evaluator = WorkspaceNavigatorPipelineEvaluator()
        let compiled = try ready(declaration, snapshot: snapshot)
        let evaluation = evaluator.evaluate(compiled)

        XCTAssertEqual(evaluation.sections.map(\.identity), [
            .rule(id: "pinned"),
            .rule(id: "active"),
            .rule(id: "snoozed"),
            .rule(id: "archived"),
        ])
        XCTAssertEqual(evaluation.sections.map { $0.items.map(\.sourceSessionID) }, [
            ["z-pinned"],
            ["x-scheduled", "v-attention", "w-ready", "r-future", "y-ordinary"],
            ["t-snoozed-archived", "u-snoozed"],
            ["s-archived"],
        ])
        let realized = Dictionary(uniqueKeysWithValues: try evaluation.sections
            .flatMap(\.items)
            .map { item in
                (item.sourceSessionID, try XCTUnwrap(
                    evaluator.realizeVisibleRow(item, in: compiled)
                ))
            })
        XCTAssertEqual(templateIntents(in: try XCTUnwrap(realized["z-pinned"])), [
            .unpin, .archive,
        ])
        XCTAssertEqual(templateIntents(in: try XCTUnwrap(realized["y-ordinary"])), [
            .pin, .archive,
        ])
        XCTAssertEqual(templateIntents(in: try XCTUnwrap(realized["x-scheduled"])), [])
        XCTAssertEqual(templateIntents(in: try XCTUnwrap(realized["u-snoozed"])), [
            .unpin, .archive,
        ])
        XCTAssertEqual(templateIntents(in: try XCTUnwrap(realized["t-snoozed-archived"])), [])
        XCTAssertEqual(templateIntents(in: try XCTUnwrap(realized["s-archived"])), [])
        let expectedStatusByID = [
            "z-pinned": "Dormant",
            "y-ordinary": "Working",
            "x-scheduled": "Waiting",
            "w-ready": "Ready",
            "v-attention": "Attention",
            "u-snoozed": "Idle",
            "t-snoozed-archived": "Limit",
            "s-archived": "Idle",
            "r-future": "Unknown",
        ]
        for row in rows {
            XCTAssertEqual(
                templateText(in: try XCTUnwrap(realized[row.id])),
                [row.name, expectedStatusByID[row.id], "Navigator Project", "navigator-pipeline"]
            )
        }

        let titleSearch = evaluator.evaluate(compiled, query: "Ordinary")
        XCTAssertEqual(titleSearch.sections.map(\.identity), [.rule(id: "active")])
        XCTAssertEqual(titleSearch.sections.flatMap(\.items).map(\.sourceSessionID), ["y-ordinary"])
        XCTAssertEqual(
            evaluator.evaluate(compiled, query: "Navigator Project").itemCount,
            0,
            "T3-inspired search must remain title-only even though project metadata is visible"
        )

        var repinnedFacts = rows.flatMap { row in
            let subject = ExtensionFactSubject.session(row.id)
            return [
                fact(title, subject, .string(row.name)),
                fact(sessionProjectID, subject, .string(projectID)),
                fact(activity, subject, .string(row.activity.rawValue)),
                fact(manualOrder, subject, .integer(row.manualOrder)),
                fact(branch, subject, .string("navigator-pipeline")),
                fact(pinned, subject, .boolean(row.id == "y-ordinary" || row.isPinned)),
                fact(archived, subject, .boolean(row.isArchived)),
                fact(snoozed, subject, .boolean(row.isSnoozed)),
                fact(scheduled, subject, .boolean(row.isScheduled)),
            ]
        }
        repinnedFacts.append(fact(
            projectName,
            .project(projectID),
            .string("Navigator Project")
        ))
        let repinnedSnapshot = makeSnapshot(
            sessionIDs: rows.map(\.id),
            definitions: definitions,
            facts: repinnedFacts,
            revision: 2
        )
        let repinnedProgram = try ready(declaration, snapshot: repinnedSnapshot)
        let repinned = evaluator.evaluate(repinnedProgram)
        XCTAssertEqual(repinned.sections[0].items.map(\.sourceSessionID), [
            "y-ordinary", "z-pinned",
        ])
        XCTAssertEqual(repinned.sections[1].items.map(\.sourceSessionID), [
            "x-scheduled", "v-attention", "w-ready", "r-future",
        ])
        let moved = try XCTUnwrap(
            repinned.sections[0].items.first { $0.sourceSessionID == "y-ordinary" }
        )
        XCTAssertEqual(
            templateIntents(in: try XCTUnwrap(
                evaluator.realizeVisibleRow(moved, in: repinnedProgram)
            )),
            [.unpin, .archive]
        )
    }

    func testVisibleRowRealizationUsesPresentationFallbacksAndExplicitProjectJoin() throws {
        let stateDefinition = definition(
            stateKey,
            type: .string,
            kinds: [.session],
            usages: [.presentable]
        )
        let detailDefinition = definition(
            detailKey,
            type: .boolean,
            kinds: [.session],
            usages: [.filterable]
        )
        let projectIDDefinition = definition(
            projectIDKey,
            type: .string,
            kinds: [.session],
            usages: [.presentable]
        )
        let projectNameDefinition = definition(
            projectNameKey,
            type: .string,
            kinds: [.project],
            usages: [.presentable]
        )
        let snapshot = makeSnapshot(
            sessionIDs: ["full", "fallback"],
            definitions: [
                titleDefinition, stateDefinition, detailDefinition,
                projectIDDefinition, projectNameDefinition,
            ],
            facts: [
                fact(titleKey, .session("full"), .string("Full")),
                fact(titleKey, .session("fallback"), .string("Fallback")),
                fact(projectIDKey, .session("full"), .string("project-1")),
                fact(projectIDKey, .session("fallback"), .string("project-1")),
                fact(projectNameKey, .project("project-1"), .string("Navigator Project")),
                fact(
                    stateKey,
                    .session("full"),
                    .string("open"),
                    label: "Open",
                    status: .positive,
                    icon: .extensionResource("icons/checkmark.png")
                ),
                fact(detailKey, .session("full"), .boolean(true)),
            ],
            sourcesByKey: [
                stateKey: .extension(
                    identifier: "com.example.fact-provider",
                    processGeneration: "generation-7"
                ),
            ]
        )
        let template = ExtensionWorkspaceNavigatorTemplateNode.stack(
            axis: .vertical,
            spacing: .small,
            children: [
                .text(.fact(.init(titleKey), facet: .value, fallback: nil), role: .body),
                .text(.fact(
                    .init(projectNameKey, scope: .project),
                    facet: .value,
                    fallback: nil
                ), role: .detail),
                .image(
                    .factIcon(.init(stateKey), fallback: .systemSymbol("questionmark")),
                    role: .icon,
                    accessibilityLabel: "State"
                ),
                .status(
                    .fact(.init(stateKey), facet: .label, fallback: "Unknown"),
                    role: .factStatus(.init(stateKey), fallback: .warning)
                ),
                .conditional(
                    .isPresent(.init(detailKey)),
                    content: .activityIndicator(accessibilityLabel: "Working")
                ),
            ]
        )
        let value = pipeline(
            consumes: [
                .init(key: titleKey), .init(key: stateKey), .init(key: detailKey),
                .init(key: projectIDKey), .init(key: projectNameKey),
            ],
            template: template
        )
        let compiled = try ready(value, snapshot: snapshot)
        let evaluator = WorkspaceNavigatorPipelineEvaluator()
        let items: [WorkspaceNavigatorPipelineItem] = evaluator.evaluate(compiled)
            .sections.flatMap(\.items)
        let full = try XCTUnwrap(items.first { $0.sourceSessionID == "full" })
        let fallback = try XCTUnwrap(items.first { $0.sourceSessionID == "fallback" })

        XCTAssertEqual(evaluator.realizeVisibleRow(full, in: compiled), .stack(
            axis: .vertical,
            spacing: .small,
            children: [
                .text("Full", role: .body),
                .text("Navigator Project", role: .detail),
                .image(.init(
                    reference: .extensionResource("icons/checkmark.png"),
                    factSource: .extension(
                        identifier: "com.example.fact-provider",
                        processGeneration: "generation-7"
                    )
                ), role: .icon, accessibilityLabel: "State"),
                .status("Open", role: .positive),
                .activityIndicator(accessibilityLabel: "Working"),
            ]
        ))
        XCTAssertEqual(evaluator.realizeVisibleRow(fallback, in: compiled), .stack(
            axis: .vertical,
            spacing: .small,
            children: [
                .text("Fallback", role: .body),
                .text("Navigator Project", role: .detail),
                .image(.init(
                    reference: .systemSymbol("questionmark"),
                    factSource: nil
                ), role: .icon, accessibilityLabel: "State"),
                .status("Unknown", role: .warning),
            ]
        ))
        XCTAssertEqual(
            fallback.destination,
            ExtensionWorkspaceNavigatorDestination.session(
                id: "fallback",
                projectID: "project-1"
            )
        )
    }

    func testVisibleRowsUseTheEvaluationClockAcrossMidnight() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let beforeMidnight = date(2026, 4, 2, 23, 59, calendar: utc)
        let afterMidnight = date(2026, 4, 3, 0, 1, calendar: utc)
        let clock = DateSequenceClock([beforeMidnight, afterMidnight])
        let dateKey = ExtensionFactKey(id: "example.visible-date")
        let snapshot = makeSnapshot(
            sessionIDs: ["session-1"],
            definitions: [
                titleDefinition,
                definition(
                    dateKey,
                    type: .date,
                    kinds: [.session],
                    usages: [.filterable]
                ),
            ],
            facts: [
                fact(titleKey, .session("session-1"), .string("One")),
                fact(dateKey, .session("session-1"), .date(beforeMidnight)),
            ]
        )
        let value = pipeline(
            consumes: [.init(key: titleKey), .init(key: dateKey)],
            template: .conditional(
                .relativeDate(.init(.init(dateKey)), .today),
                content: titleTemplate
            )
        )
        let compiled = try ready(value, snapshot: snapshot)
        let evaluator = WorkspaceNavigatorPipelineEvaluator(
            calendar: utc,
            now: { clock.next() }
        )
        let result = evaluator.evaluate(compiled)
        let item = try XCTUnwrap(result.sections.first?.items.first)

        XCTAssertEqual(result.referenceDate, beforeMidnight)
        XCTAssertEqual(item.referenceDate, beforeMidnight)
        XCTAssertEqual(evaluator.realizeVisibleRow(item, in: compiled), .text("One", role: .body))
        XCTAssertEqual(clock.callCount, 1, "Visible rows must not sample a newer host day")
    }

    func testACompletelyAbsentRealizedTemplateDoesNotEmitASelectableRow() throws {
        let snapshot = makeSnapshot(
            sessionIDs: ["full", "missing"],
            definitions: [titleDefinition],
            facts: [fact(titleKey, .session("full"), .string("Full"))]
        )
        let value = pipeline(
            consumes: [.init(key: titleKey, requirement: .required)],
            template: titleTemplate
        )

        let result = try WorkspaceNavigatorPipelineEvaluator().evaluate(
            ready(value, snapshot: snapshot)
        )

        XCTAssertEqual(result.sections.flatMap(\.items).map(\.sourceSessionID), ["full"])
    }

    func testFiveThousandSessionsAreBoundedBeforeVisibleRowRealization() throws {
        let dateKey = ExtensionFactKey(id: "example.date")
        let dateDefinition = definition(
            dateKey,
            type: .date,
            kinds: [.session],
            usages: [.sortable]
        )
        let sessionIDs = (0 ..< 5000).map { String(format: "session-%04d", $0) }
        let base = Date(timeIntervalSinceReferenceDate: 1000)
        var facts: [ExtensionFact] = []
        facts.reserveCapacity(10000)
        for (index, sessionID) in sessionIDs.enumerated() {
            facts.append(fact(titleKey, .session(sessionID), .string(sessionID)))
            facts.append(fact(
                dateKey,
                .session(sessionID),
                .date(base.addingTimeInterval(TimeInterval(index)))
            ))
        }
        let snapshot = makeSnapshot(
            sessionIDs: sessionIDs,
            definitions: [titleDefinition, dateDefinition],
            facts: facts
        )
        let value = pipeline(
            consumes: [.init(key: titleKey), .init(key: dateKey)],
            sort: [.init(operand: .init(.init(dateKey)), direction: .descending)],
            itemLimit: 1000,
            template: titleTemplate
        )
        let compiled = try ready(value, snapshot: snapshot)
        let evaluator = WorkspaceNavigatorPipelineEvaluator()
        let result = evaluator.evaluate(compiled)

        XCTAssertEqual(result.itemCount, 1000)
        XCTAssertEqual(result.omittedItemCount, 4000)
        XCTAssertEqual(
            result.sections.first?.items.first?.sourceSessionID,
            "session-4999"
        )
        XCTAssertEqual(
            result.sections.first?.items.last?.sourceSessionID,
            "session-4000"
        )
        XCTAssertEqual(
            try evaluator.realizeVisibleRow(XCTUnwrap(result.sections.first?.items.first), in: compiled),
            .text("session-4999", role: .body)
        )

        let windowedValue = pipeline(
            consumes: [.init(key: titleKey), .init(key: dateKey)],
            sort: [.init(operand: .init(.init(dateKey)), direction: .descending)],
            itemLimit: 1,
            windowing: .hostVirtualized,
            template: titleTemplate
        )
        let windowedCompiled = try ready(windowedValue, snapshot: snapshot)
        let windowedResult = evaluator.evaluate(windowedCompiled)
        let presentation = WorkspaceNavigatorPipelinePresentation(evaluation: windowedResult)

        XCTAssertEqual(windowedResult.itemCount, 5000)
        XCTAssertEqual(windowedResult.omittedItemCount, 0)
        XCTAssertEqual(
            windowedResult.sections.first?.items.first?.sourceSessionID,
            "session-4999"
        )
        XCTAssertEqual(
            windowedResult.sections.first?.items.last?.sourceSessionID,
            "session-0000"
        )
        XCTAssertEqual(
            presentation.row(matching: .session(id: "session-4999", projectID: nil)),
            0
        )
    }

    func testEvaluationSchedulerCollapsesATypeaheadBurstToTheNewestPendingRequest() throws {
        let snapshot = makeSnapshot(
            sessionIDs: ["session"],
            definitions: [titleDefinition],
            facts: [fact(titleKey, .session("session"), .string("Latest query"))]
        )
        let value = pipeline(
            consumes: [.init(key: titleKey)],
            search: .init(
                placeholder: "Search",
                accessibilityLabel: "Search sessions",
                fields: [.init(titleKey)]
            ),
            template: titleTemplate
        )
        let compiled = try ready(value, snapshot: snapshot)
        let firstEvaluationEntered = DispatchSemaphore(value: 0)
        let releaseFirstEvaluation = DispatchSemaphore(value: 0)
        let recorder = QueryRecorder()
        let deliveredLatest = expectation(description: "latest evaluation delivered")
        let scheduler = WorkspaceNavigatorPipelineEvaluationScheduler(
            evaluate: { request in
                recorder.recordEvaluation(request.query)
                if request.query == "first" {
                    firstEvaluationEntered.signal()
                    releaseFirstEvaluation.wait()
                }
                let evaluation = WorkspaceNavigatorPipelineEvaluator().evaluate(
                    request.pipeline,
                    query: request.query
                )
                return WorkspaceNavigatorPipelinePresentation(evaluation: evaluation)
            },
            deliver: { output in
                recorder.recordDelivery(output.query)
                if output.query == "Latest query" { deliveredLatest.fulfill() }
            }
        )

        scheduler.submit(.init(
            sequence: 1,
            pipeline: compiled,
            query: "first",
            calendar: .current
        ))
        XCTAssertEqual(firstEvaluationEntered.wait(timeout: .now() + 1), .success)
        for index in 2 ... 100 {
            scheduler.submit(.init(
                sequence: index,
                pipeline: compiled,
                query: index == 100 ? "Latest query" : "query-\(index)",
                calendar: .current
            ))
        }
        releaseFirstEvaluation.signal()
        wait(for: [deliveredLatest], timeout: 2)

        XCTAssertEqual(recorder.evaluations, ["first", "Latest query"])
        XCTAssertEqual(recorder.deliveries.last, "Latest query")
    }

    private var titleDefinition: ExtensionFactDefinition {
        definition(
            titleKey,
            type: .string,
            kinds: [.session],
            usages: [.filterable, .sortable, .groupable, .searchable, .presentable]
        )
    }

    private var scoreDefinition: ExtensionFactDefinition {
        definition(
            scoreKey,
            type: .integer,
            kinds: [.session],
            usages: [.filterable, .sortable, .groupable, .presentable]
        )
    }

    private var titleTemplate: ExtensionWorkspaceNavigatorTemplateNode {
        .text(.fact(.init(titleKey), facet: .value, fallback: nil), role: .body)
    }

    private func activityInboxPipelineFromShippedManifest() throws
        -> ExtensionWorkspaceNavigatorPipeline
    {
        let manifest = try shippedManifest(exampleDirectory: "ActivityInboxExtension")
        let navigator = try XCTUnwrap(
            manifest.workspaceNavigators.first { $0.id == "activity-inbox" }
        )
        return try XCTUnwrap(navigator.pipeline)
    }

    private func t3SidebarNavigatorFromShippedManifest() throws
        -> ExtensionWorkspaceNavigator
    {
        let manifest = try shippedManifest(exampleDirectory: "T3SidebarExtension")
        return try XCTUnwrap(
            manifest.workspaceNavigators.first { $0.id == "t3-sidebar" }
        )
    }

    private func shippedManifest(exampleDirectory: String) throws -> ExtensionManifest {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = repositoryRoot.appendingPathComponent(
            "Packages/ThreadingExtensionKit/Examples/\(exampleDirectory)/"
                + "threading-extension.json"
        )
        let manifest = try JSONDecoder().decode(
            ExtensionManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        try manifest.validate()
        return manifest
    }

    private func templateIntents(
        in node: WorkspaceNavigatorRealizedTemplateNode
    ) -> [ExtensionWorkspaceNavigatorIntent] {
        switch node {
        case let .intent(intent):
            [intent]
        case let .stack(_, _, children):
            children.flatMap(templateIntents(in:))
        default:
            []
        }
    }

    private func templateText(in node: WorkspaceNavigatorRealizedTemplateNode) -> [String] {
        switch node {
        case let .text(text, _):
            [text]
        case let .status(text, _):
            [text]
        case let .stack(_, _, children):
            children.flatMap(templateText(in:))
        default:
            []
        }
    }

    private func pipeline(
        consumes: [ExtensionWorkspaceNavigatorFactConsumption],
        registeredFactOptions: [ExtensionWorkspaceNavigatorRegisteredFactOption] = [],
        search: ExtensionWorkspaceNavigatorSearch? = nil,
        filters: [ExtensionWorkspaceNavigatorFilterClause] = [],
        buckets: [ExtensionWorkspaceNavigatorBucketClause] = [],
        sort: [ExtensionWorkspaceNavigatorSortClause] = [],
        itemLimit: Int = 1000,
        windowing: ExtensionWorkspaceNavigatorPipelineWindowing? = nil,
        template: ExtensionWorkspaceNavigatorTemplateNode
    ) -> ExtensionWorkspaceNavigatorPipeline {
        .init(
            consumes: consumes,
            registeredFactOptions: registeredFactOptions,
            search: search,
            filters: filters,
            buckets: buckets,
            sort: sort,
            output: .init(
                collectionID: "sessions",
                itemLimit: itemLimit,
                windowing: windowing,
                rowTemplate: template,
                emptyState: .init(title: "Nothing here")
            )
        )
    }

    private func ready(
        _ pipeline: ExtensionWorkspaceNavigatorPipeline,
        snapshot: ExtensionFactSnapshot,
        optionValues: [String: ExtensionJSONValue] = [:],
        registeredFactSelections: [String: ExtensionFactKey] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CompiledWorkspaceNavigatorPipeline {
        switch WorkspaceNavigatorPipelineCompiler().compile(
            pipeline,
            snapshot: snapshot,
            optionValues: optionValues,
            registeredFactSelections: registeredFactSelections
        ) {
        case let .ready(value):
            return value
        case let .unavailable(facts):
            XCTFail("Pipeline unavailable for \(facts)", file: file, line: line)
        case let .invalid(issues):
            XCTFail("Pipeline invalid: \(issues)", file: file, line: line)
        }
        throw TestFailure.compilation
    }

    private func makeSnapshot(
        sessionIDs: [String],
        definitions: [ExtensionFactDefinition],
        facts: [ExtensionFact],
        revision: UInt64 = 1,
        sourcesByKey: [ExtensionFactKey: ExtensionFactResolutionSource] = [:]
    ) -> ExtensionFactSnapshot {
        let definitionsByKey = Dictionary(
            uniqueKeysWithValues: definitions.map { ($0.key, $0) }
        )
        let providers = Dictionary(
            uniqueKeysWithValues: definitions.map {
                ($0.key, Set([sourcesByKey[$0.key] ?? ExtensionFactResolutionSource.host]))
            }
        )
        var table: ExtensionFactSnapshot.FactTable = [:]
        for fact in facts {
            guard let definition = definitionsByKey[fact.key] else {
                preconditionFailure("Missing test definition for \(fact.key)")
            }
            table[fact.subject, default: [:]][fact.key] = .init(
                fact: fact,
                definition: definition,
                source: sourcesByKey[fact.key] ?? .host,
                receivedAt: fact.observedAt
            )
        }
        return .init(
            revision: revision,
            sessionSubjects: sessionIDs.map(ExtensionFactSubject.session),
            definitionsByKey: definitionsByKey,
            providersByKey: providers,
            factsBySubject: table
        )
    }

    private func definition(
        _ key: ExtensionFactKey,
        type: ExtensionFactValueType,
        kinds: Set<ExtensionFactSubjectKind>,
        usages: Set<ExtensionFactUsage>
    ) -> ExtensionFactDefinition {
        .init(
            key: key,
            displayName: key.id,
            valueType: type,
            subjectKinds: kinds,
            usages: usages
        )
    }

    private func fact(
        _ key: ExtensionFactKey,
        _ subject: ExtensionFactSubject,
        _ value: ExtensionFactValue,
        label: String? = nil,
        status: ExtensionStatusRole? = nil,
        icon: ExtensionImageReference? = nil,
        observedAt: Date = Date(timeIntervalSinceReferenceDate: 100)
    ) -> ExtensionFact {
        .init(
            key: key,
            subject: subject,
            value: value,
            label: label,
            status: status,
            icon: icon,
            observedAt: observedAt
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}

private enum TestFailure: Error {
    case compilation
}

private final class DateSequenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private let dates: [Date]
    private var index = 0

    init(_ dates: [Date]) {
        precondition(!dates.isEmpty)
        self.dates = dates
    }

    var callCount: Int {
        lock.withLock { index }
    }

    func next() -> Date {
        lock.withLock {
            let date = dates[min(index, dates.count - 1)]
            index += 1
            return date
        }
    }
}

private final class QueryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvaluations: [String] = []
    private var recordedDeliveries: [String] = []

    var evaluations: [String] { lock.withLock { recordedEvaluations } }
    var deliveries: [String] { lock.withLock { recordedDeliveries } }

    func recordEvaluation(_ query: String) {
        lock.withLock { recordedEvaluations.append(query) }
    }

    func recordDelivery(_ query: String) {
        lock.withLock { recordedDeliveries.append(query) }
    }
}
