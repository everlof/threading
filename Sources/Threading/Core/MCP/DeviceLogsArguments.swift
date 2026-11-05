import Foundation

/// Stable host entry point; the plugin still validates and applies every panel parameter.
struct DeviceLogsArguments: Decodable, Sendable {
    enum Action: String, Decodable, Sendable { case state, configure, read, wait, reveal }
    enum Stream: String, Decodable, Sendable { case regular, bluetooth }

    let action: Action
    let stream: Stream
    let parameters: MCPJSONValue

    var pluginToolName: String {
        let prefix = stream == .bluetooth ? "bluetooth_" : ""
        return "plugin__devicelogs__" + prefix + action.rawValue
    }

    private enum CodingKeys: String, CodingKey { case action, stream }

    init(from decoder: Decoder) throws {
        let routing = try decoder.container(keyedBy: CodingKeys.self)
        action = try routing.decode(Action.self, forKey: .action)
        stream = try routing.decodeIfPresent(Stream.self, forKey: .stream) ?? .regular
        var fields = try decoder.singleValueContainer().decode([String: MCPJSONValue].self)
        fields.removeValue(forKey: CodingKeys.action.rawValue)
        fields.removeValue(forKey: CodingKeys.stream.rawValue)
        parameters = .object(fields)
    }
}
