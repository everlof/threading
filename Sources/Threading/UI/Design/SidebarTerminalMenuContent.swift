import AppKit

/// The terminal row's standing menu on both desktop hosts. The hosts own commands and optional
/// services; this source owns the common order, copy fold, labels and separators.
@MainActor
enum SidebarTerminalMenuContent {
    enum Command: String {
        case rename
        case copy
        case copyThreadingID
        case copyWorktreePath
        case close
        case back
    }

    struct Actions {
        var rename: (() -> Void)? = nil
        var copyThreadingID: (() -> Void)? = nil
        var copyWorktreePath: (() -> Void)? = nil
        var close: (() -> Void)? = nil
    }

    static func entries(
        actions: Actions,
        theme: ThemedMenuEntry? = nil,
        sounds: ThemedMenuEntry? = nil,
        sharing: [ThemedMenuEntry] = []
    ) -> [ThemedMenuEntry] {
        var result: [ThemedMenuEntry] = [
            item(title: L10n.string("Rename Terminal…"), command: .rename,
                 onChoose: actions.rename),
            .item(ThemedMenuItem(title: L10n.string("Copy"),
                                 representedValue: Command.copy.rawValue,
                                 submenu: copyEntries(actions: actions)))
        ]
        if let theme { result.append(theme) }
        if let sounds { result.append(sounds) }
        result.append(contentsOf: sharing)
        result.append(.separator)
        result.append(item(title: L10n.string("Close Terminal"), command: .close,
                           onChoose: actions.close))
        return result
    }

    static func copyEntries(actions: Actions) -> [ThemedMenuEntry] {
        [
            item(title: L10n.string("Threading ID"), command: .copyThreadingID,
                 onChoose: actions.copyThreadingID),
            item(title: L10n.string("Worktree Path"), command: .copyWorktreePath,
                 onChoose: actions.copyWorktreePath)
        ]
    }

    private static func item(title: String, command: Command,
                             onChoose: (() -> Void)?) -> ThemedMenuEntry {
        .item(ThemedMenuItem(title: title, representedValue: command.rawValue,
                             onChoose: onChoose))
    }
}
