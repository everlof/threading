import Foundation

enum MainThreadStallStorage {
    static let directoryName = "Stalls"
    static let fileExtension = "json"
    static let maximumFilesRead = 24
    static let maximumFileBytes = 256 * 1024
}

/// The small, kill-safe half of a watchdog capture.
///
/// A Chrome trace is still exported beside this record, and MetricKit may later provide a system
/// hang stack. This file exists because either can arrive too late when a user force-quits a
/// frozen app. It is written synchronously on the watchdog's utility queue at detection time and
/// contains only the recorder's bounded semantic span context — never a sampled stack.
struct MainThreadStallIncident: Codable, Equatable, Sendable {
    let id: UUID
    let detectedAt: Date
    let thresholdMilliseconds: Double
    let mainThreadID: UInt64
    let activeOperations: [PerformanceActiveSpanSnapshot]
    var completedAt: Date?
    var durationMilliseconds: Double?

    var isIncomplete: Bool { completedAt == nil }
    var observedDurationMilliseconds: Double {
        durationMilliseconds ?? thresholdMilliseconds
    }
}

enum MainThreadStallIncidentReading: Equatable, Sendable {
    case noDirectory
    case empty
    case unreadable(files: Int)
    case read(MainThreadStallIncidentSummary)
}

struct MainThreadStallIncidentSummary: Equatable, Sendable {
    let incidentCount: Int
    let incompleteCount: Int
    let unreadableCount: Int
    let skippedCount: Int
    let longestObservedMilliseconds: Int
    let operationNames: [String]
}

final class MainThreadStallIncidentStore: @unchecked Sendable {
    static let shared = MainThreadStallIncidentStore()

    let directory: URL
    private let reportLimit: Int
    private let lock = NSLock()

    init(directory: URL? = nil, reportLimit: Int = 20) {
        self.directory = directory ?? AppDataLocations.supportDirectory
            .appendingPathComponent(
                MetricKitStorage.performanceDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(MainThreadStallStorage.directoryName, isDirectory: true)
        self.reportLimit = reportLimit
    }

    /// Writes before the larger trace export is requested, so force-quitting a live hang still
    /// leaves its start and its active operation names behind.
    @discardableResult
    func begin(
        thresholdMilliseconds: Double,
        mainThreadID: UInt64,
        activeOperations: [PerformanceActiveSpanSnapshot],
        detectedAt: Date = Date()
    ) -> UUID? {
        lock.lock()
        defer { lock.unlock() }

        let incident = MainThreadStallIncident(
            id: UUID(),
            detectedAt: detectedAt,
            thresholdMilliseconds: thresholdMilliseconds,
            mainThreadID: mainThreadID,
            activeOperations: Array(activeOperations.prefix(16)),
            completedAt: nil,
            durationMilliseconds: nil
        )
        do {
            try write(incident)
            prune()
            return incident.id
        } catch {
            ThreadingLogger.performance.error(
                "Main-thread stall incident write failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return nil
        }
    }

    func complete(id: UUID, durationMilliseconds: Double, completedAt: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        let url = self.url(for: id)
        do {
            let data = try BoundedFileReader.read(
                url,
                maximumBytes: MainThreadStallStorage.maximumFileBytes
            )
            var incident = try JSONDecoder().decode(MainThreadStallIncident.self, from: data)
            incident.completedAt = completedAt
            incident.durationMilliseconds = max(durationMilliseconds, 0)
            try write(incident)
        } catch {
            ThreadingLogger.performance.error(
                "Main-thread stall incident completion failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
    }

    func read() -> MainThreadStallIncidentReading {
        lock.lock()
        defer { lock.unlock() }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .noDirectory
        }

        let files: [URL]
        do {
            files = try incidentFiles()
        } catch {
            return .unreadable(files: 0)
        }
        guard !files.isEmpty else { return .empty }

        let considered = Array(files.suffix(MainThreadStallStorage.maximumFilesRead))
        var incidents: [MainThreadStallIncident] = []
        var unreadable = 0
        for url in considered {
            do {
                let data = try BoundedFileReader.read(
                    url,
                    maximumBytes: MainThreadStallStorage.maximumFileBytes
                )
                incidents.append(
                    try JSONDecoder().decode(MainThreadStallIncident.self, from: data)
                )
            } catch {
                unreadable += 1
            }
        }
        guard !incidents.isEmpty else { return .unreadable(files: files.count) }

        let names = incidents
            .sorted { $0.detectedAt > $1.detectedAt }
            .flatMap(\.activeOperations)
            .map(\.name)
            .filter(Self.isShareSafeOperationName)
            .reduce(into: [String]()) { names, name in
                if names.count < 8, !names.contains(name) { names.append(name) }
            }
        let longest = incidents.map(\.observedDurationMilliseconds).max() ?? 0
        let boundedLongest: Int
        if !longest.isFinite || longest >= Double(Int.max) {
            boundedLongest = Int.max
        } else {
            boundedLongest = Int(max(longest, 0))
        }
        return .read(MainThreadStallIncidentSummary(
            incidentCount: incidents.count,
            incompleteCount: incidents.filter(\.isIncomplete).count,
            unreadableCount: unreadable,
            skippedCount: files.count - considered.count,
            longestObservedMilliseconds: boundedLongest,
            operationNames: names
        ))
    }

    private func write(_ incident: MainThreadStallIncident) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(incident).write(to: url(for: incident.id), options: .atomic)
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(
            "stall-\(id.uuidString.lowercased()).\(MainThreadStallStorage.fileExtension)"
        )
    }

    private func incidentFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == MainThreadStallStorage.fileExtension }
        .sorted {
            let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return (left ?? .distantPast) < (right ?? .distantPast)
        }
    }

    private func prune() {
        guard let files = try? incidentFiles() else { return }
        for url in files.dropLast(max(reportLimit, 1)) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Span names are compile-time schema today. Re-checking their alphabet at the sharing
    /// boundary keeps that true even if a future recorder accepts a dynamic name.
    private static func isShareSafeOperationName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 80 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }
}
