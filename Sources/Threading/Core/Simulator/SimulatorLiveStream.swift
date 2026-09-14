import CoreGraphics
import Foundation
import ThreadingSimulatorKit

struct SimulatorLiveFrame: @unchecked Sendable {
    let sequence: UInt64
    let image: CGImage
    /// The codec that produced this frame, or nil for the shared-memory transport, which does not
    /// encode.
    let codec: SimulatorBridgeCodec?
    let presentationTimeNanoseconds: UInt64
}

enum SimulatorLiveBackend: Equatable, Sendable {
    case direct(codec: SimulatorBridgeCodec)
    /// Frames arrive through shared memory with no codec — the lowest-latency, same-machine path.
    case sharedMemory
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
    /// The helper answered the handshake and stayed alive, but a visible stream delivered no
    /// frame for the whole liveness deadline.
    case stalled

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
        case .stalled: return "The direct Simulator helper stopped delivering frames."
        }
    }
}

protocol SimulatorLiveStreamSession: AnyObject, Sendable {
    var events: AsyncStream<SimulatorLiveStreamEvent> { get }
    func setVisible(_ visible: Bool)
    func sendInput(_ input: SimulatorBridgeInput) async throws
    /// Send an input in order without waiting for its acknowledgement. This is the low-latency
    /// path for streamed touch moves: a continuous pan is a fast stream of ordered moves, and
    /// gating each one on a round-trip ack is what made panning lag. The ordered, reliable socket
    /// guarantees delivery; a lost ack does not matter because the next move corrects the position.
    func streamInput(_ input: SimulatorBridgeInput)
    /// Read the foreground app's accessibility tree once. Read-only; returns the tree root or throws
    /// when this helper/Xcode cannot read it. See the Simulator accessibility feature draft.
    func requestAccessibilitySnapshot() async throws -> SimulatorAccessibilityElement
    func stop()
}

extension SimulatorLiveStreamSession {
    // The default keeps test doubles simple; the real client overrides with a genuine
    // fire-and-forget send.
    func streamInput(_ input: SimulatorBridgeInput) {
        Task { try? await sendInput(input) }
    }

    // Default keeps test doubles simple; the real client overrides with the wire round-trip.
    func requestAccessibilitySnapshot() async throws -> SimulatorAccessibilityElement {
        throw SimulatorLiveStreamError.helperUnavailable(
            "This Simulator session cannot read the accessibility tree."
        )
    }
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
