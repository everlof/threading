import Foundation
import ThreadingExtensionKit

/// Stable public option identifiers for the host's built-in navigator.
///
/// Native stays a host surface rather than pretending to be an installed extension. These IDs
/// are the shared vocabulary: an extension declares the same kinds of values through
/// `ExtensionWorkspaceNavigatorOption`, while Native keeps its existing AppSettings wire.
enum NativeSidebarPipelineOptionID: String, CaseIterable, Sendable {
    case sessionOrder = "session-order"
    case sessionOrderReversed = "session-order-reversed"
    case branchGrouping = "branch-grouping"
    case loneBranchHeadings = "lone-branch-headings"
    case compactTree = "compact-tree"
}

/// Contribution-safe values for Native's session-order choice.
///
/// `SidebarSessionOrder.recentActivity` is a persisted host raw value and cannot be renamed.
/// This separate wire is what an extension contribution can depend on without inheriting that
/// implementation spelling.
enum NativeSidebarPipelineSessionOrderValue: String, CaseIterable, Sendable {
    case orderAdded = "order-added"
    case recentActivity = "recent-activity"
    case name
    case type
}

/// One immutable read of the five native navigator options.
///
/// Tree construction and menu construction pass this value down rather than consulting defaults
/// per row, per comparator, or once for every menu entry. `jsonValues` is the exact public
/// projection a pipeline evaluator would receive; the typed properties preserve Native's
/// existing implementation without decoding its own JSON.
struct NativeSidebarPipelineOptionValues: Equatable {
    let sessionOrder: SidebarSessionOrder
    let sessionOrderReversed: Bool
    let branchGrouping: Bool
    let loneBranchHeadings: Bool
    let compactTree: Bool
    let jsonValues: [String: ExtensionJSONValue]

    init(
        sessionOrder: SidebarSessionOrder,
        sessionOrderReversed: Bool,
        branchGrouping: Bool,
        loneBranchHeadings: Bool,
        compactTree: Bool
    ) {
        self.sessionOrder = sessionOrder
        self.sessionOrderReversed = sessionOrderReversed
        self.branchGrouping = branchGrouping
        self.loneBranchHeadings = loneBranchHeadings
        self.compactTree = compactTree
        jsonValues = [
            NativeSidebarPipelineOptionID.sessionOrder.rawValue: .string(
                NativeSidebarPipelineOptions.publicValue(for: sessionOrder).rawValue
            ),
            NativeSidebarPipelineOptionID.sessionOrderReversed.rawValue: .bool(
                sessionOrderReversed
            ),
            NativeSidebarPipelineOptionID.branchGrouping.rawValue: .bool(branchGrouping),
            NativeSidebarPipelineOptionID.loneBranchHeadings.rawValue: .bool(
                loneBranchHeadings
            ),
            NativeSidebarPipelineOptionID.compactTree.rawValue: .bool(compactTree),
        ]
    }
}

/// The public declarations and legacy AppSettings adapter for Native's five pipeline options.
///
/// All production reads and writes of those settings pass through here. That gives the parity
/// lint one exact ownership point while AppSettings remains the durable persistence authority.
@MainActor
enum NativeSidebarPipelineOptions {
    static let declarations: [ExtensionWorkspaceNavigatorOption] = [
        ExtensionWorkspaceNavigatorOption(
            id: NativeSidebarPipelineOptionID.sessionOrder.rawValue,
            title: L10n.string("Session Order"),
            control: .choice(
                defaultValue: NativeSidebarPipelineSessionOrderValue.orderAdded.rawValue,
                options: [
                    .init(
                        id: NativeSidebarPipelineSessionOrderValue.orderAdded.rawValue,
                        title: SidebarSessionOrder.manual.menuTitle
                    ),
                    .init(
                        id: NativeSidebarPipelineSessionOrderValue.recentActivity.rawValue,
                        title: SidebarSessionOrder.recentActivity.menuTitle
                    ),
                    .init(
                        id: NativeSidebarPipelineSessionOrderValue.name.rawValue,
                        title: SidebarSessionOrder.name.menuTitle
                    ),
                    .init(
                        id: NativeSidebarPipelineSessionOrderValue.type.rawValue,
                        title: SidebarSessionOrder.type.menuTitle
                    ),
                ]
            )
        ),
        ExtensionWorkspaceNavigatorOption(
            id: NativeSidebarPipelineOptionID.sessionOrderReversed.rawValue,
            title: L10n.string("Reverse Session Order"),
            control: .toggle(defaultValue: false)
        ),
        ExtensionWorkspaceNavigatorOption(
            id: NativeSidebarPipelineOptionID.branchGrouping.rawValue,
            title: L10n.string("Group Sessions by Branch"),
            control: .toggle(defaultValue: true)
        ),
        ExtensionWorkspaceNavigatorOption(
            id: NativeSidebarPipelineOptionID.loneBranchHeadings.rawValue,
            title: L10n.string("Headings for Lone Branches"),
            control: .toggle(defaultValue: true)
        ),
        ExtensionWorkspaceNavigatorOption(
            id: NativeSidebarPipelineOptionID.compactTree.rawValue,
            title: L10n.string("Compact Tree"),
            control: .toggle(defaultValue: false)
        ),
    ]

