import Foundation
#if os(Linux)
@testable import CoreSlice
#endif

/// The fixed choices for a session's attachment chronology on both desktop hosts.
/// Three fixed choices with `All` first keep the alternatives visible beside the selection;
/// the fourth Subagents choice appears only when a child has contributed a file.
enum AttachmentFilter: CaseIterable {
    case all
    case agent
    case subagents
    case user

    static func visibleCases(hasSubagents: Bool) -> [Self] {
        allCases.filter { hasSubagents || $0 != .subagents }
    }

    var title: String {
        switch self {
        case .all: return L10n.string("All")
        case .agent: return L10n.string("Main agent")
        case .subagents: return L10n.string("Subagents")
        case .user: return SessionAttachment.Origin.user.title
        }
    }

    func admits(_ attachment: SessionAttachment) -> Bool {
        switch self {
        case .all: return true
        case .agent: return attachment.agentSources.contains { $0.threadID == nil }
        case .subagents: return attachment.agentSources.contains { $0.threadID != nil }
        case .user: return attachment.origin == .user
        }
    }
}
