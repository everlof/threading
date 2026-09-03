import Foundation
import ThreadingPluginKit

/// The plugins that are loaded right now, and which chat each belongs to.
///
/// A plugin's tools are only callable while the pane hosting it exists: it owns a stream, a store,
/// a view — state a tool acts on. So this tracks instances rather than bundles, and a tool call for
/// a session that has no such pane open is a refusal with a reason rather than a silent nothing.
@MainActor
final class NativePluginRuntime {

    static let shared = NativePluginRuntime()

    private struct Entry {
        let sessionID: SessionID?
        weak var controller: NativePluginPaneViewController?
        let plugin: ThreadingNativePlugin
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func register(
        _ plugin: ThreadingNativePlugin,
        controller: NativePluginPaneViewController,
        sessionID: SessionID?
    ) {
        entries[ObjectIdentifier(controller)] = Entry(
            sessionID: sessionID,
            controller: controller,
            plugin: plugin
        )
        MCPExternalToolRegistry.shared.toolsDidChange()
    }

    func deregister(_ controller: NativePluginPaneViewController) {
        entries.removeValue(forKey: ObjectIdentifier(controller))
        MCPExternalToolRegistry.shared.toolsDidChange()
    }

    /// Every loaded plugin, with dead entries swept. A pane can go away without telling anyone if
    /// its window closed, so the weak reference is the truth rather than the dictionary.
    func loaded() -> [(plugin: ThreadingNativePlugin, sessionID: SessionID?)] {
        entries = entries.filter { $0.value.controller != nil }
        return entries.values.map { ($0.plugin, $0.sessionID) }
    }

    /// The plugin with this identity that belongs to this chat, if one is open.
    func plugin(identifier: String, for sessionID: SessionID) -> ThreadingNativePlugin? {
        loaded().first { $0.plugin.pluginIdentifier == identifier && $0.sessionID == sessionID }?
            .plugin
    }
}
