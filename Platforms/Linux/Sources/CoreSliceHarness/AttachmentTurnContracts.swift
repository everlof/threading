@testable import CoreSlice
import Foundation

/// A queued prompt keeps its admitted turn identity even if its timestamp falls elsewhere.
/// Collapsing that turn removes the file value before a table can construct its row.
func runAttachmentTurnContracts() throws {
    let root = URL(fileURLWithPath: "/tmp/attachment-turn-contract", isDirectory: true)
    let session = SessionID()
    let first = SessionAttachmentTurnBoundary(
        id: GitTurnCheckpointID(), ordinal: 1, userTurnID: "first",
        requestedAt: Date(timeIntervalSince1970: 10)
    )
    let latest = SessionAttachmentTurnBoundary(
        id: GitTurnCheckpointID(), ordinal: 2, userTurnID: "latest",
        requestedAt: Date(timeIntervalSince1970: 20)
    )
    func attachment(_ name: String, turnID: String?, placement: SessionAttachment.TurnPlacement)
        -> SessionAttachment {
        let url = root.appendingPathComponent(name)
        return SessionAttachment(
            sessionID: session, root: root, url: url, relativePath: name,
            sourcePath: url.path, kind: .image, origin: .user,
            turnID: turnID, turnPlacement: placement,
            referencedAt: Date(timeIntervalSince1970: 30)
        )
    }

    let queued = attachment("queued.png", turnID: "first", placement: .next)
    let upcoming = attachment("upcoming.png", turnID: nil, placement: .next)
    let sections = SessionAttachmentTurnSectioning.sections(
        attachments: [queued, upcoming], boundaries: [latest, first]
    )
    try require(sections.map(\.id) == [.upcoming, .checkpoint(latest.id), .checkpoint(first.id)],
                "the exact queued turn or upcoming order changed")
    try require(sections[1].attachments.isEmpty && sections[2].attachments == [queued],
                "a queued prompt moved to a later turn")
    let collapsed = SessionAttachmentTurnSectioning.items(
        sections: sections, collapsed: [.checkpoint(first.id)]
    )
    try require(collapsed.compactMap(\.attachment) == [upcoming],
                "collapsed turn constructed a file row")
    try require(SessionAttachmentTurnSectioning.sections(
        attachments: [queued], boundaries: []
    ).isEmpty, "a session without checkpoints gained a false turn")
    print("PASS shared attachment turn identity, order and collapse")
}
