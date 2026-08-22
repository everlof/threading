import AppKit
import ThreadingExtensionKit

// MARK: - Row Extension Commands

/// The host-owned Extensions group at the end of a row's menu. Extensions contribute commands
/// with a row placement, never menu items; each item carries the row's own identity as its
/// context, so a command invoked here acts on the row under the pointer rather than on the
/// selection. Split into its own file like the theme menu, and for the same reason: one
/// builder serves the `⋯` button and the right-click menu alike.
extension ProjectSidebarViewController {

    /// One item's complete instruction: which command, and which row asked. Carried on the
    /// item as its `representedValue` — the closure already captures both, but a closure
    /// cannot be asserted on, and dispatching with another row's identity is exactly the bug
    /// a test must be able to see.
    struct RowExtensionCommandReference {
        let commandID: String
        let context: ExtensionCommandContext
    }

    /// The Extensions group for one row placement, or nothing when no enabled extension
    /// speaks for it — an empty group on every row would be noise.
    ///
    /// Commands whose scope the row cannot satisfy are omitted rather than disabled: a
    /// project row never names a session, so a session-scoped command has nothing to say
    /// there. Every placement draws the command's resolved shortcut: a chord is part of how an
    /// action is learned, not decoration reserved for whichever menu-bar placement happens to
    /// carry the actual key equivalent. Each command's closure carries the row's own identity,
    /// so a menu built for one row can never dispatch with another row's.
    func extensionCommandEntries(
        placement: ExtensionMenuPlacement,
        context: ExtensionCommandContext,
        commands: [AppCommand]? = nil
    ) -> [ThemedMenuEntry] {
        let groups = ExtensionCommandMenuLayout.groups(
            commands: (commands ?? CommandRegistry.shared.extensionCommands).filter {
                ExtensionCommandMenuLayout.context(context, satisfies: $0.scope)
            },
            placement: placement
        )
        guard !groups.isEmpty else { return [] }

        let groupEntries: [ThemedMenuEntry] = groups.map { group in
            .item(ThemedMenuItem(
                title: group.extensionName,
                submenu: group.commands.map { command in
                    .item(ThemedMenuItem(
                        title: command.title,
                        shortcut: ShortcutOverrideStore.shared.shortcut(for: command),
                        representedValue: RowExtensionCommandReference(
                            commandID: command.id,
                            context: context
                        ),
                        onChoose: { [weak self] in
                            self?.performRowExtensionCommand(command.id, context: context)
                        }
                    ))
                }
            ))
        }

        return [
            .separator,
            .item(ThemedMenuItem(title: L10n.string("Extensions"), submenu: groupEntries))
        ]
    }

    private func performRowExtensionCommand(
        _ commandID: String,
        context: ExtensionCommandContext
    ) {
        guard let command = CommandRegistry.shared.command(id: commandID) else { return }
        ExtensionCommandInvoker.perform(
            command,
            context: context,
            window: view.window
        )
    }
}
