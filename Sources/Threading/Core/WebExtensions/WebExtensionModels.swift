import Foundation

enum WebExtensionDefaults {
    /// Chats with a live helper at once; each helper owns up to three running browsers.
    static let maximumWorkers = 4
    /// Swift-side deadlines sit above the helper's own (150 s and 330 s) so the helper can name
    /// the step that overran before the transport gives up on it.
    static let operationTimeout: TimeInterval = 180
    static let setupTimeout: TimeInterval = 360
    /// A read behind another read waits this long; it never takes the one queued-command slot.
    static let readWaitTimeout: TimeInterval = 2
    static let queuePollNanoseconds: UInt64 = 20_000_000
    static let maximumRequestBytes = 64 * 1_024
    static let maximumResponseBytes = 4 * 1_024 * 1_024
    static let eventPageLimit = 200
    /// Compact MCP lines keep a default page within an agent's tool-output budget.
    static let toolMessageCharacters = 240

    static func timeout(for action: WebExtensionRequest.Action) -> TimeInterval {
        action == .setup ? setupTimeout : operationTimeout
    }
}

struct WebExtensionRequest: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case inspect, start, reload, stop, events, clear, scaffold, setup, test, source, debug, popup, options
        case packageSafari = "package-safari"

        /// Reads may run while the panel polls; everything else is a command the user or an
        /// agent is waiting on.
        var isRead: Bool { self == .events || self == .inspect }
    }
    var action: Action
    var target: String?
    var after: Int?
    var limit: Int?
    var query: String?
    var event: Int?
    var headless: Bool?
    /// The worker generation an event ID was read from; a mismatch is refused, not reinterpreted.
    var generation: String?
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

    /// The first stack frame in the extension's own code, as `path:line:column`. Frames in the
    /// injected `threading_` development files are the instrumentation, not the caller.
    var sourceFrame: String? {
        stack.split(whereSeparator: \.isNewline).lazy.compactMap { line -> String? in
            guard let scheme = line.range(of: "-extension://") else { return nil }
            let afterHost = line[scheme.upperBound...].drop { $0 != "/" }.dropFirst()
            let location = afterHost.prefix { !$0.isWhitespace && $0 != ")" }
            let file = location.split(separator: "/").last.map(String.init) ?? ""
            return file.isEmpty || file.hasPrefix("threading_") ? nil : String(location)
        }.first
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
    var generation: String?
}

enum WebExtensionReply: Sendable {
    case success(WebExtensionPayload, text: String)
    case failure(String)

    /// What an agent reads. An event page is one line per event, because a full record carries
    /// up to 12 KiB of message and stack; a single event by ID is the full record.
    func toolResult(for request: WebExtensionRequest) -> MCPToolResult {
        switch self {
        case .failure(let message):
            return .failure(message)
        case .success(let payload, let text):
            guard request.action == .events, let events = payload.events else { return .success(text) }
            if request.event != nil, let event = events.first {
                return .success(event.detail)
            }
            return .success(WebExtensionToolText.page(payload, events: events))
        }
    }
}

enum WebExtensionToolText {
    static func page(_ payload: WebExtensionPayload, events: [WebExtensionEvent]) -> String {
        var lines = [
            "Worker \(payload.generation ?? "unknown") · cursor \(payload.cursor ?? 0) (pass as after) · "
                + "\(payload.retained ?? events.count) retained · \(payload.dropped ?? 0) dropped · \(payload.evicted ?? 0) evicted"
        ]
        for run in payload.runs ?? [] {
            let contexts = (run.contexts ?? []).joined(separator: ", ")
            lines.append("Run \(run.target): \(run.status) · \(run.browserVersion ?? run.browser) · build \(run.build)"
                + (contexts.isEmpty ? "" : " · \(contexts)"))
        }
        lines += events.map(line)
        if events.isEmpty { lines.append("No new events.") }
        lines.append("events with event:<id> returns one full record; source with event:<id> opens its checkout file.")
        return lines.joined(separator: "\n")
    }

    private static func line(_ event: WebExtensionEvent) -> String {
        let firstLine = event.message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let message = firstLine.count > WebExtensionDefaults.toolMessageCharacters
            ? String(firstLine.prefix(WebExtensionDefaults.toolMessageCharacters)) + "…" : firstLine
        let tab = event.tab.map { " tab \($0)" } ?? ""
        let frame = event.sourceFrame.map { " — \($0)" } ?? ""
        return "#\(event.id) \(event.level.uppercased()) \(event.target)/\(event.context)\(tab) \(event.kind): \(message)\(frame)"
    }
}

struct WebExtensionDidChange: AppEvent {
    static let name = Notification.Name("WebExtensionDidChange")
    let sessionID: SessionID
}
