import Foundation
import ThreadingExtensionKit

/// A familiar session-first sidebar expressed entirely through the public navigator pipeline.
///
/// The extension receives no session snapshot and no action callback. Threading evaluates the
/// declaration over host facts, realizes only visible rows, and performs pin, unpin, and archive
/// through its native persistence and lifecycle paths.
public enum T3SidebarExtensionContract {
    public static let navigator: ExtensionWorkspaceNavigator = {
        let title = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionTitle
        )
        let projectID = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionProjectID
        )
        let projectName = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.projectName,
            scope: .project
        )
        let pinned = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionIsPinned
        )
        let archived = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionIsArchived
        )
        let lastUsed = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionLastUsedAt
        )
        let hasScheduledStart = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionHasScheduledStart
        )
        let recentSort = ExtensionWorkspaceNavigatorOptionCondition(
            optionID: "sort-order",
            equals: .string("recent")
        )
        let nameSort = ExtensionWorkspaceNavigatorOptionCondition(
            optionID: "sort-order",
            equals: .string("name")
        )
        let isPinned = ExtensionWorkspaceNavigatorPredicate.comparison(
            .init(pinned, fallback: .boolean(false)),
            .equal,
            .boolean(true)
        )
        let isNotPinned = ExtensionWorkspaceNavigatorPredicate.comparison(
            .init(pinned, fallback: .boolean(false)),
            .equal,
            .boolean(false)
        )
        let canAct = ExtensionWorkspaceNavigatorPredicate.comparison(
            .init(hasScheduledStart, fallback: .boolean(false)),
            .equal,
            .boolean(false)
        )

        return ExtensionWorkspaceNavigator(
            id: "t3-sidebar",
            title: "T3 Sidebar",
            root: .content(.status(
                "T3 Sidebar requires a newer Threading host.",
                role: .neutral
            )),
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
            intents: [.pin, .unpin, .archive],
            pipeline: .init(
                consumes: [
                    .init(key: title.key, requirement: .required),
                    .init(key: projectID.key, requirement: .required),
                    .init(key: projectName.key, requirement: .required),
                    .init(key: pinned.key, requirement: .required),
                    .init(key: archived.key, requirement: .required),
                    .init(key: lastUsed.key, requirement: .required),
                    .init(key: hasScheduledStart.key, requirement: .required),
                ],
                registeredFactOptions: [
                    .init(
                        id: "group-by-fact",
                        title: "Group by",
                        application: .bucket(
                            direction: .ascending,
                            unknownTitle: "Unknown"
                        )
                    ),
                    .init(
                        id: "sort-by-fact",
                        title: "Sort by",
                        application: .sort(direction: .ascending)
                    ),
                ],
                search: .init(
                    placeholder: "Search sessions",
                    accessibilityLabel: "Search T3 Sidebar sessions",
                    fields: [title, projectName]
                ),
                filters: [
                    .init(predicate: .comparison(
                        .init(archived, fallback: .boolean(false)),
                        .equal,
                        .boolean(false)
                    )),
                ],
                buckets: [
                    .init(strategy: .rules(
                        [
                            .init(
                                id: "pinned",
                                title: "Pinned",
                                predicate: isPinned
                            ),
                        ],
                        unmatched: .bucket(id: "sessions", title: "Sessions")
                    )),
                ],
                sort: [
                    .init(
                        when: [recentSort],
                        operand: .init(lastUsed),
                        direction: .descending
                    ),
                    .init(
                        when: [nameSort],
                        operand: .init(title),
                        direction: .ascending
                    ),
                ],
                output: .init(
                    collectionID: "t3-sessions",
                    windowing: .hostVirtualized,
                    rowTemplate: .stack(
                        axis: .horizontal,
                        spacing: .small,
                        children: [
                            .stack(
                                axis: .vertical,
                                spacing: .tight,
                                children: [
                                    .text(
                                        .fact(
                                            title,
                                            facet: .value,
                                            fallback: "Untitled session"
                                        ),
                                        role: .compactBody
                                    ),
                                    .text(
                                        .fact(
                                            projectName,
                                            facet: .value,
                                            fallback: "No project"
                                        ),
                                        role: .compactDetail
                                    ),
                                ]
                            ),
                            .flexibleSpacer,
                            .conditional(
                                .all([isNotPinned, canAct]),
                                content: .intent(.pin)
                            ),
                            .conditional(
                                .all([isPinned, canAct]),
                                content: .intent(.unpin)
                            ),
                            .conditional(canAct, content: .intent(.archive)),
                        ]
                    ),
                    emptyState: .init(
                        title: "No sessions",
                        detail: "Try changing the search or sort option."
                    )
                )
            )
        )
    }()

    public static let manifest = ExtensionManifest(
        identifier: "codes.threading.t3-sidebar",
        name: "T3 Sidebar",
        version: "0.1.0",
        runtime: .webAssembly,
        executable: "bin/t3-sidebar.wasm",
        capabilities: [.workspaceNavigation],
        workspaceNavigators: [navigator]
    )

    public static let registration = ExtensionRegistration(
        workspaceNavigators: [navigator]
    )
}
