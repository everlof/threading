import Foundation

/// JSON belongs at the plugin edge. The panel remains the owner of configuration and capture.
@MainActor
enum DeviceLogSharedToolAdapter {
    private enum Limits {
        static let argumentBytes = 32 * 1_024
        static let maximumWait: TimeInterval = 30
        static let defaultWait: TimeInterval = 5
    }

    static func invoke(
        named name: String, argumentsJSON: String, pane: DeviceLogPaneViewController?,
        stream: String = "regular",
        completion: @escaping (String, Bool) -> Void
    ) {
        Task { @MainActor in
            let response: DeviceLogSharedToolReply
            do {
                let arguments = try await Task.detached(priority: .userInitiated) {
                    try Arguments.decode(argumentsJSON, named: name)
                }.value
                guard let pane else {
                    return await finish(.failure(
                        code: "pane_unavailable", message: "Open this session's \(stream) log panel first.",
                        state: nil, stream: stream
                    ), completion: completion)
                }
                switch name {
                case DeviceLogToolNames.state:
                    let state = arguments.refresh ? pane.refreshPanelSources() : pane.panelState()
                    response = .state(state, status: state.sourceCatalogPending ? "discovery_pending" : "ok")
                case DeviceLogToolNames.configure:
                    let state = try await pane.configurePanel(arguments.configuration, expectedRevision: arguments.expectedRevision)
                    response = .state(state)
                case DeviceLogToolNames.read:
                    let page = try await pane.readPanel(
                        cursor: arguments.cursor, limit: arguments.limit,
                        expectedRevision: arguments.expectedRevision
                    )
                    response = .page(page)
                case DeviceLogToolNames.wait:
                    let page = try await pane.waitPanel(
                        cursor: arguments.cursor, limit: arguments.limit, timeout: arguments.timeout,
                        expectedRevision: arguments.expectedRevision
                    )
                    response = .page(page)
                case DeviceLogToolNames.reveal:
                    let state = try await pane.revealPanel(
                        rowID: arguments.rowID ?? "", throughRowID: arguments.throughRowID,
                        expectedRevision: arguments.expectedRevision
                    )
                    response = .state(state)
                default:
                    response = .failure(code: "unknown_tool", message: "Unknown Device Logs panel tool.", state: pane.panelState())
                }
            } catch let error as DeviceLogPanelError {
                response = .failure(code: error.code, message: error.message, state: error.state)
            } catch {
                response = .failure(code: "invalid_arguments", message: error.localizedDescription, state: pane?.panelState(), stream: stream)
            }
            await finish(response, completion: completion)
        }
    }

    private static func finish(_ response: DeviceLogSharedToolReply, completion: (String, Bool) -> Void) async {
        let encoded = await Task.detached(priority: .userInitiated) { () -> (text: String, failed: Bool) in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(response), let text = String(data: data, encoding: .utf8) else {
                return (#"{"status":"encoding_failed","stream":null,"revision":null,"cursor":null,"count":0,"has_more":false,"state":null,"rows":[],"changed":false,"change_reason":null,"data_changed":false,"timed_out":false,"cursor_truncated":false,"output_truncated":false,"history":{"scope":"unavailable","missing":true,"dropped":0,"truncated":false},"error":{"code":"encoding_failed","message":"The bounded panel reply could not be encoded."}}"#, true)
            }
            return (text, false)
        }.value
        completion(encoded.text, encoded.failed || response.error != nil)
    }

    private struct ArgumentError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Arguments: Decodable, Sendable {
        let configuration: DeviceLogPanelConfiguration
        let expectedRevision: UInt64?
        let cursor: String?
        let limit: Int
        let timeout: TimeInterval
        let rowID: String?
        let throughRowID: String?
        let refresh: Bool

        enum CodingKeys: String, CodingKey {
            case cursor, limit, refresh
            case expectedRevision = "expected_revision", timeout = "timeout_seconds"
            case rowID = "row_id", throughRowID = "through_row_id"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            expectedRevision = try values.decodeIfPresent(UInt64.self, forKey: .expectedRevision)
            cursor = try values.decodeIfPresent(String.self, forKey: .cursor)
            limit = try values.decodeIfPresent(Int.self, forKey: .limit) ?? DeviceLogToolLimits.rowsPerAnswer
            timeout = try values.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? Limits.defaultWait
            rowID = try values.decodeIfPresent(String.self, forKey: .rowID)
            throughRowID = try values.decodeIfPresent(String.self, forKey: .throughRowID)
            refresh = try values.decodeIfPresent(Bool.self, forKey: .refresh) ?? false
            configuration = try DeviceLogPanelConfiguration(from: decoder)
        }

        static func decode(_ text: String, named name: String) throws -> Self {
            guard text.utf8.count <= Limits.argumentBytes else {
                throw ArgumentError(message: "Tool arguments exceed the 32 KiB limit.")
            }
            let data = Data(text.utf8)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ArgumentError(message: "Tool arguments must be a JSON object.")
            }
            let permitted: Set<String>
            switch name {
            case DeviceLogToolNames.state: permitted = ["refresh"]
            case DeviceLogToolNames.configure:
                permitted = ["expected_revision", "device_id", "source", "route", "bundle_id", "process", "pid",
                             "text", "text_mode", "levels", "subsystem", "category", "follow", "paused",
                             "show_context", "clear_filter", "packets"]
            case DeviceLogToolNames.read: permitted = ["expected_revision", "cursor", "limit"]
            case DeviceLogToolNames.wait: permitted = ["expected_revision", "cursor", "limit", "timeout_seconds"]
            case DeviceLogToolNames.reveal: permitted = ["expected_revision", "row_id", "through_row_id"]
            default: permitted = []
            }
            let unknown = Set(object.keys).subtracting(permitted)
            guard unknown.isEmpty else {
                throw ArgumentError(message: "Unsupported arguments: \(unknown.sorted().joined(separator: ", ")). Configure the shared panel before reading.")
            }
            let arguments = try JSONDecoder().decode(Self.self, from: data)
            guard (1...DeviceLogToolLimits.rowsPerAnswer).contains(arguments.limit) else {
                throw ArgumentError(message: "limit must be between 1 and 50.")
            }
            guard arguments.timeout.isFinite, (0...Limits.maximumWait).contains(arguments.timeout) else {
                throw ArgumentError(message: "timeout_seconds must be between 0 and 30.")
            }
            if name == DeviceLogToolNames.reveal, arguments.rowID?.isEmpty != false {
                throw ArgumentError(message: "row_id must be a stable row identity returned by read or wait.")
            }
            if arguments.throughRowID?.isEmpty == true {
                throw ArgumentError(message: "through_row_id must not be empty.")
            }
            return arguments
        }
    }
}

