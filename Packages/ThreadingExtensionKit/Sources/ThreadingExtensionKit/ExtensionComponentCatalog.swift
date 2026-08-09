import Foundation

/// One contextual image identifier available while previewing or rendering a component.
public struct ExtensionComponentHostAsset: Codable, Equatable, Sendable {
    public let id: String
    public let description: String
    public let isOptional: Bool

    public init(
        id: String,
        description: String,
        isOptional: Bool = false
    ) {
        self.id = id
        self.description = description
        self.isOptional = isOptional
    }
}

/// The authoring information paired with one public component contract.
public struct ExtensionComponentCatalogEntry: Codable, Equatable, Sendable {
    public let summary: String
    public let contract: ExtensionComponentContract
    public let hostAssets: [ExtensionComponentHostAsset]
    public let examplePatch: ExtensionComponentPatch

    public init(
        summary: String,
        contract: ExtensionComponentContract,
        hostAssets: [ExtensionComponentHostAsset] = [],
        examplePatch: ExtensionComponentPatch
    ) {
        self.summary = summary
        self.contract = contract
        self.hostAssets = hostAssets
        self.examplePatch = examplePatch
    }
}

/// A complete machine-readable description returned by authoring tools and written to docs.
public struct ExtensionComponentDescription: Codable, Equatable, Sendable {
    public let entry: ExtensionComponentCatalogEntry
    public let patchSchema: ExtensionJSONValue

    public init(entry: ExtensionComponentCatalogEntry, patchSchema: ExtensionJSONValue) {
        self.entry = entry
        self.patchSchema = patchSchema
    }
}

public struct ExtensionComponentCatalogDocument: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let components: [ExtensionComponentDescription]

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        components: [ExtensionComponentDescription]
    ) {
        self.formatVersion = formatVersion
        self.components = components
    }
}

/// Threading's current public component catalogue.
///
/// This lives in the Foundation-only SDK so the app, generated documentation and extension
/// authoring tools all consume the same values. A component is added only after its host shell,
/// fallback and constraints have product tests.
public enum ThreadingComponentCatalog {
    private static let mainWindowHookConstraints = ExtensionComponentNodeConstraints(
        maximumDepth: 6,
        maximumNodes: 16,
        maximumTextLength: 200,
        allowedStackAxes: [.horizontal, .vertical],
        allowedTextRoles: ExtensionTextRole.allCases,
        allowedImageRoles: ExtensionImageRole.allCases,
        allowedButtonRoles: ExtensionButtonRole.allCases,
        allowedStatusRoles: ExtensionStatusRole.allCases,
        allowsDivider: true,
        allowsFixedSpacer: true,
        allowsFlexibleSpacer: true,
        allowsProceed: true,
        requiresProceed: true,
        allowsOverlay: true,
        allowedCustomSurfaceKinds: [.metal]
    )

    private static let compactRowAccessoryConstraints = ExtensionComponentNodeConstraints(
        maximumDepth: 0,
        maximumNodes: 1,
        maximumTextLength: 24,
        allowedStatusRoles: [.neutral, .positive, .warning, .negative]
    )

    private static let compactRowReplacementConstraints = ExtensionComponentNodeConstraints(
        maximumDepth: 1,
        maximumNodes: 8,
        maximumTextLength: 80,
        requiredRootAxis: .horizontal,
        allowedStackAxes: [.horizontal],
        allowedTextRoles: [.compactBody, .compactDetail],
        allowedImageRoles: [.identity, .icon, .decoration],
        allowedButtonRoles: [.standard],
        allowedStatusRoles: [.neutral, .positive, .warning, .negative],
        allowsFixedSpacer: true,
        allowsFlexibleSpacer: true
    )

    private static let hoverCardReplacementConstraints = ExtensionComponentNodeConstraints(
        maximumDepth: 6,
        maximumNodes: 48,
        maximumTextLength: 1_000,
        allowedStackAxes: [.horizontal, .vertical],
        allowedTextRoles: ExtensionTextRole.allCases,
        allowedImageRoles: ExtensionImageRole.allCases,
        allowedButtonRoles: ExtensionButtonRole.allCases,
        allowedStatusRoles: ExtensionStatusRole.allCases,
        allowsDivider: true,
        allowsFixedSpacer: true,
        allowsFlexibleSpacer: true,
        allowsOverlay: true
    )

