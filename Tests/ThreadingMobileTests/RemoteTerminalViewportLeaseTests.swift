import Combine
import SwiftTerm
import ThreadingRemoteKit
import UIKit
import XCTest
@testable import ThreadingMobile

/// A pinch, a keyboard, or an animated layout reports one grid per crossed cell boundary, and
/// each forwarded grid soft-resets and reflows the Mac's emulator and SIGWINCHes the agent into
/// a whole-screen repaint. The Mac's journal showed nineteen leases from one gesture, and every
/// hello behind that churn stalled for seconds — which read on the phone as "entering a chat
/// with smaller text is very much slower". Only the first grid of a lease and the settled grid
/// after a storm may reach the wire.
///
/// The demo script plays the Mac's half in-process and answers an accepted lease with `resize`,
/// so the applied grid is observable as `terminalColumns`/`terminalRows` without a socket.
final class RemoteTerminalViewportLeaseTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        static let settleDelay: Duration = .milliseconds(40)
        /// Comfortably past the settle delay, far short of flaking on a busy machine.
        static let settleTimeout: TimeInterval = 2
        /// The grids one pinch from 9 to 13 points reports, oldest first.
        static let pinchLadder = [(62, 54), (56, 47), (52, 43), (48, 41)]
        static let entryGrid = (cols: 69, rows: 59)
    }

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - Tests

    @MainActor
    func testTheFirstGridOfALeaseIsSentImmediately() {
        let connection = Self.demoConnection()
        connection.connect()

        connection.updateTerminalViewport(
            cols: Fixture.entryGrid.cols,
            rows: Fixture.entryGrid.rows
        )

        XCTAssertEqual(connection.terminalColumns, Fixture.entryGrid.cols)
        XCTAssertEqual(connection.terminalRows, Fixture.entryGrid.rows)
    }

    @MainActor
    func testAViewportStormLeasesOnlyTheSettledGrid() {
        let connection = Self.demoConnection()
        connection.connect()
        connection.updateTerminalViewport(
            cols: Fixture.entryGrid.cols,
            rows: Fixture.entryGrid.rows
        )
        var appliedGrids: [(Int, Int)] = []
        // Rows publish after columns in `updateTerminalGrid`, so sampling on the rows change
        // sees the whole applied grid.
        connection.$terminalRows
            .dropFirst()
            .sink { [weak connection] rows in
                appliedGrids.append((connection?.terminalColumns ?? 0, rows))
            }
            .store(in: &cancellables)

        for grid in Fixture.pinchLadder {
            connection.updateTerminalViewport(cols: grid.0, rows: grid.1)
        }

        XCTAssertTrue(
            appliedGrids.isEmpty,
            "A grid still in motion is not a lease, got \(appliedGrids)"
        )

        let settled = expectation(description: "the settled grid is leased")
        connection.$terminalColumns
            .filter { $0 == Fixture.pinchLadder.last?.0 }
            .prefix(1)
            .sink { _ in settled.fulfill() }
            .store(in: &cancellables)
        wait(for: [settled], timeout: Fixture.settleTimeout)

        XCTAssertEqual(appliedGrids.count, 1, "One settled lease, got \(appliedGrids)")
        XCTAssertEqual(appliedGrids.first?.0, Fixture.pinchLadder.last?.0)
        XCTAssertEqual(appliedGrids.first?.1, Fixture.pinchLadder.last?.1)
    }

    @MainActor
    func testReleasingTheViewportCancelsAPendingLease() async throws {
        let connection = Self.demoConnection()
        connection.connect()
        connection.updateTerminalViewport(
            cols: Fixture.entryGrid.cols,
            rows: Fixture.entryGrid.rows
        )

        connection.updateTerminalViewport(cols: 48, rows: 41)
        connection.releaseTerminalViewport()
        try await Task.sleep(for: Fixture.settleDelay * 4)

        XCTAssertEqual(
            connection.terminalColumns,
            Fixture.entryGrid.cols,
            "A lease cancelled by release must not resize the Mac afterwards"
        )
    }

    /// `updateUIView` runs for every published change on the connection, and reinstalling an
    /// identical palette clears SwiftTerm's attribute caches and marks the whole screen dirty —
    /// a cold whole-grid repaint per presence or status tick, growing with cell count as the
    /// font shrinks.
    @MainActor
    func testReapplyingAnUnchangedThemeDoesNotRepaintTheWholeScreen() {
        let view = RemoteTerminalView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 720),
            font: UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        )
        TerminalViewRepresentable.apply(Self.theme(background: "#101010"), to: view)
        view.getTerminal().clearUpdateRange()

        TerminalViewRepresentable.apply(Self.theme(background: "#101010"), to: view)

        XCTAssertNil(
            view.getTerminal().getUpdateRange(),
            "An unchanged theme must not invalidate a single row"
        )

        TerminalViewRepresentable.apply(Self.theme(background: "#202020"), to: view)

        XCTAssertNotNil(
            view.getTerminal().getUpdateRange(),
            "A changed theme still repaints"
        )
    }

    @MainActor
    func testTheFallbackThemeIsAppliedOnceNotPerUpdate() {
        let view = RemoteTerminalView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 720),
            font: UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        )
        TerminalViewRepresentable.apply(nil, to: view)
        view.getTerminal().clearUpdateRange()

        TerminalViewRepresentable.apply(nil, to: view)

        XCTAssertNil(view.getTerminal().getUpdateRange())
    }

    // MARK: - Private Methods

    @MainActor
    private static func demoConnection() -> RemoteSessionConnection {
        let session = RemoteSessionSummaryDTO(
            id: "0e6f7d1c-5716-470b-933c-d68310644b4f",
            title: "Claude Code · AnotherTerminal",
            agentKind: "claude",
            surface: .terminal,
            state: "running",
            projectName: "AnotherTerminal"
        )
        let link = RemoteConnectionLink(string: "https://demo.threading.invalid/#terminal-lease")!
        return RemoteSessionConnection(
            session: session,
            client: RemoteClient(link: link),
            viewportSettleDelay: Fixture.settleDelay
        )
    }

    private static func theme(background: String) -> RemoteTerminalThemeDTO {
        RemoteTerminalThemeDTO(
            id: "lease-test",
            name: "Lease Test",
            foreground: "#e6e6e6",
            background: background,
            cursor: "#ffcc00",
            selection: "#334455",
            ansi: [
                "#000000", "#cc0000", "#00cc00", "#cccc00",
                "#0000cc", "#cc00cc", "#00cccc", "#cccccc",
                "#333333", "#ff3333", "#33ff33", "#ffff33",
                "#3333ff", "#ff33ff", "#33ffff", "#ffffff",
            ]
        )
    }
}
