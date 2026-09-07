/// A host-rendered choice that changes how the native navigator projects the same facts.
/// These become extension-declared options in rollout 4; they are not entity data.
enum NativeSidebarOptionDependency: String, CaseIterable, Sendable {
    case sessionOrder
    case sessionOrderDirection
    case branchGrouping
    case loneBranchHeadings
    case compactTree
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
    case clock
    case visibilityScope
    case transientExclusion
    case customizationPresentation
    case identityPresentation
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
}

/// A host preference read that supplies one exact navigator option.
enum NativeSidebarOptionSourceAlias: String, CaseIterable, Sendable {
    case sessionOrder = "AppSettings.sidebarSessionOrder"
    case sessionOrderDirection = "AppSettings.sidebarSessionOrderIsReversed"
    case branchGrouping = "AppSettings.groupsSessionsByBranch"
    case loneBranchHeadings = "AppSettings.groupsLoneBranches"
    case compactTree = "AppSettings.compactsSidebarTree"
}

/// A scalar entry input or static host service that must remain host-owned.
enum NativeSidebarHostInputAlias: String, CaseIterable, Sendable {
    case rowLoading = "SessionRowView.configure.isLoading"
    case rowConduct = "SessionRowView.configure.conduct"
    case rootVisibility = "SidebarTreeBuilder.rootNodes.visibility"
    case rootExclusions = "SidebarTreeBuilder.rootNodes.excludingSessionIDs"
    case rootClock = "SidebarTreeBuilder.rootNodes.date"
    case projectNodeIdentity = "SidebarTreeBuilder.projectNode.projectID"
    case projectNodeVisibility = "SidebarTreeBuilder.projectNode.visibility"
    case projectNodeExclusions = "SidebarTreeBuilder.projectNode.excludingSessionIDs"
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
    /// Every native option dependency is the implementation of one public option declaration.
    /// The parity lint checks both sides are total and one-to-one.
    static let publicOptionOwnership: [
        NativeSidebarOptionDependency: NativeSidebarPipelineOptionID
    ] = [
        .sessionOrder: .sessionOrder,
        .sessionOrderDirection: .sessionOrderReversed,
        .branchGrouping: .branchGrouping,
        .loneBranchHeadings: .loneBranchHeadings,
        .compactTree: .compactTree,
    ]

    static let optionSourceOwnership: [
        NativeSidebarOptionSourceAlias: NativeSidebarOptionDependency
    ] = [
        .sessionOrder: .sessionOrder,
        .sessionOrderDirection: .sessionOrderDirection,
        .branchGrouping: .branchGrouping,
        .loneBranchHeadings: .loneBranchHeadings,
        .compactTree: .compactTree,
    ]

    static let hostInputOwnership: [
        NativeSidebarHostInputAlias: NativeSidebarHostDependency
    ] = [
        .rowLoading: .transientLoading,
        .rowConduct: .conductDetail,
        .rootVisibility: .visibilityScope,
        .rootExclusions: .transientExclusion,
        .rootClock: .clock,
        .projectNodeIdentity: .entityIdentity,
        .projectNodeVisibility: .visibilityScope,
        .projectNodeExclusions: .transientExclusion,
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
    ]

    @inline(__always)
    static func fact<Value>(_ dependency: NativeSidebarFactDependency, _ value: Value) -> Value {
        value
    }

    @inline(__always)
    static func facts<Value>(
        _ dependencies: [NativeSidebarFactDependency],
        _ value: Value
    ) -> Value {
        value
    }

    @inline(__always)
    static func option<Value>(
        _ dependency: NativeSidebarOptionDependency,
        _ value: Value
    ) -> Value {
        value
    }

    @inline(__always)
    static func host<Value>(_ dependency: NativeSidebarHostDependency, _ value: Value) -> Value {
        value
    }
}
