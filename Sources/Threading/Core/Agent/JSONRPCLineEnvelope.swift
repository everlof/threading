import Foundation

/// The small newline-delimited JSON-RPC surface shared by persistent agent transports.
///
/// Codex omits the optional `"jsonrpc"` member while ACP includes it. Keeping this decoder
/// tolerant and dictionary-backed lets either protocol add fields without taking down a native
/// conversation, and keeps process/framing mechanics out of each provider adapter.
/// JSONSerialization returns an immutable Foundation value graph. The envelope never exposes a
/// mutating reference to it, so it is safe to transfer once from the transport parser to main.
/// The provider adapters still consume their historical Foundation dictionaries; migrating that
/// schema surface is separate from the pipe's actor boundary.
enum JSONRPCLineEnvelope: @unchecked Sendable {
    case response(id: JSONRPCRequestID, result: [String: Any]?, error: String?)
    case request(
        id: JSONRPCRequestID,
        method: String,
        parameters: [String: Any]
    )
    case notification(method: String, parameters: [String: Any])

    static func parse(_ line: String) -> JSONRPCLineEnvelope? {
        guard let data = line.data(using: .utf8) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> JSONRPCLineEnvelope? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let method = object["method"] as? String
        let parameters = object["params"] as? [String: Any] ?? [:]

        if let method, let id = JSONRPCRequestID(object["id"]) {
            return .request(id: id, method: method, parameters: parameters)
        }
        if let method {
            return .notification(method: method, parameters: parameters)
        }
        guard let id = JSONRPCRequestID(object["id"]) else { return nil }

        return .response(
            id: id,
            result: object["result"] as? [String: Any],
            error: errorText(object["error"])
        )
    }

    private static func errorText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let object = value as? [String: Any] else { return nil }
        return object["message"] as? String
            ?? encodedText(object)
    }

    static func encodedText(_ value: Any?) -> String {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.prettyPrinted, .sortedKeys]
              )
        else { return value.map { String(describing: $0) } ?? "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Request Identity

enum JSONRPCRequestID: Hashable {
    case integer(Int64)
    case string(String)
    case null

    init?(_ value: Any?) {
        if value is NSNull {
            self = .null
        } else if let value = value as? String {
            self = .string(value)
        } else if let value = value as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID() {
            self = .integer(value.int64Value)
        } else {
            return nil
        }
    }

    var foundationValue: Any {
        switch self {
        case .integer(let value): return value
        case .string(let value): return value
        case .null: return NSNull()
        }
    }
}

/// Source-compatible names retained for the Codex adapter and its focused wire tests.
typealias CodexAppServerEnvelope = JSONRPCLineEnvelope
typealias CodexAppServerRequestID = JSONRPCRequestID
