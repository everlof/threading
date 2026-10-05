import Foundation

/// Four independent opt-ins. This is capture policy, not authority to visit an origin.
struct BrowserNetworkCaptureOptions: Codable, Equatable, Sendable {
    var requestHeaders = false
    var responseHeaders = false
    var requestBody = false
    var responseBody = false

    static let metadataOnly = Self()

    subscript(field: BrowserNetworkCaptureField) -> Bool {
        get {
            switch field {
            case .requestHeaders: requestHeaders
            case .responseHeaders: responseHeaders
            case .requestBody: requestBody
            case .responseBody: responseBody
            }
        }
        set {
            switch field {
            case .requestHeaders: requestHeaders = newValue
            case .responseHeaders: responseHeaders = newValue
            case .requestBody: requestBody = newValue
            case .responseBody: responseBody = newValue
            }
        }
    }

    var scriptValue: String {
        "{request_headers:\(requestHeaders),response_headers:\(responseHeaders),"
            + "request_body:\(requestBody),response_body:\(responseBody)}"
    }

    private enum CodingKeys: String, CodingKey {
        case requestHeaders = "request_headers"
        case responseHeaders = "response_headers"
        case requestBody = "request_body"
        case responseBody = "response_body"
    }
}

struct BrowserNetworkCaptureDidChange: AppEvent {
    static let name = Notification.Name("browserNetworkCaptureDidChange")
}

@MainActor
final class BrowserNetworkCaptureSettings {
    static let shared = BrowserNetworkCaptureSettings()
    private let defaults: UserDefaults
    private let key = "browser.networkCapture"
    private(set) var revision: UInt64 = 0

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var options: BrowserNetworkCaptureOptions {
        get {
            let values = defaults.dictionary(forKey: key) ?? [:]
            return BrowserNetworkCaptureOptions(
                requestHeaders: values["request_headers"] as? Bool ?? false,
                responseHeaders: values["response_headers"] as? Bool ?? false,
                requestBody: values["request_body"] as? Bool ?? false,
                responseBody: values["response_body"] as? Bool ?? false
            )
        }
        set {
            guard newValue != options else { return }
            revision &+= 1
            defaults.set([
                "request_headers": newValue.requestHeaders,
                "response_headers": newValue.responseHeaders,
                "request_body": newValue.requestBody,
                "response_body": newValue.responseBody
            ], forKey: key)
            // Retire payloads on every policy change; an in-flight read cannot retain an old grant.
            BrowserNetworkPayloadBuffer.shared.clear()
            NotificationCenter.default.post(BrowserNetworkCaptureDidChange())
        }
    }

    var agentConfiguration: MCPJSONValue {
        let current = options
        return .object([
            "request_headers": .bool(current.requestHeaders),
            "response_headers": .bool(current.responseHeaders),
            "request_body": .bool(current.requestBody),
            "response_body": .bool(current.responseBody),
            "scope": .string("all_in_app_browser_tabs"),
            "settings_page": .string("tools"),
            "settings_section": .string("Browser Network Capture"),
            "request_tool": .string("browser_network"),
            "request_argument": .string("request_capture"),
            "maximum_body_bytes": .number(Double(BrowserNetworkPayload.maximumBodyBytes)),
            "maximum_payload_records": .number(Double(BrowserNetworkPayloadBuffer.maximumRecords)),
            "maximum_headers": .integer(Int64(BrowserNetworkPayload.maximumHeaders)),
            "maximum_header_value_bytes": .integer(Int64(BrowserNetworkPayload.maximumHeaderValueBytes)),
            "maximum_concurrent_body_reads": .integer(4),
            "body_read_deadline_ms": .integer(1000),
            "maximum_requests_with_details": .integer(5),
            "coverage": .string("Main-frame fetch/XHR, page-visible headers and bounded text bodies. Document/resource bodies, cross-origin frames and binary/streaming bodies are excluded."),
            "sensitive_headers": .string("redacted"),
            "capture_changes": .string("Apply to future requests without reloading; existing payloads are cleared.")
        ])
    }

    var agentDescription: String {
        let current = options
        return """
            Browser network capture (all in-app tabs):
            request_headers: \(current.requestHeaders)
            response_headers: \(current.responseHeaders)
            request_body: \(current.requestBody)
            response_body: \(current.responseBody)
            Main-frame fetch/XHR only; page-visible headers and text bodies up to 8192 bytes.
            Sensitive headers are redacted. Binary/streaming and document/resource bodies are excluded.
            At most 64 payload records across the app. Changes clear payloads and affect future requests.
            Settings ▸ Tools ▸ Browser Network Capture.
            Request changed options with browser_network(request_capture: {response_body: true}); owner approval is required.
            """
    }
}

struct BrowserNetworkCaptureRequest: Codable, Sendable {
    let requestHeaders: Bool?
    let responseHeaders: Bool?
    let requestBody: Bool?
    let responseBody: Bool?