    private static let hoverCardHookConstraints = ExtensionComponentNodeConstraints(
        maximumDepth: 6,
        maximumNodes: 48,
        maximumTextLength: 1_000,
        allowedStackAxes: [.horizontal, .vertical],
        allowedTextRoles: ExtensionTextRole.allCases,
        allowedImageRoles: ExtensionImageRole.allCases,
        allowedButtonRoles: ExtensionButtonRole.allCases,
        allowedStatusRoles: ExtensionStatusRole.allCases,
        allowsDivider: true,
        allowsFixedSpacer: true,
        allowsFlexibleSpacer: true,
        allowsProceed: true,
        requiresProceed: true,
        allowsOverlay: true
    )

    /// Composer hooks are accessories, not alternate composers. Requiring one horizontal root
    /// with exactly one `.proceed` lets an extension place compact content before or after the
    /// host input without moving it into a vertical wrapper or drawing over it.
    private static let composerAccessoryHookConstraints = ExtensionComponentNodeConstraints(
        maximumDepth: 2,
        maximumNodes: 8,
        maximumTextLength: 80,
        requiredRootAxis: .horizontal,
        allowedStackAxes: [.horizontal],
        allowedTextRoles: [.compactBody, .compactDetail],
        allowedImageRoles: [.icon, .decoration],
        allowedButtonRoles: [.standard],
        allowedStatusRoles: [.neutral, .positive, .warning, .negative],
        allowsFixedSpacer: true,
        allowsProceed: true,
        requiresProceed: true
    )

    /// Conversation annotations sit above or below an intact native row. A vertical root avoids
    /// compressing message measure or the tool header, while a nested horizontal stack permits
    /// compact badges and actions. There is deliberately no overlay or replacement vocabulary.
    private static let conversationRowHookConstraints = ExtensionComponentNodeConstraints(
        maximumDepth: 2,
        maximumNodes: 10,
        maximumTextLength: 160,
        requiredRootAxis: .vertical,
        allowedStackAxes: [.horizontal, .vertical],
        allowedTextRoles: [.compactBody, .compactDetail],
        allowedImageRoles: [.icon, .decoration],
        allowedButtonRoles: [.standard],
        allowedStatusRoles: [.neutral, .positive, .warning, .negative],
        allowsDivider: true,
        allowsFixedSpacer: true,
        allowsProceed: true,
        requiresProceed: true
    )

    /// Approval cards may be annotated, but an extension-owned button beside Allow/Deny would
    /// blur the security boundary. Their hook vocabulary is therefore display-only.
    private static let permissionCardHookConstraints = ExtensionComponentNodeConstraints(
        maximumDepth: 2,
        maximumNodes: 8,
        maximumTextLength: 160,
        requiredRootAxis: .vertical,
        allowedStackAxes: [.horizontal, .vertical],
        allowedTextRoles: [.compactBody, .compactDetail],
        allowedImageRoles: [.icon, .decoration],
        allowedStatusRoles: [.neutral, .positive, .warning, .negative],
        allowsDivider: true,
        allowsFixedSpacer: true,
        allowsProceed: true,
        requiresProceed: true
    )

    /// A small command/status region between the scrolling tabs and the host-owned new-tab
    /// button. The empty `.proceed` anchor makes several extensions compose in order while
    /// preventing any of them from wrapping or replacing the tab strip itself.
    private static let displayPaneHeaderHookConstraints = ExtensionComponentNodeConstraints(
        maximumDepth: 1,
        maximumNodes: 6,
        maximumTextLength: 40,
        requiredRootAxis: .horizontal,
        allowedStackAxes: [.horizontal],
        allowedTextRoles: [.compactBody, .compactDetail],
        allowedImageRoles: [.icon, .decoration],
        allowedButtonRoles: [.standard],
        allowedStatusRoles: [.neutral, .positive, .warning, .negative],
        allowsFixedSpacer: true,
        allowsProceed: true,
        requiresProceed: true
    )

