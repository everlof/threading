import AppKit
#if os(Linux)
@testable import CoreSlice
#endif

/// The standing session menu on both desktop hosts. The hosts supply commands and the services
/// they support; this source owns the common rows, their order, Copy fold and group boundaries.
@MainActor
enum SidebarSessionMenuContent {
    struct Actions {
        var pin: (() -> Void)? = nil
        var unsnooze: (() -> Void)? = nil
        var archive: (() -> Void)? = nil
        var close: (() -> Void)? = nil
        var closeWithoutAsking: (() -> Void)? = nil
        var rename: (() -> Void)? = nil
        var copyAgentID: (() -> Void)? = nil
        var copyThreadingID: (() -> Void)? = nil
        var copyWorktreePath: (() -> Void)? = nil
        var copyTranscriptPath: (() -> Void)? = nil
    }

    struct Copy {
        var hasAgentID = false
        var hasWorktreePath = false
        var hasTranscriptPath = false
        var prelude: [ThemedMenuEntry] = []
    }

    struct Sections {
        var beforeGroups: [ThemedMenuEntry] = []
        var sideChats: [ThemedMenuEntry] = []
        var appearance: [ThemedMenuEntry] = []
        var identityPrefix: [ThemedMenuEntry] = []
        var afterRename: [ThemedMenuEntry] = []
        var identityTail: [ThemedMenuEntry] = []
        var destructive: [ThemedMenuEntry] = []
    }

    struct Configuration {
        var isPinned = false
        var isSnoozed = false
        var isRunning = false
        var snoozeSubmenu: [ThemedMenuEntry] = []
        var closeShortcut: KeyboardShortcut? = nil
        var renameShortcut: KeyboardShortcut? = nil
        var actions = Actions()
        var copy = Copy()
        var copyEntry: ThemedMenuEntry? = nil
        var sections = Sections()
    }

    static func entries(_ configuration: Configuration) -> [ThemedMenuEntry] {
        let actions = configuration.actions
        var rows = [
            item(configuration.isPinned ? "Unpin" : "Pin",
                 symbol: configuration.isPinned ? "pin.slash" : "pin", command: "pin",
                 onChoose: actions.pin),
            snoozeEntry(isSnoozed: configuration.isSnoozed,
                        submenu: configuration.snoozeSubmenu,
                        onUnsnooze: actions.unsnooze),
            item("Archive", symbol: "archivebox", command: "archive", onChoose: actions.archive)
        ]
        if configuration.isRunning {
            let alternate = actions.closeWithoutAsking.map { action in
                ThemedMenuAlternate(title: L10n.string("Close Session Without Asking"), action: action)
            }
            rows.append(item("Close Session", symbol: "stop.circle", command: "close",
                             shortcut: configuration.closeShortcut, alternate: alternate,
                             onChoose: actions.close))
        }
        rows.append(contentsOf: configuration.sections.beforeGroups)
        appendGroup(configuration.sections.sideChats, to: &rows)
        appendGroup(configuration.sections.appearance, to: &rows)

        var identity = configuration.sections.identityPrefix
        identity.append(item("Rename Session…", symbol: "pencil", command: "rename",
                             shortcut: configuration.renameShortcut, onChoose: actions.rename))
        identity.append(contentsOf: configuration.sections.afterRename)
        identity.append(configuration.copyEntry ?? copyEntry(configuration.copy, actions: actions))
        identity.append(contentsOf: configuration.sections.identityTail)
        appendGroup(identity, to: &rows)
        appendGroup(configuration.sections.destructive, to: &rows)
        return rows
    }

    static func copyEntry(_ copy: Copy, actions: Actions) -> ThemedMenuEntry {
        .item(ThemedMenuItem(title: L10n.string("Copy"),
                             image: ThemedMenuIcon.symbol("doc.on.doc"),
                             representedValue: "copy",
                             submenu: copyEntries(copy, actions: actions)))
    }

    static func copyEntries(_ copy: Copy, actions: Actions) -> [ThemedMenuEntry] {
        var rows = copy.prelude
        if copy.hasAgentID {
            rows.append(item("Agent Session ID", symbol: "number", command: "copyAgentID",
                             onChoose: actions.copyAgentID))
        }
        rows.append(item("Threading ID", symbol: "number", command: "copyThreadingID",
                         onChoose: actions.copyThreadingID))
        if copy.hasWorktreePath {
            rows.append(item("Worktree Path", symbol: "folder", command: "copyWorktreePath",
                             onChoose: actions.copyWorktreePath))
        }
        if copy.hasTranscriptPath {
            rows.append(item("Transcript Path", symbol: "folder", command: "copyTranscriptPath",
                             onChoose: actions.copyTranscriptPath))
        }
        return rows
    }

    /// The same wall-clock choices appear in the row, context and pane-header menus on both
    /// desktop hosts. A Linux paged menu supplies its Back row as a prelude; macOS presents
    /// these entries directly as a submenu. The host still owns the deadline mutation and
    /// custom-time sheet.
    static func snoozeEntries(
        moments: [SnoozeWallClockMoments.Moment],
        prelude: [ThemedMenuEntry] = [],
        onChoose: ((Date) -> Void)? = nil,
        onCustom: (() -> Void)? = nil
    ) -> [ThemedMenuEntry] {
        var rows = prelude
        let choices = SnoozeWallClockMoments.presentations(for: moments)
        for (index, choice) in choices.enumerated() {
            rows.append(.item(ThemedMenuItem(
                title: choice.title, subtitle: choice.detail,
                representedValue: "snoozeChoice:\(index)",
                onChoose: onChoose.map { action in { action(choice.moment.date) } }
            )))
        }
        rows.append(.separator)
        rows.append(.item(ThemedMenuItem(
            title: L10n.string("Custom time…"),
            image: ThemedMenuIcon.symbol("calendar"),
            representedValue: "customSnooze", onChoose: onCustom
        )))
        return rows
    }

    private static func snoozeEntry(isSnoozed: Bool, submenu: [ThemedMenuEntry],
                                    onUnsnooze: (() -> Void)?) -> ThemedMenuEntry {
        if isSnoozed {
            return item("Unsnooze", symbol: "bell", command: "unsnooze",
                        onChoose: onUnsnooze)
        }
        return .item(ThemedMenuItem(title: L10n.string("Snooze"),
                                    image: ThemedMenuIcon.symbol("moon.zzz"),
                                    representedValue: "snooze", submenu: submenu))
    }

    private static func item(_ title: String, symbol: String, command: String,
                             shortcut: KeyboardShortcut? = nil,
                             alternate: ThemedMenuAlternate? = nil,
                             onChoose: (() -> Void)?) -> ThemedMenuEntry {
        var row = ThemedMenuItem(title: L10n.string(title), shortcut: shortcut,
                                 image: ThemedMenuIcon.symbol(symbol),
                                 representedValue: command, onChoose: onChoose)
        row.alternate = alternate
        return .item(row)
    }

    private static func appendGroup(_ group: [ThemedMenuEntry], to rows: inout [ThemedMenuEntry]) {
        guard !group.isEmpty else { return }
        if rows.last?.isItem == true { rows.append(.separator) }
        rows.append(contentsOf: group)
    }
}
