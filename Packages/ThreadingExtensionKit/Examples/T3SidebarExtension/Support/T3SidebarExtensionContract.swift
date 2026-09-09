import Foundation
import ThreadingExtensionKit

/// A T3 Code-inspired thread navigator expressed entirely through the public pipeline.
///
/// This proof of concept mirrors the source product's lifecycle-oriented information hierarchy,
/// not its private chrome or behavior. Threading still owns search, selection, virtualization,
/// resizing, and the available pin, unpin, and archive actions.
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
        let activity = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionDetailedActivity
        )
        let manualOrder = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionManualOrder
        )
        let branch = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionBranch
        )
        let pinned = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionIsPinned
        )
        let archived = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionIsArchived
        )
        let snoozed = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionIsSnoozed
        )
        let hasScheduledStart = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionHasScheduledStart
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
        let isArchived = ExtensionWorkspaceNavigatorPredicate.comparison(
            .init(archived, fallback: .boolean(false)),
            .equal,
            .boolean(true)
        )
        let isNotArchived = ExtensionWorkspaceNavigatorPredicate.not(isArchived)
        let isSnoozed = ExtensionWorkspaceNavigatorPredicate.comparison(
            .init(snoozed, fallback: .boolean(false)),
            .equal,
            .boolean(true)
        )
        let isNotSnoozed = ExtensionWorkspaceNavigatorPredicate.not(isSnoozed)
        let hasNoScheduledStart = ExtensionWorkspaceNavigatorPredicate.comparison(
            .init(hasScheduledStart, fallback: .boolean(false)),
            .equal,
            .boolean(false)
        )
        let canAct = ExtensionWorkspaceNavigatorPredicate.all([
            hasNoScheduledStart,
            isNotArchived,
        ])
        let awaitingUser = ExtensionWorkspaceNavigatorPredicate.comparison(
            .init(activity),
            .equal,
            .string(ExtensionSessionDetailedActivity.awaitingUser.rawValue)
        )
        let working = ExtensionWorkspaceNavigatorPredicate.comparison(
            .init(activity),
            .equal,
            .string(ExtensionSessionDetailedActivity.working.rawValue)
        )
        let idle = ExtensionWorkspaceNavigatorPredicate.comparison(
            .init(activity),
            .equal,
            .string(ExtensionSessionDetailedActivity.idle.rawValue)
        )
        let dormant = ExtensionWorkspaceNavigatorPredicate.comparison(
            .init(activity),
            .equal,
            .string(ExtensionSessionDetailedActivity.dormant.rawValue)
        )
        let readyWithBackgroundWork = ExtensionWorkspaceNavigatorPredicate.comparison(
            .init(activity),
            .equal,
            .string(ExtensionSessionDetailedActivity.readyWithBackgroundWork.rawValue)
        )
        let needsAttention = ExtensionWorkspaceNavigatorPredicate.comparison(
            .init(activity),
            .equal,
            .string(ExtensionSessionDetailedActivity.needsAttention.rawValue)
        )
        let limitReached = ExtensionWorkspaceNavigatorPredicate.comparison(
            .init(activity),
            .equal,
            .string(ExtensionSessionDetailedActivity.limitReached.rawValue)
        )
        let knownActivity = ExtensionWorkspaceNavigatorPredicate.any([
            dormant,
            awaitingUser,
            working,
            idle,
            readyWithBackgroundWork,
            needsAttention,
            limitReached,
        ])

        return ExtensionWorkspaceNavigator(
            id: "t3-sidebar",
            title: "T3 Code Threads POC",
            root: .content(.status(
                "T3 Code Threads POC requires a newer Threading host.",
                role: .neutral
            )),
            intents: [.pin, .unpin, .archive],
            pipeline: .init(
                consumes: [
                    .init(key: title.key, requirement: .required),
                    .init(key: projectID.key, requirement: .required),
                    .init(key: projectName.key, requirement: .required),
                    .init(key: activity.key, requirement: .required),
                    .init(key: manualOrder.key, requirement: .required),
                    .init(key: branch.key, requirement: .required),
                    .init(key: pinned.key, requirement: .required),
                    .init(key: archived.key, requirement: .required),
                    .init(key: snoozed.key, requirement: .required),
                    .init(key: hasScheduledStart.key, requirement: .required),
                ],
                search: .init(
                    placeholder: "Search",
                    accessibilityLabel: "Search threads",
                    fields: [title]
                ),
                buckets: [
                    .init(strategy: .rules(
                        [
                            .init(
                                id: "pinned",
                                title: "Pinned",
                                predicate: .all([
                                    isPinned,
                                    isNotSnoozed,
                                    isNotArchived,
                                ])
                            ),
                            .init(
                                id: "active",
                                title: "Active",
                                predicate: .all([
                                    isNotSnoozed,
                                    isNotArchived,
                                ])
                            ),
                            .init(
                                id: "snoozed",
                                title: "Snoozed",
                                predicate: isSnoozed
                            ),
                        ],
                        unmatched: .bucket(id: "archived", title: "Archived")
                    )),
                ],
                // T3 Code keeps a stable user-authored order; activity changes never reshuffle
                // threads. Threading publishes that same semantic order as a sortable host fact.
                sort: [.init(
                    operand: .init(manualOrder),
                    direction: .ascending
                )],
                output: .init(
                    collectionID: "t3-sessions",
                    windowing: .hostVirtualized,
                    rowTemplate: .stack(
                        axis: .vertical,
                        spacing: .tight,
                        children: [
                            .stack(
                                axis: .horizontal,
                                spacing: .small,
                                children: [
                                    .text(
                                        .fact(
                                            title,
                                            facet: .value,
                                            fallback: "Untitled session"
                                        ),
                                        role: .compactBody
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
                            .stack(
                                axis: .horizontal,
                                spacing: .small,
                                children: [
                                    .conditional(
                                        dormant,
                                        content: .status(
                                            .literal("Dormant"),
                                            role: .literal(.neutral)
                                        )
                                    ),
                                    .conditional(
                                        awaitingUser,
                                        content: .status(
                                            .literal("Waiting"),
                                            role: .literal(.warning)
                                        )
                                    ),
                                    .conditional(
                                        working,
                                        content: .status(
                                            .literal("Working"),
                                            role: .literal(.positive)
                                        )
                                    ),
                                    .conditional(
                                        idle,
                                        content: .status(
                                            .literal("Idle"),
                                            role: .literal(.neutral)
                                        )
                                    ),
                                    .conditional(
                                        readyWithBackgroundWork,
                                        content: .status(
                                            .literal("Ready"),
                                            role: .literal(.positive)
                                        )
                                    ),
                                    .conditional(
                                        needsAttention,
                                        content: .status(
                                            .literal("Attention"),
                                            role: .literal(.warning)
                                        )
                                    ),
                                    .conditional(
                                        limitReached,
                                        content: .status(
                                            .literal("Limit"),
                                            role: .literal(.negative)
                                        )
                                    ),
                                    .conditional(
                                        .not(knownActivity),
                                        content: .status(
                                            .literal("Unknown"),
                                            role: .literal(.neutral)
                                        )
                                    ),
                                    .flexibleSpacer,
                                    .text(
                                        .fact(
                                            projectName,
                                            facet: .value,
                                            fallback: "No project"
                                        ),
                                        role: .compactDetail
                                    ),
                                    .text(
                                        .fact(
                                            branch,
                                            facet: .value,
                                            fallback: "No branch"
                                        ),
                                        role: .compactDetail
                                    ),
                                ]
                            ),
                        ]
                    ),
                    emptyState: .init(
                        title: "No threads",
                        detail: "Try another search."
                    )
                )
            ),
            preferredWidth: 400
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
