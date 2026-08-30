import Foundation

/// The small, provider-neutral slice of a durable checkpoint that attachment chronology needs.
/// Keeping the projection value-only makes grouping testable without opening a repository or
/// asking git for either endpoint of a turn.
struct SessionAttachmentTurnBoundary: Equatable {
    let id: GitTurnCheckpointID
    let ordinal: Int
    let userTurnID: String
    let requestedAt: Date

    init(_ checkpoint: GitTurnCheckpoint) {
        id = checkpoint.id
        ordinal = checkpoint.ordinal
        userTurnID = checkpoint.userTurnID
        requestedAt = checkpoint.requestedAt
    }

    init(id: GitTurnCheckpointID, ordinal: Int, userTurnID: String, requestedAt: Date) {
        self.id = id
        self.ordinal = ordinal
        self.userTurnID = userTurnID
        self.requestedAt = requestedAt
    }
}

/// One collapsible run in the attachment chronology. Attachments stay as values until the table
/// asks for a visible row, so folding an old turn prevents its row views from being constructed.
struct SessionAttachmentTurnSection: Equatable {
    enum ID: Hashable {
        case checkpoint(GitTurnCheckpointID)
        case upcoming
        case betweenTurns
    }

    let id: ID
    let ordinal: Int?
    let distanceFromLatest: Int?
    let isLatest: Bool
    let attachments: [SessionAttachment]
}

enum SessionAttachmentTurnListItem: Equatable {
    case header(SessionAttachmentTurnSection)
    case attachment(SessionAttachment)

    var attachment: SessionAttachment? {
        guard case .attachment(let attachment) = self else { return nil }
        return attachment
    }
}

enum SessionAttachmentTurnSectioning {

    /// Groups a bounded attachment list against the bounded checkpoint ledger. Exact turn ids
    /// win. Temporal placement is the migration/fallback path: agent output points back to the
    /// current turn, a prompt handoff points forward to the next admitted turn, and pane-local
    /// comparison input belongs between turns rather than to a later unrelated prompt.
    static func sections(
        attachments: [SessionAttachment],
        boundaries unsortedBoundaries: [SessionAttachmentTurnBoundary]
    ) -> [SessionAttachmentTurnSection] {
        guard !attachments.isEmpty else { return [] }

        let boundaries = unsortedBoundaries.sorted {
            $0.ordinal == $1.ordinal
                ? $0.requestedAt < $1.requestedAt
                : $0.ordinal < $1.ordinal
        }
        // A session with no durable turn ledger has no truthful boundary to name. This includes
        // legacy and terminal sessions; an attachment that happens to point forward must not
        // leave those panes under a permanent “Upcoming turn” heading.
        guard !boundaries.isEmpty else { return [] }

        // A damaged/newer ledger must not crash the pane merely because two records repeat one
        // optional transport identity. Newest wins, matching the chronology's visible order.
        var exact: [String: Int] = [:]
        for (index, boundary) in boundaries.enumerated() where !boundary.userTurnID.isEmpty {
            exact[boundary.userTurnID] = index
        }
        var grouped = Array(repeating: [SessionAttachment](), count: boundaries.count)
        var upcoming: [SessionAttachment] = []
        var betweenTurns: [SessionAttachment] = []

        for attachment in attachments {
            if let turnID = attachment.turnID, let index = exact[turnID] {
                grouped[index].append(attachment)
                continue
            }

            switch attachment.turnPlacement {
            case .current:
                if let index = lastBoundary(atOrBefore: attachment.referencedAt, in: boundaries) {
                    grouped[index].append(attachment)
                } else {
                    betweenTurns.append(attachment)
                }
            case .next:
                if let index = firstBoundary(atOrAfter: attachment.referencedAt, in: boundaries) {
                    grouped[index].append(attachment)
                } else {
                    upcoming.append(attachment)
                }
            case .none:
                betweenTurns.append(attachment)
            }
        }

        var result: [SessionAttachmentTurnSection] = []
        if !upcoming.isEmpty {
            result.append(SessionAttachmentTurnSection(
                id: .upcoming,
                ordinal: nil,
                distanceFromLatest: nil,
                isLatest: false,
                attachments: upcoming
            ))
        }

        if let latestIndex = boundaries.indices.last {
            for index in boundaries.indices.reversed()
                where !grouped[index].isEmpty || index == latestIndex {
                let boundary = boundaries[index]
                result.append(SessionAttachmentTurnSection(
                    id: .checkpoint(boundary.id),
                    ordinal: boundary.ordinal,
                    distanceFromLatest: latestIndex - index,
                    isLatest: index == latestIndex,
                    attachments: grouped[index]
                ))
            }
        }

        if !betweenTurns.isEmpty {
            result.append(SessionAttachmentTurnSection(
                id: .betweenTurns,
                ordinal: nil,
                distanceFromLatest: nil,
                isLatest: false,
                attachments: betweenTurns
            ))
        }
        return result
    }

    static func items(
        sections: [SessionAttachmentTurnSection],
        collapsed: Set<SessionAttachmentTurnSection.ID>
    ) -> [SessionAttachmentTurnListItem] {
        sections.flatMap { section in
            var rows: [SessionAttachmentTurnListItem] = [.header(section)]
            if !collapsed.contains(section.id) {
                rows.append(contentsOf: section.attachments.map(SessionAttachmentTurnListItem.attachment))
            }
            return rows
        }
    }

    private static func lastBoundary(
        atOrBefore date: Date,
        in boundaries: [SessionAttachmentTurnBoundary]
    ) -> Int? {
        var lower = 0
        var upper = boundaries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if boundaries[middle].requestedAt <= date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower == 0 ? nil : lower - 1
    }

    private static func firstBoundary(
        atOrAfter date: Date,
        in boundaries: [SessionAttachmentTurnBoundary]
    ) -> Int? {
        var lower = 0
        var upper = boundaries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if boundaries[middle].requestedAt < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower == boundaries.count ? nil : lower
    }
}
