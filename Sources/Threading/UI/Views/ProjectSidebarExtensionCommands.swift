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
    /// item itself rather than in controller state, so a menu built for one row can never
    /// dispatch with another row's identity.
    final class RowExtensionCommandReference {
        let commandID: String
        let context: ExtensionCommandContext

        init(commandID: String, context: ExtensionCommandContext) {
            self.commandID = commandID
            self.context = context
        }
    }

    /// Appends the Extensions group for one row placement, or nothing when no enabled
    /// extension speaks for it — an empty group on every row would be noise.
    ///
    /// Commands whose scope the row cannot satisfy are omitted rather than disabled: a
    /// project row never names a session, so a session-scoped command has nothing to say
    /// there. Row menus never display key equivalents; the canonical menu-bar placement owns
    /// the visible shortcut.
    func appendExtensionCommandItems(
        to menu: NSMenu,
        placement: ExtensionMenuPlacement,
        context: ExtensionCommandContext,
        commands: [AppCommand]? = nil
    ) {
        let groups = ExtensionCommandMenuLayout.groups(
            commands: (commands ?? CommandRegistry.shared.extensionCommands).filter {
                ExtensionCommandMenuLayout.context(context, satisfies: $0.scope)
            },
            placement: placement
        )
        guard !groups.isEmpty else { return }

        let submenu = NSMenu(title: "Extensions")
        for group in groups {
            let groupMenu = NSMenu(title: group.extensionName)
            for command in group.commands {
                let item = NSMenuItem(
                    title: command.title,
                    action: #selector(rowExtensionCommandClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = RowExtensionCommandReference(
                    commandID: command.id,
                    context: context
                )
                groupMenu.addItem(item)
            }
            let groupItem = NSMenuItem()
            groupItem.title = group.extensionName
            groupItem.submenu = groupMenu
            submenu.addItem(groupItem)
        }

        menu.addItem(.separator())
        let extensionsItem = NSMenuItem()
        extensionsItem.title = L10n.string("Extensions")
        extensionsItem.submenu = submenu
        menu.addItem(extensionsItem)
    }

    @objc func rowExtensionCommandClicked(_ sender: NSMenuItem) {
        guard let reference = sender.representedObject as? RowExtensionCommandReference,
              let command = CommandRegistry.shared.command(id: reference.commandID) else {
            return
        }
        ExtensionCommandInvoker.perform(
            command,
            context: reference.context,
            window: view.window
        )
    }
}
