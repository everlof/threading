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
        static let hydrationQuietDelay: Duration = .milliseconds(80)
        static let hydrationHalfDelay: Duration = .milliseconds(40)
        static let staticDemoHydrationWait: Duration = .milliseconds(1_200)
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

    /// Codex answers a resize by clearing and re-emitting terminal-owned history in many PTY
    /// reads. The emulator must keep parsing those reads, but the phone must not reveal the
    /// clear and partial reflow states between them.
    @MainActor
    func testInitialTerminalStaysHydratingUntilOutputIsQuietAfterTheViewport() async throws {
        let connection = Self.demoConnection(
            hydrationQuietDelay: Fixture.hydrationQuietDelay
        )
        connection.onTerminalOutput = { _ in }
        connection.connect()

        // Model an older host: it knows the ordinary terminal protocol but does not advertise
        // the ordered hydration boundary. The phone must retain its conservative silence
        // fallback for compatibility.
        connection.receiveServerTextForTesting(Self.encoded(RemoteHelloDTO(
            surface: .terminal,
            capability: RemoteCapability.interact.rawValue,
            cols: 80,
            rows: 24,
            title: "Legacy terminal",
            features: []
        )))

        XCTAssertTrue(connection.isTerminalHydrating)
        connection.updateTerminalViewport(
            cols: Fixture.entryGrid.cols,
            rows: Fixture.entryGrid.rows
        )
        try await Task.sleep(for: Fixture.hydrationHalfDelay)
        XCTAssertTrue(connection.isTerminalHydrating)

        // Another repaint chunk restarts the quiet boundary instead of exposing a partial frame.
        connection.receiveDemoTerminalOutput(Data("late repaint chunk".utf8))
        try await Task.sleep(for: Fixture.hydrationHalfDelay)
        XCTAssertTrue(connection.isTerminalHydrating)
        try await Task.sleep(for: Fixture.hydrationQuietDelay)
        XCTAssertFalse(connection.isTerminalHydrating)
    }

    /// A current Mac puts `terminalReady` behind the resize repaint and final screen seed, so a
    /// one-second phone timer is both slower and less accurate than the ordered wire boundary.
    @MainActor
    func testCurrentHostRevealsOnTheMatchingTerminalBoundary() {
        let connection = Self.demoConnection(hydrationQuietDelay: .seconds(2))
        connection.onTerminalOutput = { _ in }
        connection.connect()

        XCTAssertTrue(connection.isTerminalHydrating)
        connection.updateTerminalViewport(
            cols: Fixture.entryGrid.cols,
            rows: Fixture.entryGrid.rows
        )

        XCTAssertFalse(
            connection.isTerminalHydrating,
            "The host boundary must avoid the old fixed quiet tax"
        )
    }

    /// WebSocket ordering alone is insufficient when the SwiftTerm view has not mounted: the
    /// binary frames can be buffered in the connection while the later ready text is decoded.
    /// Reveal follows renderer delivery, not merely socket receipt.
    @MainActor
    func testTerminalBoundaryWaitsForBufferedOutputToReachSwiftTerm() {
        let connection = Self.demoConnection(hydrationQuietDelay: .seconds(2))
        connection.connect()
        connection.updateTerminalViewport(
            cols: Fixture.entryGrid.cols,
            rows: Fixture.entryGrid.rows
        )

        XCTAssertTrue(connection.isTerminalHydrating)
        var received = Data()
        connection.onTerminalOutput = { received.append($0) }

        XCTAssertFalse(received.isEmpty)
        XCTAssertFalse(connection.isTerminalHydrating)
    }

    /// A settled layout can supersede the first grid while its repaint is still in flight. A
    /// delayed boundary from that older generation must not uncover the newer resize.
    @MainActor
    func testAStaleTerminalBoundaryCannotRevealANewerViewportGeneration() throws {
        let connection = Self.demoConnection(hydrationQuietDelay: .seconds(2))
        connection.onTerminalOutput = { _ in }
        connection.receiveServerTextForTesting(Self.encoded(RemoteHelloDTO(
            surface: .terminal,
            capability: RemoteCapability.interact.rawValue,
            cols: 80,
            rows: 24,
            title: "Current terminal",
            features: [RemoteWebSocketFeature.terminalHydrationBoundary.rawValue]
        )))
        connection.updateTerminalViewport(
            cols: Fixture.entryGrid.cols,
            rows: Fixture.entryGrid.rows
        )
        let requestID = try XCTUnwrap(connection.terminalHydrationRequestIDForTesting)

        connection.receiveServerTextForTesting(Self.encoded(
            RemoteTerminalReadyDTO(requestID: "stale-viewport-generation")
        ))
        XCTAssertTrue(connection.isTerminalHydrating)

        connection.receiveServerTextForTesting(Self.encoded(
            RemoteTerminalReadyDTO(requestID: requestID)
        ))
        XCTAssertFalse(connection.isTerminalHydrating)
    }

    /// A layout can briefly cross another cell count and then settle back on the grid already
    /// leased to the Mac. The duplicate lease is intentionally not sent; its newly constructed
    /// request id must not replace the id of the viewport that really did cross the wire.
    @MainActor
    func testAnUnsentDuplicateViewportCannotReplaceTheHydrationGeneration() async throws {
        let session = RemoteSessionSummaryDTO(
            id: "0e6f7d1c-5716-470b-933c-d68310644b4f",
            title: "Codex · AnotherTerminal",
            agentKind: "codex",
            surface: .terminal,
            state: .idle,
            projectName: "AnotherTerminal"
        )
        let connection = RemoteSessionConnection(
            session: session,
            client: RemoteClient(
                link: RemoteConnectionLink(
                    string: "https://viewport-generation.invalid/#fixture"
                )!
            ),
            viewportSettleDelay: Fixture.settleDelay,
            terminalHydrationQuietDelay: .seconds(2),
            terminalHydrationMaximumDelay: .seconds(2)
        )
        connection.receiveServerTextForTesting(Self.encoded(RemoteHelloDTO(
            surface: .terminal,
            capability: RemoteCapability.interact.rawValue,
            cols: 80,
            rows: 24,
            title: "Current terminal",
            features: [RemoteWebSocketFeature.terminalHydrationBoundary.rawValue]
        )))

        connection.updateTerminalViewport(cols: 48, rows: 41)
        let sentRequestID = try XCTUnwrap(connection.terminalHydrationRequestIDForTesting)
        connection.updateTerminalViewport(cols: 47, rows: 41)
        connection.updateTerminalViewport(cols: 48, rows: 41)
        try await Task.sleep(for: Fixture.settleDelay * 2)

        XCTAssertEqual(connection.terminalHydrationRequestIDForTesting, sentRequestID)
        connection.receiveServerTextForTesting(Self.encoded(
            RemoteTerminalReadyDTO(requestID: sentRequestID)
        ))
        XCTAssertFalse(connection.isTerminalHydrating)
    }

    /// The screenshot fixtures preload terminal bytes before SwiftUI mounts the representable.
    /// Taking that buffer must start the same hydration transaction as a real socket frame;
    /// otherwise the animated opening placeholder remains forever and no evidence can stabilize.
    @MainActor
    func testBufferedStaticDemoOutputCompletesHydrationAfterTheViewport() async throws {
        let connection = RemoteSessionConnection.demoTerminal()
        var received = Data()

        connection.onTerminalOutput = { received.append($0) }
        connection.updateTerminalViewport(
            cols: Fixture.entryGrid.cols,
            rows: Fixture.entryGrid.rows
        )
        try await Task.sleep(for: Fixture.staticDemoHydrationWait)

        XCTAssertFalse(received.isEmpty)
        XCTAssertFalse(connection.isTerminalHydrating)
    }

    /// SwiftUI may mount a replacement representable before UIKit dismantles the outgoing one.
    /// The old teardown must not clear the new renderer's callback or release its viewport: that
    /// leaves a healthy socket buffering typed repaints until the chat is opened yet again.
    @MainActor
    func testStaleRendererTeardownCannotDetachItsReplacement() {
        let connection = Self.demoConnection()
        connection.connect()
        let outgoing = NSObject()
        let replacement = NSObject()
        var replacementOutput = Data()

        connection.mountTerminalRenderer(outgoing, output: { _ in }, gridChange: { _, _ in })
        connection.updateTerminalViewport(
            cols: Fixture.entryGrid.cols,
            rows: Fixture.entryGrid.rows
        )
        connection.mountTerminalRenderer(
            replacement,
            output: { replacementOutput.append($0) },
            gridChange: { _, _ in }
        )

        XCTAssertFalse(connection.unmountTerminalRenderer(outgoing))
        XCTAssertTrue(connection.isTerminalRendererOwner(replacement))

        let repaint = Data("typed repaint".utf8)
        connection.receiveDemoTerminalOutput(repaint)

        XCTAssertEqual(replacementOutput.suffix(repaint.count), repaint)
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
        XCTAssertEqual(view.themeApplicationCount, 1)

        TerminalViewRepresentable.apply(Self.theme(background: "#101010"), to: view)

        XCTAssertEqual(
            view.themeApplicationCount,
            1,
            "An unchanged theme must not invalidate a single row"
        )

        TerminalViewRepresentable.apply(Self.theme(background: "#202020"), to: view)

        XCTAssertEqual(
            view.themeApplicationCount,
            2,
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
        XCTAssertEqual(view.themeApplicationCount, 1)

        TerminalViewRepresentable.apply(nil, to: view)

        XCTAssertEqual(view.themeApplicationCount, 1)
    }

    // MARK: - Private Methods

    @MainActor
    private static func demoConnection(
        hydrationQuietDelay: Duration = .milliseconds(500)
    ) -> RemoteSessionConnection {
        let session = RemoteSessionSummaryDTO(
            id: "0e6f7d1c-5716-470b-933c-d68310644b4f",
            title: "Claude Code · AnotherTerminal",
            agentKind: "claude",
            surface: .terminal,
            state: .idle,
            projectName: "AnotherTerminal"
        )
        let link = RemoteConnectionLink(string: "https://demo.threading.invalid/#terminal-lease")!
        return RemoteSessionConnection(
            session: session,
            client: RemoteClient(link: link),
            viewportSettleDelay: Fixture.settleDelay,
            terminalHydrationQuietDelay: hydrationQuietDelay,
            terminalHydrationMaximumDelay: .seconds(2)
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

    private static func encoded<T: Encodable>(_ value: T) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }
}
