import Foundation
@testable import ThreadingExtensionKit
import XCTest

final class WorkspaceNavigatorPipelineContractTests: XCTestCase {
    func testActivityInboxPipelineRoundTripsAndConsumesEveryDeclaration() throws {
        let navigator = activityInboxNavigator()

        XCTAssertEqual(navigator.validationIssues(path: "navigator"), [])
        let data = try JSONEncoder().encode(navigator)
        XCTAssertEqual(
            try JSONDecoder().decode(ExtensionWorkspaceNavigator.self, from: data),
            navigator
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(object["root"], "v1 fallback remains on the wire")
        XCTAssertNotNil(object["pipeline"])
    }

    func testLegacyNavigatorWireRemainsPipelineFree() throws {
        let legacy = ExtensionWorkspaceNavigator(
            id: "legacy",
            title: "Legacy",
            root: .content(.status("Ready", role: .neutral))
        )

        let data = try JSONEncoder().encode(legacy)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(object["pipeline"])
        XCTAssertNil(try JSONDecoder().decode(
            ExtensionWorkspaceNavigator.self,
            from: data
        ).pipeline)
    }

    func testExplicitNullPipelineIsRejectedRatherThanTreatedAsLegacyAbsence() {
        let data = Data("""
        {
          "id": "legacy",
          "title": "Legacy",
          "root": {
            "type": "content",
            "content": { "type": "status", "text": "Ready", "role": "neutral" }
          },
          "pipeline": null
        }
        """.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(
            ExtensionWorkspaceNavigator.self,
            from: data
        ))
    }

    func testEveryTaggedPipelineWireShapeIsPinnedExactly() throws {
        let title = ExtensionWorkspaceNavigatorFactReference(ExtensionHostFactKey.sessionTitle)
        let operand = ExtensionWorkspaceNavigatorFactOperand(title)
        let present = ExtensionWorkspaceNavigatorPredicate.isPresent(title)

        try assertWire(
            ExtensionWorkspaceNavigatorPredicate.comparison(
                operand,
                .equal,
                .string("Ready")
            ),
            equals: """
            {"type":"comparison","operand":{"fact":{"key":{"id":"session.title","version":1},"scope":"item"}},"operation":"equal","value":{"type":"string","value":"Ready"}}
            """
        )
        try assertWire(
            present,
            equals: """
            {"type":"isPresent","fact":{"key":{"id":"session.title","version":1},"scope":"item"}}
            """
        )
        for (range, expected) in [
            (ExtensionWorkspaceNavigatorRelativeDateRange.today, "today"),
            (.yesterday, "yesterday"),
        ] {
            try assertWire(
                ExtensionWorkspaceNavigatorPredicate.relativeDate(operand, range),
                equals: """
                {"type":"relativeDate","operand":{"fact":{"key":{"id":"session.title","version":1},"scope":"item"}},"range":{"type":"\(expected)"}}
                """
            )
        }
        try assertWire(
            ExtensionWorkspaceNavigatorPredicate.relativeDate(operand, .lastDays(7)),
            equals: """
            {"type":"relativeDate","operand":{"fact":{"key":{"id":"session.title","version":1},"scope":"item"}},"range":{"type":"lastDays","days":7}}
            """
        )
        try assertWire(
            ExtensionWorkspaceNavigatorPredicate.all([present]),
            equals: """
            {"type":"all","predicates":[{"type":"isPresent","fact":{"key":{"id":"session.title","version":1},"scope":"item"}}]}
            """
        )
        try assertWire(
            ExtensionWorkspaceNavigatorPredicate.any([present]),
            equals: """
            {"type":"any","predicates":[{"type":"isPresent","fact":{"key":{"id":"session.title","version":1},"scope":"item"}}]}
            """
        )
        try assertWire(
            ExtensionWorkspaceNavigatorPredicate.not(present),
            equals: """
            {"type":"not","predicate":{"type":"isPresent","fact":{"key":{"id":"session.title","version":1},"scope":"item"}}}
            """
        )

        try assertWire(
            ExtensionWorkspaceNavigatorBucketStrategy.fact(
                operand,
                direction: .ascending,
                explicitOrder: [.string("Ready")]
            ),
            equals: """
            {"type":"fact","operand":{"fact":{"key":{"id":"session.title","version":1},"scope":"item"}},"direction":"ascending","explicitOrder":[{"type":"string","value":"Ready"}]}
            """
        )
        try assertWire(
            ExtensionWorkspaceNavigatorUnmatchedBucket.omit,
            equals: "{\"type\":\"omit\"}"
        )
        try assertWire(
            ExtensionWorkspaceNavigatorBucketStrategy.rules(
                [.init(id: "ready", title: "Ready", predicate: present)],
                unmatched: .bucket(id: "other", title: "Other")
            ),
            equals: """
            {"type":"rules","rules":[{"id":"ready","title":"Ready","predicate":{"type":"isPresent","fact":{"key":{"id":"session.title","version":1},"scope":"item"}}}],"unmatched":{"type":"bucket","id":"other","title":"Other"}}
            """
        )

        try assertWire(
            ExtensionWorkspaceNavigatorTextBinding.literal("Title"),
            equals: "{\"type\":\"literal\",\"text\":\"Title\"}"
        )
        try assertWire(
            ExtensionWorkspaceNavigatorTextBinding.fact(title, facet: .label, fallback: "Unknown"),
            equals: """
            {"type":"fact","fact":{"key":{"id":"session.title","version":1},"scope":"item"},"facet":"label","fallback":"Unknown"}
            """
        )
        try assertWire(
            ExtensionWorkspaceNavigatorImageBinding.literal(.systemSymbol("terminal")),
            equals: """
            {"type":"literal","reference":{"type":"systemSymbol","name":"terminal"}}
            """
        )
        try assertWire(
            ExtensionWorkspaceNavigatorImageBinding.factIcon(
                title,
                fallback: .extensionResource("Resources/fallback.png")
            ),
            equals: """
            {"type":"factIcon","fact":{"key":{"id":"session.title","version":1},"scope":"item"},"fallback":{"type":"extensionResource","path":"Resources/fallback.png"}}
            """
        )
        try assertWire(
            ExtensionWorkspaceNavigatorStatusBinding.literal(.neutral),
            equals: "{\"type\":\"literal\",\"role\":\"neutral\"}"
        )
        try assertWire(
            ExtensionWorkspaceNavigatorStatusBinding.factStatus(title, fallback: .warning),
            equals: """
            {"type":"factStatus","fact":{"key":{"id":"session.title","version":1},"scope":"item"},"fallback":"warning"}
            """
        )

        let templateCases: [(ExtensionWorkspaceNavigatorTemplateNode, String)] = [
            (.text(.literal("Title"), role: .body),
             "{\"type\":\"text\",\"binding\":{\"type\":\"literal\",\"text\":\"Title\"},\"role\":\"body\"}"),
            (.image(.literal(.hostAsset("project")), role: .icon, accessibilityLabel: "Project"),
             "{\"type\":\"image\",\"binding\":{\"type\":\"literal\",\"reference\":{\"type\":\"hostAsset\",\"identifier\":\"project\"}},\"role\":\"icon\",\"accessibilityLabel\":\"Project\"}"),
            (.status(.literal("Ready"), role: .literal(.positive)),
             "{\"type\":\"status\",\"binding\":{\"type\":\"literal\",\"text\":\"Ready\"},\"role\":{\"type\":\"literal\",\"role\":\"positive\"}}"),
            (.activityIndicator(accessibilityLabel: "Working"),
             "{\"type\":\"activityIndicator\",\"accessibilityLabel\":\"Working\"}"),
            (.conditional(present, content: .divider),
             "{\"type\":\"conditional\",\"predicate\":{\"type\":\"isPresent\",\"fact\":{\"key\":{\"id\":\"session.title\",\"version\":1},\"scope\":\"item\"}},\"content\":{\"type\":\"divider\"}}"),
            (.divider, "{\"type\":\"divider\"}"),
            (.spacer(.small), "{\"type\":\"spacer\",\"spacing\":\"small\"}"),
            (.flexibleSpacer, "{\"type\":\"flexibleSpacer\"}"),
            (.stack(axis: .horizontal, spacing: .tight, children: [.divider]),
             "{\"type\":\"stack\",\"axis\":\"horizontal\",\"spacing\":\"tight\",\"children\":[{\"type\":\"divider\"}]}"),
        ]
        for (value, expected) in templateCases {
            try assertWire(value, equals: expected)
        }
    }

    func testPipelineRejectsUndeclaredAndUnusedFacts() {
        let pipeline = ExtensionWorkspaceNavigatorPipeline(
            consumes: [
                .init(key: ExtensionHostFactKey.sessionTitle),
                .init(key: ExtensionHostFactKey.sessionModel),
            ],
            filters: [
                .init(predicate: .isPresent(.init(ExtensionHostFactKey.sessionBranch))),
            ],
            output: output(titleFact: ExtensionHostFactKey.sessionTitle)
        )

        let issues = pipeline.validationIssues(path: "pipeline")
        XCTAssertTrue(issues.contains {
            $0.path == "pipeline.consumes"
                && $0.message.contains("session.branch@1")
        })
        XCTAssertTrue(issues.contains {
            $0.path == "pipeline.consumes"
                && $0.message.contains("unused fact 'session.model@1'")
        })
    }

    func testProjectScopedReferenceRequiresExplicitSessionProjectJoin() {
        let pipeline = ExtensionWorkspaceNavigatorPipeline(
            consumes: [.init(key: ExtensionHostFactKey.projectName)],
            output: output(
                titleFact: ExtensionHostFactKey.projectName,
                scope: .project
            )
        )

        XCTAssertTrue(pipeline.validationIssues(path: "pipeline").contains {
            $0.path == "pipeline.consumes"
                && $0.message.contains("session.project-id@1")
        })

        let joined = ExtensionWorkspaceNavigatorPipeline(
            consumes: [
                .init(key: ExtensionHostFactKey.sessionProjectID, requirement: .required),
                .init(key: ExtensionHostFactKey.projectName, requirement: .required),
            ],
            output: output(
                titleFact: ExtensionHostFactKey.projectName,
                scope: .project
            )
        )
        XCTAssertEqual(joined.validationIssues(path: "pipeline"), [])
    }

    func testPipelineRejectsInertOrMismatchedOptions() {
        let options = [
            ExtensionWorkspaceNavigatorOption(
                id: "sort-order",
                title: "Sort",
                control: .choice(
                    defaultValue: "recent",
                    options: [
                        .init(id: "recent", title: "Recent"),
                        .init(id: "name", title: "Name"),
                    ]
                )
            ),
            ExtensionWorkspaceNavigatorOption(
                id: "compact",
                title: "Compact",
                control: .toggle(defaultValue: false)
            ),
        ]
        let pipeline = ExtensionWorkspaceNavigatorPipeline(
            consumes: [.init(key: ExtensionHostFactKey.sessionTitle)],
            sort: [
                .init(
                    when: [.init(optionID: "sort-order", equals: .string("missing"))],
                    operand: .init(.init(ExtensionHostFactKey.sessionTitle)),
                    direction: .ascending
                ),
            ],
            output: output(titleFact: ExtensionHostFactKey.sessionTitle)
        )

        let issues = pipeline.validationIssues(path: "pipeline", options: options)
        XCTAssertTrue(issues.contains {
            $0.path == "pipeline.sort[0].when[0].equals"
                && $0.message.contains("not accepted")
        })
        XCTAssertTrue(issues.contains {
            $0.path == "pipeline.options"
                && $0.message.contains("'compact'")
        })
    }

    func testPipelineRejectsActionDrivenRefreshAndEvents() {
        var navigator = activityInboxNavigator()
        navigator = ExtensionWorkspaceNavigator(
            id: navigator.id,
            title: navigator.title,
            root: navigator.root,
            options: navigator.options,
            pipeline: navigator.pipeline,
            loadActionID: "load",
            eventActionID: "events"
        )

        let issues = navigator.validationIssues(path: "navigator")
        XCTAssertTrue(issues.contains {
            $0.path == "navigator.loadActionID"
                && $0.message.contains("not available")
        })
        XCTAssertTrue(issues.contains {
            $0.path == "navigator.eventActionID"
                && $0.message.contains("not available")
        })
    }

    func testPipelineBoundsRejectLimitPlusOne() {
        let fields = (0 ... ExtensionWorkspaceNavigatorPipeline.maximumSearchFields).map {
            ExtensionWorkspaceNavigatorFactReference(.init(id: "example.field-\($0)"))
        }
        let consumes = fields.map {
            ExtensionWorkspaceNavigatorFactConsumption(key: $0.key)
        }
        let pipeline = ExtensionWorkspaceNavigatorPipeline(
            consumes: consumes,
            search: .init(
                placeholder: "Search",
                accessibilityLabel: "Search sessions",
                fields: fields
            ),
            output: .init(
                collectionID: "sessions",
                rowTemplate: .text(.literal("Session"), role: .body)
            )
        )

        XCTAssertTrue(pipeline.validationIssues(path: "pipeline").contains {
            $0.path == "pipeline.search.fields"
                && $0.message.contains("at most 8")
        })
    }

    func testOutputPinsSourceSessionRoutingAndBoundedOverflow() throws {
        let output = ExtensionWorkspaceNavigatorPipelineOutput(
            collectionID: "sessions",
            itemLimit: 250,
            rowTemplate: .text(.literal("Session"), role: .body)
        )

        XCTAssertEqual(
            output.activation.destination(
                sourceSessionID: "session-1",
                projectID: "project-1"
            ),
            .session(id: "session-1", projectID: "project-1")
        )
        XCTAssertEqual(output.overflow, .truncateWithNotice)
        XCTAssertEqual(
            try jsonObject(output)["activation"] as? String,
            "sourceSession"
        )
        XCTAssertEqual(
            try jsonObject(output)["overflow"] as? String,
            "truncateWithNotice"
        )

        let overLimit = ExtensionWorkspaceNavigatorPipeline(
            consumes: [.init(key: ExtensionHostFactKey.sessionTitle)],
            output: .init(
                collectionID: "sessions",
                itemLimit: ExtensionWorkspaceNavigatorPipeline.maximumOutputItems + 1,
                rowTemplate: .text(
                    .fact(
                        .init(ExtensionHostFactKey.sessionTitle),
                        facet: .value,
                        fallback: "Untitled"
                    ),
                    role: .body
                )
            )
        )
        XCTAssertTrue(overLimit.validationIssues().contains {
            $0.path == "pipeline.output.itemLimit"
        })
    }

    func testEncodedOutputMatchesPublishedSchemaShape() throws {
        let output = ExtensionWorkspaceNavigatorPipelineOutput(
            collectionID: "sessions",
            rowTemplate: .text(.literal("Session"), role: .body)
        )
        let encodedKeys = try Set(jsonObject(output).keys)
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schemaData = try Data(contentsOf: repository
            .appendingPathComponent("docs/extensions/schema/workspace-navigator-pipeline.schema.json"))
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
        )
        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let outputSchema = try XCTUnwrap(definitions["output"] as? [String: Any])
        let required = try XCTUnwrap(outputSchema["required"] as? [String])
        let properties = try XCTUnwrap(outputSchema["properties"] as? [String: Any])

        XCTAssertEqual(encodedKeys, Set(required))
        XCTAssertEqual(
            (properties["activation"] as? [String: Any])?["const"] as? String,
            "sourceSession"
        )
        XCTAssertEqual(
            (properties["overflow"] as? [String: Any])?["const"] as? String,
            "truncateWithNotice"
        )
        XCTAssertEqual(
            (properties["itemLimit"] as? [String: Any])?["maximum"] as? Int,
            ExtensionWorkspaceNavigatorPipeline.maximumOutputItems
        )
    }

