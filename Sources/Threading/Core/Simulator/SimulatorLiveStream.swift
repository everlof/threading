import CoreGraphics
import Foundation
import ThreadingSimulatorKit

struct SimulatorLiveFrame: @unchecked Sendable {
    let sequence: UInt64
    let image: CGImage
    let codec: SimulatorBridgeCodec
    let presentationTimeNanoseconds: UInt64
}

enum SimulatorLiveBackend: Equatable, Sendable {
    case direct(codec: SimulatorBridgeCodec)
    case screenshotFallback(reason: String)
}

enum SimulatorLiveStreamEvent: Sendable {
    case ready(
        backend: SimulatorLiveBackend,
        capabilities: SimulatorBridgeCapabilities,
        coreSimulatorVersion: String?,
        simulatorKitVersion: String?
    )
    case frame(SimulatorLiveFrame)
    case statistics(SimulatorBridgeStatistics)
    case failed(String)
    case ended
}

enum SimulatorLiveStreamError: LocalizedError, Equatable, Sendable {
    case helperUnavailable(String)
    case signatureInvalid(String)
    case streamLimit(maximum: Int)
    case handshakeTimedOut
    case refused(SimulatorBridgeRefusal, String)
    case disconnected
    case invalidFrame
    case inputTimedOut

    var errorDescription: String? {
        switch self {
        case .helperUnavailable(let detail), .signatureInvalid(let detail): return detail
        case .streamLimit(let maximum):
            return "Threading already has \(maximum) live Simulator streams. Close one to start another."
        case .handshakeTimedOut: return "The direct Simulator helper did not finish connecting."
        case .refused(_, let detail): return detail
        case .disconnected: return "The direct Simulator helper disconnected."
        case .invalidFrame: return "The direct Simulator helper returned an invalid frame."
        case .inputTimedOut: return "The Simulator did not acknowledge the input request."
        }
    }
}

protocol SimulatorLiveStreamSession: AnyObject, Sendable {
    var events: AsyncStream<SimulatorLiveStreamEvent> { get }
    func setVisible(_ visible: Bool)
    func sendInput(_ input: SimulatorBridgeInput) async throws
    func stop()
}

protocol SimulatorLiveStreamCoordinating: Sendable {
    func openStream(for deviceID: SimulatorDeviceID) async throws -> any SimulatorLiveStreamSession
}

/// A small value-type admission controller for the app-wide stream budget.
///
/// It is separate from helper launch so the limit can be proven without creating processes, and
/// so every error path releases the exact reservation it acquired.
struct SimulatorStreamBudget {
    static let defaultMaximum = 4

    let maximum: Int
    private(set) var active: Set<UUID> = []

    init(maximum: Int = defaultMaximum) {
        precondition(maximum > 0)
        self.maximum = maximum
    }

    var hasCapacity: Bool { active.count < maximum }
    var activeCount: Int { active.count }

    mutating func reserve() throws -> UUID {
        guard hasCapacity else {
            throw SimulatorLiveStreamError.streamLimit(maximum: maximum)
        }
        let token = UUID()
        active.insert(token)
        return token
    }

    mutating func release(_ token: UUID) {
        active.remove(token)
    }
}
