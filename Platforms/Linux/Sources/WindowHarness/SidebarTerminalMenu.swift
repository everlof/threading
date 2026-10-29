#if os(Linux)
import AppKit

/// The terminal-specific commands in the shared sidebar menu surface. Stable terminal and
/// project identities travel with the open menu; the host revalidates both on selection.
@MainActor
struct SidebarTerminalMenu {
    typealias Command = SidebarTerminalMenuContent.Command

    enum Page { case actions, copy }

    let terminalID: String
    let projectID: String
    let displayTitle: String
    let customTitle: String?
    var page: Page = .actions
    var selected = 0

    var entries: [ThemedMenuEntry] {
        switch page {
        case .actions:
            return SidebarTerminalMenuContent.entries(actions: .init())
        case .copy:
            return copyEntries
        }
    }

    private var copyEntries: [ThemedMenuEntry] {
        [.item(ThemedMenuItem(title: "‹  Copy", representedValue: Command.back.rawValue)),
         .separator] + SidebarTerminalMenuContent.copyEntries(actions: .init())
    }

    func command(at index: Int) -> Command? {
        guard entries.indices.contains(index),
              let value = entries[index].item?.representedValue as? String else { return nil }
        return Command(rawValue: value)
    }

    mutating func openCopy() {
        page = .copy
        selected = 2
    }

    mutating func returnToActions() {
        page = .actions
        selected = entries.firstIndex(where: {
            $0.item?.representedValue as? String == Command.copy.rawValue
        }) ?? 0
    }
}
#endif
