import ThreadingRemoteKit

/// Device-local reading aid. It never changes the Mac's completion/read-receipt authority.
/// A cold projection visits the loaded window once (normally 200 rows, stress 5,000); live
/// appends then visit only the new rows. Missing history is explicit rather than counted as zero.
struct RemoteConversationCatchUp: Equatable {
    var firstUnreadID: String?
    var latestReplyID: String?
    var replies = 0
    var actions = 0
    var isPartial = false

    init(rows: [RemoteConversationRowDTO], after seenID: String, hasEarlier: Bool) {
        if let index = rows.firstIndex(where: { $0.id == seenID }) {
            append(Array(rows.dropFirst(index + 1)))
        } else if hasEarlier {
            isPartial = true
            append(rows)
        }
    }

    mutating func append(_ rows: [RemoteConversationRowDTO]) {
        for row in rows {
            if firstUnreadID == nil { firstUnreadID = row.id }
            if row.kind == .assistant {
                replies += 1
                latestReplyID = row.id
            }
            if row.kind == .tool { actions += 1 }
        }
    }

    var summary: String {
        if isPartial { return MobileL10n.string("Since you left · Recent activity") }
        var parts: [String] = []
        if replies > 0 { parts.append(replies == 1 ? MobileL10n.string("1 reply") : MobileL10n.string("%lld replies", replies)) }
        if actions > 0 { parts.append(actions == 1 ? MobileL10n.string("1 tool action") : MobileL10n.string("%lld tool actions", actions)) }
        return parts.isEmpty ? MobileL10n.string("Since you left · New messages")
            : MobileL10n.string("Since you left · %@", parts.joined(separator: " · "))
    }
}
