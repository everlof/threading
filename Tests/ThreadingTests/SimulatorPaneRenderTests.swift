import AppKit
import XCTest
@testable import Threading

/// Captures the adopted device where it ships: in the right display pane beside a real native
/// conversation, inside the app's permanent window-chrome host. The fake ends at the simulator
/// control boundary; every visible view, split, tab and control is production UI.
@MainActor
final class SimulatorPaneRenderTests: XCTestCase {
    private enum Render {
        static let size = NSSize(width: 1_280, height: 760)
        static let panelWidth: CGFloat = 420

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let appearances: [(name: String, value: NSAppearance.Name)] = [
            ("light", .aqua),
            ("dark", .darkAqua)
        ]
    }

    func testRendersAdoptedSimulatorInRightPanel() async throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }
        AppThemePalette.set(.system)
        let deviceFrame = try makeDeviceFramePNG()

        for appearance in Render.appearances {
            let fixture = try makeFixture(
                appearance: appearance.value,
                deviceFrame: deviceFrame
            )
            defer { fixture.tearDown() }

            try await eventually {
                fixture.simulator.frameImageForTesting != nil
            }
            settle(fixture.window)

            let content = try XCTUnwrap(fixture.window.contentView)
            XCTAssertEqual(
                fixture.panel.view.bounds.width,
                Render.panelWidth,
                accuracy: 2,
                "the adopted device was not rendered at the protected right-panel width"
            )
            let representation = try XCTUnwrap(
                content.bitmapImageRepForCachingDisplay(in: content.bounds)
            )
            content.cacheDisplay(in: content.bounds, to: representation)
            let png = try XCTUnwrap(
                representation.representation(using: .png, properties: [:])
            )
            try png.write(
                to: Render.directory.appendingPathComponent(
                    "simulator-pane-system-\(appearance.name).png"
                )
            )
        }

        print("Rendered the adopted Simulator pane to \(Render.directory.path)")
    }

    private func makeFixture(
        appearance appearanceName: NSAppearance.Name,
        deviceFrame: Data
    ) throws -> SimulatorPaneRenderFixture {
        let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
        let device = SimulatorDevice(
            id: try XCTUnwrap(
                SimulatorDeviceID("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
            ),
            name: "iPhone 17 Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            family: .iPhone,
            state: .booted,
            lastBootedAt: nil
        )
        let control = SimulatorPaneRenderControl(
            device: device,
            frame: deviceFrame
        )
        let project = Project(
            name: "Threading",
            folderURL: FileManager.default.temporaryDirectory
        )
        let session = AgentSession(
            kind: .claude,
            title: "Polish onboarding",
            usesNativeUI: true
        )
        let conversation = requireConversationViewController(
            agentSession: session,
            project: project,
            customizationLookup: { _ in .empty }
        )
        applyConversationFixture(to: conversation)

        let panel = DisplayPaneController(simulatorControl: control)
        let split = SidebarSplitViewController()
        let conversationItem = NSSplitViewItem(viewController: conversation)
        conversationItem.minimumThickness = 560
        let panelItem = NSSplitViewItem(viewController: panel)
        // The real main window applies its opening width when it reveals this item. This direct
        // shell fixture has no window coordinator to perform that reveal, so hold the same
        // review width here rather than accepting NSSplitViewController's fitting-size answer.
        panelItem.minimumThickness = Render.panelWidth
        split.addSplitViewItem(conversationItem)
        split.addSplitViewItem(panelItem)

        let host = WindowChromeHostViewController(workspace: split)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Render.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentViewController = host
        window.setContentSize(Render.size)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)

        host.setTitle("Threading")
        host.setTakeoverActive(true)
        host.bandView.fixtureIsKey = true
        host.commandBandView.setLeadingControls(makeWindowControls())
        host.view.frame = NSRect(origin: .zero, size: Render.size)
        host.view.appearance = appearance
        host.view.layoutSubtreeIfNeeded()

        let dividerPosition = split.splitView.bounds.width
            - Render.panelWidth
            - split.splitView.dividerThickness
        split.splitView.setPosition(dividerPosition, ofDividerAt: 0)
        host.view.layoutSubtreeIfNeeded()

        panel.showSession(session.id)
        let simulator = panel.activateSimulator(for: session.id, deviceID: device.id)
        conversation.scrollToConversationEnd()
        AppThemeRefresh.repaint(host.view)
        settle(window)

        return SimulatorPaneRenderFixture(
            window: window,
            panel: panel,
            simulator: simulator
        )
    }

    private func applyConversationFixture(to conversation: ConversationViewController) {
        let events: [StreamEvent] = [
            .userMessage(
                "Run the onboarding flow on an iPhone and keep the device beside this chat."
            ),
            .assistantMessage(blocks: [
                .thinking(
                    "I will use the session's in-panel Simulator instead of opening another window."
                ),
                .text(
                    "The iPhone is ready in the right panel. I’ll keep using that device while I iterate."
                )
            ]),
            .turnFinished(
                text: nil,
                outcome: .completed,
                metrics: TurnMetrics(
                    duration: 6.4,
                    outputTokens: 96,
                    effort: "high",
                    contextTokens: 21_300,
                    contextWindow: 200_000
                )
            )
        ]

        for event in events {
            for change in conversation.timeline.apply(event) {
                conversation.apply(change)
            }
        }
    }

    private func makeWindowControls() -> [NSView] {
        let sidebar = ThemedIconButton(
            symbolName: "sidebar.leading",
            accessibility: L10n.string("Show or hide sidebar"),
            inkSource: .chrome
        )
        let back = ThemedIconButton(
            symbolName: "chevron.left",
            accessibility: L10n.string("Go back"),
            inkSource: .chrome
        )
        back.isEnabled = false
        let forward = ThemedIconButton(
            symbolName: "chevron.right",
            accessibility: L10n.string("Go forward"),
            inkSource: .chrome
        )
        forward.isEnabled = false
        return [sidebar, back, forward]
    }

    private func settle(_ window: NSWindow) {
        guard let content = window.contentView else { return }
        AppThemeRefresh.repaint(content)
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        window.makeFirstResponder(nil)
    }

    /// A fixed, legible phone framebuffer. Its job is to prove scaling, clipping and chrome;
    /// it does not replace the product UI around it with a mock.
    private func makeDeviceFramePNG() throws -> Data {
        let size = NSSize(width: 393, height: 852)
        let image = NSImage(size: size)
        image.lockFocus()

        let bounds = NSRect(origin: .zero, size: size)
        let gradient = try XCTUnwrap(NSGradient(
            starting: NSColor(red: 0.09, green: 0.14, blue: 0.29, alpha: 1),
            ending: NSColor(red: 0.23, green: 0.13, blue: 0.43, alpha: 1)
        ))
        gradient.draw(in: bounds, angle: 90)

        drawText(
            "9:41",
            at: NSPoint(x: 28, y: 814),
            size: 15,
            weight: .semibold,
            color: .white
        )
        drawText(
            "Welcome back",
            at: NSPoint(x: 28, y: 700),
            size: 30,
            weight: .bold,
            color: .white
        )
        drawText(
            "Your workspace is ready.",
            at: NSPoint(x: 28, y: 668),
            size: 17,
            weight: .regular,
            color: NSColor.white.withAlphaComponent(0.72)
        )

        let card = NSBezierPath(
            roundedRect: NSRect(x: 24, y: 420, width: 345, height: 190),
            xRadius: 24,
            yRadius: 24
        )
        NSColor.white.withAlphaComponent(0.13).setFill()
        card.fill()
        drawText(
            "TODAY",
            at: NSPoint(x: 48, y: 558),
            size: 12,
            weight: .bold,
            color: NSColor.white.withAlphaComponent(0.62)
        )
        drawText(
            "3 focused tasks",
            at: NSPoint(x: 48, y: 512),
            size: 24,
            weight: .semibold,
            color: .white
        )
        drawText(
            "Onboarding · 8 min",
            at: NSPoint(x: 48, y: 468),
            size: 16,
            weight: .regular,
            color: NSColor.white.withAlphaComponent(0.74)
        )

        let button = NSBezierPath(
            roundedRect: NSRect(x: 24, y: 328, width: 345, height: 58),
            xRadius: 18,
            yRadius: 18
        )
        NSColor(red: 1, green: 0.54, blue: 0.25, alpha: 1).setFill()
        button.fill()
        drawText(
            "Continue",
            at: NSPoint(x: 151, y: 347),
            size: 17,
            weight: .semibold,
            color: NSColor(red: 0.12, green: 0.08, blue: 0.13, alpha: 1)
        )
        image.unlockFocus()

        let representation = try XCTUnwrap(
            NSBitmapImageRep(data: image.tiffRepresentation ?? Data())
        )
        return try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )
    }

    private func drawText(
        _ text: String,
        at point: NSPoint,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color
            ]
        ).draw(at: point)
    }

    private func eventually(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for the adopted Simulator frame.")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

@MainActor
private struct SimulatorPaneRenderFixture {
    let window: NSWindow
    let panel: DisplayPaneController
    let simulator: SimulatorPaneViewController

    func tearDown() {
        simulator.terminate()
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }
}

private actor SimulatorPaneRenderControl: SimulatorControlling {
    private let device: SimulatorDevice
    private let frame: Data

    init(device: SimulatorDevice, frame: Data) {
        self.device = device
        self.frame = frame
    }

    func availableDevices() async throws -> [SimulatorDevice] { [device] }

    func prepare(deviceID: SimulatorDeviceID?) async throws -> SimulatorDeviceLease {
        SimulatorDeviceLease(device: device, bootOwnership: .user)
    }

    func installAndLaunch(
        applicationURL: URL,
        bundleIdentifier: String,
        on deviceID: SimulatorDeviceID,
        arguments: [String]
    ) async throws -> SimulatorLaunchReceipt {
        SimulatorLaunchReceipt(
            deviceID: deviceID,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: nil
        )
    }

    func screenshot(of deviceID: SimulatorDeviceID) async throws -> Data { frame }

    func release(_ lease: SimulatorDeviceLease) async throws {}
}
