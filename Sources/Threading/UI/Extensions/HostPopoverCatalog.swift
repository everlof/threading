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
    case toolbarAllAccountUsage = "toolbar.all-account-usage-popover"
    case settingsAccountIconPicker = "settings.account-icon-picker"
    case extensionNodeDetail = "extension.node-detail"
    case conversationChangedFileDiff = "conversation.changed-file-diff"
    case sessionCornerCardAttachment = "session.corner-card.attachment-preview"
    case composerModelEffortPicker = "composer.model-effort-picker"
    case designHelp = "design.help"
    case sessionRunPlan = "session.run-plan"

    var exposure: HostPopoverExposure {
        switch self {
        case .sidebarProjectHoverCard:
            return .component(.sidebarProjectHoverCard)
        case .sidebarSessionHoverCard:
            return .component(.sidebarSessionHoverCard)
        case .toolbarAccountUsage:
            return .component(.toolbarAccountUsagePopover)
        case .toolbarAllAccountUsage:
            return .hostOnly(
                reason: "A live operational fleet over every enabled login. Refresh pacing, "
                    + "stable account ordering, bounded scrolling, current-session migration "
                    + "eligibility and dismissal remain host-owned; the public account-usage "
                    + "component contract describes one account and cannot honestly replace "
                    + "or compose this multi-account action surface."
            )
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
                reason: "Edits user-owned account appearance and shared defaults. Threading owns "
                    + "inheritance, persistence, image admission, accessibility and dismissal; "
                    + "extensions contribute icon resolvers but cannot replace the native editor."
            )
        case .conversationChangedFileDiff:
            return .hostOnly(
                reason: "One file's diff under the pointer, drawn by the same renderer as Git "
                    + "Review from what git reported for that turn. There is nothing here for "
                    + "an extension to compose into — the body *is* the change — and the "
                    + "surface exists only while a reader is holding a row open, so its "
                    + "timing, placement, chrome and dismissal stay host-owned."
            )
        case .composerModelEffortPicker:
            return .hostOnly(
                reason: "Edits executable launch configuration from the selected runtime and "
                    + "login's live model catalogue. Provider validity, inherited defaults, "
                    + "persistence, launch flags, keyboard focus and dismissal stay host-owned; "
                    + "extensions can customize the surrounding composer without replacing the "
                    + "provider-truth surface that decides what process AnotherTerminal starts."
            )
        case .designHelp:
            return .hostOnly(
                reason: "The panel behind a \"?\" beside a control. Its body is the words the "
                    + "surface it belongs to already published as its own copy — a way in's four "
                    + "questions, an operation's cost — so there is nothing here for an extension "
                    + "to compose into that it could not compose into that surface. What stays "
                    + "host-owned is the affordance: the press, the placement, Escape, the focus "
                    + "return, and the promise that the same words reach a screen reader from the "
                    + "button whether or not the panel is ever opened."
            )
        case .sessionCornerCardAttachment:
            return .hostOnly(
                reason: "A bounded glimpse of one attachment plus host file actions. Extensions "
                    + "already contribute arbitrary rows through session.corner-card@1 and "
                    + "attachment renderers through attachments.preview@1; composing a second "
                    + "extension into this transient action surface would mix those authorities. "
                    + "Its hover timing, local-file actions and dismissal stay host-owned."
            )
        case .sessionRunPlan:
            return .hostOnly(
                reason: "Provider-authored live plan truth shared by terminal and native session "
                    + "chrome. Exact ordering, turn-boundary clearing, transcript recovery, "
                    + "remote paging, accessibility and dismissal remain host-owned; extensions "
                    + "may add corner-card rows but cannot replace session activity truth."
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
