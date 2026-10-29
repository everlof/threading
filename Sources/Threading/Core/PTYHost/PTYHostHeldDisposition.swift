import Foundation
import ThreadingPTYHostKit

/// One daemon-held identity's launch disposition. Both desktop hosts use the daemon's channel
/// rather than assuming that every live child can be reattached to a new client.
enum PTYHostHeldDisposition {
    case adopt
    case resumeFromTranscript
    case ended
    case orphan

    static func classify(_ summary: PTYHostSessionSummary, isKnown: Bool) -> Self {
        guard isKnown else { return .orphan }
        guard summary.exit == nil else { return .ended }
        switch summary.resolvedChannel {
        case .pty: return .adopt
        case .pipes: return .resumeFromTranscript
        }
    }
}
