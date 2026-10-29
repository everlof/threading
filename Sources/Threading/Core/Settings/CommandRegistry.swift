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

    private struct Panel {
        let id: String
        let title: String
    }

    private struct ExtensionCommands {
        let name: String
        let commands: [ExtensionCommand]
        let panels: [Panel]
    }

    private let builtInCommands: [AppCommand]
    private var extensions: [String: ExtensionCommands] = [:]
    private var nativePluginBundles: [URL] = []
    private var scannedBundledPluginURLs: [URL] = []
    private var nativePluginPanes: [NativePluginPaneDescriptor] = []
    private(set) var nativePluginScanComplete = false
    private var projectScripts: [ProjectScript] = []
    private var appearanceCommands: [AppCommand] = []
    private var resolvedCommands: [AppCommand]

    init(builtInCommands: [AppCommand] = AppCommands.all) {
        self.builtInCommands = builtInCommands
        resolvedCommands = builtInCommands
    }

    var all: [AppCommand] {
        resolvedCommands
    }

    var extensionCommands: [AppCommand] {
        resolvedCommands.filter { $0.origin.extensionIdentifier != nil && $0.panelTarget == nil }
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
        commands: [ExtensionCommand],
        panels: [ExtensionPanel] = []
    ) {
        extensions[extensionIdentifier] = ExtensionCommands(
            name: extensionName,
            commands: commands,
            panels: panels.map { Panel(id: $0.id, title: $0.title) }
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

    func replaceNativePluginBundles(
        _ bundles: [URL], paneDescriptors: [NativePluginPaneDescriptor] = [],
        scannedBundledBundles: [URL] = []
    ) {
        let bounded = Array(bundles.prefix(32))
        let panes = Array(paneDescriptors.prefix(32))
        let bundled = Array(scannedBundledBundles.prefix(32))
        guard !nativePluginScanComplete || bounded != nativePluginBundles || panes != nativePluginPanes ||
                bundled != scannedBundledPluginURLs else { return }
        nativePluginScanComplete = true
        nativePluginBundles = bounded
        nativePluginPanes = panes
        scannedBundledPluginURLs = bundled
        rebuildAndNotify()
    }

    func nativePluginPane(at url: URL) -> NativePluginPaneDescriptor? {
        let path = url.standardizedFileURL.path
        return nativePluginPanes.first { $0.bundleURL.standardizedFileURL.path == path }
    }

    func hasScannedNativePlugin(at url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return (nativePluginBundles + scannedBundledPluginURLs).contains {
            $0.standardizedFileURL.path == path
        }
    }

    func nativePluginPane(identifier: String, section: String) -> NativePluginPaneDescriptor? {
        nativePluginPanes.first {
            $0.pluginIdentifier == identifier && $0.contains(section)
        }
    }

    func nativePluginPane(identifier: String, route: String) -> NativePluginPaneDescriptor? {
        nativePluginPanes.first {
            $0.pluginIdentifier == identifier && $0.route(route) != nil
        }
    }

    func nativePluginRoutes(
        context: NativePluginPaneDescriptor.Context
    ) -> [(pane: NativePluginPaneDescriptor, route: NativePluginPaneDescriptor.Route)] {
        nativePluginPanes.flatMap { pane in
            pane.routes.filter { $0.context == context }.map { (pane, $0) }
        }
    }

    var panelCommands: [AppCommand] { resolvedCommands.filter { $0.panelTarget != nil } }

    func replaceAppearanceCommands(_ commands: [AppCommand]) {
        let unchanged = commands.count == appearanceCommands.count && zip(commands, appearanceCommands).allSatisfy {
            $0.id == $1.id && $0.title == $1.title && $0.detail == $1.detail
        }
        guard !unchanged else { return }
        appearanceCommands = commands
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
                            menuPlacements: command.menuPlacements,
                            extensionInput: command.input
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
        let nativePanels = nativePluginBundles.filter { url in
            NativePluginManagedOffer.all.first {
                $0.bundleName == url.lastPathComponent
            }?.showsGenericPaneCommand ?? true
        }.filter { url in
            nativePluginPane(at: url)?.sections.contains(where: { $0.command != nil }) != true
        }.map { url in
            AppCommand(id: PanelCommands.nativePluginID(url), group: .view,
                       title: url.deletingPathExtension().lastPathComponent,
                       defaultShortcut: nil, isEditable: true, scope: .session,
                       iconName: "puzzlepiece.extension", panelTarget: .nativePlugin(url))
        }
        let nativeSections = nativePluginPanes.flatMap { pane in
            pane.sections.compactMap { section -> AppCommand? in
                guard let command = section.command,
                      NativePluginManagedOffer.all.contains(where: {
                          $0.identifier == pane.pluginIdentifier
                      }) == false else { return nil }
                return AppCommand(
                    id: PanelCommands.nativePluginSectionID(
                        identifier: pane.pluginIdentifier, section: section.identifier
                    ), group: .view, title: command.title, detail: command.detail,
                    defaultShortcut: nil, isEditable: true, scope: .session,
                    iconName: command.symbol,
                    panelTarget: .nativePluginSection(
                        identifier: pane.pluginIdentifier, section: section.identifier
                    )
                )
            }
        }
        let extensionPanels = extensions.sorted { $0.key < $1.key }.flatMap { identifier, contribution in
            contribution.panels.map { panel in
                AppCommand(id: PanelCommands.extensionPanelID(identifier: identifier, panelID: panel.id),
                           group: .extensions, title: panel.title, defaultShortcut: nil, isEditable: true,
                           origin: .extensionCommand(identifier: identifier, name: contribution.name, localID: panel.id),
                           scope: .session, iconName: "puzzlepiece.extension",
                           panelTarget: .extensionPanel(identifier: identifier, panelID: panel.id))
            }
        }
        resolvedCommands = builtInCommands + scriptCommands + extensionCommands + nativePanels + nativeSections + extensionPanels + appearanceCommands
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
