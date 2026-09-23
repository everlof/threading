import AppKit
import ThreadingRemoteKit
import ThreadingSimulatorKit
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
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
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

    func testRendersAdoptedSimulatorInRightPanel() throws {
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

            eventually {
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
            var representation = try XCTUnwrap(
                content.bitmapImageRepForCachingDisplay(in: content.bounds)
            )
            representation = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: representation)
            let png = try XCTUnwrap(
                representation.representation(using: .png, properties: [:])
            )
            try png.write(
                to: Render.directory.appendingPathComponent(
                    "simulator-pane-system-\(appearance.name).png"
                )
            )

            let capture = try XCTUnwrap(findCaptureButton(in: content))
            let originalTitle = capture.accessibilityTitle()
            sendModifiers(.control, to: fixture.window)
            XCTAssertEqual(capture.accessibilityTitle(), L10n.string("Copy Snapshot"))
            XCTAssertEqual(capture.toolTip, L10n.string("Copy Snapshot"))
            settle(fixture.window)
            representation = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: representation)
            try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent(
                    "simulator-pane-copy-system-\(appearance.name).png"
                )
            )
            sendModifiers([], to: fixture.window)
            XCTAssertEqual(capture.accessibilityTitle(), originalTitle)
            sendModifiers(.option, to: fixture.window)
            XCTAssertEqual(capture.accessibilityTitle(), originalTitle)
            sendModifiers([], to: fixture.window)

            fixture.simulator.setAnnotatingNotes(true)
            settle(fixture.window)
            representation = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: representation)
            try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent(
                    "simulator-pane-annotating-system-\(appearance.name).png"
                )
            )
            fixture.simulator.setAnnotatingNotes(false)

            let screen = try XCTUnwrap(findView(SimulatorScreenView.self, in: content))
            XCTAssertFalse(screen.isAnnotatingNotes)
            let location = screen.convert(CGPoint(x: screen.imageRect.midX, y: screen.imageRect.midY), to: nil)
            let click = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: location, modifierFlags: .option,
                timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
            screen.mouseDown(with: click)
            XCTAssertFalse(screen.isAnnotatingNotes, "A quick note must not leave annotation mode enabled")
            let editor = try XCTUnwrap(findView(BrowserAnnotationEditor.self, in: content))
            XCTAssertEqual(screen.noteMarks.count, 1)
            settle(fixture.window)
            XCTAssertEqual(fixture.panel.view.bounds.width, Render.panelWidth, accuracy: 2,
                           "Adding a note must not widen the simulator pane")
            representation = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: representation)
            try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent(
                    "simulator-pane-quick-note-system-\(appearance.name).png"
                )
            )
            editor.onCancel?()
            XCTAssertTrue(screen.noteMarks.isEmpty)
        }

        print("Rendered the adopted Simulator pane to \(Render.directory.path)")
    }

    /// The Test Notification tab beside the same conversation, in the states a person meets:
    /// filled in from an agent's request in each theme, a refused request, and a shared chat
    /// whose agent linked an attachment — the one case that shows the recipient and tap rows.
    func testRendersNotificationTestInRightPanel() throws {
        try FileManager.default.createDirectory(
            at: Render.directory, withIntermediateDirectories: true
        )
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }
        let frame = try makeDeviceFramePNG()
        let variants: [(name: String, theme: AppTheme, appearance: NSAppearance.Name)] = [
            ("system-light", .system, .aqua),
            ("system-dark", .system, .darkAqua),
            ("cyberpunk", try XCTUnwrap(AppThemeLibrary.stock.first { $0.name == "Cyberpunk" }), .darkAqua),
            ("swiss", try XCTUnwrap(AppThemeLibrary.stock.first { $0.name == "Swiss Minimalist" }), .aqua)
        ]
        let request = NotifyUserArguments(
            title: "BT001 watch test",
            message: "Check whether your Kronaby moves its hands and vibrates.",
            recipient: "owner",
            delivery: "ios"
        )

        func capture(_ fixture: SimulatorPaneRenderFixture, as name: String) throws {
            settle(fixture.window)
            let content = try XCTUnwrap(fixture.window.contentView)
            let representation = try XCTUnwrap(
                content.bitmapImageRepForCachingDisplay(in: content.bounds)
            )
            content.cacheDisplay(in: content.bounds, to: representation)
            try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent("notification-test-\(name).png")
            )
            // A long refusal once pushed the panel across half the window to keep its status on
            // one line; the form wraps inside the width the panel was given.
            XCTAssertEqual(fixture.panel.view.bounds.width, Render.panelWidth, accuracy: 2, name)
            XCTAssertEqual(content.bounds.width, Render.size.width, accuracy: 1, name)
        }

        for variant in variants {
            AppThemePalette.set(variant.theme)
            let fixture = try makeFixture(appearance: variant.appearance, deviceFrame: frame)
            defer { fixture.tearDown() }
            let sessionID = try XCTUnwrap(fixture.panel.currentSessionID)
            let host = RenderNotificationTestHost()
            host.notificationTests.record(
                request,
                outcome: .queued("Notification queued for the owner."),
                origin: .agent,
                for: sessionID
            )
            fixture.panel.notificationTestHost = host
            let form = try XCTUnwrap(fixture.panel.activateNotificationTest(for: sessionID))
            XCTAssertFalse(form.showsRecipientChoice)
            XCTAssertFalse(form.showsTargetChoice)
            AppThemeRefresh.repaint(fixture.window.contentView!)
            try capture(fixture, as: variant.name)

            guard variant.name == "system-light" else { continue }
            host.notificationTests.record(
                request,
                outcome: .refused(
                    "No opted-in phone has a live connection or usable push registration. "
                        + "Open Threading on the phone to refresh notification delivery."
                ),
                origin: .agent,
                for: sessionID
            )
            try capture(fixture, as: "unavailable-system-light")

            host.memberNames = ["Anna", "Ben"]
            host.targetKinds = ["report": .attachment]
            host.notificationTests.record(
                NotifyUserArguments(
                    title: "Report ready",
                    message: "The accessibility report is attached.",
                    recipient: "Anna",
                    delivery: "both",
                    targetRef: "report"
                ),
                outcome: .queued("Notification queued for the Mac and Anna."),
                origin: .agent,
                for: sessionID
            )
            XCTAssertTrue(form.showsRecipientChoice)
            XCTAssertTrue(form.showsTargetChoice)
            try capture(fixture, as: "shared-system-light")
        }
    }

    private func sendModifiers(_ modifiers: NSEvent.ModifierFlags, to window: NSWindow) {
        let event = NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 59
        )!
        NSApp.sendEvent(event)
    }

    private func findView<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.findView(type, in: $0) }.first
    }

    private func findCaptureButton(in view: NSView) -> ThemedIconButton? {
        if let button = view as? ThemedIconButton,
           button.accessibilityIdentifier() == "simulator.capture" { return button }
        return view.subviews.lazy.compactMap { self.findCaptureButton(in: $0) }.first
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
        let image = try XCTUnwrap(NSImage(data: deviceFrame))
        var imageRect = NSRect(origin: .zero, size: image.size)
        let liveFrame = try XCTUnwrap(
            image.cgImage(forProposedRect: &imageRect, context: nil, hints: nil)
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

        let panel = DisplayPaneController(
            simulatorControl: control,
            simulatorStreamCoordinator: SimulatorPaneRenderStreamCoordinator(frame: liveFrame)
        )
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
        window.animationBehavior = .none
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
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for the adopted Simulator frame.")
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
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

/// The evidence fixture replaces only the CoreSimulator transport boundary. Its frame still
/// travels through the production live-stream event path, decoder-independent view model and
/// interactive screen view, so the capture proves the shipped adopted surface rather than the
/// slower screenshot fallback.
private final class SimulatorPaneRenderStreamCoordinator:
    SimulatorLiveStreamCoordinating,
    @unchecked Sendable
{
    private let session: SimulatorPaneRenderStreamSession

    init(frame: CGImage) {
        session = SimulatorPaneRenderStreamSession(frame: frame)
    }

    func openStream(
        for deviceID: SimulatorDeviceID
    ) async throws -> any SimulatorLiveStreamSession {
        session
    }
}

private final class SimulatorPaneRenderStreamSession:
    SimulatorLiveStreamSession,
    @unchecked Sendable
{
    let events: AsyncStream<SimulatorLiveStreamEvent>
    private let continuation: AsyncStream<SimulatorLiveStreamEvent>.Continuation

    init(frame: CGImage) {
        let pair = AsyncStream<SimulatorLiveStreamEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        events = pair.stream
        continuation = pair.continuation
        continuation.yield(.ready(
            backend: .direct(codec: .h264),
            capabilities: SimulatorBridgeCapabilities(
                codecs: [.h264, .jpeg],
                supportsTouch: true,
                supportsKeyboard: true,
                supportsButtons: true,
                maximumFramesPerSecond: 30
            ),
            coreSimulatorVersion: "evidence",
            simulatorKitVersion: "evidence"
        ))
        continuation.yield(.frame(SimulatorLiveFrame(
            sequence: 1,
            image: frame,
            codec: .h264,
            presentationTimeNanoseconds: 0
        )))
    }

    func setVisible(_ visible: Bool) {}
    func sendInput(_ input: SimulatorBridgeInput) async throws {}
    func stop() { continuation.finish() }
}

/// Answers the Test Notification tab for a render: who is in the chat and what a link opens are
/// the fixture's choice, and nothing is sent.
@MainActor
private final class RenderNotificationTestHost: NotificationTestHosting {
    let notificationTests = NotificationTestLedger()
    var memberNames: [String] = []
    var targetKinds: [String: RemoteNotificationDestinationDTO.Kind] = [:]

    func sendTestNotification(
        _ arguments: NotifyUserArguments,
        for sessionID: SessionID
    ) -> RequestedNotificationOutcome {
        .queued("Notification queued for the owner.")
    }

    func notificationRecipientNames(for sessionID: SessionID) -> [String] { memberNames }

    func notificationTargetKind(
        _ reference: String,
        for sessionID: SessionID
    ) -> RemoteNotificationDestinationDTO.Kind? {
        targetKinds[reference]
    }
}