    func testPipelineRejectsInvalidLiteralAndFallbackImages() {
        let title = ExtensionWorkspaceNavigatorFactReference(ExtensionHostFactKey.sessionTitle)
        let icon = ExtensionWorkspaceNavigatorFactReference(
            ExtensionFactKey(id: "example.icon")
        )
        let pipeline = ExtensionWorkspaceNavigatorPipeline(
            consumes: [
                .init(key: title.key, requirement: .required),
                .init(key: icon.key, requirement: .enhances),
            ],
            output: .init(
                collectionID: "sessions",
                rowTemplate: .stack(
                    axis: .horizontal,
                    spacing: .small,
                    children: [
                        .image(
                            .literal(.systemSymbol("")),
                            role: .icon,
                            accessibilityLabel: nil
                        ),
                        .image(
                            .factIcon(icon, fallback: .extensionResource("../../secret")),
                            role: .icon,
                            accessibilityLabel: nil
                        ),
                        .text(.fact(title, facet: .value, fallback: "Untitled"), role: .body),
                    ]
                )
            )
        )

        let issues = pipeline.validationIssues()
        XCTAssertTrue(issues.contains {
            $0.path == "pipeline.output.rowTemplate.children[0].binding.reference"
                && $0.message.contains("1 to 512 UTF-8 bytes")
        })
        XCTAssertTrue(issues.contains {
            $0.path == "pipeline.output.rowTemplate.children[1].binding.fallback"
                && $0.message.contains("safe package-relative path")
        })
    }

