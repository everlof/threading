import Combine
import SwiftTerm
import SwiftUI
import ThreadingRemoteKit
import UIKit
import XCTest
@testable import ThreadingMobile

/// Exercise the representable's actual construction and first layout. Lease-settlement tests
/// start with a grid that is already authoritative; they cannot catch a screen-sized temporary
/// frame escaping while SwiftUI constructs a terminal for a warm interactive connection.
@MainActor
final class RemoteTerminalInitialViewportTests: XCTestCase {
    private enum Fixture {
        static let contentSize = CGSize(width: 393, height: 540)
        static let settleDelay: Duration = .milliseconds(40)
        static let observationDelay: Duration = .milliseconds(300)
        static let fontSize: Double = 10
    }

    func testAnInteractiveConnectionLeasesOnlyTheFirstLaidOutContentGrid() async throws {
        let connection = makeConnection()
        connection.connect()
        defer { connection.disconnect() }
        let connected = await eventually { connection.phase == .connected }
        XCTAssertTrue(connected)

        // A parked connection retains its interactive capability when the replacement view is
        // constructed. Delivering the ordinary demo hello before mounting reproduces that state.
        var appliedGrids: [String] = []
        let observation = connection.$terminalRows.dropFirst().sink { [weak connection] rows in
            guard let connection else { return }
            appliedGrids.append("\(connection.terminalColumns)x\(rows)")
        }
        defer { observation.cancel() }

        let host = makeHost(connection: connection)
        defer {
            host.window.isHidden = true
            host.window.rootViewController = nil
        }
        host.window.layoutIfNeeded()
        host.controller.view.layoutIfNeeded()
        let mounted = await eventually { self.terminalLayout(in: host.controller.view) != nil }
        XCTAssertTrue(mounted)
        let layout = try XCTUnwrap(terminalLayout(in: host.controller.view))
        let revealed = await eventually { !connection.isTerminalHydrating }
        XCTAssertTrue(revealed)
        try await Task.sleep(for: Fixture.observationDelay)

        XCTAssertEqual(layout.bounds.width, Fixture.contentSize.width, accuracy: 0.5)
        XCTAssertEqual(layout.bounds.height, Fixture.contentSize.height, accuracy: 0.5)
        let actual = layout.terminalView.terminalDimensions
        XCTAssertEqual(
            appliedGrids, ["\(actual.cols)x\(actual.rows)"],
            "Construction must not lease UIScreen bounds before the actual chat content is laid out"
        )
        XCTAssertTrue(connection.isTerminalRendererOwner(layout.terminalView))
        XCTAssertTrue(connection.hasPresentedTerminalOutput)
    }

    func testQueuedSizeFromAReplacedRendererCannotLeaseTheConnection() async throws {
        let connection = makeConnection()
        connection.connect()
        defer { connection.disconnect() }
        let connected = await eventually { connection.phase == .connected }
        XCTAssertTrue(connected)
        let initialGrid = "\(connection.terminalColumns)x\(connection.terminalRows)"
        let terminal = RemoteTerminalView(
            frame: CGRect(origin: .zero, size: Fixture.contentSize),
            font: .monospacedSystemFont(ofSize: CGFloat(Fixture.fontSize), weight: .regular)
        )
        defer { _ = terminal.updateUiClosed() }
        let layout = RemoteTerminalLayoutView(
            frame: terminal.frame,
            terminalView: terminal,
            contentInset: 0
        )
        let coordinator = TerminalViewRepresentable.Coordinator(
            connection: connection,
            allowsInput: true,
            keyBridge: TerminalKeyBridge(),
            initialScrollProgress: nil,
            onScrollProgress: { _ in }
        )
        coordinator.attach(to: terminal, in: layout)
        terminal.terminalDelegate = coordinator
        coordinator.bindRenderer(to: connection)
        terminal.setUsesLocalViewport(true)
        let replacement = NSObject()
        connection.mountTerminalRenderer(
            replacement,
            output: { _ in },
            gridChange: { _, _ in }
        )

        // The earlier resize's main-actor delegate delivery is still queued. The new renderer
        // now owns this connection and has not supplied its own viewport yet.
        try await Task.sleep(for: Fixture.observationDelay)

        XCTAssertTrue(connection.isTerminalRendererOwner(replacement))
        XCTAssertEqual("\(connection.terminalColumns)x\(connection.terminalRows)", initialGrid)
        coordinator.detach()
    }

