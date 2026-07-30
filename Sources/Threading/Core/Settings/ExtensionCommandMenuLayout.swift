import Foundation
import ThreadingExtensionKit

/// Pure layout rules shared by AppKit menu construction and tests.
///
/// Extensions name stable host placements, never menu indexes. The first declared placement owns
/// the key equivalent when a command is intentionally visible in more than one menu; all copies
/// still route through the same qualified command ID.
enum ExtensionCommandMenuLayout {
    struct Group {
        let extensionIdentifier: String
        let extensionName: String
        let commands: [AppCommand]
    }

    /// The placements rendered in the menu bar. Row placements live in per-row context
    /// menus, which never display key equivalents, so only a menu-bar placement can own a
    /// command's visible shortcut.
    static let menuBarPlacements: Set<ExtensionMenuPlacement> = [.extensions, .project, .view]

    static func canonicalPlacement(
        for command: AppCommand
    ) -> ExtensionMenuPlacement? {
        command.menuPlacements.first { menuBarPlacements.contains($0) }
    }

    /// A command visible only in row menus still needs one hidden menu-bar item, or its
    /// user-assigned shortcut would have nowhere to dispatch from.
    static func needsHiddenShortcutCarrier(_ command: AppCommand) -> Bool {
        canonicalPlacement(for: command) == nil
    }

    /// Whether an invocation context can satisfy the command's declared scope. Row menus
    /// filter with the row's own identity, so a project row simply never offers a
    /// session-scoped command rather than offering it disabled.
    static func context(
        _ context: ExtensionCommandContext,
        satisfies scope: ExtensionCommandScope
    ) -> Bool {
        switch scope {
        case .application: return true
        case .project: return context.projectID != nil
        case .session: return context.sessionID != nil
        }
    }

    static func groups(
        commands: [AppCommand],
        placement: ExtensionMenuPlacement
    ) -> [Group] {
        Dictionary(grouping: commands.filter {
            $0.menuPlacements.contains(placement)
        }) {
            $0.origin.extensionIdentifier ?? ""
        }
        .map { identifier, commands in
            Group(
                extensionIdentifier: identifier,
                extensionName: commands.first?.origin.extensionName ?? identifier,
                commands: commands.sorted {
                    let titles = $0.title.localizedCaseInsensitiveCompare($1.title)
                    if titles != .orderedSame { return titles == .orderedAscending }
                    return $0.id < $1.id
                }
            )
        }
        .sorted {
            let names = $0.extensionName.localizedCaseInsensitiveCompare($1.extensionName)
            if names != .orderedSame { return names == .orderedAscending }
            return $0.extensionIdentifier < $1.extensionIdentifier
        }
    }
}
