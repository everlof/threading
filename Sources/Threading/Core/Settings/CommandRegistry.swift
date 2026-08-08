import AppKit
import Foundation
import ThreadingExtensionKit

/// Posted whenever the commands visible to menus and Keyboard settings change.
struct CommandRegistryDidChange: AppEvent {
    static let name = Notification.Name("commandRegistryDidChange")
}

/// One command namespace shared by Threading's own actions and enabled extensions.
///
/// Extensions register semantic values. AppKit menu items, shortcut conflict handling and
/// invocation remain host-owned, so disabling a process removes every entry point at once.
@MainActor
final class CommandRegistry {
    static let shared = CommandRegistry()

    private struct ExtensionCommands {
        let name: String
        let commands: [ExtensionCommand]
    }

    private let builtInCommands: [AppCommand]
    private var extensions: [String: ExtensionCommands] = [:]
    private var projectScripts: [ProjectScript] = []
    private var resolvedCommands: [AppCommand]

    init(builtInCommands: [AppCommand] = AppCommands.all) {
        self.builtInCommands = builtInCommands
        resolvedCommands = builtInCommands
    }

    var all: [AppCommand] {
        resolvedCommands
    }

    var extensionCommands: [AppCommand] {
        resolvedCommands.filter { $0.origin.extensionIdentifier != nil }
    }

    var projectScriptCommands: [AppCommand] {
        resolvedCommands.filter {
            if case .projectScript = $0.origin { return true }
            return false
        }
    }

    func command(id: String) -> AppCommand? {
        resolvedCommands.first { $0.id == id }
    }

    func grouped() -> [(group: AppCommand.Group, commands: [AppCommand])] {
        AppCommand.Group.allCases.compactMap { group in
            let commands = resolvedCommands.filter { $0.group == group }
            return commands.isEmpty ? nil : (group, commands)
        }
    }

    func replaceExtensionCommands(
        extensionIdentifier: String,
        extensionName: String,
        commands: [ExtensionCommand]
    ) {
        extensions[extensionIdentifier] = ExtensionCommands(
            name: extensionName,
            commands: commands
        )
        rebuildAndNotify()
    }

    func removeExtensionCommands(extensionIdentifier: String) {
        guard extensions.removeValue(forKey: extensionIdentifier) != nil else { return }
        rebuildAndNotify()
    }

    func removeAllExtensionCommands() {
        guard !extensions.isEmpty else { return }
        extensions.removeAll()
        rebuildAndNotify()
    }

    func replaceProjectScripts(_ scripts: [ProjectScript]) {
        guard scripts != projectScripts else { return }
        projectScripts = scripts
        rebuildAndNotify()
    }

    static func qualifiedID(extensionIdentifier: String, commandID: String) -> String {
        "extension.\(extensionIdentifier).\(commandID)"
    }

    static func projectScriptID(_ scriptID: String) -> String {
        "project.script.\(scriptID)"
    }

    private func rebuildAndNotify() {
        let extensionCommands = extensions
            .sorted { left, right in
                let names = left.value.name.localizedCaseInsensitiveCompare(right.value.name)
                if names != .orderedSame { return names == .orderedAscending }
                return left.key.localizedCaseInsensitiveCompare(right.key) == .orderedAscending
            }
            .flatMap { entry in
                let identifier = entry.key
                let contribution = entry.value
                return contribution.commands
                    .sorted {
                        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                    .map { command in
                        AppCommand(
                            id: Self.qualifiedID(
                                extensionIdentifier: identifier,
                                commandID: command.id
                            ),
                            group: .extensions,
                            title: command.title,
                            detail: command.description,
                            defaultShortcut: command.defaultShortcut.map(KeyboardShortcut.init),
                            isEditable: true,
                            origin: .extensionCommand(
                                identifier: identifier,
                                name: contribution.name,
                                localID: command.id
                            ),
                            scope: command.scope,
                            risk: command.risk,
                            menuPlacements: command.menuPlacements
                        )
                    }
            }
        let scriptCommands = projectScripts
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { script in
                AppCommand(
                    id: Self.projectScriptID(script.id),
                    group: .projectScripts,
                    title: script.name,
                    detail: script.command,
                    defaultShortcut: nil,
                    isEditable: false,
                    origin: .projectScript(localID: script.id),
                    scope: .project,
                    iconName: script.icon
                )
            }
        resolvedCommands = builtInCommands + scriptCommands + extensionCommands
        NotificationCenter.default.post(CommandRegistryDidChange())
    }
}

private extension KeyboardShortcut {
    init(_ shortcut: ExtensionKeyboardShortcut) {
        var modifiers: NSEvent.ModifierFlags = []
        for modifier in shortcut.modifiers {
            switch modifier {
            case .control: modifiers.insert(.control)
            case .option: modifiers.insert(.option)
            case .shift: modifiers.insert(.shift)
            case .command: modifiers.insert(.command)
            }
        }
        self.init(key: shortcut.key.lowercased(), modifiers: modifiers)
    }
}
