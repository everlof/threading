import XCTest
@testable import Skalman

/// The rules every tab host shares, tested as pure state: which neighbour inherits selection
/// when a tab closes, how a move clamps, what a stale active id falls back to. These were the
/// display panel's private behaviour first — the parity cases pin what its users already rely
/// on, so the drawer and the main pane inherit the same feel rather than a rediscovery of it.
@MainActor
final class TabListStateTests: XCTestCase {

    // MARK: - Fixtures

    /// The one tab kind constructible without a live view controller.
    private func tab() -> PaneTab {
        PaneTab(body: .content(DisplayContent(
            body: .html("<p>fixture</p>"),
            title: nil,
            subtitle: "Fixture"
        )))
    }

    private func state(count: Int, activeIndex: Int? = nil) -> (TabListState, [PaneTab]) {
        let tabs = (0..<count).map { _ in tab() }
        let active = activeIndex.map { tabs[$0].id }
        return (TabListState(tabs: tabs, activeTabID: active), tabs)
    }

    // MARK: - Closing

    func testRemovingTheActiveTabSelectsTheNeighbourThatSlidIntoItsSlot() {
        var (state, tabs) = state(count: 3, activeIndex: 1)

        let removed = state.remove(id: tabs[1].id)

        XCTAssertEqual(removed?.removed.id, tabs[1].id)
        XCTAssertEqual(removed?.index, 1)
        XCTAssertEqual(state.activeTabID, tabs[2].id)
    }

    func testRemovingTheActiveLastTabSelectsTheNewLast() {
        var (state, tabs) = state(count: 3, activeIndex: 2)

        _ = state.remove(id: tabs[2].id)

        XCTAssertEqual(state.activeTabID, tabs[1].id)
    }

    func testRemovingAnInactiveTabLeavesTheSelectionAlone() {
        var (state, tabs) = state(count: 3, activeIndex: 0)

        _ = state.remove(id: tabs[2].id)

        XCTAssertEqual(state.activeTabID, tabs[0].id)
    }

    func testRemovingTheOnlyTabClearsTheSelection() {
        var (state, tabs) = state(count: 1, activeIndex: 0)

        _ = state.remove(id: tabs[0].id)

        XCTAssertNil(state.activeTabID)
        XCTAssertTrue(state.tabs.isEmpty)
    }

    func testRemovingAnUnknownIDReportsNilAndChangesNothing() {
        var (state, tabs) = state(count: 2, activeIndex: 0)

        XCTAssertNil(state.remove(id: UUID()))
        XCTAssertEqual(state.tabs.map(\.id), tabs.map(\.id))
        XCTAssertEqual(state.activeTabID, tabs[0].id)
    }

    // MARK: - Moving

    func testMoveReportsWhetherAnythingChanged() {
        var (state, tabs) = state(count: 3)

        XCTAssertTrue(state.move(id: tabs[0].id, toIndex: 2))
        XCTAssertEqual(state.tabs.map(\.id), [tabs[1].id, tabs[2].id, tabs[0].id])

        XCTAssertFalse(state.move(id: tabs[0].id, toIndex: 2))
    }

    func testMoveClampsToTheStripEnds() {
        var (state, tabs) = state(count: 3)

        XCTAssertTrue(state.move(id: tabs[1].id, toIndex: 99))
        XCTAssertEqual(state.tabs.last?.id, tabs[1].id)

        XCTAssertTrue(state.move(id: tabs[1].id, toIndex: -5))
        XCTAssertEqual(state.tabs.first?.id, tabs[1].id)
    }

    func testMoveKeepsTheActiveTabActive() {
        var (state, tabs) = state(count: 3, activeIndex: 0)

        _ = state.move(id: tabs[0].id, toIndex: 2)

        XCTAssertEqual(state.activeTabID, tabs[0].id)
        XCTAssertEqual(state.activeTab?.id, tabs[0].id)
    }

    func testMoveOfUnknownIDReportsFalse() {
        var (state, _) = state(count: 2)
        XCTAssertFalse(state.move(id: UUID(), toIndex: 0))
    }

    // MARK: - Inserting & Activating

    func testInsertAppendsWhenNoIndexIsGiven() {
        var (state, tabs) = state(count: 2)
        let newcomer = tab()

        state.insert(newcomer)

        XCTAssertEqual(state.tabs.map(\.id), [tabs[0].id, tabs[1].id, newcomer.id])
    }

    func testInsertClampsAnOutOfRangeIndex() {
        var (state, _) = state(count: 2)
        let newcomer = tab()

        state.insert(newcomer, at: 99)

        XCTAssertEqual(state.tabs.last?.id, newcomer.id)
    }

    func testInsertDoesNotSteallTheSelection() {
        var (state, tabs) = state(count: 2, activeIndex: 0)

        state.insert(tab())

        XCTAssertEqual(state.activeTabID, tabs[0].id)
    }

    func testActivateRefusesAnUnknownID() {
        var (state, tabs) = state(count: 2, activeIndex: 0)

        XCTAssertFalse(state.activate(id: UUID()))
        XCTAssertEqual(state.activeTabID, tabs[0].id)

        XCTAssertTrue(state.activate(id: tabs[1].id))
        XCTAssertEqual(state.activeTabID, tabs[1].id)
    }

    func testActiveTabFallsBackToTheLastWhenTheIDIsStale() {
        let tabs = [tab(), tab()]
        let state = TabListState(tabs: tabs, activeTabID: UUID())

        XCTAssertEqual(state.activeTab?.id, tabs[1].id)
    }

    // MARK: - Nearest

    func testNearestPrefersTheCloserMatch() {
        let tabs = [tab(), tab(), tab(), tab()]
        let state = TabListState(tabs: tabs)
        let wanted = Set([tabs[0].id, tabs[3].id])

        let nearest = state.nearest(to: 2) { wanted.contains($0.id) }

        XCTAssertEqual(nearest?.id, tabs[3].id)
    }

    func testNearestReportsNilWhenNothingMatches() {
        let (state, _) = state(count: 2)
        XCTAssertNil(state.nearest(to: 0) { _ in false })
    }
}
