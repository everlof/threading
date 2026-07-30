import Foundation
import ThreadingExtensionKit

/// Adapts installed extensions to the host-owned optional MCP provider seam.
///
/// This is intentionally the only place where MCP core vocabulary and extension SDK vocabulary
/// meet. Removing extension support means removing this adapter and its composition-root install,
/// not teaching the MCP server how to live without extension types.
@MainActor
final class ExtensionMCPToolProvider: MCPExternalToolProvider {
    private let manager: ExtensionManager
    private let appEvents = AppEventObservations()

    init(manager: ExtensionManager? = nil) {
        self.manager = manager ?? .shared
        appEvents.observe(ExtensionsDidChange.self) { _ in
            NotificationCenter.default.post(MCPExternalToolsDidChange())
        }
    }

    var groups: [MCPExternalToolGroup] {
        manager.mcpToolInventory.map { inventory in
            let availability: String
            if !inventory.isExtensionEnabled {
                availability = " Enable the extension to make these tools available."
            } else if inventory.registeredTools.isEmpty {
                availability = " The running extension has not registered these tools."
            } else {
                availability = ""
            }

            return MCPExternalToolGroup(
                id: inventory.groupID,
                title: inventory.extensionName,
                summary: "Tools contributed by the \(inventory.extensionName) extension."
                    + availability,
                symbol: "puzzlepiece.extension",
                tools: inventory.declaredTools.map { tool in
                    MCPExternalTool(
                        name: tool.qualifiedName(
                            extensionIdentifier: inventory.extensionIdentifier
                        ),
                        title: tool.title,
                        detail: tool.description,
                        symbol: "wrench.and.screwdriver",
                        description: tool.description,
                        inputSchema: MCPJSONValue(tool.inputSchema)
                    )
                },
                instruction: """
                    \(inventory.extensionName) contributes additional tools through Threading's \
                    optional tool provider. Use them only for the purposes described by each tool.
                    """,
                isAvailable: inventory.isExtensionEnabled
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
        manager.invokeMCPTool(
            named: name,
            arguments: ExtensionJSONValue(arguments),
            for: sessionID
        ) { result in
            switch result {
            case .success(let response):
                completion(MCPExternalToolResponse(
                    text: response.text,
                    isError: response.isError
                ))
            case .failure(let error):
                completion(MCPExternalToolResponse(
                    text: error.localizedDescription,
                    isError: true
                ))
            }
        }
    }
}

private extension MCPJSONValue {
    init(_ value: ExtensionJSONValue) {
        switch value {
        case .null:
            self = .null
        case .bool(let value):
            self = .bool(value)
        case .integer(let value):
            self = .integer(value)
        case .number(let value):
            self = .number(value)
        case .string(let value):
            self = .string(value)
        case .array(let values):
            self = .array(values.map(MCPJSONValue.init))
        case .object(let values):
            self = .object(values.mapValues(MCPJSONValue.init))
        }
    }
}

private extension ExtensionJSONValue {
    init(_ value: MCPJSONValue) {
        switch value {
        case .null:
            self = .null
        case .bool(let value):
            self = .bool(value)
        case .integer(let value):
            self = .integer(value)
        case .number(let value):
            self = .number(value)
        case .string(let value):
            self = .string(value)
        case .array(let values):
            self = .array(values.map(ExtensionJSONValue.init))
        case .object(let values):
            self = .object(values.mapValues(ExtensionJSONValue.init))
        }
    }
}
