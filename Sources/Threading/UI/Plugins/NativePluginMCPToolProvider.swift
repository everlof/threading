import Foundation
import ThreadingPluginKit

/// The agent's route into a native plugin's tools.
///
/// The second implementation of `MCPExternalToolProvider`, beside the extension tier's. Nothing in
/// the MCP core changed to allow it, which was the seam's stated intent: the catalogue, wire
/// format, settings page and dispatcher are the same ones the built-in tools use.
///
/// Names are namespaced by the plugin's own identity, so two plugins offering `search` are two
/// tools, and a name in a transcript says which one ran.
@MainActor
final class NativePluginMCPToolProvider: MCPExternalToolProvider {

    private enum Naming {
        static let prefix = "plugin"
        static let separator = "__"

        /// `plugin__devicelogs__search`. The plugin's identifier is reversed-DNS, which is not a
        /// tool name, so the last component stands for it.
        static func qualified(identifier: String, tool: String) -> String {
            let short = identifier.split(separator: ".").last.map(String.init) ?? identifier
            return [prefix, short, tool].joined(separator: separator)
        }

        static func split(_ qualified: String) -> (short: String, tool: String)? {
            let parts = qualified.components(separatedBy: separator)
            guard parts.count == 3, parts[0] == prefix else { return nil }
            return (parts[1], parts[2])
        }
    }

    var groups: [MCPExternalToolGroup] {
        var seen: Set<String> = []
        return NativePluginRuntime.shared.loaded().compactMap { loaded in
            let identifier = loaded.plugin.pluginIdentifier
            // One group per plugin, not per open pane: two chats watching two devices offer the
            // same tools, and listing them twice would read as two different capabilities.
            guard seen.insert(identifier).inserted else { return nil }
            guard let declared = loaded.plugin.pluginTools, !declared.isEmpty else { return nil }
            return MCPExternalToolGroup(
                id: identifier,
                title: declared.first?.title ?? identifier,
                summary: declared.first?.detail ?? "",
                symbol: declared.first?.symbol ?? "puzzlepiece.extension",
                tools: declared.map { tool in
                    MCPExternalTool(
                        name: Naming.qualified(identifier: identifier, tool: tool.name),
                        title: tool.title,
                        detail: tool.detail,
                        symbol: tool.symbol,
                        description: tool.summary,
                        inputSchema: schema(tool.inputSchemaJSON)
                    )
                },
                instruction: "",
                isAvailable: true
            )
        }
    }

    @discardableResult
    func invokeTool(
        named name: String,
        arguments: MCPJSONValue,
        for sessionID: SessionID,
        completion: @escaping (MCPExternalToolResponse) -> Void
    ) -> Bool {
        guard let parsed = Naming.split(name) else { return false }
        let match = NativePluginRuntime.shared.loaded().first { loaded in
            let identifier = loaded.plugin.pluginIdentifier
            return Naming.qualified(identifier: identifier, tool: parsed.tool) == name
                && loaded.sessionID == sessionID
        }
        guard let match else {
            // The name is ours, so answering is ours too. A plugin whose pane is closed is a
            // reason, not a missing tool: the agent can open it and try again.
            completion(MCPExternalToolResponse(
                text: "No \(parsed.short) pane is open in this chat, so its tools have nothing to "
                    + "act on. Ask the user to open it, or open it yourself if you have a tool for "
                    + "that, then call this again.",
                isError: true
            ))
            return true
        }
        guard let invoke = match.plugin.invokeTool else {
            completion(MCPExternalToolResponse(
                text: "\(parsed.short) declares tools but does not implement invocation.",
                isError: true
            ))
            return true
        }
        // A tool answers when its own work does — a store query completes on the queue that owns
        // the store — so the reply arrives on whatever thread the plugin used. Hop rather than
        // assume: `assumeIsolated` off the main thread is a trap, not a check.
        invoke(parsed.tool, json(arguments)) { text, isError in
            DispatchQueue.main.async {
                completion(MCPExternalToolResponse(text: text, isError: isError))
            }
        }
        return true
    }

    // MARK: - The JSON edge

    /// The plugin speaks JSON text; the MCP core speaks its own value. Translating here is what
    /// keeps `ThreadingPluginKit` free of a dependency on either.
    private func schema(_ text: String) -> MCPJSONValue {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(MCPJSONValue.self, from: data) else {
            return .emptyObject
        }
        return value
    }

    private func json(_ value: MCPJSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
