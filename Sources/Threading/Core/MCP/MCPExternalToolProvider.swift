import Foundation

/// A JSON value owned by the MCP core.
///
/// External tool providers translate this at their own boundary. The wire protocol therefore
/// stays useful without taking a dependency on any particular extension or plugin SDK.
enum MCPJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    static let emptyObject = Self.object([:])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MCPJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: MCPJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

/// One externally supplied MCP tool, in host-owned vocabulary.
struct MCPExternalTool {
    let name: String
    let title: String
    let detail: String
    let symbol: String
    let description: String
    let inputSchema: MCPJSONValue
}

/// A provider-owned group shown and toggled beside Threading's built-in tool groups.
struct MCPExternalToolGroup {
    let id: String
    let title: String
    let summary: String
    let symbol: String
    let tools: [MCPExternalTool]
    let instruction: String
    let isAvailable: Bool
}

struct MCPExternalToolResponse {
    let text: String
    let isError: Bool
}

/// The only seam the MCP core exposes to optional tool systems.
///
/// Extensions are one implementation today. A different implementation — or no implementation
/// at all — leaves the catalogue, wire format, settings page, and dispatcher unchanged.
@MainActor
protocol MCPExternalToolProvider: AnyObject {
    var groups: [MCPExternalToolGroup] { get }

    /// Returns false only when this provider does not own the name.
    @discardableResult
    func invokeTool(
        named name: String,
        arguments: MCPJSONValue,
        for sessionID: SessionID,
        completion: @escaping (MCPExternalToolResponse) -> Void
    ) -> Bool
}

struct MCPExternalToolsDidChange: AppEvent {
    static let name = Notification.Name("mcpExternalToolsDidChange")
}

/// The replaceable process-wide provider slot.
///
/// Its nil state is the complete no-extensions implementation: no groups, no definitions, and
/// no routed calls. The app composition root installs the extension adapter explicitly.
@MainActor
final class MCPExternalToolRegistry {
    static let shared = MCPExternalToolRegistry()

    /// More than one, because tools now come from two places: the safe extension tier and the
    /// native plugin tier. `invokeTool` already answered "false when this provider does not own the
    /// name", which is the whole mechanism for asking each in turn — this only stops there being
    /// exactly one to ask.
    private(set) var providers: [any MCPExternalToolProvider] = [] {
        didSet {
            NotificationCenter.default.post(MCPExternalToolsDidChange())
        }
    }

    func register(_ provider: any MCPExternalToolProvider) {
        providers.append(provider)
    }

    /// Announces that a provider's tools changed without changing the list itself — a plugin
    /// loading brings tools with it.
    func toolsDidChange() {
        NotificationCenter.default.post(MCPExternalToolsDidChange())
    }

    var groups: [MCPExternalToolGroup] {
        providers.flatMap(\.groups)
    }

    @discardableResult
    func invokeTool(
        named name: String,
        arguments: MCPJSONValue,
        for sessionID: SessionID,
        completion: @escaping (MCPExternalToolResponse) -> Void
    ) -> Bool {
        for provider in providers
        where provider.invokeTool(
            named: name,
            arguments: arguments,
            for: sessionID,
            completion: completion
        ) {
            return true
        }
        return false
    }
}
