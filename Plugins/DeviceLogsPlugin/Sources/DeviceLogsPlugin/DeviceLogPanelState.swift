import Foundation

/// The panel's one filter, consumed by the table projection and by bounded agent reads.
public struct DeviceLogPanelFilter: Codable, Equatable, Sendable {
    public enum TextMode: String, Codable, Sendable { case literal, regex }
    public var text = ""
    public var textMode = TextMode.literal
    public var minimumSeverity = 1
    public var levels: [String] = []
    public var process: String?
    public var bundleID: String?
    public var pid: Int?
    public var subsystem: String?
    public var category: String?
    public var showingContext = false

    enum CodingKeys: String, CodingKey {
        case text, levels, process, pid, subsystem, category
        case textMode = "text_mode", minimumSeverity = "minimum_severity"
        case bundleID = "bundle_id", showingContext = "show_context"
    }
}

/// A patch. Omitted fields keep their value; an empty string clears an optional text field.
public struct DeviceLogPanelConfiguration: Codable, Sendable {
    public var packets: String?
    public var deviceID: String?
    public var source: String?
    public var route: String?
    public var bundleID: String?
    public var process: String?
    public var pid: Int?
    public var text: String?
    public var textMode: DeviceLogPanelFilter.TextMode?
    public var levels: [String]?
    public var subsystem: String?
    public var category: String?
    public var follow: Bool?
    public var paused: Bool?
    public var showContext: Bool?
    public var clearFilter: Bool?

    public init() {}
    enum CodingKeys: String, CodingKey {
        case source, route, process, pid, text, levels, subsystem, category, follow, paused, packets
        case deviceID = "device_id", bundleID = "bundle_id", textMode = "text_mode"
        case showContext = "show_context", clearFilter = "clear_filter"
    }
}

public struct DeviceLogPanelDevice: Codable, Sendable {
    public let id: String
    public let name: String
    public let simulator: Bool
}

public struct DeviceLogPanelProcess: Codable, Equatable, Sendable {
    public let process: String
    public let bundleID: String?
    public let pid: Int?
    enum CodingKeys: String, CodingKey {
        case process, pid
        case bundleID = "bundle_id"
    }
}

public struct DeviceLogPanelSource: Codable, Sendable {
    public let deviceID: String
    public let title: String
    public let bundleID: String?
    public let process: String?
    public let pid: Int?
    public let routes: [String]
    public let catalogWarning: String?
    enum CodingKeys: String, CodingKey {
        case title, process, pid, routes
        case deviceID = "device_id", bundleID = "bundle_id", catalogWarning = "catalog_warning"
    }
}

public struct DeviceLogPanelState: Codable, Sendable {
    public let stream: String
    public let bluetooth: DeviceLogBluetoothState?
    public let devices: [DeviceLogPanelDevice]
    public let processes: [DeviceLogPanelProcess]
    public let sources: [DeviceLogPanelSource]
    public let observedSources: [String]
    public let sourceAvailabilityDetail: String?
    public let selectedPID: Int?
    public let revision: UInt64
    public let dataRevision: UInt64
    public let deviceID: String?
    public let deviceName: String?
    public let source: String?
    public let sourceKind: String
    public let route: String
    public let filter: DeviceLogPanelFilter
    public let captureMinimumSeverity: Int
    public let projectionPending: Bool
    public let projectionLimited: Bool
    public let readScope: String
    public let filterEvaluationLimits: String?
    public let following: Bool
    public let paused: Bool
    public let captureState: String
    public let readerStatus: String
    public let retainedCount: Int
    public let ringCapacity: Int
    public let retainedBytes: Int
    public let ringByteCapacity: Int
    public let ringDropped: Int
    public let handoffDropped: Int
    public let historyScope: String
    public let historyHasGap: Bool
    public let oldestRowID: String?
    public let newestRowID: String?
    public let sourceGeneration: Int
    public let sourceCatalogPending: Bool
    public let sourceCatalogUpdatedAt: Date?
    public let availableSources: [String]
    public let unavailableSources: [String]

    enum CodingKeys: String, CodingKey {
        case revision, filter, following, paused, route, source, stream, devices, processes, sources, bluetooth
        case observedSources = "observed_sources", sourceAvailabilityDetail = "source_availability_detail"
        case selectedPID = "selected_pid", captureMinimumSeverity = "capture_minimum_severity"
        case readScope = "read_scope", filterEvaluationLimits = "filter_evaluation_limits"
        case projectionPending = "projection_pending", projectionLimited = "projection_limited"
        case dataRevision = "data_revision", deviceID = "device_id", deviceName = "device_name"
        case sourceKind = "source_kind", captureState = "capture_state", readerStatus = "reader_status"
        case retainedCount = "retained_count", ringCapacity = "ring_capacity", ringDropped = "ring_dropped"
        case retainedBytes = "retained_bytes", ringByteCapacity = "ring_byte_capacity"
        case handoffDropped = "handoff_dropped", historyScope = "history_scope", historyHasGap = "history_has_gap"
        case oldestRowID = "oldest_row_id", newestRowID = "newest_row_id", sourceGeneration = "source_generation"
        case sourceCatalogPending = "source_catalog_pending", sourceCatalogUpdatedAt = "source_catalog_updated_at"
        case availableSources = "available_sources", unavailableSources = "unavailable_sources"
    }
}

public struct DeviceLogPanelReadRow: Codable, Sendable {
    public let id: String
    public let time: String
    public let timestamp: Date?
    public let level: String
    public let process: String
    public let bundleID: String?
    public let pid: Int?
    public let subsystem: String?
    public let category: String?
    public let source: String
    public let message: String
    public let rawLine: String
    public let deviceID: String?
    public let truncated: Bool
    public let isMatch: Bool

    init(_ row: DeviceLogRow, isMatch: Bool = true) {
        self.isMatch = isMatch
        id = row.id; time = row.time; timestamp = row.timestamp; level = row.level
        process = row.process; bundleID = row.bundleID; pid = row.pid
        subsystem = row.subsystem; category = row.category; source = row.source.rawValue
        message = Self.bounded(row.message); rawLine = Self.bounded(row.rawLine)
        deviceID = row.deviceID
        truncated = message.utf8.count < row.message.utf8.count || rawLine.utf8.count < row.rawLine.utf8.count
    }
    private static func bounded(_ value: String) -> String {
        guard value.utf8.count > 8_192 else { return value }
        return String(decoding: value.utf8.prefix(8_192), as: UTF8.self)
    }
    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case id, time, timestamp, level, process, pid, subsystem, category, source, message, truncated
        case isMatch = "is_match"
        case bundleID = "bundle_id", rawLine = "raw_line"
    }
}

public struct DeviceLogPanelReadPage: Codable, Sendable {
    public let state: DeviceLogPanelState
    public let rows: [DeviceLogPanelReadRow]
    public let cursor: String
    public let count: Int
    public let hasMore: Bool
    public let cursorTruncated: Bool
    public let timedOut: Bool
    public let changed: Bool
    public let outputTruncated: Bool
    public let changeReason: String?
    public let dataChanged: Bool
    public let pending: Bool

    enum CodingKeys: String, CodingKey {
        case state, rows, cursor, count, changed, pending
        case outputTruncated = "output_truncated", changeReason = "change_reason", dataChanged = "data_changed"
        case hasMore = "has_more", cursorTruncated = "cursor_truncated", timedOut = "timed_out"
    }
}

public struct DeviceLogPanelError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let state: DeviceLogPanelState
    public var errorDescription: String? { message }
}
