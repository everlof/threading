import Foundation

// MARK: - Chat Preview

/// How far one project's chat list is revealed in the sidebar.
///
/// The Mac half of the phone's staged preview (`MobileProjectChatPreview.Stage`): a first page,
/// two more pages of the same size, then everything. The page is longer here because a sidebar row
/// is a fraction of a phone row's height — five rows answer "what was I just doing in this project"
/// where three do on a phone.
enum SidebarChatPreviewStage: Int, CaseIterable, Sendable {
    case compact
    case firstBatch
    case secondBatch
    case all

    /// How many top-level chats the compact stage shows, and how many each later page adds.
    static let pageSize = 5

    /// The most top-level chats this stage shows.
    var limit: Int {
        switch self {
        case .compact: Self.pageSize
        case .firstBatch: Self.pageSize * 2
        case .secondBatch: Self.pageSize * 3
        case .all: .max
        }
    }

    /// The stage the disclosure row advances to.
    var next: Self {
        switch self {
        case .compact: .firstBatch
        case .firstBatch: .secondBatch
        case .secondBatch, .all: .all
        }
    }

    /// The smallest stage showing the top-level chat at `offset`, so revealing one chat never
    /// opens more of the list than it has to.
    static func revealing(offset: Int) -> Self {
        allCases.first { offset < $0.limit } ?? .all
    }
}

/// What one project's disclosure row says, derived once by `SidebarTreeBuilder`.
///
/// A value rather than a view's state, and computed before any node exists: the chats beyond the
/// stage never become outline nodes, row views or constraints, which is the whole scaling point of
/// the preview. Only their identities are kept, for the hidden-activity summary.
struct SidebarChatPreview: Equatable, Sendable {
    let stage: SidebarChatPreviewStage
    /// Top-level chats in the project's current order, before the stage cut them.
    let totalCount: Int
    /// Top-level chats the stage shows.
    let visibleCount: Int
    /// Every chat the stage keeps off the list — hidden top-level chats and the side chats
    /// forked from them. A set, because the one question asked of it is membership: whether a
    /// running chat is one the row has to speak for.
    let hiddenSessionIDs: Set<SessionID>

    var hiddenCount: Int { totalCount - visibleCount }

    /// Everything is showing after the user asked for more, so the row offers to fold back.
    var isExpanded: Bool { hiddenCount == 0 && stage != .compact }

    /// The stage the row's press moves to.
    var nextStage: SidebarChatPreviewStage { isExpanded ? .compact : stage.next }

    /// How many more top-level chats that press reveals.
    var nextRevealCount: Int { min(totalCount, nextStage.limit) - visibleCount }

    /// Whether a project this long earns the row at all. A project that fits the first page
    /// has nothing to fold, whatever stage it was left at.
    static func isWorthShowing(totalCount: Int) -> Bool {
        totalCount > SidebarChatPreviewStage.compact.limit
    }
}
