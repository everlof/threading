import Foundation

/// Provider-neutral client state for a remote conversation.
///
/// Keeping reconciliation in the Foundation-only wire package makes revision recovery,
/// idempotent history pages, and row updates testable without mounting either AppKit or UIKit.
public struct RemoteConversationState: Equatable {
    public enum ApplyResult: Equatable {
        case replaced
        case changed(inserted: [String], updated: [String])
        case prepended([String])
        case requiresSnapshot
        case unchanged
    }

    public private(set) var rows: [RemoteConversationRowDTO]
    public private(set) var streamingText: String
    public private(set) var canSend: Bool
    public private(set) var permission: RemotePermissionRequestDTO?
    public private(set) var revision: Int
    public private(set) var hasEarlier: Bool

    public init(
        rows: [RemoteConversationRowDTO] = [],
        streamingText: String = "",
        canSend: Bool = false,
        permission: RemotePermissionRequestDTO? = nil,
        revision: Int = 0,
        hasEarlier: Bool = false
    ) {
        self.rows = rows
        self.streamingText = streamingText
        self.canSend = canSend
        self.permission = permission
        self.revision = revision
        self.hasEarlier = hasEarlier
    }

    @discardableResult
    public mutating func apply(_ snapshot: RemoteConversationSnapshotDTO) -> ApplyResult {
        rows = Self.unique(snapshot.rows)
        streamingText = snapshot.streamingText
        canSend = snapshot.canSend
        permission = snapshot.permission
        revision = snapshot.revision
        hasEarlier = snapshot.hasEarlier
        return .replaced
    }

    @discardableResult
    public mutating func apply(_ delta: RemoteConversationDeltaDTO) -> ApplyResult {
        guard delta.baseRevision == revision else { return .requiresSnapshot }

        var inserted: [String] = []
        var updated: [String] = []

        if !delta.updatedRows.isEmpty || !delta.appendedRows.isEmpty {
            var indices = Dictionary(uniqueKeysWithValues: rows.enumerated().map {
                ($0.element.id, $0.offset)
            })

            for row in delta.updatedRows {
                guard let index = indices[row.id] else { continue }
                guard rows[index] != row else { continue }
                rows[index] = row
                updated.append(row.id)
            }

            for row in delta.appendedRows where indices[row.id] == nil {
                indices[row.id] = rows.count
                rows.append(row)
                inserted.append(row.id)
            }
        }

        let metadataChanged = streamingText != delta.streamingText
            || canSend != delta.canSend
            || permission != delta.permission
            || delta.hasEarlier.map { hasEarlier != $0 } == true
        streamingText = delta.streamingText
        canSend = delta.canSend
        permission = delta.permission
        if let hasEarlier = delta.hasEarlier {
            self.hasEarlier = hasEarlier
        }
        revision = delta.revision

        if inserted.isEmpty, updated.isEmpty, !metadataChanged {
            return .unchanged
        }
        return .changed(inserted: inserted, updated: updated)
    }

    @discardableResult
    public mutating func prepend(_ page: RemoteConversationPageDTO) -> ApplyResult {
        let existing = Set(rows.map(\.id))
        let newRows = Self.unique(page.rows).filter { !existing.contains($0.id) }
        hasEarlier = page.hasEarlier
        guard !newRows.isEmpty else { return .unchanged }
        rows.insert(contentsOf: newRows, at: 0)
        return .prepended(newRows.map(\.id))
    }

    private static func unique(
        _ rows: [RemoteConversationRowDTO]
    ) -> [RemoteConversationRowDTO] {
        var seen: Set<String> = []
        return rows.filter { seen.insert($0.id).inserted }
    }
}