    func testFactBucketFallbackMatchesExplicitValueType() {
        let title = ExtensionWorkspaceNavigatorFactReference(ExtensionHostFactKey.sessionTitle)
        let pipeline = ExtensionWorkspaceNavigatorPipeline(
            consumes: [.init(key: title.key)],
            buckets: [
                .init(strategy: .fact(
                    .init(title, fallback: .string("Unknown")),
                    direction: .ascending,
                    explicitOrder: [.boolean(true)]
                )),
            ],
            output: output(titleFact: title.key)
        )

        XCTAssertTrue(pipeline.validationIssues().contains {
            $0.path == "pipeline.buckets[0].strategy.operand.fallback"
                && $0.message.contains("same scalar type")
        })
    }

    private func activityInboxNavigator() -> ExtensionWorkspaceNavigator {
        let title = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionTitle
        )
        let activity = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionDetailedActivity
        )
        let lastUsed = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionLastUsedAt
        )
        let archived = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionIsArchived
        )
        let snoozed = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionIsSnoozed
        )
        let sortRecent = ExtensionWorkspaceNavigatorOptionCondition(
            optionID: "sort-order",
            equals: .string("recent")
        )
        let sortName = ExtensionWorkspaceNavigatorOptionCondition(
            optionID: "sort-order",
            equals: .string("name")
        )

        return ExtensionWorkspaceNavigator(
            id: "activity-inbox",
            title: "Activity Inbox",
            root: .content(.status("Activity Inbox requires a newer Threading host.", role: .neutral)),
            options: [
                .init(
                    id: "sort-order",
                    title: "Sort",
                    control: .choice(
                        defaultValue: "recent",
                        options: [
                            .init(id: "recent", title: "Recent activity"),
                            .init(id: "name", title: "Name"),
                        ]
                    )
                ),
            ],
            pipeline: ExtensionWorkspaceNavigatorPipeline(
                consumes: [
                    .init(key: title.key, requirement: .required),
                    .init(key: activity.key, requirement: .enhances),
                    .init(key: lastUsed.key, requirement: .enhances),
                    .init(key: archived.key, requirement: .required),
                    .init(key: snoozed.key, requirement: .required),
                ],
                search: .init(
                    placeholder: "Search",
                    accessibilityLabel: "Search sessions",
                    fields: [title]
                ),
                filters: [
                    .init(predicate: .comparison(
                        .init(archived),
                        .equal,
                        .boolean(false)
                    )),
                    .init(predicate: .comparison(
                        .init(snoozed),
                        .equal,
                        .boolean(false)
                    )),
                ],
                buckets: [
                    .init(strategy: .rules(
                        [
                            .init(
                                id: "priority",
                                title: "Priority",
                                predicate: .comparison(
                                    .init(activity),
                                    .equal,
                                    .string("awaiting-user")
                                )
                            ),
                            .init(
                                id: "today",
                                title: "Today",
                                predicate: .relativeDate(.init(lastUsed), .today)
                            ),
                            .init(
                                id: "yesterday",
                                title: "Yesterday",
                                predicate: .relativeDate(.init(lastUsed), .yesterday)
                            ),
                            .init(
                                id: "last-seven-days",
                                title: "Last 7 days",
                                predicate: .relativeDate(.init(lastUsed), .lastDays(7))
                            ),
                        ],
                        unmatched: .bucket(id: "older", title: "Older")
                    )),
                ],
                sort: [
                    .init(
                        when: [sortRecent],
                        operand: .init(lastUsed),
                        direction: .descending
                    ),
                    .init(
                        when: [sortName],
                        operand: .init(title),
                        direction: .ascending
                    ),
                ],
                output: .init(
                    collectionID: "sessions",
                    rowTemplate: .stack(
                        axis: .horizontal,
                        spacing: .small,
                        children: [
                            .text(
                                .fact(title, facet: .value, fallback: "Untitled session"),
                                role: .body
                            ),
                            .flexibleSpacer,
                            .conditional(
                                .comparison(
                                    .init(activity),
                                    .equal,
                                    .string("working")
                                ),
                                content: .activityIndicator(
                                    accessibilityLabel: "Working"
                                )
                            ),
                        ]
                    ),
                    emptyState: .init(
                        title: "No sessions",
                        detail: "Try changing the search or filter."
                    )
                )
            )
        )
    }

    private func output(
        titleFact: ExtensionFactKey,
        scope: ExtensionWorkspaceNavigatorFactScope = .item
    ) -> ExtensionWorkspaceNavigatorPipelineOutput {
        .init(
            collectionID: "sessions",
            rowTemplate: .text(
                .fact(.init(titleFact, scope: scope), facet: .value, fallback: "Untitled"),
                role: .body
            )
        )
    }

    private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                as? [String: Any]
        )
    }

    private func assertWire(
        _ value: some Encodable,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expectedObject = try JSONSerialization.jsonObject(with: Data(expected.utf8))
        let actualObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        XCTAssertEqual(
            try String(data: JSONSerialization.data(
                withJSONObject: actualObject,
                options: [.sortedKeys]
            ), encoding: .utf8),
            try String(data: JSONSerialization.data(
                withJSONObject: expectedObject,
                options: [.sortedKeys]
            ), encoding: .utf8),
            file: file,
            line: line
        )
    }
}
