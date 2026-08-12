import Foundation
import ThreadingRemoteKit

/// Main-actor state observed directly by the UIKit timeline.
///
/// The surrounding SwiftUI screen deliberately does not publish the row array. Streaming text
/// can therefore update one reusable collection cell without invalidating the navigation,
/// composer, presence banner, and every previously rendered message.
@MainActor
final class RemoteConversationStore {
    enum Change: Equatable {
        case unchanged
        case reset(updated: [String])
        case delta(
            inserted: [String],
            updated: [String],
            streamingChanged: Bool,
            permissionChanged: Bool,
            capabilitiesChanged: Bool,
            historyChanged: Bool
        )
        case prepended([String])
        case loadingChanged
    }

    private(set) var state = RemoteConversationState()
    private(set) var isLoadingEarlier = false

    var onCanSendChange: ((Bool) -> Void)?

    private var observers: [UUID: (Change) -> Void] = [:]
    private var rowsByID: [String: RemoteConversationRowDTO] = [:]

    @discardableResult
    func observe(_ observer: @escaping (Change) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID?) {
        guard let id else { return }
        observers[id] = nil
    }

    @discardableResult
    func replace(with snapshot: RemoteConversationSnapshotDTO) -> Change {
        let oldState = state
        let oldRowsByID = rowsByID
        let oldCanSend = state.canSend
        let wasLoadingEarlier = isLoadingEarlier
        state.apply(snapshot)
        rowsByID = Dictionary(uniqueKeysWithValues: state.rows.map { ($0.id, $0) })
        isLoadingEarlier = false
        if oldCanSend != state.canSend {
            onCanSendChange?(state.canSend)
        }

        let hasSameRowIdentities = oldState.rows.count == state.rows.count
            && zip(oldState.rows, state.rows).allSatisfy { oldRow, newRow in
                oldRow.id == newRow.id
            }
        let updated = state.rows.compactMap { row -> String? in
            guard let oldRow = oldRowsByID[row.id], oldRow != row else { return nil }
            return row.id
        }
        guard hasSameRowIdentities else {
            let change = Change.reset(updated: updated)
            notify(change)
            return change
        }

        let streamingChanged = oldState.streamingText != state.streamingText
        let permissionChanged = oldState.permission != state.permission
        let capabilitiesChanged = oldState.composerCapabilities != state.composerCapabilities
        let historyChanged = oldState.hasEarlier != state.hasEarlier || wasLoadingEarlier
        guard !updated.isEmpty
                || streamingChanged
                || permissionChanged
                || capabilitiesChanged
                || historyChanged else {
            return .unchanged
        }

        let change = Change.delta(
            inserted: [],
            updated: updated,
            streamingChanged: streamingChanged,
            permissionChanged: permissionChanged,
            capabilitiesChanged: capabilitiesChanged,
            historyChanged: historyChanged
        )
        notify(change)
        return change
    }

    /// Returns false when the delta cannot be reconciled and the socket must request a snapshot.
    @discardableResult
    func apply(_ delta: RemoteConversationDeltaDTO) -> Bool {
        let oldStreaming = state.streamingText
        let oldPermission = state.permission
        let oldCapabilities = state.composerCapabilities
        let oldCanSend = state.canSend
        let oldHasEarlier = state.hasEarlier
        switch state.apply(delta) {
        case .requiresSnapshot:
            return false
        case .changed(let inserted, let updated):
            let changedIDs = Set(inserted + updated)
            for row in delta.updatedRows + delta.appendedRows where changedIDs.contains(row.id) {
                rowsByID[row.id] = row
            }
            if oldCanSend != state.canSend {
                onCanSendChange?(state.canSend)
            }
            notify(.delta(
                inserted: inserted,
                updated: updated,
                streamingChanged: oldStreaming != state.streamingText,
                permissionChanged: oldPermission != state.permission,
                capabilitiesChanged: oldCapabilities != state.composerCapabilities,
                historyChanged: oldHasEarlier != state.hasEarlier
            ))
        case .unchanged:
            break
        default:
            notify(.reset(updated: []))
        }
        return true
    }

    func prepend(_ page: RemoteConversationPageDTO) {
        isLoadingEarlier = false
        switch state.prepend(page) {
        case .prepended(let ids):
            let inserted = Set(ids)
            for row in page.rows where inserted.contains(row.id) {
                rowsByID[row.id] = row
            }
            notify(.prepended(ids))
        default:
            notify(.loadingChanged)
        }
    }

    /// Returns the row before which the host should page, or nil if no request is needed.
    func beginLoadingEarlier() -> String? {
        guard state.hasEarlier, !isLoadingEarlier, let first = state.rows.first else {
            return nil
        }
        isLoadingEarlier = true
        notify(.loadingChanged)
        return first.id
    }

    func cancelLoadingEarlier() {
        guard isLoadingEarlier else { return }
        isLoadingEarlier = false
        notify(.loadingChanged)
    }

    func row(withID id: String) -> RemoteConversationRowDTO? {
        rowsByID[id]
    }

    private func notify(_ change: Change) {
        for observer in observers.values {
            observer(change)
        }
    }
}