    func testViewOnlyReplayKeepsTheHostGridThroughTheFirstPhoneLayout() async throws {
        let connection = makeConnection()
        connection.receiveServerTextForTesting(String(decoding: try JSONEncoder().encode(
            RemoteHelloDTO(
                surface: .terminal,
                capability: .view,
                cols: 141,
                rows: 43,
                title: "View-only fixture",
                features: []
            )
        ), as: UTF8.self))
        connection.receiveServerTerminalOutputForTesting(Data("\u{1B}[43;141H@".utf8))
        defer { connection.disconnect() }
        let host = makeHost(connection: connection)
        defer {
            host.window.isHidden = true
            host.window.rootViewController = nil
        }
        host.window.layoutIfNeeded()
        host.controller.view.layoutIfNeeded()
        let mounted = await eventually { self.terminalLayout(in: host.controller.view) != nil }
        XCTAssertTrue(mounted)
        let layout = try XCTUnwrap(terminalLayout(in: host.controller.view))
        try await Task.sleep(for: Fixture.observationDelay)

        XCTAssertFalse(layout.terminalView.usesLocalViewport)
        XCTAssertEqual(layout.terminalView.terminalDimensions.cols, 141)
        XCTAssertEqual(layout.terminalView.terminalDimensions.rows, 43)
        XCTAssertTrue(connection.hasPresentedTerminalOutput)
    }

