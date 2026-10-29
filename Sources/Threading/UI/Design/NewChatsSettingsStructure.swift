import AppKit
#if os(Linux)
@testable import CoreSlice
#endif

/// New-chat defaults have one row order and one explanation on both desktop hosts.
/// The host supplies the controls it supports and owns their persistence.
@MainActor
enum NewChatsSettingsStructure {
    struct Help {
        let title: String
        let detail: String

        var topic: HelpTopic {
            HelpTopic(title: L10n.string(title), paragraphs: [L10n.string(detail)])
        }
    }

    struct Row {
        let title: String
        let subtitle: String
        let help: Help?
    }

    struct Controls {
        var agent: NSView?
        var permission: NSView?
        let claudeSpeed: NSView
        let codexSpeed: NSView
    }

    struct PermissionChoice {
        let title: String
        let subtitle: String?
        let mode: AgentPermissionMode?
    }

    static func permissionChoices(for kind: AgentKind) -> [PermissionChoice] {
        [PermissionChoice(title: L10n.string("Agent's Setting"), subtitle: nil, mode: nil)]
            + AgentPermissionMode.allCases.map { mode in
                PermissionChoice(title: mode.displayName(for: kind),
                    subtitle: mode.menuDescription(for: kind), mode: mode)
            }
    }

    static func rows(controls: Controls, makeRow: (Row, NSView) -> NSView) -> [NSView] {
        var result: [NSView] = []
        if let agent = controls.agent {
            result.append(makeRow(Row(
                title: "New sessions use",
                subtitle: "Used by New Session (⌘N). Other agents stay available from the Project menu.",
                help: nil), agent))
        }
        if let permission = controls.permission {
            result.append(makeRow(Row(
                title: "New sessions start in",
                subtitle: "How much a session may do before it stops to ask.",
                help: Help(title: "New sessions start in",
                    detail: "Following leaves it to the agent's own configuration. A single chat can still be set from its ⋯ menu, and the mode applies from that chat's next launch.")),
                permission))
        }
        result.append(makeRow(Row(
            title: "Claude sessions start in",
            subtitle: "Fast uses more credits and needs a supported model.",
            help: Help(title: "Claude sessions start in",
                detail: "Applies to Terminal and Native chats. Agent's Setting preserves Claude Code's own choice.")),
            controls.claudeSpeed))
        result.append(makeRow(Row(
            title: "Codex sessions start in",
            subtitle: "Fast uses more credits.",
            help: Help(title: "Codex sessions start in",
                detail: "Applies to Terminal and Native chats. Agent's Setting preserves Codex's own service tier.")),
            controls.codexSpeed))
        return result
    }
}
