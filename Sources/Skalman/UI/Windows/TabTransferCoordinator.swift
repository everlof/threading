import AppKit

/// Moves one tab between the window's tab hosts — the same `PaneTab` object, reparented,
/// never rebuilt: the shell keeps its process and the browser its page.
///
/// Owned by the window controller because only the window sees all the hosts; the hosts
/// themselves know how to give a tab up (`detachTab`, which unparents without ending) and how
/// to take one in (`adopt`), and refuse what they cannot show (`canAdopt`). A destination
/// refuses, among other things, what it could not *restore*: movement is bounded by what
/// survives a relaunch, so a moved tab is never one the layout later forgets.
@MainActor
final class TabTransferCoordinator {

    private let host: (TabHostID) -> TabHosting?

    init(host: @escaping (TabHostID) -> TabHosting?) {
        self.host = host
    }

    /// Whether the tab could move — what a menu asks before offering the item.
    func canMove(
        tabID: UUID,
        from sourceID: TabHostID,
        to destinationID: TabHostID,
        sessionID: SessionID?
    ) -> Bool {
        guard sourceID != destinationID,
              let source = host(sourceID),
              let destination = host(destinationID),
              let tab = source.tabs(for: sessionID).first(where: { $0.id == tabID })
        else { return false }
        return destination.canAdopt(tab)
    }

    /// Detach, adopt, done. Both hosts persist their own slice inside those calls, so a move
    /// is durable the moment it happens and the tab lives in exactly one store.
    @discardableResult
    func move(
        tabID: UUID,
        from sourceID: TabHostID,
        to destinationID: TabHostID,
        index: Int? = nil,
        sessionID: SessionID?
    ) -> Bool {
        guard canMove(
            tabID: tabID, from: sourceID, to: destinationID, sessionID: sessionID
        ),
        let source = host(sourceID),
        let destination = host(destinationID),
        let detached = source.detachTab(id: tabID, for: sessionID)
        else { return false }

        destination.adopt(detached, at: index, for: sessionID)
        return true
    }
}
