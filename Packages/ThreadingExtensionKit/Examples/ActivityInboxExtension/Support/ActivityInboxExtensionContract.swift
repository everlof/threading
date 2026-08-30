import Foundation
import ThreadingExtensionKit

/// A complete navigator assembled only from the public pipeline vocabulary.
///
/// The extension contributes no session-reading capability and runs no code when facts change.
/// Threading evaluates this static declaration over its own generation-fenced fact snapshot,
/// owns the calendar boundary, realizes visible rows, and routes their source-session intent.
public enum ActivityInboxExtensionContract {
    public static let navigator: ExtensionWorkspaceNavigator = {
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
        let recentSort = ExtensionWorkspaceNavigatorOptionCondition(
            optionID: "sort-order",
            equals: .string("recent")
        )
        let nameSort = ExtensionWorkspaceNavigatorOptionCondition(
            optionID: "sort-order",
            equals: .string("name")
        )

        return ExtensionWorkspaceNavigator(
            id: "activity-inbox",
            title: "Activity Inbox",
            root: .content(.status(
                "Activity Inbox requires a newer Threading host.",
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
            pipeline: .init(
                consumes: [
                    .init(key: title.key, requirement: .required),
                    .init(key: activity.key, requirement: .required),
                    .init(key: lastUsed.key, requirement: .required),
                    .init(key: archived.key, requirement: .required),
                    .init(key: snoozed.key, requirement: .required),
                ],
                search: .init(
                    placeholder: "Search sessions",
                    accessibilityLabel: "Search Activity Inbox sessions",
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
                                    .string(ExtensionSessionDetailedActivity.awaitingUser.rawValue)
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
                        unmatched: .omit
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
                    collectionID: "activity-sessions",
                    windowing: .hostVirtualized,
                    rowTemplate: .stack(
                        axis: .horizontal,
                        spacing: .small,
                        children: [
                            .text(
                                .fact(title, facet: .value, fallback: "Untitled session"),
                                role: .compactBody
                            ),
                            .flexibleSpacer,
                            .conditional(
                                .comparison(
                                    .init(activity),
                                    .equal,
                                    .string(ExtensionSessionDetailedActivity.working.rawValue)
                                ),
                                content: .activityIndicator(
                                    accessibilityLabel: "Working"
                                )
                            ),
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
        identifier: "codes.threading.activity-inbox",
        name: "Activity Inbox",
        version: "0.1.0",
        runtime: .webAssembly,
        executable: "bin/activity-inbox.wasm",
        capabilities: [.workspaceNavigation],
        workspaceNavigators: [navigator]
    )

    public static let registration = ExtensionRegistration(
        workspaceNavigators: [navigator]
    )
}
