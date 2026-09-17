/// A host-rendered choice that changes how the native navigator projects the same facts.
/// These become extension-declared options in rollout 4; they are not entity data.
enum NativeSidebarOptionDependency: String, CaseIterable, Sendable {
    case sessionOrder
    case sessionOrderDirection
    case branchGrouping
    case loneBranchHeadings
    case compactTree
    case chatPreview
    case groupByFact
    case sortByFact
}

/// State Threading must keep host-owned when navigator content is customizable.
///
/// Identity addresses a fact subject rather than supplying a value. Everything else is
/// interaction, presentation detail, or a clock input—not durable session/project/terminal data.
enum NativeSidebarHostDependency: String, CaseIterable, Sendable {
    case entityIdentity
    case transientLoading
    case hoverContent
    case conductDetail
    /// Which machine a row's sessions run on. A launch-destination decision the host owns, shown
    /// so it can never be a silent setting; not a navigator fact.
    case executionPlacement
    case clock
    case visibilityScope
    case transientExclusion
    /// How far the user has opened each project's chat preview, and the chats that must stay
    /// revealed whatever the stage — the selected one. Interaction state, never session data.
    case transientDisclosure
    case customizationPresentation
    case identityPresentation
    case registeredFactResolution
    /// Local filesystem and shared-git-directory context that cannot cross the extension boundary.
    case localRepositoryContext
}

/// A provider method whose output is presentation machinery rather than a durable fact.
enum NativeSidebarHostProviderAlias: String, CaseIterable, Sendable {
    case componentAction = "ComponentCustomizationProviderSlot.perform"
    case componentCustomization = "ComponentCustomizationProviderSlot.customization"
    case providerIcon = "ExtensionIdentityResolverProviderSlot.providerIcon"
    case accountIcon = "ExtensionIdentityResolverProviderSlot.accountIcon"
    case extensionImage = "ExtensionManager.imageResourceURL"
    case accountDiscovery = "AgentAccountDiscovery.account"
    case accountPresentation = "AccountPresentation.showsStandardBadge"
    case accountBadgeSelection = "AccountPresentation.hasUserSelectedBadge"
    case accountBadge = "AccountBadge.chip"
    case registeredFactEligibility = "ExtensionFactRegistry.isRegisteredFactDefinitionEligible"
}

/// A host preference read that supplies one exact navigator option.
enum NativeSidebarOptionSourceAlias: String, CaseIterable, Sendable {
    case sessionOrder = "AppSettings.sidebarSessionOrder"
    case sessionOrderDirection = "AppSettings.sidebarSessionOrderIsReversed"
    case branchGrouping = "AppSettings.groupsSessionsByBranch"
    case loneBranchHeadings = "AppSettings.groupsLoneBranches"
    case compactTree = "AppSettings.compactsSidebarTree"
    case chatPreview = "AppSettings.previewsSidebarChats"
    case groupByFact = "AppSettings.nativeSidebarGroupByFact"
    case sortByFact = "AppSettings.nativeSidebarSortByFact"
}

/// A scalar entry input or static host service that must remain host-owned.
enum NativeSidebarHostInputAlias: String, CaseIterable, Sendable {
    case rowLoading = "SessionRowView.configure.isLoading"
    case rowConduct = "SessionRowView.configure.conduct"
    case rowExecutionHost = "SessionRowView.configure.executionHost"
    case rootVisibility = "SidebarTreeBuilder.rootNodes.visibility"
    case rootExclusions = "SidebarTreeBuilder.rootNodes.excludingSessionIDs"
    case rootClock = "SidebarTreeBuilder.rootNodes.date"
    case rootChatPreviewStages = "SidebarTreeBuilder.rootNodes.chatPreviewStages"
    case rootRevealedSessions = "SidebarTreeBuilder.rootNodes.revealingSessionIDs"
    case projectNodeIdentity = "SidebarTreeBuilder.projectNode.projectID"
    case projectNodeVisibility = "SidebarTreeBuilder.projectNode.visibility"
    case projectNodeExclusions = "SidebarTreeBuilder.projectNode.excludingSessionIDs"
    case projectNodeChatPreviewStage = "SidebarTreeBuilder.projectNode.chatPreviewStage"
    case projectNodeRevealedSessions = "SidebarTreeBuilder.projectNode.revealingSessionIDs"
    case rootFactSnapshot = "SidebarTreeBuilder.rootNodes.factSnapshot"
    case projectNodeFactSnapshot = "SidebarTreeBuilder.projectNode.factSnapshot"
    case repositoryIdentity = "GitInfo.repositoryIdentity"
    case repositoryName = "GitInfo.repositoryName"
    case worktreeLocation = "GitInfo.worktreeLocation"
    case checkoutBranch = "GitInfo.currentBranch"
}

