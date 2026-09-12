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
        let window = UIWindow(frame: UIScreen.main.bounds)
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
