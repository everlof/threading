import Foundation
@preconcurrency import MetricKit

/// Persists Apple's delayed, production-collected performance and diagnostic payloads.
///
/// MetricKit normally delivers about once per day and makes no delivery guarantee. These files
/// complement, rather than replace, immediate signposts and stall traces: they capture hangs,
/// crashes, launch time, CPU, memory, disk, and responsiveness seen on real machines without an
/// interactive Instruments session.
final class MetricKitDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    static let shared = MetricKitDiagnostics()

    let directory: URL

    private let queue = DispatchQueue(
        label: "codes.threading.performance.metrickit",
        qos: .utility
    )
    private let reportLimit: Int

    /// Guards subscription because launch and termination are main-thread calls while tests may
    /// exercise lifecycle from another queue.
    private let lock = NSLock()
    private var isSubscribed = false

    /// MetricKit payload objects are immutable snapshots, but the Objective-C framework does not
    /// annotate them `Sendable`. This wrapper documents the one handoff to our serial writer.
    private struct PastPayloads: @unchecked Sendable {
        let metrics: [MXMetricPayload]
        let diagnostics: [MXDiagnosticPayload]
    }

    /// The same immutable framework objects when MetricKit calls its subscriber.
    private struct MetricPayloads: @unchecked Sendable {
        let values: [MXMetricPayload]
    }

    private struct DiagnosticPayloads: @unchecked Sendable {
        let values: [MXDiagnosticPayload]
    }

    /// `~/Library/Application Support/Threading/Performance/MetricKit`.
    ///
    /// Named on the type because `MetricKitDiagnosticReader` reads the same directory from the
    /// other side of the launch, and a path spelled out twice is a path that eventually differs.
    static var defaultDirectory: URL {
        AppDataLocations.supportDirectory
            .appendingPathComponent(
                MetricKitStorage.performanceDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(MetricKitStorage.rootDirectoryName, isDirectory: true)
    }

    init(directory: URL? = nil, reportLimit: Int = 20) {
        self.directory = directory ?? Self.defaultDirectory
        self.reportLimit = reportLimit
    }

    func start() {
        lock.lock()
        guard !isSubscribed else {
            lock.unlock()
            return
        }
        isSubscribed = true
        lock.unlock()

        let manager = MXMetricManager.shared
        manager.add(self)

        let payloads = PastPayloads(
            metrics: manager.pastPayloads,
            diagnostics: manager.pastDiagnosticPayloads
        )
        queue.async { [weak self] in
            self?.persist(metricPayloads: payloads.metrics)
            self?.persist(diagnosticPayloads: payloads.diagnostics)
        }
    }

    func stop() {
        lock.lock()
        guard isSubscribed else {
            lock.unlock()
            return
        }
        isSubscribed = false
        lock.unlock()

        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let payloads = MetricPayloads(values: payloads)
        queue.async { [weak self] in
            self?.persist(metricPayloads: payloads.values)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let payloads = DiagnosticPayloads(values: payloads)
        queue.async { [weak self] in
            self?.persist(diagnosticPayloads: payloads.values)
        }
    }

    private func persist(metricPayloads payloads: [MXMetricPayload]) {
        var written = 0
        for payload in payloads {
            if write(
                payload.jsonRepresentation(),
                kind: MetricKitStorage.metricsDirectoryName,
                beganAt: payload.timeStampBegin,
                endedAt: payload.timeStampEnd
            ) {
                written += 1
            }
        }
        if !payloads.isEmpty {
            ThreadingLogger.performance.info(
                "MetricKit payload batch kind=metrics received=\(payloads.count, privacy: .public) persisted=\(written, privacy: .public)"
            )
        }
        prune(kind: MetricKitStorage.metricsDirectoryName)
    }

    private func persist(diagnosticPayloads payloads: [MXDiagnosticPayload]) {
        var written = 0
        for payload in payloads {
            if write(
                payload.jsonRepresentation(),
                kind: MetricKitStorage.diagnosticsDirectoryName,
                beganAt: payload.timeStampBegin,
                endedAt: payload.timeStampEnd
            ) {
                written += 1
            }
        }
        if !payloads.isEmpty {
            ThreadingLogger.performance.info(
                "MetricKit payload batch kind=diagnostics received=\(payloads.count, privacy: .public) persisted=\(written, privacy: .public)"
            )
        }
        prune(kind: MetricKitStorage.diagnosticsDirectoryName)
    }

    @discardableResult
    private func write(_ data: Data, kind: String, beganAt: Date, endedAt: Date) -> Bool {
        let kindDirectory = directory.appendingPathComponent(kind, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: kindDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            ThreadingLogger.performance.error(
                "MetricKit \(kind, privacy: .public) directory creation failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return false
        }

        let beginning = Int64(beganAt.timeIntervalSince1970)
        let ending = Int64(endedAt.timeIntervalSince1970)
        let url = kindDirectory.appendingPathComponent(
            "\(beginning)-\(ending).\(MetricKitStorage.payloadExtension)"
        )
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }

        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            ThreadingLogger.performance.error(
                "MetricKit \(kind, privacy: .public) write failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return false
        }
    }

    private func prune(kind: String) {
        let kindDirectory = directory.appendingPathComponent(kind, isDirectory: true)
        guard FileManager.default.fileExists(atPath: kindDirectory.path) else { return }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: kindDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == MetricKitStorage.payloadExtension }
        } catch {
            ThreadingLogger.performance.warning(
                "MetricKit \(kind, privacy: .public) retention scan failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return
        }

        for url in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            .dropFirst(max(reportLimit, 1)) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                ThreadingLogger.performance.warning(
                    "MetricKit \(kind, privacy: .public) retention deletion failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
    }
}
