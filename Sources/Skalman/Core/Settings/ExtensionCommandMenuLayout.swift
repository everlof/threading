import Foundation
import SkalmanExtensionKit

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

    static func canonicalPlacement(
        for command: AppCommand
    ) -> ExtensionMenuPlacement? {
        command.menuPlacements.first
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