    private static let sessionIdentityReplacementConstraints =
        ExtensionComponentNodeConstraints(
            maximumDepth: 1,
            maximumNodes: 5,
            maximumTextLength: 1,
            requiredRootAxis: .horizontal,
            allowedStackAxes: [.horizontal],
            allowedImageRoles: [.identity, .icon, .decoration],
            allowsFixedSpacer: true
        )

    /// What a corner-card row's *second level* may say.
    ///
    /// The row is a reading in the corner of someone's work; this is a surface Threading opens
    /// on purpose, so it has room the row does not: several rows, vertical grouping, dividers,
    /// longer strings — and actions, which the row itself still refuses. That split is the
    /// point. A control in the compact row would fight the card's own hit targets; the same
    /// control on the revealed level fights nothing, because the reveal is what the reader just
    /// asked for.
    ///
    /// `standard` is the only button role: a hover reveal is not where a destructive action or
    /// a screen's one primary action belongs.
    private static let cornerCardDetailConstraints = ExtensionComponentNodeConstraints(
        maximumDepth: 2,
        maximumNodes: 60,
        maximumTextLength: 80,
        allowedStackAxes: [.horizontal, .vertical],
        allowedTextRoles: [.compactBody, .compactDetail],
        allowedImageRoles: [.icon, .decoration],
        allowedButtonRoles: [.standard],
        allowedStatusRoles: [.neutral, .positive, .warning, .negative],
        allowsDivider: true,
        allowsFixedSpacer: true,
        allowsFlexibleSpacer: true
    )

    /// One corner-card row is a compact horizontal reading, not a control surface: the whole
    /// card is one click target whose navigation stays host-owned, so the slot vocabulary has
    /// no buttons. Depth 2 permits a bare status, one row stack of leaves, or a disclosure
    /// whose summary is that row stack.
    private static let cornerCardSlotConstraints = ExtensionComponentNodeConstraints(
        maximumDepth: 2,
        maximumNodes: 8,
        maximumTextLength: 40,
        allowedStackAxes: [.horizontal],
        allowedTextRoles: [.compactBody, .compactDetail],
        allowedStatusRoles: [.neutral, .positive, .warning, .negative],
        allowsFixedSpacer: true,
        allowsFlexibleSpacer: true,
        disclosureDetail: .vocabulary(cornerCardDetailConstraints)
    )

    public static let sessionCornerCard = ExtensionComponentContract(
        id: .sessionCornerCard,
        version: 1,
        context: .sessionPresentation,
        slots: [
            .init(
                id: "top-trailing",
                maximumInlineItems: 3,
                contentConstraints: cornerCardSlotConstraints
            )
        ],
        hostOwnedBehavior: [
            .cardNavigation,
            .activityState,
            .dataRefresh,
            .accessibilityContainer
        ]
    )

    public static let sidebarSessionIdentity = ExtensionComponentContract(
        id: .sidebarSessionIdentity,
        version: 1,
        context: .sessionPresentation,
        replacement: .contentOnly,
        replacementConstraints: sessionIdentityReplacementConstraints,
        hostOwnedBehavior: [
            .activityState,
            .accessibilityContainer
        ]
    )

    public static let applicationMainWindow = ExtensionComponentContract(
        id: .applicationMainWindow,
        version: 1,
        context: .application,
        hookConstraints: mainWindowHookConstraints,
        hostOwnedBehavior: [
            .windowChrome,
            .inputRouting,
            .accessibilityContainer
        ]
    )

    public static let composerSessionStart = ExtensionComponentContract(
        id: .composerSessionStart,
        version: 1,
        context: .projectPresentation,
        hookConstraints: composerAccessoryHookConstraints,
        hostOwnedBehavior: [
            .textInput,
            .submission,
            .keyboardRouting,
            .draftPersistence,
            .accessibilityContainer
        ]
    )

    public static let composerConversationReply = ExtensionComponentContract(
        id: .composerConversationReply,
        version: 1,
        context: .sessionPresentation,
        hookConstraints: composerAccessoryHookConstraints,
        hostOwnedBehavior: [
            .textInput,
            .submission,
            .keyboardRouting,
            .streamAvailability,
            .permissionState,
            .accessibilityContainer
        ]
    )

    public static let conversationUserMessage = ExtensionComponentContract(
        id: .conversationUserMessage,
        version: 1,
        context: .conversationRow,
        hookConstraints: conversationRowHookConstraints,
        hostOwnedBehavior: [
            .transcriptOrder,
            .messageContent,
            .turnBoundary,
            .accessibilityContainer
        ]
    )

