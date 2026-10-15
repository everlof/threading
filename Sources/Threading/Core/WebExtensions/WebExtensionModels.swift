import Foundation

struct WebExtensionRequest: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case inspect, start, reload, stop, events, clear, scaffold, setup, test, source, debug, popup, options
        case packageSafari = "package-safari"
    }
    var action: Action
    var target: String?
    var after: Int?
    var limit: Int?
    var query: String?
    var event: Int?
    var headless: Bool?
}

struct WebExtensionTarget: Decodable, Sendable, Equatable {
    let id: String
    let browser: String
    let source: String
    let build: [String]?
}

struct WebExtensionRun: Decodable, Sendable, Equatable {
    let target: String
    let browser: String
    let build: String
    let status: String
    let directory: String
    let instructions: String?
    var contexts: [String]? = nil
    var browserVersion: String? = nil
    private enum CodingKeys: String, CodingKey {
        case target, browser, build, status, directory, instructions, contexts
        case browserVersion = "browser_version"
    }
}

struct WebExtensionEvent: Decodable, Sendable, Equatable {
    let id: Int
    let target: String
    let level: String
    let kind: String
    let message: String
    let stack: String
    let context: String
    let contextID: String
    let build: String
    let url: String
    let received: Double
    let tab: Int?
    let frame: Int?

    var summary: String { "\(level.uppercased()) · \(target) · \(context) · \(kind)" }
    var detail: String {
        [summary, "\(Date(timeIntervalSince1970: received).ISO8601Format()) · Event \(id)", "Build: \(build) · Context: \(contextID)",
         "Tab: \(tab.map(String.init) ?? "—") · Frame: \(frame.map(String.init) ?? "—")",
         url, message, stack].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

struct WebExtensionPayload: Decodable, Sendable {
    var targets: [WebExtensionTarget]?
    var runs: [WebExtensionRun]?
    var events: [WebExtensionEvent]?
    var cursor: Int?
    var oldest: Int?
    var retained: Int?
    var dropped: Int?
    var evicted: Int?
    var instructions: String?
    var project: String?
    var path: String?
    var line: Int?
}

enum WebExtensionReply: Sendable {
    case success(WebExtensionPayload, text: String)
    case failure(String)

    var toolResult: MCPToolResult {
        switch self {
        case .success(_, let text): return .success(text)
        case .failure(let message): return .failure(message)
        }
    }
}

struct WebExtensionDidChange: AppEvent {
    static let name = Notification.Name("WebExtensionDidChange")
    let sessionID: SessionID
}
