import AppKit
import ThreadingExtensionKit

/// Every product popover must be named here before it can be created.
///
/// The catalogue forces one explicit extension-boundary decision: either the visual body has a
/// public component contract, or the presentation stays host-only for a stated reason. A source
/// audit rejects direct system popover construction elsewhere, so adding a popover cannot silently
/// bypass this review.
enum HostPopoverID: String, CaseIterable {
    case sidebarProjectHoverCard = "sidebar.project-hover-card"
    case sidebarSessionHoverCard = "sidebar.session-hover-card"
    case toolbarAccountUsage = "toolbar.account-usage-popover"
    case settingsAccountIconPicker = "settings.account-icon-picker"
    case extensionNodeDetail = "extension.node-detail"
    case conversationChangedFileDiff = "conversation.changed-file-diff"

    var exposure: HostPopoverExposure {
        switch self {
        case .sidebarProjectHoverCard:
            return .component(.sidebarProjectHoverCard)
        case .sidebarSessionHoverCard:
            return .component(.sidebarSessionHoverCard)
        case .toolbarAccountUsage:
            return .component(.toolbarAccountUsagePopover)
        case .extensionNodeDetail:
            return .hostOnly(
                reason: "The second level behind an extension's own summary. Its *body* is "
                    + "already that extension's tree, so there is nothing here for another "
                    + "extension to compose into — and the surface only exists while a reader "
                    + "is holding a row open. The reveal, its timing, placement, chrome and "
                    + "dismissal stay host-owned; see ExtensionNode.disclosure."
            )
        case .settingsAccountIconPicker:
            return .hostOnly(
                reason: "Edits an explicit user-owned identity choice; extensions contribute "
                    + "icon resolvers but cannot replace the native picker."
            )
        case .conversationChangedFileDiff:
            return .hostOnly(
                reason: "One file's diff under the pointer, drawn by the same renderer as Git "
                    + "Review from what git reported for that turn. There is nothing here for "
                    + "an extension to compose into — the body *is* the change — and the "
                    + "surface exists only while a reader is holding a row open, so its "
                    + "timing, placement, chrome and dismissal stay host-owned."
            )
        }
    }
}

enum HostPopoverExposure: Equatable {
    case component(ExtensionComponentID)
    case hostOnly(reason: String)
}

@MainActor
enum HostPopoverFactory {
    static func make(_ id: HostPopoverID) -> ThemedPopover {
        // Reading `id.exposure` is deliberate even though construction needs no branch: every
        // enum case must satisfy the exhaustive exposure switch before it can reach this point.
        _ = id.exposure
        return ThemedPopover()
    }
}
