/// The complete backpressure state for a live Simulator stream.
///
/// One frame may be on the wire awaiting acknowledgement and one latest frame may wait behind
/// it. Every newer offer replaces that waiter. There is no queue whose memory or latency can grow
/// with the device's frame rate.
public struct SimulatorLatestFrameWindow<Frame> {
    public enum Offer {
        case send(Frame)
        case held(replaced: Bool)
    }

    private var outstandingSequence: UInt64?
    private var pending: (sequence: UInt64, frame: Frame)?

    public init() {}

    public var hasOutstandingFrame: Bool { outstandingSequence != nil }
    public var pendingFrameCount: Int { pending == nil ? 0 : 1 }

    public mutating func offer(_ frame: Frame, sequence: UInt64) -> Offer {
        guard outstandingSequence != nil else {
            outstandingSequence = sequence
            return .send(frame)
        }
        let replaced = pending != nil
        pending = (sequence, frame)
        return .held(replaced: replaced)
    }

    public mutating func acknowledge(sequence: UInt64) -> Frame? {
        guard sequence == outstandingSequence else { return nil }
        guard let pending else {
            outstandingSequence = nil
            return nil
        }
        self.pending = nil
        outstandingSequence = pending.sequence
        return pending.frame
    }

    public mutating func clear() {
        outstandingSequence = nil
        pending = nil
    }
}
