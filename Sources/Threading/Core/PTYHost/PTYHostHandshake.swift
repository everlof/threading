import Foundation
import ThreadingPTYHostKit

/// Retains the complete, ordered batch around hello until the host admits the peer. Transport,
/// diagnostics and retirement effects are injected; no callback escapes this value's caller.
struct PTYHostHandshake {
    enum Delivery: Sendable {
        case control(PTYHostFrame)
        case output(Data, standardError: Bool)
    }

    struct Completion {
        let peer: PTYHostHello
        let pending: [Delivery]
    }

    static let maximumBufferedBytes = 4 * PTYHostFramingDefaults.maximumPayloadBytes
    private let maximumBytes: Int
    private var pending: [Delivery] = []
    private var bufferedBytes = 0
    private var completed = false

    init(maximumBytes: Int = Self.maximumBufferedBytes) {
        precondition(maximumBytes >= 0)
        self.maximumBytes = maximumBytes
    }

    mutating func accept(
        _ frames: [PTYHostWireFrame],
        decodeControl: (Data) -> PTYHostFrame?,
        admit: (PTYHostHello, PTYHostCompatibility) throws -> Void,
        unexpectedInput: () -> Void = {}
    ) throws -> Completion? {
        guard !completed else { throw PTYHostClientError.notReady }
        var peer: PTYHostHello?
        for wire in frames {
            if wire.kind == .input { unexpectedInput(); continue }
            guard let delivery = Self.delivery(wire, decodeControl: decodeControl) else { continue }
            if case .control(let control) = delivery {
                switch control {
                case .hello(let hello):
                    guard peer == nil else { continue }
                    try admit(hello, PTYHostCompatibility.evaluate(peer: hello))
                    peer = hello
                    continue
                case .helloRefused(let refusal):
                    guard peer == nil else { continue }
                    throw PTYHostClientError.incompatible(Self.flipped(refusal.compatibility))
                default: break
                }
            }
            // Include the header: even a flood of empty output frames has a finite budget.
            let cost = wire.payload.count + PTYHostFramingDefaults.headerBytes
            guard cost <= maximumBytes - bufferedBytes else {
                throw PTYHostClientError.handshakeBufferOverflow(bufferedBytes: bufferedBytes + cost)
            }
            bufferedBytes += cost
            pending.append(delivery)
        }
        guard let peer else { return nil }
        completed = true
        let result = Completion(peer: peer, pending: pending)
        pending = []
        bufferedBytes = 0
        return result
    }

    static func delivery(_ wire: PTYHostWireFrame, decodeControl: (Data) -> PTYHostFrame?) -> Delivery? {
        switch wire.kind {
        case .control: return decodeControl(wire.payload).map(Delivery.control)
        case .output:
            return .output(wire.payload, standardError: wire.flags & PTYHostFramingDefaults.standardErrorFlag != 0)
        case .input: return nil
        }
    }

    /// The daemon's peer is this client, so its compatibility refusal is our mirror image.
    private static func flipped(_ value: PTYHostCompatibility) -> PTYHostCompatibility {
        switch value {
        case .compatible: return .compatible
        case .peerTooOld: return .selfTooOld
        case .selfTooOld: return .peerTooOld
        }
    }
}