    public static let conversationAssistantMessage = ExtensionComponentContract(
        id: .conversationAssistantMessage,
        version: 1,
        context: .conversationRow,
        hookConstraints: conversationRowHookConstraints,
        hostOwnedBehavior: [
            .transcriptOrder,
            .messageContent,
            .streamingLifecycle,
            .accessibilityContainer
        ]
    )

    public static let conversationToolCall = ExtensionComponentContract(
        id: .conversationToolCall,
        version: 1,
        context: .conversationRow,
        hookConstraints: conversationRowHookConstraints,
        hostOwnedBehavior: [
            .transcriptOrder,
            .toolResultAttachment,
            .toolExpansion,
            .accessibilityContainer
        ]
    )

    public static let conversationPermissionCard = ExtensionComponentContract(
        id: .conversationPermissionCard,
        version: 1,
        context: .conversationRow,
        hookConstraints: permissionCardHookConstraints,
        hostOwnedBehavior: [
            .transcriptOrder,
            .permissionState,
            .permissionDecision,
            .permissionQueue,
            .remoteMirroring,
            .accessibilityContainer
        ]
    )

    public static let displayPaneHeader = ExtensionComponentContract(
        id: .displayPaneHeader,
        version: 1,
        context: .sessionPresentation,
        hookConstraints: displayPaneHeaderHookConstraints,
        hostOwnedBehavior: [
            .tabSelection,
            .tabClosure,
            .tabOrder,
            .tabIdentity,
            .tabActiveState,
            .tabOverflow,
            .tabPersistence,
            .newTabMenu,
            .paneVisibility,
            .accessibilityContainer
        ]
    )

    public static let displayTabHeader = ExtensionComponentContract(
        id: .displayTabHeader,
        version: 1,
        context: .sessionPresentation,
        slots: [
            .init(
                id: "after-title",
                maximumInlineItems: 1,
                contentConstraints: compactRowAccessoryConstraints
            )
        ],
        hostOwnedBehavior: [
            .tabSelection,
            .tabClosure,
            .tabOrder,
            .tabIdentity,
            .tabActiveState,
            .tabOverflow,
            .tabPersistence,
            .accessibilityContainer
        ]
    )

    public static let sidebarSessionRow = ExtensionComponentContract(
        id: .sidebarSessionRow,
        version: 1,
        context: .sessionPresentation,
        properties: [.title, .identityImage, .toolTip],
        slots: [
            .init(
                id: "after-title",
                maximumInlineItems: 2,
                contentConstraints: compactRowAccessoryConstraints
            )
        ],
        replacement: .contentOnly,
        replacementConstraints: compactRowReplacementConstraints,
        hostOwnedBehavior: [
            .selection,
            .dragAndDrop,
            .rowActions,
            .activityState,
            .accessibilityContainer
        ]
    )

    public static let sidebarProjectRow = ExtensionComponentContract(
        id: .sidebarProjectRow,
        version: 1,
        context: .projectPresentation,
        properties: [.title, .identityImage, .toolTip],
        slots: [
            .init(
                id: "after-title",
                maximumInlineItems: 2,
                contentConstraints: compactRowAccessoryConstraints
            )
        ],
        replacement: .contentOnly,
        replacementConstraints: compactRowReplacementConstraints,
        hostOwnedBehavior: [
            .selection,
            .dragAndDrop,
            .rowActions,
            .aggregateCount,
            .accessibilityContainer
        ]
    )

    public static let sidebarProjectHoverCard = ExtensionComponentContract(
        id: .sidebarProjectHoverCard,
        version: 1,
        context: .projectPresentation,
        replacement: .contentOnly,
        replacementConstraints: hoverCardReplacementConstraints,
        hookConstraints: hoverCardHookConstraints,
        hostOwnedBehavior: [
            .hoverTrigger,
            .presentationLifecycle,
            .popoverChrome,
            .accessibilityContainer
        ]
    )