    func testKeypressProbeTraversesProductionEchoDrawAndDisplayOpportunity() async throws {
        let host = try await makeProbeHost()
        defer { host.connection.disconnect(); host.window.isHidden = true }
        var records: [(RemoteDiagnosticEvent, String, String, String, String)] = []
        host.view.inputLatencyProbe.record = { records.append(($0, $1, $2, $3, $4)) }

        XCTAssertGreaterThan(host.view.diagnostics.renders, 0, "fixture must actually draw on screen")
        host.view.insertText("Q")
        let completed = await eventually {
            records.contains { $0.0 == .terminalInputVisualProbeEnded }
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(records.map { $0.2 }, [
            "keypress", "send", "firstOutput", "echoParsed", "echoDrawn", "displayOpportunity",
        ])
        XCTAssertEqual(records.last?.3, "estimated")
        XCTAssertEqual(Set(records.map { $0.1 }).count, 1)
        let durations = records.compactMap { UInt64($0.4) }
        XCTAssertEqual(durations, durations.sorted())
        XCTAssertFalse(host.view.inputLatencyProbe.isPending)

        // The connection's production gate must bound a burst, not just the fixture recorder.
        for _ in 0..<100 { host.view.insertText("x") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(records.filter { $0.0 == .terminalInputVisualProbeStarted }.count, 1)
    }

    func testUnrelatedOutputCannotCompleteTheExpectedCellProbeAndUnmountCancels() async throws {
        let host = try await makeProbeHost()
        defer { host.connection.disconnect(); host.window.isHidden = true }
        var results: [String] = []
        host.view.inputLatencyProbe.record = { event, _, _, result, _ in
            if event == .terminalInputVisualProbeEnded { results.append(result) }
        }
        XCTAssertTrue(host.view.inputLatencyProbe.begin(
            ascii: 81, requestID: "fixture", startedAt: CACurrentMediaTime(), view: host.view
        ))
        host.view.inputLatencyProbe.sent(requestID: "fixture")
        // The same glyph on another row is not the character at the input cursor.
        host.view.feed(text: "\u{1b}[2;1HQ")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(results.isEmpty)
        host.view.removeFromSuperview()
        XCTAssertEqual(results, ["unmounted"])
        host.view.feed(text: "\u{1b}[1;1HQ")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(results, ["unmounted"], "late draws cannot complete a retired sample")
    }

    func testEchoProbeRejectsPreexistingCharacterAndDoesNotMatchBeforeSend() async throws {
        let host = try await makeProbeHost()
        defer { host.connection.disconnect(); host.window.isHidden = true }
        host.view.feed(text: "Q\r")
        XCTAssertFalse(host.view.inputLatencyProbe.begin(
            ascii: 81, requestID: "preexisting", startedAt: CACurrentMediaTime(), view: host.view
        ))
        host.view.feed(text: "\u{1b}[2J\u{1b}[H")
        var phases: [String] = []
        host.view.inputLatencyProbe.record = { _, _, phase, _, _ in phases.append(phase) }
        XCTAssertTrue(host.view.inputLatencyProbe.begin(
            ascii: 81, requestID: "unsent", startedAt: CACurrentMediaTime(), view: host.view
        ))
        host.view.feed(text: "Q")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(phases, ["keypress"])
        host.view.inputLatencyProbe.cancel()
    }

    func testDelayedEchoIsIncludedInTheDrawAndDisplayTimings() async throws {
        let host = try await makeProbeHost()
        defer { host.connection.disconnect(); host.window.isHidden = true }
        var durations: [String: UInt64] = [:]
        host.view.inputLatencyProbe.record = { _, _, phase, _, duration in
            durations[phase] = UInt64(duration)
        }
        XCTAssertTrue(host.view.inputLatencyProbe.begin(
            ascii: 81, requestID: "delayed", startedAt: CACurrentMediaTime(), view: host.view
        ))
        host.view.inputLatencyProbe.sent(requestID: "delayed")
        try await Task.sleep(for: .milliseconds(100))
        host.view.feed(text: "Q")
        let completed = await eventually { durations["displayOpportunity"] != nil }
        XCTAssertTrue(completed)
        let parsed = try XCTUnwrap(durations["echoParsed"])
        let drawn = try XCTUnwrap(durations["echoDrawn"])
        let displayed = try XCTUnwrap(durations["displayOpportunity"])
        XCTAssertGreaterThanOrEqual(parsed, 100)
        XCTAssertGreaterThanOrEqual(drawn, parsed)
        XCTAssertGreaterThanOrEqual(displayed, drawn)
    }

    func testMissingEchoTimesOutAndBackgroundRetiresAnObservation() async throws {
        let host = try await makeProbeHost()
        defer { host.connection.disconnect(); host.window.isHidden = true }
        let probe = MobileTerminalInputLatencyProbe(timeout: .milliseconds(30))
        var results: [String] = []
        probe.record = { event, _, _, result, _ in
            if event == .terminalInputVisualProbeEnded { results.append(result) }
        }
        XCTAssertTrue(probe.begin(ascii: 81, requestID: "timeout",
                                 startedAt: CACurrentMediaTime(), view: host.view))
        let timedOut = await eventually { !probe.isPending }
        XCTAssertTrue(timedOut)
        XCTAssertEqual(results, ["unmatchedTimeout"])
        XCTAssertTrue(probe.begin(ascii: 81, requestID: "background",
                                 startedAt: CACurrentMediaTime(), view: host.view))
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertFalse(probe.isPending)
        XCTAssertEqual(results, ["unmatchedTimeout", "backgrounded"])
    }

    private func makeProbeHost() async throws -> (
        connection: RemoteSessionConnection, window: UIWindow, view: RemoteTerminalView
    ) {
        let connection = makeConnection()
        connection.connect()
        let connected = await eventually { connection.phase == .connected }
        XCTAssertTrue(connected)
        let host = makeHost(connection: connection)
        host.window.layoutIfNeeded()
        host.controller.view.layoutIfNeeded()
        let ready = await eventually {
            self.terminalLayout(in: host.controller.view) != nil && !connection.isTerminalHydrating
        }
        XCTAssertTrue(ready)
        let view = try XCTUnwrap(terminalLayout(in: host.controller.view)?.terminalView)
        view.feed(text: "\u{1b}[2J\u{1b}[H")
        try await Task.sleep(for: .milliseconds(100))
        return (connection, host.window, view)
    }

    private func makeConnection() -> RemoteSessionConnection {
        RemoteSessionConnection(
            session: RemoteSessionSummaryDTO(
                id: "f90f27ce-67ce-4904-a885-5f29644b22fe",
                title: "Initial viewport fixture",
                agentKind: "codex",
                surface: .terminal,
                state: .idle,
                projectName: "Fixture"
            ),
            client: RemoteClient(link: RemoteConnectionLink(
                string: "https://demo.threading.invalid/#initial-viewport"
            )!),
            viewportSettleDelay: Fixture.settleDelay
        )
    }

    private func makeHost(connection: RemoteSessionConnection) -> (
        window: UIWindow,
        controller: UIViewController
    ) {
        let content = TerminalViewRepresentable(
            connection: connection,
            theme: connection.terminalTheme,
            chromeTheme: RemoteThemePalette(nil),
            allowsDirectInput: true,
            keyBridge: TerminalKeyBridge(),
            fontSize: Fixture.fontSize,
            onFontSizeChange: { _ in },
            initialScrollProgress: nil,
            onScrollProgress: { _ in },
            focusesOnCreation: false
        )
        let hosting = UIHostingController(rootView: content)
        let controller = UIViewController()
        controller.addChild(hosting)
        controller.view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            hosting.view.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
            hosting.view.widthAnchor.constraint(equalToConstant: Fixture.contentSize.width),
            hosting.view.heightAnchor.constraint(equalToConstant: Fixture.contentSize.height),
        ])
        hosting.didMove(toParent: controller)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        window.frame = UIScreen.main.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return (window, controller)
    }

    private func terminalLayout(in view: UIView) -> RemoteTerminalLayoutView? {
        if let terminal = view as? RemoteTerminalLayoutView { return terminal }
        return view.subviews.lazy.compactMap { self.terminalLayout(in: $0) }.first
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
