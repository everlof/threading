import Foundation
import ThreadingPTYHostKit

/// Host-owned reporting for client events that are useful to log but do not change the wire.
public enum PTYHostClientDiagnostic: Sendable {
    case connected(protocolVersion: Int)
    case protocolMismatch(compatibility: PTYHostCompatibility, update: String)
    case framingRefused(String, duringHandshake: Bool)
    case unexpectedInput
    case lostSessions(Int)
    case unknownFrameType(String)
    case unreadableControl(String)
    case writeQueueOverflow(queuedBytes: Int, bound: Int)
}