    public static let sidebarSessionHoverCard = ExtensionComponentContract(
        id: .sidebarSessionHoverCard,
        version: 1,
        context: .sessionPresentation,
        replacement: .contentOnly,
        replacementConstraints: hoverCardReplacementConstraints,
        hookConstraints: hoverCardHookConstraints,
        hostOwnedBehavior: [
            .hoverTrigger,
            .presentationLifecycle,
            .popoverChrome,
            .accessibilityContainer
        ]
    )

    public static let toolbarAccountUsagePopover = ExtensionComponentContract(
        id: .toolbarAccountUsagePopover,
        version: 1,
        context: .accountPresentation,
        replacement: .contentOnly,
        replacementConstraints: hoverCardReplacementConstraints,
        hookConstraints: hoverCardHookConstraints,
        hostOwnedBehavior: [
            .hoverTrigger,
            .presentationLifecycle,
            .popoverChrome,
            .dataRefresh,
            .accountSelection,
            .hoverSurvival,
            .accessibilityContainer
        ]
    )

    public static let entries: [ExtensionComponentCatalogEntry] = [
        ExtensionComponentCatalogEntry(
            summary: "Composable visual hooks around the complete main-window content.",
            contract: applicationMainWindow,
            examplePatch: ExtensionComponentPatch(
                id: "window-surface",
                target: .init(
                    component: .applicationMainWindow,
                    contractVersion: 1
                ),
                hook: .overlay(
                    base: .proceed,
                    overlay: .customSurface(
                        .metal(ExtensionMetalSurface(
                            shaderResource: "Resources/window-surface.metal"
                        )),
                        accessibilityLabel: nil
                    )
                )
            )
        ),
        ExtensionComponentCatalogEntry(
            summary: "Compact accessories before or after the protected new-session prompt.",
            contract: composerSessionStart,
            examplePatch: ExtensionComponentPatch(
                id: "project-template",
                target: .sessionStartComposer(),
                hook: .stack(
                    axis: .horizontal,
                    spacing: .small,
                    children: [
                        .button(
                            id: "insert-template",
                            title: "Template",
                            role: .standard,
                            isEnabled: true
                        ),
                        .proceed
                    ]
                )
            )
        ),
        ExtensionComponentCatalogEntry(
            summary: "Compact accessories before or after the protected conversation reply prompt.",
            contract: composerConversationReply,
            examplePatch: ExtensionComponentPatch(
                id: "conversation-context",
                target: .conversationReplyComposer(),
                hook: .stack(
                    axis: .horizontal,
                    spacing: .small,
                    children: [
                        .proceed,
                        .button(
                            id: "attach-context",
                            title: "Context",
                            role: .standard,
                            isEnabled: true
                        )
                    ]
                )
            )
        ),
        ExtensionComponentCatalogEntry(
            summary: "Display or action annotations around an intact user-message row.",
            contract: conversationUserMessage,
            examplePatch: ExtensionComponentPatch(
                id: "user-message-note",
                target: .conversationUserMessage(),
                hook: .stack(
                    axis: .vertical,
                    spacing: .small,
                    children: [
                        .proceed,
                        .status("Tracked by extension", role: .neutral)
                    ]
                )
            )
        ),
        ExtensionComponentCatalogEntry(
            summary: "Display or action annotations around an intact assistant-message row.",
            contract: conversationAssistantMessage,
            examplePatch: ExtensionComponentPatch(
                id: "assistant-message-action",
                target: .conversationAssistantMessage(),
                hook: .stack(
                    axis: .vertical,
                    spacing: .small,
                    children: [
                        .proceed,
                        .button(
                            id: "save-answer",
                            title: "Save answer",
                            role: .standard,
                            isEnabled: true
                        )
                    ]
                )
            )
        ),
        ExtensionComponentCatalogEntry(
            summary: "Display or action annotations around an intact collapsible tool-call row.",
            contract: conversationToolCall,
            examplePatch: ExtensionComponentPatch(
                id: "tool-call-environment",
                target: .conversationToolCall(),
                hook: .stack(
                    axis: .vertical,
                    spacing: .small,
                    children: [
                        .status("Development environment", role: .neutral),
                        .proceed
                    ]
                )
            )
        ),
        ExtensionComponentCatalogEntry(
            summary: "Display-only annotations around an intact host-owned permission card.",
            contract: conversationPermissionCard,
            examplePatch: ExtensionComponentPatch(
                id: "permission-policy-note",
                target: .conversationPermissionCard(),
                hook: .stack(
                    axis: .vertical,
                    spacing: .small,
                    children: [
                        .status("Workspace policy applies", role: .warning),
                        .proceed
                    ]
                )
            )
        ),
        ExtensionComponentCatalogEntry(
            summary: "Compact commands or status in the host-owned display-pane header.",
            contract: displayPaneHeader,
            examplePatch: ExtensionComponentPatch(
                id: "display-environment",
                target: .displayPaneHeader(),
                hook: .stack(
                    axis: .horizontal,
                    spacing: .small,
                    children: [
                        .status("Development", role: .neutral),
                        .button(
                            id: "refresh-display-status",
                            title: "Refresh",
                            role: .standard,
                            isEnabled: true
                        ),
                        .proceed
                    ]
                )
            )
        ),
        ExtensionComponentCatalogEntry(
            summary: "One compact status annotation after each intact native display-tab title.",
            contract: displayTabHeader,
            examplePatch: ExtensionComponentPatch(
                id: "display-tab-status",
                target: .displayTabHeader(),
                slots: [
                    .init(
                        slot: "after-title",
                        children: [.status("Live", role: .positive)]
                    )
                ]
            )
        ),
        ExtensionComponentCatalogEntry(
            summary: "Compact display rows appended to the floating corner card over the "
                + "session's pane. The slot ID names the corner: top-trailing is the only "
                + "card today; top-leading is reserved for a future leading card. The card's "
                + "click-through, visibility, and activity presentation stay host-owned. A row "
                + "may be a disclosure: the summary stays a compact reading without controls, "
                + "while the level Threading reveals from it may list, group and act.",
            contract: sessionCornerCard,
            examplePatch: ExtensionComponentPatch(
                id: "ci-card-row",
                target: .sessionCornerCard(),
                slots: [
                    .init(
                        slot: "top-trailing",
                        children: [
                            .disclosure(
                                id: "ci-checks",
                                summary: .stack(
                                    axis: .horizontal,
                                    spacing: .small,
                                    children: [
                                        .text("Checks", role: .compactDetail),
                                        .flexibleSpacer,
                                        .status("3 pending", role: .warning)
                                    ]
                                ),
                                detail: [
                                    .stack(
                                        axis: .horizontal,
                                        spacing: .small,
                                        children: [
                                            .text("build-ananke", role: .compactBody),
                                            .flexibleSpacer,
                                            .status("Running", role: .warning)
                                        ]
                                    ),
                                    .stack(
                                        axis: .horizontal,
                                        spacing: .small,
                                        children: [
                                            .text("tagger", role: .compactBody),
                                            .flexibleSpacer,
                                            .status("Succeeded", role: .positive)
                                        ]
                                    ),
                                    .divider,
                                    .button(
                                        id: "open-checks",
                                        title: "Open on GitHub",
                                        role: .standard,
                                        isEnabled: true
                                    )
                                ]
                            )
                        ]
                    )
                ]
            )
        ),
        ExtensionComponentCatalogEntry(
            summary: "Provider/account identity at the leading edge of a session row.",
            contract: sidebarSessionIdentity,
            hostAssets: [
                .init(
                    id: "session.provider-image",
                    description: "The provider image after primitive resolver and side-chat precedence."
                ),
                .init(
                    id: "session.account-image",
                    description: "The account image after explicit user-choice precedence.",
                    isOptional: true
                )
            ],
            examplePatch: ExtensionComponentPatch(
                id: "two-part-session-identity",
                target: .sessionIdentity(),
                replacement: .stack(
                    axis: .horizontal,
                    spacing: .tight,
                    children: [
                        .image(
                            .hostAsset("session.provider-image"),
                            role: .identity,
                            accessibilityLabel: "Provider"
                        )
                    ]
                )
            )
        ),
        ExtensionComponentCatalogEntry(
            summary: "The replaceable visual content and after-title slot of a session row.",
            contract: sidebarSessionRow,
            hostAssets: [
                .init(
                    id: "session.provider-image",
                    description: "The session's already-resolved provider or side-chat image."
                ),
                .init(
                    id: "session.account-image",
                    description: "The session's already-resolved optional account image.",
                    isOptional: true
                )
            ],
            examplePatch: ExtensionComponentPatch(
                id: "ci-session-row",
                target: .init(
                    component: "sidebar.session-row",
                    contractVersion: 1
                ),
                replacement: .stack(
                    axis: .horizontal,
                    spacing: .small,
                    children: [
                        .image(
                            .hostAsset("session.provider-image"),
                            role: .identity,
                            accessibilityLabel: "Provider"
                        ),
                        .text("Deploy production", role: .compactBody),
                        .flexibleSpacer,
                        .status("CI passed", role: .positive)
                    ]
                )
            )
        ),
        ExtensionComponentCatalogEntry(
            summary: "Composable content inside the hover card presented from a session row.",
            contract: sidebarSessionHoverCard,
            examplePatch: ExtensionComponentPatch(
                id: "session-runtime-details",
                target: .sessionHoverCard(),
                hook: .stack(
                    axis: .vertical,
                    spacing: .medium,
                    children: [
                        .proceed,
                        .divider,
                        .status("Preview ready", role: .positive)
                    ]
                )
            )
        ),
        ExtensionComponentCatalogEntry(
            summary: "Composable detail content in the toolbar's active-account usage popover.",
            contract: toolbarAccountUsagePopover,
            examplePatch: ExtensionComponentPatch(
                id: "account-budget-note",
                target: .accountUsagePopover(),
                hook: .stack(
                    axis: .vertical,
                    spacing: .medium,
                    children: [
                        .proceed,
                        .divider,
                        .status("Team budget available", role: .neutral)
                    ]
                )
            )
        ),
        ExtensionComponentCatalogEntry(
            summary: "The replaceable visual content and after-title slot of a project row.",
            contract: sidebarProjectRow,
            hostAssets: [
                .init(
                    id: "project.image",
                    description: "The project's resolved icon or generated fallback tile."
                )
            ],
            examplePatch: ExtensionComponentPatch(
                id: "ci-project-status",
                target: .init(
                    component: "sidebar.project-row",
                    contractVersion: 1
                ),
                slots: [
                    .init(
                        slot: "after-title",
                        children: [.status("CI passed", role: .positive)]
                    )
                ]
            )
        ),
        ExtensionComponentCatalogEntry(
            summary: "Composable content inside the hover card presented from a project row.",
            contract: sidebarProjectHoverCard,
            examplePatch: ExtensionComponentPatch(
                id: "project-ci-details",
                target: .projectHoverCard(),
                hook: .stack(
                    axis: .vertical,
                    spacing: .medium,
                    children: [
                        .proceed,
                        .divider,
                        .status("CI passed", role: .positive)
                    ]
                )
            )
        )
    ]

