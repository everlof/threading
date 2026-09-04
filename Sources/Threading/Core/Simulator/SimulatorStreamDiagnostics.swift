import Foundation
import ThreadingSimulatorKit

/// Content-free live-stream facts for logs and user-exported support reports.
final class SimulatorStreamDiagnostics: @unchecked Sendable {
    static let shared = SimulatorStreamDiagnostics()

    private struct Session {
        let codec: SimulatorBridgeCodec
        var statistics: SimulatorBridgeStatistics
    }

    private let lock = NSLock()
    private var sessions: [UUID: Session] = [:]
    private var starts: UInt64 = 0
    private var h264Starts: UInt64 = 0
    private var jpegStarts: UInt64 = 0
    private var fallbackCount: UInt64 = 0
    private var completedFrames: UInt64 = 0
    private var completedReplacements: UInt64 = 0
    private var lastFailure = "none"

    func started(id: UUID, codec: SimulatorBridgeCodec) {
        lock.lock()
        starts += 1
        if codec == .h264 { h264Starts += 1 } else { jpegStarts += 1 }
        sessions[id] = Session(codec: codec, statistics: Self.emptyStatistics)
        lock.unlock()
    }

    func update(id: UUID, statistics: SimulatorBridgeStatistics) {
        lock.lock()
        if var session = sessions[id] {
            session.statistics = statistics
            sessions[id] = session
        }
        lock.unlock()
    }

    func ended(id: UUID) {
        lock.lock()
        if let session = sessions.removeValue(forKey: id) {
            completedFrames += session.statistics.sentFrames
            completedReplacements += session.statistics.replacedFrames
        }
        lock.unlock()
    }

    func recordedFallback() {
        lock.lock()
        fallbackCount += 1
        lock.unlock()
    }

    func recordedFailure(_ error: SimulatorLiveStreamError) {
        lock.lock()
        lastFailure = Self.token(for: error)
        lock.unlock()
    }

    var reportToken: String {
        lock.lock()
        defer { lock.unlock() }
        let liveFrames = sessions.values.reduce(UInt64(0)) { $0 + $1.statistics.sentFrames }
        let liveReplacements = sessions.values.reduce(UInt64(0)) {
            $0 + $1.statistics.replacedFrames
        }
        return [
            "active=\(sessions.count)",
            "limit=\(SimulatorStreamBudget.defaultMaximum)",
            "starts=\(starts)",
            "h264=\(h264Starts)",
            "jpeg=\(jpegStarts)",
            "fallback=\(fallbackCount)",
            "frames=\(completedFrames + liveFrames)",
            "replaced=\(completedReplacements + liveReplacements)",
            "last=\(lastFailure)"
        ].joined(separator: " ")
    }

    private static let emptyStatistics = SimulatorBridgeStatistics(
        capturedFrames: 0,
        sentFrames: 0,
        replacedFrames: 0,
        encodedBytes: 0
    )

    private static func token(for error: SimulatorLiveStreamError) -> String {
        switch error {
        case .helperUnavailable: return "helper-unavailable"
        case .signatureInvalid: return "signature-invalid"
        case .streamLimit: return "stream-limit"
        case .handshakeTimedOut: return "handshake-timeout"
        case .refused(let refusal, _): return "refused-\(refusal.rawValue)"
        case .disconnected: return "disconnected"
        case .invalidFrame: return "invalid-frame"
        case .inputTimedOut: return "input-timeout"
        case .stalled: return "stalled"
        }
    }
}