/// Every answer has the same continuation and loss fields, including refusals and timeouts.
private struct DeviceLogSharedToolReply: Encodable, Sendable {
    struct Failure: Encodable, Sendable { let code: String; let message: String }
    struct History: Encodable, Sendable {
        let scope: String
        let missing: Bool
        let dropped: Int
        let truncated: Bool
    }
    let status: String
    let stream: String
    let state: DeviceLogPanelState?
    let cursor: String?
    let rows: [DeviceLogPanelReadRow]
    let count: Int
    let hasMore: Bool
    let cursorTruncated: Bool
    let timedOut: Bool
    let changed: Bool
    let changeReason: String?
    let dataChanged: Bool
    let outputTruncated: Bool
    let pending: Bool
    let error: Failure?

    static func state(_ state: DeviceLogPanelState, status: String = "ok") -> Self {
        Self(status: status, stream: state.stream, state: state, cursor: nil, rows: [], count: 0, hasMore: false,
             cursorTruncated: false, timedOut: false, changed: false, changeReason: nil,
             dataChanged: false, outputTruncated: false, pending: state.sourceCatalogPending, error: nil)
    }

    static func page(_ page: DeviceLogPanelReadPage) -> Self {
        Self(status: page.changed ? "changed" : page.timedOut ? "timeout" : page.pending ? "pending" : "ok", stream: page.state.stream, state: page.state,
             cursor: page.cursor, rows: page.rows, count: page.count, hasMore: page.hasMore,
             cursorTruncated: page.cursorTruncated, timedOut: page.timedOut, changed: page.changed,
             changeReason: page.changeReason, dataChanged: page.dataChanged,
             outputTruncated: page.outputTruncated, pending: page.pending, error: nil)
    }

    static func failure(code: String, message: String, state: DeviceLogPanelState?, stream: String = "regular") -> Self {
        Self(status: code, stream: state?.stream ?? stream, state: state, cursor: nil, rows: [], count: 0, hasMore: false,
             cursorTruncated: false, timedOut: false,
             changed: ["stale_revision", "cursor_reset"].contains(code),
             changeReason: ["stale_revision", "cursor_reset"].contains(code) ? code : nil,
             dataChanged: false, outputTruncated: false, pending: false,
             error: Failure(code: code, message: message))
    }

    enum CodingKeys: String, CodingKey {
        case status, state, revision, cursor, rows, count, history, error, changed, pending
        case hasMore = "has_more", cursorTruncated = "cursor_truncated", timedOut = "timed_out"
        case stream
        case outputTruncated = "output_truncated"
        case changeReason = "change_reason", dataChanged = "data_changed"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(status, forKey: .status)
        try values.encode(stream, forKey: .stream)
        try values.encode(state, forKey: .state)
        try values.encode(state?.revision, forKey: .revision)
        try values.encode(cursor, forKey: .cursor)
        try values.encode(rows, forKey: .rows)
        try values.encode(count, forKey: .count)
        try values.encode(hasMore, forKey: .hasMore)
        try values.encode(cursorTruncated, forKey: .cursorTruncated)
        try values.encode(timedOut, forKey: .timedOut)
        try values.encode(changed, forKey: .changed)
        try values.encode(changeReason, forKey: .changeReason)
        try values.encode(dataChanged, forKey: .dataChanged)
        try values.encode(outputTruncated, forKey: .outputTruncated)
        try values.encode(pending, forKey: .pending)
        let dropped = (state?.ringDropped ?? 0) + (state?.handoffDropped ?? 0)
        try values.encode(History(
            scope: state?.historyScope ?? "unavailable",
            missing: state == nil || state?.historyHasGap == true || dropped > 0 || cursorTruncated,
            dropped: dropped, truncated: cursorTruncated || outputTruncated
        ), forKey: .history)
        try values.encodeIfPresent(error, forKey: .error)
    }
}