    var isEmpty: Bool {
        requestHeaders == nil && responseHeaders == nil && requestBody == nil && responseBody == nil
    }

    func applying(to current: BrowserNetworkCaptureOptions) -> BrowserNetworkCaptureOptions {
        BrowserNetworkCaptureOptions(
            requestHeaders: requestHeaders ?? current.requestHeaders,
            responseHeaders: responseHeaders ?? current.responseHeaders,
            requestBody: requestBody ?? current.requestBody,
            responseBody: responseBody ?? current.responseBody
        )
    }

    private enum CodingKeys: String, CodingKey {
        case requestHeaders = "request_headers"
        case responseHeaders = "response_headers"
        case requestBody = "request_body"
        case responseBody = "response_body"
    }
}

enum BrowserNetworkCaptureField: Int, CaseIterable {
    case requestHeaders, responseHeaders, requestBody, responseBody

    var title: String {
        switch self {
        case .requestHeaders: "Capture request headers"
        case .responseHeaders: "Capture response headers"
        case .requestBody: "Capture request bodies"
        case .responseBody: "Capture response bodies"
        }
    }
}

/// Already page-bounded values get bounded and header-redacted again at the native boundary.
struct BrowserNetworkPayload {
    static let maximumBodyBytes = 8_192
    static let maximumHeaders = 32
    static let maximumHeaderValueBytes = 512
    let requestHeaders: [String: String]?
    let responseHeaders: [String: String]?
    let requestBody: String?
    let responseBody: String?

    init(message: [String: Any], options: BrowserNetworkCaptureOptions) {
        requestHeaders = options.requestHeaders ? Self.headers(message["request_headers"]) : nil
        responseHeaders = options.responseHeaders ? Self.headers(message["response_headers"]) : nil
        requestBody = options.requestBody ? Self.body(message["request_body"]) : nil
        responseBody = options.responseBody ? Self.body(message["response_body"]) : nil
    }

    private static func body(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        return bounded(value, bytes: maximumBodyBytes)
    }

    private static func headers(_ value: Any?) -> [String: String]? {
        guard let pairs = value as? NSArray else { return nil }
        var result: [String: String] = [:]
        for index in 0..<min(pairs.count, maximumHeaders) {
            guard let pair = pairs[index] as? NSArray, pair.count == 2,
                  let rawName = pair[0] as? String, let rawValue = pair[1] as? String else { continue }
            let name = bounded(rawName, bytes: 128).lowercased()
            let sensitive = ["authorization", "cookie", "token", "secret", "api-key", "api_key", "apikey", "credential"]
                .contains { name.contains($0) }
            result[name] = sensitive ? "[redacted]" : bounded(rawValue, bytes: maximumHeaderValueBytes)
        }
        return result
    }

    private static func bounded(_ value: String, bytes: Int) -> String {
        // Reserve the replacement scalar's three bytes if the prefix splits a UTF-8 scalar.
        String(decoding: value.utf8.prefix(max(0, bytes - 3)), as: UTF8.self)
    }

    func agentText(options: BrowserNetworkCaptureOptions) -> String {
        var lines: [String] = []
        for (name, headers, enabled) in [
            ("Request headers", requestHeaders, options.requestHeaders),
            ("Response headers", responseHeaders, options.responseHeaders)
        ] where enabled {
            if let headers {
                lines.append("  \(name):")
                lines += headers.keys.sorted().map { "    \($0): \(headers[$0] ?? "")" }
            }
        }
        for (name, body, enabled) in [
            ("Request body", requestBody, options.requestBody),
            ("Response body", responseBody, options.responseBody)
        ] where enabled {
            if let body { lines.append("  \(name): \(body.isEmpty ? "(empty)" : body)") }
        }
        return lines.joined(separator: "\n")
    }
}

/// A process-wide bound, rather than 300 large bodies multiplied by every retained chat/tab.
/// Expected: 10–20 payloads. Stress/cap: 64, each at most two 8 KiB bodies and 64 small headers.
@MainActor
final class BrowserNetworkPayloadBuffer {
    static let shared = BrowserNetworkPayloadBuffer()
    static let maximumRecords = 64
    private struct Key: Hashable { let owner: UUID; let request: String }
    private var records: [Key: BrowserNetworkPayload] = [:]
    private var order: [Key] = []

    func record(_ payload: BrowserNetworkPayload, owner: UUID, request: String) {
        let key = Key(owner: owner, request: request)
        if records[key] == nil { order.append(key) }
        records[key] = payload
        if order.count > Self.maximumRecords { records.removeValue(forKey: order.removeFirst()) }
    }

    func payload(owner: UUID, request: String) -> BrowserNetworkPayload? {
        records[Key(owner: owner, request: request)]
    }

    func clear(owner: UUID? = nil) {
        guard let owner else {
            records.removeAll()
            order.removeAll()
            return
        }
        order.removeAll { key in
            guard key.owner == owner else { return false }
            records.removeValue(forKey: key)
            return true
        }
    }
}