    public static let all = entries.map(\.contract)

    public static func entry(
        id: ExtensionComponentID,
        version: Int? = nil
    ) -> ExtensionComponentCatalogEntry? {
        entries.first {
            $0.contract.id == id && (version == nil || $0.contract.version == version)
        }
    }

    public static var document: ExtensionComponentCatalogDocument {
        ExtensionComponentCatalogDocument(
            components: entries.map {
                ExtensionComponentDescription(
                    entry: $0,
                    patchSchema: patchSchema(for: $0.contract)
                )
            }
        )
    }

    /// Generates a contract-specific JSON Schema around the generic patch/node schemas.
    public static func patchSchema(
        for contract: ExtensionComponentContract
    ) -> ExtensionJSONValue {
        let propertyNames = contract.properties.map {
            ExtensionJSONValue.string($0.rawValue)
        }
        let slotSchemas = contract.slots.map { slot -> ExtensionJSONValue in
            var children: [String: ExtensionJSONValue] = [
                "type": .string("array"),
                "minItems": .integer(1),
                "maxItems": .integer(Int64(slot.maximumInlineItems)),
                "items": .object([
                    "$ref": .string(
                        "https://threading.codes/schema/extension-node.schema.json"
                    )
                ])
            ]
            if let constraints = slot.contentConstraints,
               let encoded = try? jsonValue(constraints) {
                children["x-threading-node-constraints"] = encoded
            }
            return .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("slot"), .string("children")]),
                "properties": .object([
                    "slot": .object(["const": .string(slot.id.rawValue)]),
                    "children": .object(children)
                ])
            ])
        }

        var patchProperties: [String: ExtensionJSONValue] = [
            "id": .object([
                "type": .string("string"),
                "minLength": .integer(1)
            ]),
            "target": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([
                    .string("component"),
                    .string("contractVersion")
                ]),
                "properties": .object([
                    "component": .object(["const": .string(contract.id.rawValue)]),
                    "contractVersion": .object([
                        "const": .integer(Int64(contract.version))
                    ]),
                    "entityID": .object([
                        "type": .string("string"),
                        "minLength": .integer(1)
                    ])
                ])
            ]),
            "properties": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "required": .array([.string("property"), .string("value")]),
                    "properties": .object([
                        "property": .object(["enum": .array(propertyNames)]),
                        "value": .object([
                            "$ref": .string(
                                "https://threading.codes/schema/extension-host.schema.json#/$defs/propertyValue"
                            )
                        ])
                    ])
                ])
            ]),
            "slots": .object([
                "type": .string("array"),
                "items": slotSchemas.isEmpty
                    ? .bool(false)
                    : .object(["oneOf": .array(slotSchemas)])
            ])
        ]

        if contract.replacement == .contentOnly {
            var replacement: [String: ExtensionJSONValue] = [
                "$ref": .string(
                    "https://threading.codes/schema/extension-node.schema.json"
                )
            ]
            if let constraints = contract.replacementConstraints,
               let encoded = try? jsonValue(constraints) {
                replacement["x-threading-node-constraints"] = encoded
            }
            patchProperties["replacement"] = .object(replacement)
        }
        if let constraints = contract.hookConstraints {
            var hook: [String: ExtensionJSONValue] = [
                "$ref": .string(
                    "https://threading.codes/schema/extension-node.schema.json"
                )
            ]
            if let encoded = try? jsonValue(constraints) {
                hook["x-threading-node-constraints"] = encoded
            }
            patchProperties["hook"] = .object(hook)
        }

        return .object([
            "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
            "$id": .string(
                "https://threading.codes/schema/components/\(contract.id.rawValue)-v\(contract.version).schema.json"
            ),
            "title": .string(
                "Threading \(contract.id.rawValue) v\(contract.version) component patch"
            ),
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([
                .string("id"),
                .string("target"),
                .string("properties"),
                .string("slots")
            ]),
            "properties": .object(patchProperties)
        ])
    }

    public static func documentationMarkdown() -> String {
        var lines = [
            "# Threading public component catalogue",
            "",
            "<!-- Generated by ThreadingComponentCatalogGenerator. Do not edit by hand. -->",
            "",
            "Catalogue format: \(ExtensionComponentCatalogDocument.currentFormatVersion)",
            ""
        ]

        for entry in entries {
            let contract = entry.contract
            lines.append("## `\(contract.id.rawValue)` v\(contract.version)")
            lines.append("")
            lines.append(entry.summary)
            lines.append("")
            lines.append("- Context: `\(contract.context.rawValue)`")
            lines.append("- Replacement: `\(contract.replacement.rawValue)`")
            lines.append("- Composable hooks: \(contract.hookConstraints == nil ? "none" : "around content")")
            lines.append(
                "- Properties: "
                    + markdownValues(contract.properties.map(\.rawValue))
            )
            lines.append(
                "- Slots: "
                    + markdownValues(contract.slots.map(\.id.rawValue))
            )
            lines.append(
                "- Host-owned behavior: "
                    + markdownValues(contract.hostOwnedBehavior.map(\.rawValue))
            )
            lines.append(
                "- Host assets: "
                    + markdownValues(entry.hostAssets.map {
                        $0.id + ($0.isOptional ? " (optional)" : "")
                    })
            )
            if let constraints = contract.replacementConstraints {
                lines.append(
                    "- Replacement limits: depth \(constraints.maximumDepth), "
                        + "nodes \(constraints.maximumNodes), text \(constraints.maximumTextLength)"
                )
            }
            lines.append("")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func markdownValues(_ values: [String]) -> String {
        values.isEmpty ? "none" : values.map { "`\($0)`" }.joined(separator: ", ")
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> ExtensionJSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ExtensionJSONValue.self, from: data)
    }
}
