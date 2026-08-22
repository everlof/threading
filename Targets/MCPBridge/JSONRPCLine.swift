import Foundation

// MARK: - Decoded message

/// One stdin line, reduced to the three things routing depends on.
///
/// The client's `id` is carried as the JSON fragment it arrived as rather than as a decoded
/// value. JSON-RPC lets an id be a number or a string, a client is entitled to expect the exact
/// value back, and a decode-then-re-encode round trip through `Any` would put an integer's
/// spelling at the mercy of `NSNumber`. Bytes round-trip; they are also `Sendable`, which a
/// decoded `Any` is not, and this value crosses onto the request queue.
struct DecodedJSONRPCMessage: Sendable {
    let method: String
    /// `nil` for a notification, which by definition expects no reply.
    let encodedID: Data?
    /// `params.protocolVersion` of an `initialize`, so a cache-served handshake can echo it.
    let requestedProtocolVersion: String?

    var isNotification: Bool { encodedID == nil }
}

// MARK: - Line codec

/// Reads and writes the stdio transport's newline-delimited JSON-RPC.
enum JSONRPCLine {

    enum DecodeFailure: Error {
        /// Not JSON at all.
        case parse
        /// JSON, but not a JSON-RPC request object.
        case invalidRequest
    }

    // MARK: - Decoding

    static func decode(_ line: Data) throws -> DecodedJSONRPCMessage {
        guard line.count <= BridgeDefaults.maximumMessageBytes else {
            throw DecodeFailure.parse
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: line, options: [])
        } catch {
            throw DecodeFailure.parse
        }
        guard let object = value as? [String: Any] else { throw DecodeFailure.invalidRequest }
        guard let method = object["method"] as? String else { throw DecodeFailure.invalidRequest }

        // `contains` rather than a nil test: an explicit `"id": null` is a request with a null
        // id, which must be answered, while an absent key is a notification, which must not.
        let encodedID = object.index(forKey: "id") == nil
            ? nil
            : encode(fragment: object["id"] ?? NSNull())

        let parameters = object["params"] as? [String: Any]
        return DecodedJSONRPCMessage(
            method: method,
            encodedID: encodedID,
            requestedProtocolVersion: parameters?["protocolVersion"] as? String
        )
    }

    // MARK: - Encoding

    /// A successful reply, with `body` spliced in as the `result` value.
    static func result(id: Data, body: Data) -> Data {
        var line = Data(#"{"jsonrpc":"2.0","id":"#.utf8)
        line.append(id)
        line.append(Data(#","result":"#.utf8))
        line.append(body)
        line.append(Data("}".utf8))
        return line
    }

    /// A JSON-RPC error. `id` is `nil` only for a message that could not be parsed far enough to
    /// have one, which the specification answers with an explicit null.
    static func failure(id: Data?, code: Int, message: String) -> Data {
        var line = Data(#"{"jsonrpc":"2.0","id":"#.utf8)
        line.append(id ?? Data("null".utf8))
        line.append(Data(#","error":{"code":"#.utf8))
        line.append(Data(String(code).utf8))
        line.append(Data(#","message":"#.utf8))
        line.append(Data(quoted(message).utf8))
        line.append(Data("}}".utf8))
        return line
    }

    /// The `result` of a successful call whose *tool* failed — MCP's own error shape.
    ///
    /// A transport error would be handled by the client and never reach the model. This is a
    /// result, so the model reads the sentence and decides what to do, which is the whole point
    /// of refusing this way.
    static func toolErrorResult(text: String) -> Data {
        var body = Data(#"{"content":[{"type":"text","text":"#.utf8)
        body.append(Data(quoted(text).utf8))
        body.append(Data(#"}],"isError":true}"#.utf8))
        return body
    }

    /// The `result` value of an object built from parts the bridge owns.
    ///
    /// Returns `nil` rather than throwing so a caller can fall back; every dictionary passed here
    /// is a literal in this binary, so a failure means a programming error, not bad input.
    static func encode(object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [])
    }

    /// Re-serialises a JSON fragment — a number, a string, or null — that came from
    /// `JSONSerialization`.
    private static func encode(fragment: Any) -> Data {
        if fragment is NSNull { return Data("null".utf8) }
        if let text = fragment as? String { return Data(quoted(text).utf8) }
        if let data = try? JSONSerialization.data(
            withJSONObject: fragment,
            options: [.fragmentsAllowed]
        ) {
            return data
        }
        return Data("null".utf8)
    }

    /// JSON-escapes a string into a quoted literal.
    ///
    /// Written out rather than reached for through `JSONSerialization`, which has no top-level
    /// fragment *encoding* API, or `JSONEncoder`, whose fragment support has changed across
    /// Foundation versions. The refusal text is user-visible and contains typographic quotes, so
    /// getting this wrong would corrupt the one message the model is meant to read.
    static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