    static var current: NativeSidebarPipelineOptionValues {
        NativeSidebarPipelineOptionValues(
            sessionOrder: sessionOrder,
            sessionOrderReversed: sessionOrderReversed,
            branchGrouping: branchGrouping,
            loneBranchHeadings: loneBranchHeadings,
            compactTree: compactTree
        )
    }

    static var sessionOrder: SidebarSessionOrder {
        NativeSidebarParity.option(.sessionOrder, AppSettings.sidebarSessionOrder)
    }

    static var sessionOrderReversed: Bool {
        NativeSidebarParity.option(
            .sessionOrderDirection,
            AppSettings.sidebarSessionOrderIsReversed
        )
    }

    static var branchGrouping: Bool {
        NativeSidebarParity.option(
            .branchGrouping,
            AppSettings.groupsSessionsByBranch
        )
    }

    static var loneBranchHeadings: Bool {
        NativeSidebarParity.option(
            .loneBranchHeadings,
            AppSettings.groupsLoneBranches
        )
    }

    static var compactTree: Bool {
        NativeSidebarParity.option(
            .compactTree,
            AppSettings.shared.compactsSidebarTree
        )
    }

    static func setSessionOrder(_ value: SidebarSessionOrder) {
        NativeSidebarParity.option(
            .sessionOrder,
            AppSettings.shared.sidebarSessionOrder = value
        )
    }

    static func setSessionOrderReversed(_ value: Bool) {
        NativeSidebarParity.option(
            .sessionOrderDirection,
            AppSettings.shared.sidebarSessionOrderIsReversed = value
        )
    }

    static func setBranchGrouping(_ value: Bool) {
        NativeSidebarParity.option(
            .branchGrouping,
            AppSettings.shared.groupsSessionsByBranch = value
        )
    }

    static func setLoneBranchHeadings(_ value: Bool) {
        NativeSidebarParity.option(
            .loneBranchHeadings,
            AppSettings.shared.groupsLoneBranches = value
        )
    }

    static func setCompactTree(_ value: Bool) {
        NativeSidebarParity.option(
            .compactTree,
            AppSettings.shared.compactsSidebarTree = value
        )
    }

    static func toggleBranchGrouping() {
        setBranchGrouping(!branchGrouping)
    }

    static func toggleLoneBranchHeadings() {
        setLoneBranchHeadings(!loneBranchHeadings)
    }

    static func toggleCompactTree() {
        setCompactTree(!compactTree)
    }

    nonisolated static func publicValue(
        for order: SidebarSessionOrder
    ) -> NativeSidebarPipelineSessionOrderValue {
        switch order {
        case .manual: .orderAdded
        case .recentActivity: .recentActivity
        case .name: .name
        case .type: .type
        }
    }

    nonisolated static func sessionOrder(
        for value: NativeSidebarPipelineSessionOrderValue
    ) -> SidebarSessionOrder {
        switch value {
        case .orderAdded: .manual
        case .recentActivity: .recentActivity
        case .name: .name
        case .type: .type
        }
    }
}