/// Compiler-visible ownership markers for the navigator parity checker.
///
/// These eager, nonescaping identity functions inline away. The deliberately literal call shape
/// lets the boundary checker derive accepted fact names from `HostFactCatalog`, with no parallel
/// Python or JSON field allowlist.
enum NativeSidebarParity {
    /// Every native option dependency has one public-shaped declaration and durable owner.
    /// The source parity lint checks this map is total and one-to-one with the public option IDs
    /// and declarations, and separately enforces the reads below. Native still layers its
    /// host-only interaction invariants — notably pin precedence — over those option values.
    static let publicOptionOwnership: [
        NativeSidebarOptionDependency: NativeSidebarPipelineOptionID
    ] = [
        .sessionOrder: .sessionOrder,
        .sessionOrderDirection: .sessionOrderReversed,
        .branchGrouping: .branchGrouping,
        .loneBranchHeadings: .loneBranchHeadings,
        .compactTree: .compactTree,
        .chatPreview: .chatPreview,
        .groupByFact: .groupByFact,
        .sortByFact: .sortByFact,
    ]

    static let optionSourceOwnership: [
        NativeSidebarOptionSourceAlias: NativeSidebarOptionDependency
    ] = [
        .sessionOrder: .sessionOrder,
        .sessionOrderDirection: .sessionOrderDirection,
        .branchGrouping: .branchGrouping,
        .loneBranchHeadings: .loneBranchHeadings,
        .compactTree: .compactTree,
        .chatPreview: .chatPreview,
        .groupByFact: .groupByFact,
        .sortByFact: .sortByFact,
    ]

    static let hostInputOwnership: [
        NativeSidebarHostInputAlias: NativeSidebarHostDependency
    ] = [
        .rowLoading: .transientLoading,
        .rowConduct: .conductDetail,
        .rowExecutionHost: .executionPlacement,
        .rootVisibility: .visibilityScope,
        .rootExclusions: .transientExclusion,
        .rootClock: .clock,
        .rootChatPreviewStages: .transientDisclosure,
        .rootRevealedSessions: .transientDisclosure,
        .projectNodeIdentity: .entityIdentity,
        .projectNodeVisibility: .visibilityScope,
        .projectNodeExclusions: .transientExclusion,
        .projectNodeChatPreviewStage: .transientDisclosure,
        .projectNodeRevealedSessions: .transientDisclosure,
        .rootFactSnapshot: .registeredFactResolution,
        .projectNodeFactSnapshot: .registeredFactResolution,
        .repositoryIdentity: .localRepositoryContext,
        .repositoryName: .localRepositoryContext,
        .worktreeLocation: .localRepositoryContext,
        .checkoutBranch: .localRepositoryContext,
    ]

    static let providerOwnership: [
        NativeSidebarHostProviderAlias: NativeSidebarHostDependency
    ] = [
        .componentAction: .customizationPresentation,
        .componentCustomization: .customizationPresentation,
        .providerIcon: .identityPresentation,
        .accountIcon: .identityPresentation,
        .extensionImage: .identityPresentation,
        .accountDiscovery: .identityPresentation,
        .accountPresentation: .identityPresentation,
        .accountBadgeSelection: .identityPresentation,
        .accountBadge: .identityPresentation,
        .registeredFactEligibility: .registeredFactResolution,
    ]

    @inline(__always)
    static func fact<Value>(_: NativeSidebarFactDependency, _ value: Value) -> Value {
        value
    }

    @inline(__always)
    static func facts<Value>(
        _: [NativeSidebarFactDependency],
        _ value: Value
    ) -> Value {
        value
    }

    @inline(__always)
    static func option<Value>(
        _: NativeSidebarOptionDependency,
        _ value: Value
    ) -> Value {
        value
    }

    @inline(__always)
    static func host<Value>(_: NativeSidebarHostDependency, _ value: Value) -> Value {
        value
    }
}
