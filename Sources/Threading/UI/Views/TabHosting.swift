import AppKit

// MARK: - Tab Hosting

/// What every tab-hosting pane answers for, stated once so tab commands — cycling, closing,
/// reordering, and moving a tab between panes — can be written against the host and not against
/// the display panel it happened to be built for.
///
/// `sessionID` is part of every signature because the hosts keep their tabs per session — the
/// panel and the drawer both follow the session on screen. Callers pass the session they mean,
/// or nil for "the host's current scope".
@MainActor
protocol TabHosting: AnyObject {

    var hostID: TabHostID { get }

    /// The host's tabs in strip order, within the given session's scope.
    func tabs(for sessionID: SessionID?) -> [PaneTab]

    func activeTabID(for sessionID: SessionID?) -> UUID?

    @discardableResult
    func activateTab(id: UUID, for sessionID: SessionID?) -> Bool

    @discardableResult
    func closeTab(id: UUID, for sessionID: SessionID?) -> Bool

    /// Moves a tab within the host's own strip. `index` names the position in the list as it
    /// stands after the move.
    @discardableResult
    func moveTab(id: UUID, toIndex index: Int, for sessionID: SessionID?) -> Bool

    /// Whether a tab of this kind may live here — a destination adopts only what it can
    /// rebuild after a relaunch. Checked before any transfer is offered.
    func canAdopt(_ tab: PaneTab) -> Bool

    /// Removes a tab *without* tearing its content down: the hosted controller is unparented
    /// but stays alive, which is what lets another host adopt the same object. Contrast
    /// `closeTab`, which ends what the tab held.
    func detachTab(id: UUID, for sessionID: SessionID?) -> PaneTab?

    /// Inserts a previously detached tab, activates it, and persists. A nil index appends.
    func adopt(_ tab: PaneTab, at index: Int?, for sessionID: SessionID?)
}

// MARK: - Standard Tab Menu

extension TabHosting {

    /// The context-menu entries every tab strip offers, written once against the host contract
    /// so the panel's menu and the drawer's cannot drift: the closes a tabbed app is expected
    /// to have — this tab, the others, the ones after it, all of them — then the
    /// keyboard-reachable reorder pair. Entries that would do nothing are disabled rather than
    /// hidden, so the menu keeps one learnable shape wherever it opens. Hosts append what only
    /// they know (a "Move to …" destination) after these.
    func standardTabEntries(for id: UUID, sessionID: SessionID?) -> [ThemedMenuEntry] {
        let tabs = tabs(for: sessionID)
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return [] }

        // Captured as ids, not indices: each close mutates the list, and the menu's promise
        // is about the tabs the user saw when it opened.
        let all = tabs.map(\.id)
        let others = tabs.filter { $0.id != id }.map(\.id)
        let after = tabs.suffix(from: index + 1).map(\.id)

        return [
            .item(ThemedMenuItem(
                title: L10n.string("Close Tab"),
                onChoose: { [weak self] in _ = self?.closeTab(id: id, for: sessionID) }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Close Other Tabs"),
                isEnabled: !others.isEmpty,
                onChoose: { [weak self] in
                    for other in others { _ = self?.closeTab(id: other, for: sessionID) }
                }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Close Tabs to the Right"),
                isEnabled: !after.isEmpty,
                onChoose: { [weak self] in
                    for trailing in after { _ = self?.closeTab(id: trailing, for: sessionID) }
                }
            )),
            // Always applicable — with one tab it is Close Tab said another way, which is
            // cheaper to read than an entry that greys out for a reason nobody can see.
            .item(ThemedMenuItem(
                title: L10n.string("Close All Tabs"),
                onChoose: { [weak self] in
                    for tab in all { _ = self?.closeTab(id: tab, for: sessionID) }
                }
            )),
            .separator,
            .item(ThemedMenuItem(
                title: L10n.string("Move Left"),
                isEnabled: index > 0,
                onChoose: { [weak self] in
                    _ = self?.moveTab(id: id, toIndex: index - 1, for: sessionID)
                }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Move Right"),
                isEnabled: index < tabs.count - 1,
                onChoose: { [weak self] in
                    _ = self?.moveTab(id: id, toIndex: index + 1, for: sessionID)
                }
            ))
        ]
    }
}

// MARK: - Tab List State

/// One host's ordered tabs and its active tab, with the operations every host repeats.
///
/// A value type on purpose: the subtle parts of tab bookkeeping — which neighbour inherits
/// selection when the active tab closes, how a move clamps — were written once inside the
/// display panel and would otherwise be re-derived (and re-broken) by each new host. Pure
/// state in, pure state out, so tests cover the rules without building a pane.
@MainActor
struct TabListState {

    private(set) var tabs: [PaneTab]
    private(set) var activeTabID: UUID?

    init(tabs: [PaneTab] = [], activeTabID: UUID? = nil) {
        self.tabs = tabs
        self.activeTabID = activeTabID
    }

    var activeTab: PaneTab? {
        guard !tabs.isEmpty else { return nil }
        if let activeTabID, let tab = tabs.first(where: { $0.id == activeTabID }) {
            return tab
        }
        return tabs.last
    }

    /// Inserts at the given position, clamped; nil appends. Does not change the active tab —
    /// whether arriving content takes the front is the host's policy, not the list's.
    mutating func insert(_ tab: PaneTab, at index: Int? = nil) {
        let target = min(max(index ?? tabs.count, 0), tabs.count)
        tabs.insert(tab, at: target)
    }

    @discardableResult
    mutating func activate(id: UUID) -> Bool {
        guard tabs.contains(where: { $0.id == id }) else { return false }
        activeTabID = id
        return true
    }

    /// Removes the tab and reports it with the slot it held. When the active tab is the one
    /// removed, selection moves to the neighbour that slid into its slot, else the new last —
    /// the reading position stays put instead of jumping to an end.
    mutating func remove(id: UUID) -> (removed: PaneTab, index: Int)? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = tabs.remove(at: index)

        if activeTabID == id {
            let neighbour = tabs.indices.contains(index) ? tabs[index] : tabs.last
            activeTabID = neighbour?.id
        }
        return (removed, index)
    }

    /// Moves a tab to `index`, its position in the list as it stands after the move, clamped
    /// to the list's ends. Reports whether anything changed.
    @discardableResult
    mutating func move(id: UUID, toIndex index: Int) -> Bool {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let tab = tabs.remove(at: from)
        let target = min(max(index, 0), tabs.count)
        tabs.insert(tab, at: target)
        return target != from
    }

    /// The matching tab nearest the given slot — how the panel re-points "the browser the agent
    /// is driving" when that browser's tab closes.
    func nearest(to index: Int, where matches: (PaneTab) -> Bool) -> PaneTab? {
        tabs.enumerated()
            .filter { matches($0.element) }
            .min { abs($0.offset - index) < abs($1.offset - index) }?
            .element
    }
}
