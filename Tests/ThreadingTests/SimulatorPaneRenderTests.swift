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
        try renderUnavailableSimulator()
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
            XCTAssertEqual(
                fixture.simulator.logsButtonForTesting.accessibilityTitle(),
                L10n.string("Open Device Logs in Bottom Pane")
            )
            XCTAssertNotNil(
                fixture.simulator.logsButtonForTesting.window,
                "the Device Logs shortcut must ship in the visible Simulator toolbar"
            )
            let soloHeader = try XCTUnwrap(fixture.panel.currentSimulatorWorkspace?.headerForTesting)
            XCTAssertEqual(soloHeader.leadingViews.map { $0.accessibilityIdentifier() },
                           ["simulator.device", "simulator.workspace.add"],
                           "One device has nothing to arrange: the header is the single pane's row plus Add.")
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
            XCTAssertEqual(capture.accessibilityTitle(), L10n.string("Copy Screenshot"))
            XCTAssertEqual(capture.toolTip, L10n.string("Copy Screenshot"))
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
            let band = try XCTUnwrap(fixture.simulator.annotationBandForTesting)
            let screenFrame = fixture.simulator.screenViewForTesting.convert(
                fixture.simulator.screenViewForTesting.bounds, to: content
            )
            let bandFrame = band.convert(band.bounds, to: content)
            XCTAssertFalse(
                bandFrame.insetBy(dx: 1, dy: 1).intersects(screenFrame),
                "The annotation band must push the device down, not cover it"
            )
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

            // Recording, with touches drawn in a chosen style: the badge, the screen's ring and
            // the status line all say so.
            fixture.simulator.showRecordingPresentationForTesting(elapsedSeconds: 72)
            screen.touchStyle = SimulatorTouchStyle(color: .yellow, size: .large, showsTrail: true)
            screen.touchIndicators = Self.touchFixture
            settle(fixture.window)
            let badge = fixture.simulator.recordingBadgeForTesting
            XCTAssertFalse(badge.isHidden)
            XCTAssertEqual(badge.title, L10n.format("REC %@", "1:12"))
            XCTAssertTrue(
                screen.bounds.contains(badge.convert(badge.bounds, to: screen)),
                "The recording badge must sit over the device it is recording"
            )
            XCTAssertTrue(screen.isRecording)
            XCTAssertEqual(fixture.simulator.statusForTesting, L10n.format("Recording %@", "1:12"))
            representation = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: representation)
            try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent(
                    "simulator-pane-recording-system-\(appearance.name).png"
                )
            )
            fixture.simulator.showRecordingPresentationForTesting(elapsedSeconds: nil)
            screen.touchIndicators = nil
            XCTAssertTrue(badge.isHidden)
            XCTAssertFalse(screen.isRecording)

            // The device's own right-click menu.
            let secondary = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: location, modifierFlags: [],
                timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
            screen.rightMouseDown(with: secondary)
            settle(fixture.window)
            representation = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: representation)
            try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent(
                    "simulator-pane-menu-system-\(appearance.name).png"
                )
            )
        }

        try renderWorkspaceLayouts()
        print("Rendered the adopted Simulator pane to \(Render.directory.path)")
    }

    /// One app on both platforms: an iPhone and a Pixel side by side. Each member's hardware row is
    /// its own platform's, the tab names both, and selecting the Android member swaps the shared
    /// row to Back/Home/Overview/Power/volume/rotate without a target escaping it.
    func testRendersAndroidBesideIOSInTheWorkspace() throws {
        for (name, appearance) in Render.appearances {
            AppThemePalette.set(.system)
            let fixture = try makeFixture(appearance: appearance, deviceFrame: try makeDeviceFramePNG(),
                                          additionalDeviceCount: 1, androidSecond: true)
            defer { fixture.tearDown() }
            let workspace = try XCTUnwrap(fixture.panel.currentSimulatorWorkspace)
            eventually { workspace.simulators.allSatisfy { $0.frameImageForTesting != nil } }
            XCTAssertEqual(workspace.state.members.compactMap(\.deviceID?.platform), [.iOSSimulator, .androidEmulator])
            workspace.select(workspace.state.members[1].id)
            settle(fixture.window)
            let hardware = workspace.selectedSimulator.workspaceHardwareControls
            let shown = hardware.subviews.filter { !$0.isHidden }.map { $0.accessibilityIdentifier() }
            XCTAssertEqual(shown, ["simulator.button.back", "simulator.button.home", "simulator.button.overview",
                                   "simulator.button.power", "simulator.button.volumeDown", "simulator.button.volumeUp",
                                   "simulator.button.rotateLeft", "simulator.button.rotateRight", "simulator.appearance"])
            for button in hardware.subviews where !button.isHidden {
                XCTAssertTrue(hardware.bounds.contains(button.frame), "A hardware target escaped its shared viewport.")
            }
            assertTilesHugTheirDevices(workspace, compact: false)
            let root = try XCTUnwrap(fixture.window.contentView)
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent("simulator-pane-workspace-android-\(name).png"))

            // Pointing at the Pixel brings its ✕ over the screen's top corner, clear of its name.
            let pixel = workspace.simulators[1]
            let remove = try XCTUnwrap(firstSubview(of: pixel.view, identifier: "simulator.workspace.memberRemove"))
            XCTAssertEqual(remove.alphaValue, 0)
            Design.Motion.reduceMotionOverrideForTesting = true
            defer { Design.Motion.reduceMotionOverrideForTesting = nil }
            pixel.workspaceTileIsHoveredForTesting = true
            settle(fixture.window)
            XCTAssertEqual(remove.alphaValue, 1)
            XCTAssertTrue(pixel.view.bounds.contains(remove.frame), "the ✕ stays inside its tile")
            let title = try XCTUnwrap(firstSubview(of: pixel.view, identifier: "simulator.workspace.member"))
            XCTAssertFalse(title.convert(title.bounds, to: pixel.view).intersects(remove.frame), "the name gives way to the ✕")
            XCTAssertEqual(firstSubview(of: workspace.simulators[0].view, identifier: "simulator.workspace.memberRemove")?
                .alphaValue, 0, "only the tile under the pointer shows it")
            try write(fixture.window, "simulator-pane-workspace-remove-\(name)")
            pixel.workspaceTileIsHoveredForTesting = false
            workspace.select(workspace.state.members[0].id)
            settle(fixture.window)
            let iOSShown = workspace.selectedSimulator.workspaceHardwareControls.subviews.filter { !$0.isHidden }
                .map { $0.accessibilityIdentifier() }
            XCTAssertEqual(iOSShown, ["simulator.button.home", "simulator.button.lock", "simulator.button.side",
                                      "simulator.button.volumeDown", "simulator.button.volumeUp", "simulator.appearance"],
                           "the iOS member keeps exactly the row it always had")
        }
    }

    /// The Scenarios button, the band on a step and after a refusal, and the setup help, where they
    /// ship: in the right panel beside a conversation, light and dark, and at the narrowest pane.
    func testRendersScenariosInTheWorkspace() throws {
        let checkout = FileManager.default.temporaryDirectory
            .appendingPathComponent("scenario-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".threading"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: checkout) }
        try Data(SimulatorScenarioGuide.example.utf8).write(to: checkout.appendingPathComponent(".threading/scenarios.json"))

        let variants: [(String, NSAppearance.Name, CGFloat)] = [
            ("light", .aqua, Render.panelWidth), ("dark", .darkAqua, Render.panelWidth), ("narrow", .aqua, 260),
        ]
        for (name, appearance, width) in variants {
            AppThemePalette.set(.system)
            let fixture = try makeFixture(appearance: appearance, deviceFrame: try makeDeviceFramePNG(),
                                          panelWidth: width, scenarioCheckout: checkout)
            defer { fixture.tearDown() }
            let workspace = try XCTUnwrap(fixture.panel.currentSimulatorWorkspace)
            eventually { workspace.simulators.allSatisfy { $0.frameImageForTesting != nil } }
            let header = workspace.headerForTesting
            let narrow = name == "narrow"
            XCTAssertEqual(header.leadingViews.contains { $0 === workspace.scenarioButtonForTesting }, !narrow,
                           "a narrow header keeps the device's name and offers Scenarios from its … menu")
            if narrow {
                let overflow = workspace.selectedSimulator.workspaceHeaderMenuEntries().compactMap(\.item).map(\.title)
                XCTAssertTrue(overflow.contains(L10n.string("Scenarios…")), "\(overflow)")
            }

            try run {
                _ = try await workspace.scenarios.open("order/delivery")
                _ = try await workspace.scenarios.go(to: 1)
            }
            eventually { workspace.simulators.allSatisfy { $0.frameImageForTesting != nil } }
            settle(fixture.window)
            let band = try XCTUnwrap(workspace.scenarioBandForTesting)
            XCTAssertEqual(band.title, "Order from cart to delivery")
            XCTAssertTrue(band.message.contains("Payment accepted"), band.message)
            XCTAssertEqual(band.actionControls.map(\.title),
                           [L10n.string("Back"), L10n.string("Next")] + (narrow ? [] : [L10n.string("Play")]))
            XCTAssertTrue(band.actionControls.allSatisfy(\.isEnabled))
            for button in band.actionControls {
                XCTAssertGreaterThanOrEqual(button.frame.width, button.fittingSize.width - 0.5,
                                            "\(button.title) was squeezed at \(width) points")
            }
            // Window coordinates grow upward: "under" is a smaller y.
            let canvas = workspace.canvasForTesting
            let bandFrame = band.convert(band.bounds, to: nil)
            XCTAssertLessThanOrEqual(bandFrame.maxY, header.convert(header.bounds, to: nil).minY,
                                     "The band sits under the header.")
            XCTAssertLessThanOrEqual(canvas.convert(canvas.bounds, to: nil).maxY, bandFrame.minY,
                                     "The band pushes the devices down rather than covering them.")
            for control in band.actionControls + [band.dismissControl].compactMap({ $0 }) {
                XCTAssertTrue(band.bounds.contains(control.convert(control.bounds, to: band)),
                              "A band control escaped the band at \(width) points.")
            }
            for view in header.leadingViews + header.trailingViews {
                XCTAssertTrue(header.bounds.contains(view.convert(view.bounds, to: header)),
                              "A header control escaped the header at \(width) points.")
            }
            try write(fixture.window, "simulator-scenarios-step-\(name)")

            if name == "light" {
                try run { _ = try await workspace.scenarios.go(to: 0) }
                settle(fixture.window)
                XCTAssertEqual(workspace.scenarioBandForTesting?.actionControls.map(\.isEnabled), [false, true, true],
                               "Back rests at the first step")
                try run {
                    await fixture.control.refuseLaunches(.applicationNotInstalled("com.example.shop"))
                    _ = try await workspace.scenarios.open("home/empty")
                }
                settle(fixture.window)
                let failure = try XCTUnwrap(workspace.scenarioBandForTesting)
                XCTAssertTrue(failure.message.contains("com.example.shop"), failure.message)
                XCTAssertEqual(failure.actionControls.map(\.title), [L10n.string("Try Again")])
                try write(fixture.window, "simulator-scenarios-failure-light")
            }
        }

        for (name, appearance) in Render.appearances {
            for (state, status) in [
                ("missing", SimulatorScenarioHelpViewController.Status.missing(checkout.appendingPathComponent(".threading/scenarios.json"))),
                ("loaded", .loaded(checkout.appendingPathComponent(".threading/scenarios.json"), scenarios: 3, problems: 0)),
            ] {
                let help = SimulatorScenarioHelpViewController(status: status)
                let drawing = try XCTUnwrap(NSAppearance(named: appearance))
                help.view.appearance = drawing
                help.view.layoutSubtreeIfNeeded()
                help.view.setFrameSize(help.view.fittingSize)
                help.view.layoutSubtreeIfNeeded()
                // The popover draws the panel's ground; stand in for it so the picture shows the
                // text on the surface it ships on rather than on a transparent sheet.
                let ground = NSView(frame: help.view.bounds)
                ground.wantsLayer = true
                ground.appearance = drawing
                drawing.performAsCurrentDrawingAppearance {
                    ground.layer?.backgroundColor = Design.Surface.floating.cgColor
                }
                ground.addSubview(help.view)
                AppThemeRefresh.repaint(help.view)
                let bitmap = try XCTUnwrap(ground.bitmapImageRepForCachingDisplay(in: ground.bounds))
                ground.cacheDisplay(in: ground.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: Render.directory.appendingPathComponent("simulator-scenarios-help-\(state)-\(name).png"))
            }
        }
    }

    /// Runs async work to completion while the run loop turns, as the rest of these synchronous
    /// render fixtures do, so the device stream keeps delivering frames meanwhile.
    private func run(_ body: @escaping @MainActor () async throws -> Void) throws {
        var outcome: Result<Void, Error>?
        Task { @MainActor in
            do { try await body(); outcome = .success(()) } catch { outcome = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(5)
        while outcome == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        try XCTUnwrap(outcome, "the work did not finish").get()
    }

    private func firstSubview(of view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        return view.subviews.lazy.compactMap { self.firstSubview(of: $0, identifier: identifier) }.first
    }

    private func write(_ window: NSWindow, _ name: String) throws {
        let root = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try FileManager.default.createDirectory(at: Render.directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
            to: Render.directory.appendingPathComponent("\(name).png"))
    }

    private func renderWorkspaceLayouts() throws {
        let variants: [(String, AppTheme, NSAppearance.Name, Int, Bool, Bool, SimulatorWorkspaceLayout)] = [
            ("portraits-light", .system, .aqua, 2, false, false, .automatic),
            ("portraits-dark", .system, .darkAqua, 2, false, false, .automatic),
            ("landscapes-light", .system, .aqua, 2, true, false, .automatic),
            ("landscapes-dark", .system, .darkAqua, 2, true, false, .automatic),
            ("mixed-light", .system, .aqua, 2, false, true, .automatic),
            ("three-light", .system, .aqua, 3, false, false, .automatic),
            ("grid-light", .system, .aqua, 4, false, false, .grid),
            ("focus-light", .system, .aqua, 4, false, false, .focus),
            ("focus-narrow", .system, .aqua, 4, false, false, .focus),
            ("portraits-cyberpunk", AppThemeStyles.cyberpunk, .darkAqua, 2, false, false, .automatic),
            ("grid-swiss", AppThemeStyles.swissMinimalist, .aqua, 4, false, false, .grid),
        ]
        for (name, theme, appearance, count, landscape, mixed, layout) in variants {
            AppThemePalette.set(theme)
            let frame = try landscape ? makeLandscapeFramePNG() : makeDeviceFramePNG()
            let fixture = try makeFixture(appearance: appearance, deviceFrame: frame,
                additionalDeviceCount: count - 1, alternateFrame: mixed ? makeLandscapeFramePNG() : nil,
                panelWidth: name == "focus-narrow" ? 260 : Render.panelWidth)
            defer { fixture.tearDown() }
            let workspace = try XCTUnwrap(fixture.panel.currentSimulatorWorkspace)
            eventually { workspace.simulators.allSatisfy { $0.frameImageForTesting != nil } }
            workspace.setLayout(layout)
            settle(fixture.window)
            XCTAssertEqual(workspace.state.members.count, count)
            XCTAssertEqual(fixture.panel.view.bounds.width,
                name == "focus-narrow" ? 260 : Render.panelWidth, accuracy: 2)
            let hardware = workspace.selectedSimulator.workspaceHardwareControls
            for button in hardware.subviews {
                XCTAssertEqual(button.bounds.height, ThemedIconButton.Target.device.size.height, accuracy: 0.1)
                XCTAssertTrue(hardware.bounds.contains(button.frame), "A hardware target escaped its shared viewport.")
            }
            if layout == .automatic, !mixed, count == 2 {
                XCTAssertEqual(workspace.canvasForTesting.plan?.layout, landscape ? .column : .row)
            }
            if layout == .focus {
                XCTAssertEqual(workspace.simulators.filter(\.isPresentedForTesting).count, 1)
            }
            assertTilesHugTheirDevices(workspace, compact: name == "focus-narrow")
            let root = try XCTUnwrap(fixture.window.contentView)
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent("simulator-pane-workspace-\(name).png"))
        }
    }

    /// What the first workspace renders showed and no assertion caught: a letterboxed screen left
    /// its status line stranded at the bottom of a tall tile, the selected name's plate pushed its
    /// screen below its neighbours', and a 260pt header truncated two choosers to a letter each.
    private func assertTilesHugTheirDevices(_ workspace: SimulatorWorkspaceViewController, compact: Bool,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let canvas = workspace.canvasForTesting
        var tops: [CGFloat: CGFloat] = [:]
        for (index, simulator) in workspace.simulators.enumerated() where !simulator.view.isHidden {
            let screen = simulator.screenViewForTesting
            XCTAssertEqual(screen.imageRect.width, screen.bounds.width, accuracy: 1.5,
                           "The screen view is the frame's own aspect, never letterboxed.", file: file, line: line)
            XCTAssertEqual(screen.imageRect.height, screen.bounds.height, accuracy: 1.5,
                           "The screen view is the frame's own aspect, never letterboxed.", file: file, line: line)
            let status = simulator.statusViewForTesting
            let gap = screen.convert(screen.bounds, to: canvas).maxY - status.convert(status.bounds, to: canvas).minY
            XCTAssertLessThanOrEqual(abs(gap), Design.Spacing.medium,
                                     "The status line hangs from its screen.", file: file, line: line)
            guard let cell = canvas.plan?.frames[index] else { continue }
            let top = screen.convert(screen.bounds, to: canvas).minY
            if let rowTop = tops[cell.minY] {
                XCTAssertEqual(top, rowTop, accuracy: 0.5, "Screens in one row share a top edge.", file: file, line: line)
            } else {
                tops[cell.minY] = top
            }
        }
        let header = workspace.headerForTesting
        let showsLayout = header.leadingViews.contains { $0.accessibilityIdentifier() == "simulator.workspace.layout" }
        XCTAssertEqual(showsLayout, !compact,
                       "The layout chooser stands in a header with room and moves to the options menu without.",
                       file: file, line: line)
    }

    private func makeLandscapeFramePNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 852, height: 393))
        image.lockFocus()
        NSColor(red: 0.16, green: 0.08, blue: 0.3, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        drawText("9:41", at: NSPoint(x: 32, y: 352), size: 15, weight: .semibold, color: .white)
        drawText("Welcome back", at: NSPoint(x: 48, y: 266), size: 32, weight: .bold, color: .white)
        drawText("Your workspace is ready.", at: NSPoint(x: 48, y: 225), size: 18, weight: .regular, color: .white)
        drawText("3 focused tasks", at: NSPoint(x: 48, y: 125), size: 24, weight: .semibold, color: .white)
        NSColor.orange.setFill()
        NSBezierPath(roundedRect: NSRect(x: 520, y: 100, width: 250, height: 70), xRadius: 18, yRadius: 18).fill()
        drawText("Continue", at: NSPoint(x: 600, y: 124), size: 18, weight: .semibold, color: .black)
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testRendersPhysicalIPhoneInRightPanel() throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }
        AppThemePalette.set(.system)
        let deviceFrame = try makeDeviceFramePNG()

        for appearance in Render.appearances {
            let fixture = try makePhysicalDeviceFixture(
                appearance: appearance.value,
                deviceFrame: deviceFrame
            )
            defer { fixture.tearDown() }

            eventually {
                fixture.realDevice.frameImageForTesting != nil
            }
            settle(fixture.window)

            let content = try XCTUnwrap(fixture.window.contentView)
            XCTAssertEqual(
                fixture.panel.view.bounds.width,
                Render.panelWidth,
                accuracy: 2,
                "the physical iPhone was not rendered at the protected right-panel width"
            )
            XCTAssertEqual(
                fixture.realDevice.screenInteractionStateForTesting,
                .unavailable,
                "the screen must remain view-only until the user grants input"
            )
            XCTAssertEqual(
                fixture.realDevice.controlSupportForTesting,
                .available(supportedMediaFeatures: 140)
            )
            XCTAssertTrue(fixture.realDevice.statusForTesting.contains("View only"))
            XCTAssertTrue(fixture.realDevice.statusForTesting.contains("Preview fallback"))
            XCTAssertTrue(fixture.realDevice.statusForTesting.contains("Click to enable control"))
            XCTAssertEqual(
                fixture.realDevice.controlButtonForTesting.accessibilityTitle(),
                L10n.string("Enable iPhone Control")
            )
            XCTAssertTrue(fixture.realDevice.controlButtonForTesting.isEnabled)
            XCTAssertEqual(
                fixture.realDevice.logsButtonForTesting.accessibilityTitle(),
                L10n.string("Open Device Logs in Bottom Pane")
            )
            XCTAssertNotNil(
                fixture.realDevice.logsButtonForTesting.window,
                "the Device Logs shortcut must ship in the visible iPhone toolbar"
            )

            for button in [fixture.realDevice.captureButtonForTesting, fixture.realDevice.recordButtonForTesting,
                           fixture.realDevice.touchesButtonForTesting, fixture.realDevice.presenterButtonForTesting] {
                XCTAssertTrue(button.isEnabled)
                let bounds = button.convert(button.bounds, to: fixture.realDevice.view)
                XCTAssertTrue(fixture.realDevice.view.bounds.contains(bounds), "iPhone toolbar action was clipped")
            }

            let representation = try XCTUnwrap(
                content.bitmapImageRepForCachingDisplay(in: content.bounds)
            )
            content.cacheDisplay(in: content.bounds, to: representation)
            let png = try XCTUnwrap(
                representation.representation(using: .png, properties: [:])
            )
            try png.write(
                to: Render.directory.appendingPathComponent(
                    "physical-iphone-pane-system-\(appearance.name).png"
                )
            )

            let idleDeviceRect = fixture.realDevice.screenViewForTesting.imageRect
            fixture.realDevice.showRecordingPresentationForTesting(elapsedSeconds: 72)
            fixture.realDevice.screenViewForTesting.touchIndicators = SimulatorTouchIndicators(
                ripples: [], contact: .init(point: CGPoint(x: 0.6, y: 0.4),
                    trail: [CGPoint(x: 0.4, y: 0.7), CGPoint(x: 0.5, y: 0.55), CGPoint(x: 0.6, y: 0.4)]))
            settle(fixture.window)
            XCTAssertFalse(fixture.realDevice.recordingBadgeForTesting.isHidden)
            XCTAssertEqual(fixture.realDevice.screenViewForTesting.imageRect, idleDeviceRect,
                           "Starting a recording must not resize the device under the pointer")
            let recording = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: recording)
            try XCTUnwrap(recording.representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent("physical-iphone-pane-recording-\(appearance.name).png"))
            fixture.realDevice.showRecordingPresentationForTesting(elapsedSeconds: nil)
            let screen = fixture.realDevice.screenViewForTesting
            XCTAssertTrue(screen.onContextMenu?(.init(anchor: .pointer(screen.convert(
                CGPoint(x: screen.bounds.midX, y: screen.bounds.midY), to: nil)),
                point: nil, noteID: nil)) == true)
            settle(fixture.window)
            let menu = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: menu)
            try XCTUnwrap(menu.representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent("physical-iphone-pane-menu-\(appearance.name).png"))
            fixture.window.firstResponder?.cancelOperation(nil)
        }

        print("Rendered the physical iPhone pane to \(Render.directory.path)")
        try renderPhysicalIPhoneToolingSetup()
    }

    private func renderPhysicalIPhoneToolingSetup() throws {
        let variants: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua),
            ("system-dark", .system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, .aqua),
        ]
        for (name, theme, appearance) in variants {
            AppThemePalette.set(theme)
            let fixture = try makePhysicalDeviceFixture(
                appearance: appearance,
                deviceFrame: Data(),
                missingTooling: true
            )
            defer { fixture.tearDown() }
            eventually { fixture.realDevice.statusForTesting.contains("Setup required") }
            settle(fixture.window)
            let button = fixture.realDevice.toolingButtonForTesting
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(button.isEnabled)
            XCTAssertEqual(button.accessibilityTitle(), L10n.string("Install iPhone Tooling…"))
            XCTAssertEqual(fixture.panel.view.bounds.width, Render.panelWidth, accuracy: 2)
            XCTAssertFalse(fixture.realDevice.emptyLabelForTesting.stringValue.contains("Connect and unlock"))
            var openedSettings = false
            fixture.realDevice.onOpenToolingSettings = { openedSettings = true }
            XCTAssertTrue(button.accessibilityPerformPress())
            XCTAssertTrue(openedSettings)
            let pane = fixture.realDevice.view
            XCTAssertTrue(pane.bounds.contains(button.convert(button.bounds, to: pane)))
            let content = try XCTUnwrap(fixture.window.contentView)
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent("physical-iphone-pane-setup-\(name).png")
            )
            // The same attached helper follows a live palette switch without rebuilding its tree.
            AppThemePalette.set(.system)
            AppThemeRefresh.repaint(content)
            XCTAssertEqual(button.title, L10n.string("Install iPhone Tooling…"))
        }
    }

    private func bluetoothFixtureCapture() -> Data {
        // PCAP link type 201, then Reset and an ATT Write Command to attribute 0x0025.
        var capture = Data([
            0xa1, 0xb2, 0xc3, 0xd4, 0, 2, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 8, 0, 0, 0, 0, 201,
        ])
        let packets: [[UInt8]] = [[1, 3, 12, 0], [2, 1, 0x20, 8, 0, 4, 0, 4, 0, 0x52, 0x25, 0, 0xab]]
        for h4 in packets {
            for value in [UInt32(1), 123_456, UInt32(h4.count + 4), UInt32(h4.count + 4)] {
                capture.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
            }
            capture.append(contentsOf: [0, 0, 0, 0])
            capture.append(contentsOf: h4)
        }
        return capture
    }

    func testRendersNestedDockingAndScopedPreviewsInProductShell() throws {
        try FileManager.default.createDirectory(at: Render.directory, withIntermediateDirectories: true)
        let previous = AppThemePalette.current
        defer { AppThemePalette.set(previous) }
        // The preview fades between landings; capture each one where it lands.
        Design.Motion.reduceMotionOverrideForTesting = true
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }
        for (name, theme, appearance) in [
            ("system-dark", AppTheme.system, NSAppearance.Name.darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, NSAppearance.Name.aqua),
        ] {
            AppThemePalette.set(theme)
            let fixture = try makeFixture(appearance: appearance, deviceFrame: makeDeviceFramePNG(), docked: true)
            defer { fixture.tearDown() }
            let dock = try XCTUnwrap(fixture.dock)
            let session = try XCTUnwrap(fixture.panel.currentSessionID)
            let logs = try XCTUnwrap(fixture.panel.activateDeviceLog(for: session))
            // Bluetooth is its own command; open it beside the logs, then bring the logs forward.
            XCTAssertNotNil(fixture.panel.activateBluetoothLog(for: session))
            XCTAssertTrue(fixture.panel.activateDeviceLog(for: session) === logs)
            eventually { logs.loaded != nil || logs.refusal != nil }
            XCTAssertNil(logs.refusal)
            let plugin = try XCTUnwrap(logs.loaded as? NSObject)
            plugin.perform(NSSelectorFromString("installBluetoothCaptureForTesting:"),
                with: bluetoothFixtureCapture() as NSData)
            let tabs = fixture.panel.tabs(for: session)
            let regular = try XCTUnwrap(tabs.first { tab in
                if case let .nativePlugin(plugin) = tab.body { return plugin.paneSection == "regular" }
                return false
            })
            let bluetooth = try XCTUnwrap(tabs.first { tab in
                if case let .nativePlugin(plugin) = tab.body { return plugin.paneSection == "bluetooth" }
                return false
            })
            func capture(_ suffix: String) throws {
                settle(fixture.window)
                let image = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow,
                    CGWindowID(fixture.window.windowNumber), [.boundsIgnoreFraming, .nominalResolution]))
                try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    .write(to: Render.directory.appendingPathComponent("workspace-dock-\(suffix)-\(name).png"))
            }
            for (scope, target, surface) in [
                ("whole", Optional<UUID>.none, dock.view),
                ("conversation", Optional(WorkspaceDockLayout.conversationID), dock.conversation.view),
                ("side", Optional(WorkspaceDockLayout.displayID), dock.display.view),
            ] {
                let bounds = dock.view.convert(surface.bounds, from: surface)
                dock.showPreview(.init(targetID: target, edge: .bottom,
                    frame: WorkspaceDockController.previewFrame(bounds, edge: .bottom, share: target == nil
                        ? WorkspaceDockLayout.workspaceShare : WorkspaceDockLayout.paneShare)))
                try capture("preview-" + scope)
            }
            // The middle of the side panel joins it: the whole pane is shaded and named.
            dock.showPreview(.init(targetID: WorkspaceDockLayout.displayID, edge: nil,
                frame: dock.view.convert(dock.display.view.bounds, from: dock.display.view)))
            try capture("preview-join")
            dock.showPreview(nil)
            let left = try XCTUnwrap(dock.createGroup(at: .init(targetID: nil, edge: .bottom, frame: .zero)))
            let detachedBluetooth = try XCTUnwrap(fixture.panel.detachTab(id: bluetooth.id, for: session))
            left.adopt(detachedBluetooth, at: nil, for: session)
            let right = try XCTUnwrap(dock.createGroup(at: .init(targetID: left.dockID, edge: .right, frame: .zero)))
            let detachedRegular = try XCTUnwrap(fixture.panel.detachTab(id: regular.id, for: session))
            right.adopt(detachedRegular, at: nil, for: session)
            eventually { fixture.simulator.frameImageForTesting != nil }
            settle(fixture.window)
            XCTAssertTrue(left.tabs(for: session).first === bluetooth)
            XCTAssertTrue(right.tabs(for: session).first === regular)
            let leftRect = dock.view.convert(left.view.bounds, from: left.view)
            let rightRect = dock.view.convert(right.view.bounds, from: right.view)
            let simulatorRect = dock.view.convert(fixture.panel.view.bounds, from: fixture.panel.view)
            XCTAssertLessThan(leftRect.maxY, simulatorRect.minY + 3)
            XCTAssertEqual(leftRect.maxX, rightRect.minX, accuracy: 4)
            XCTAssertEqual(leftRect.height, rightRect.height, accuracy: 1)
            XCTAssertGreaterThan(leftRect.width, 500)
            try capture("bottom-pair")
            let data = try XCTUnwrap(DisplayPaneStore.shared.loadLayout(for: session))
            XCTAssertEqual(data.dockTabs.count, 2)
        }
    }

    func testRendersDeviceLogsFiltersInProductShell() throws {
        try FileManager.default.createDirectory(at: Render.directory, withIntermediateDirectories: true)
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }
        for (name, theme, appearance) in [
            ("system-dark", AppTheme.system, NSAppearance.Name.darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, NSAppearance.Name.darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, NSAppearance.Name.aqua),
        ] {
            AppThemePalette.set(theme)
            let fixture = try makePhysicalDeviceFixture(appearance: appearance, deviceFrame: makeDeviceFramePNG())
            defer { fixture.tearDown() }
            var logs = try XCTUnwrap(fixture.panel.activateDeviceLog(for: fixture.sessionID))
            eventually { logs.loaded != nil || logs.refusal != nil }
            XCTAssertNil(logs.refusal)
            XCTAssertNotNil(logs.loaded)
            // The same shipping panel may occupy the bottom drawer or a wider side split.
            let split = try XCTUnwrap(fixture.panel.parent as? NSSplitViewController)
            split.splitView.setPosition(split.splitView.bounds.width - 700 - split.splitView.dividerThickness, ofDividerAt: 0)
            settle(fixture.window)
            func find(_ id: String, in view: NSView) -> NSView? {
                if view.accessibilityIdentifier() == id { return view }
                return view.subviews.lazy.filter { !$0.isHidden || $0.accessibilityIdentifier() == id }
                    .compactMap { find(id, in: $0) }.first
            }
            for id in ["device-log-process", "device-log-context"] {
                let control = try XCTUnwrap(find(id, in: logs.view))
                XCTAssertFalse(control.isHiddenOrHasHiddenAncestor)
                XCTAssertTrue(logs.view.bounds.contains(control.convert(control.bounds, to: logs.view)))
            }
            func pluginTabTitles() -> [String] {
                fixture.panel.tabs(for: fixture.sessionID).filter {
                    if case .nativePlugin = $0.body { return true }; return false
                }.map(\.title)
            }
            XCTAssertEqual(pluginTabTitles(), [L10n.string("Device Logs")])
            // Bluetooth is its own command; open it beside the logs, then bring the logs forward.
            XCTAssertNotNil(fixture.panel.activateBluetoothLog(for: fixture.sessionID))
            XCTAssertTrue(fixture.panel.activateDeviceLog(for: fixture.sessionID) === logs)
            XCTAssertEqual(pluginTabTitles(), [L10n.string("Device Logs"), L10n.string("Bluetooth")])
            // cacheDisplay omitted the layer-backed chrome and plugin controls while every
            // geometry assertion above passed. Capture only this test-owned window, as the
            // sheet render tests do, so the evidence includes its actual composited controls.
            settle(fixture.window)
            let image = try XCTUnwrap(CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(fixture.window.windowNumber),
                [.boundsIgnoreFraming, .nominalResolution]
            ))
            let bitmap = NSBitmapImageRep(cgImage: image)
            XCTAssertGreaterThan(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0, 0.9)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent("device-log-shell-\(name).png")
            )

            // Drag the real decorated workspace chip through its pointer path. The marker
            // must be visible in the product shell before the host persists the new order.
            func tabStrip(in view: NSView) -> ThemedTabStripView? {
                if let strip = view as? ThemedTabStripView { return strip }
                return view.subviews.lazy.compactMap { tabStrip(in: $0) }.first
            }
            let strip = try XCTUnwrap(tabStrip(in: fixture.panel.view))
            let originalOrder = fixture.panel.tabs(for: fixture.sessionID).map(\.id)
            let activeID = try XCTUnwrap(fixture.panel.activeTabID(for: fixture.sessionID))
            let chip = try XCTUnwrap(strip.chipView(for: activeID))
            let first = try XCTUnwrap(strip.chipView(for: try XCTUnwrap(originalOrder.first)))
            let start = chip.convert(NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil)
            let finish = first.convert(NSPoint(x: 4, y: first.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: fixture.window.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1))
            }
            let content = try XCTUnwrap(fixture.window.contentView)
            XCTAssertTrue(content.hitTest(content.convert(start, from: nil)) === chip)
            chip.mouseDown(with: try event(.leftMouseDown, start))
            chip.mouseDragged(with: try event(.leftMouseDragged, finish))
            settle(fixture.window)
            XCTAssertEqual(strip.landingIndex, 0)
            XCTAssertNotNil(strip.landingMarkerFrame)
            XCTAssertEqual(fixture.panel.tabs(for: fixture.sessionID).map(\.id), originalOrder)
            let dragImage = try XCTUnwrap(CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(fixture.window.windowNumber),
                [.boundsIgnoreFraming, .nominalResolution]
            ))
            try XCTUnwrap(NSBitmapImageRep(cgImage: dragImage).representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent("device-log-shell-tab-drag-\(name).png")
            )
            chip.mouseUp(with: try event(.leftMouseUp, finish))
            settle(fixture.window)
            XCTAssertEqual(fixture.panel.tabs(for: fixture.sessionID).first?.id, activeID)
            XCTAssertNil(strip.landingMarkerFrame)
            XCTAssertTrue(fixture.panel.activateDeviceLog(for: fixture.sessionID) === logs)

            let plugin = try XCTUnwrap(logs.loaded as? NSObject)
            let selector = NSSelectorFromString("installBluetoothCaptureForTesting:")
            XCTAssertTrue(plugin.responds(to: selector))
            let capture = bluetoothFixtureCapture()
            let bluetoothTab = try XCTUnwrap(fixture.panel.tabs(for: fixture.sessionID).first {
                if case let .nativePlugin(plugin) = $0.body { return plugin.paneSection == "bluetooth" }
                return false
            })
            XCTAssertTrue(fixture.panel.activateTab(id: bluetoothTab.id, for: fixture.sessionID))
            if case let .nativePlugin(bluetooth) = bluetoothTab.body { logs = bluetooth }
            plugin.perform(selector, with: capture as NSData)
            settle(fixture.window)
            let process = try XCTUnwrap(find("device-log-process", in: logs.view))
            XCTAssertTrue(process.isHidden, "Bluetooth packets have no app process")
            func findTable(in view: NSView) -> NSTableView? {
                if let table = view as? NSTableView { return table }
                return view.subviews.lazy.filter { !$0.isHidden }.compactMap { findTable(in: $0) }.first
            }
            let table = try XCTUnwrap(findTable(in: logs.view))
            XCTAssertTrue(try XCTUnwrap(table.tableColumn(withIdentifier: .init("process"))).isHidden)
            let messageColumn = table.column(withIdentifier: .init("message"))
            let messageFrame = table.convert(table.rect(ofColumn: messageColumn), to: logs.view)
            XCTAssertGreaterThan(messageFrame.intersection(logs.view.bounds).width, 350,
                                 "packet summaries must be readable without first scrolling past metadata")
            var packetText = ""
            logs.loaded?.invokeTool?(named: "visible", argumentsJSON: "{}") { answer, isError in
                XCTAssertFalse(isError)
                packetText = answer
            }
            XCTAssertTrue(packetText.contains("Write Command attribute=0x0025"), packetText)
            let regularID = try XCTUnwrap(fixture.panel.tabs(for: fixture.sessionID).first { tab in
                if case let .nativePlugin(plugin) = tab.body { return plugin.paneSection == "regular" }
                return false
            }?.id)
            let regularChip = try XCTUnwrap(strip.chipView(for: regularID))
            let bluetoothChip = try XCTUnwrap(strip.chipView(for: bluetoothTab.id))
            XCTAssertTrue(regularChip.accessibilityPerformPress())
            settle(fixture.window)
            XCTAssertFalse(try XCTUnwrap(find("device-log-process", in: fixture.panel.view)).isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(bluetoothChip.accessibilityPerformPress())
            settle(fixture.window)
            XCTAssertTrue(findTable(in: logs.view) === table, "switching tabs retains the Bluetooth view")
            XCTAssertEqual(table.numberOfRows, 2, "returning to Bluetooth retains its captured packets")
            let setup = try XCTUnwrap(find("bluetooth-profile-setup", in: logs.view))
            XCTAssertFalse(setup.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(setup.accessibilityPerformPress())
            settle(fixture.window)
            for id in ["bluetooth-profile-install", "bluetooth-profile-download"] {
                let action = try XCTUnwrap(find(id, in: logs.view))
                XCTAssertFalse(action.isHiddenOrHasHiddenAncestor)
                XCTAssertTrue(logs.view.bounds.contains(action.convert(action.bounds, to: logs.view)))
            }
            settle(fixture.window)
            let bluetoothImage = try XCTUnwrap(CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(fixture.window.windowNumber),
                [.boundsIgnoreFraming, .nominalResolution]
            ))
            try XCTUnwrap(NSBitmapImageRep(cgImage: bluetoothImage).representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent("device-log-shell-bluetooth-\(name).png")
            )
            if name == "system-dark" {
                // The dedicated production WebKit surface, left blank so no sign-in details or
                // changing Apple page content enter deterministic UI evidence.
                plugin.perform(NSSelectorFromString("showBluetoothProfileBrowserForTesting"))
                settle(fixture.window)
                let browser = try XCTUnwrap(find("bluetooth-profile-browser", in: logs.view))
                XCTAssertTrue(logs.view.bounds.contains(browser.convert(browser.bounds, to: logs.view)))
                let download = try XCTUnwrap(find("bluetooth-profile-download", in: logs.view))
                XCTAssertFalse(download.isAccessibilityEnabled())
                let browserImage = try XCTUnwrap(CGWindowListCreateImage(
                    .null, .optionIncludingWindow, CGWindowID(fixture.window.windowNumber),
                    [.boundsIgnoreFraming, .nominalResolution]
                ))
                try XCTUnwrap(NSBitmapImageRep(cgImage: browserImage).representation(using: .png, properties: [:])).write(
                    to: Render.directory.appendingPathComponent("device-log-shell-bluetooth-browser.png")
                )
            }
        }
    }

    func testRendersBootFailureInTheRightPanel() throws {
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
                deviceFrame: deviceFrame,
                bootFailure: "Device boot failed: NSPOSIXErrorDomain Code=22 Invalid argument"
            )
            defer { fixture.tearDown() }
            eventually {
                if case .failed = fixture.simulator.presentationState { return true }
                return false
            }
            settle(fixture.window)

            let content = try XCTUnwrap(fixture.window.contentView)
            XCTAssertEqual(fixture.panel.view.bounds.width, Render.panelWidth, accuracy: 2)
            XCTAssertEqual(
                fixture.simulator.recoveryViewForTesting?.detail,
                L10n.format(
                    "Couldn’t start %@. Try Refresh or choose another Simulator.",
                    "iPhone 17 Pro"
                )
            )
            let representation = try XCTUnwrap(
                content.bitmapImageRepForCachingDisplay(in: content.bounds)
            )
            content.cacheDisplay(in: content.bounds, to: representation)
            try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent(
                    "simulator-pane-boot-failure-system-\(appearance.name).png"
                )
            )
        }
    }

    /// The presenter window's content — the device alone, with touches — at the size it opens
    /// at. Built and drawn offscreen: the window itself is never ordered on screen here.
    func testRendersPresenterWindowContent() throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }
        AppThemePalette.set(.system)
        let frame = try XCTUnwrap(NSImage(data: try makeDeviceFramePNG()))

        for appearance in Render.appearances {
            let content = SimulatorPresenterViewController()
            let size = SimulatorPresenterViewController.contentSize(
                forImageSize: frame.size,
                height: 640
            )
            content.view.frame = NSRect(origin: .zero, size: size)
            content.view.appearance = NSAppearance(named: appearance.value)
            content.screenView.image = frame
            content.screenView.touchStyle = SimulatorTouchStyle(color: .white, size: .medium, showsTrail: true)
            content.screenView.touchIndicators = Self.touchFixture
            AppThemeRefresh.repaint(content.view)
            content.view.layoutSubtreeIfNeeded()

            let screen = content.screenView
            XCTAssertEqual(
                screen.imageRect.width / screen.imageRect.height,
                frame.size.width / frame.size.height,
                accuracy: 0.01
            )
            XCTAssertEqual(
                screen.imageRect.height, screen.bounds.height, accuracy: 1,
                "A window sized for the device must show it without letterboxing"
            )

            let representation = try XCTUnwrap(
                content.view.bitmapImageRepForCachingDisplay(in: content.view.bounds)
            )
            content.view.cacheDisplay(in: content.view.bounds, to: representation)
            try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent(
                    "simulator-presenter-system-\(appearance.name).png"
                )
            )
        }
    }

    /// A tap fading out and a finger mid-swipe with its trail.
    private static let touchFixture = SimulatorTouchIndicators(
        ripples: [.init(point: CGPoint(x: 0.3, y: 0.34), progress: 0.25)],
        contact: .init(
            point: CGPoint(x: 0.62, y: 0.62),
            trail: [
                CGPoint(x: 0.62, y: 0.44),
                CGPoint(x: 0.62, y: 0.5),
                CGPoint(x: 0.62, y: 0.56),
                CGPoint(x: 0.62, y: 0.62),
            ]
        )
    )

    /// The Push Test tab beside the same conversation, in the states a person meets:
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

    private func renderUnavailableSimulator() throws {
        try FileManager.default.createDirectory(at: Render.directory, withIntermediateDirectories: true)
        let previous = AppThemePalette.current
        defer { AppThemePalette.set(previous) }
        let variants: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua),
            ("system-dark", .system, .darkAqua),
            ("cyberpunk", try XCTUnwrap(AppThemeLibrary.stock.first { $0.name == "Cyberpunk" }), .darkAqua),
            ("swiss", try XCTUnwrap(AppThemeLibrary.stock.first { $0.name == "Swiss Minimalist" }), .aqua),
        ]
        for (name, theme, appearance) in variants {
            AppThemePalette.set(theme)
            let fixture = try makeFixture(appearance: appearance, deviceFrame: makeDeviceFramePNG(), additionalDeviceCount: 1)
            defer { fixture.tearDown() }
            eventually { fixture.simulator.frameImageForTesting != nil }
            let id = try XCTUnwrap(fixture.simulator.selectedDeviceID)
            Task {
                await fixture.control.makeUnavailable(id)
                fixture.streams.disconnect(id)
            }
            eventually { if case .failed = fixture.simulator.presentationState { return true }; return false }
            XCTAssertNil(fixture.simulator.frameImageForTesting)
            let recovery = try XCTUnwrap(fixture.simulator.recoveryViewForTesting)
            XCTAssertFalse(recovery.isHidden)
            XCTAssertTrue(ThemeBoundaryAudit.violations(in: recovery).isEmpty)
            XCTAssertTrue(fixture.simulator.statusTooltipForTesting.contains("Invalid device:"))
            XCTAssertFalse(recovery.detail.contains(id.rawValue))
            settle(fixture.window)
            let content = try XCTUnwrap(fixture.window.contentView)
            XCTAssertEqual(fixture.panel.view.bounds.width, Render.panelWidth, accuracy: 2)
            for action in [recovery.retryButton, recovery.chooseButton] {
                XCTAssertTrue(recovery.bounds.contains(action.convert(action.bounds, to: recovery)), "\(name): recovery action clipped")
                XCTAssertEqual(action.accessibilityRole(), .button)
            }
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent("simulator-pane-unavailable-\(name).png")
            )
            // Switching the theme while unavailable uses the existing component, with the same actions.
            AppThemePalette.set(.system)
            AppThemeRefresh.repaint(content)
            XCTAssertTrue(fixture.simulator.recoveryViewForTesting === recovery)
            XCTAssertTrue(recovery.chooseButton.performPrimaryAction())
            eventually { ThemedMenuPresenter.isMenuOpen(in: fixture.window) }
            XCTAssertFalse(fixture.simulator.availableWorkspaceDevices.contains { $0.id == id },
                           "The recovery chooser must refresh its stale catalogue.")
            func replacementRow(in view: NSView) -> NSView? {
                if view.accessibilityRole() == .menuItem,
                   view.accessibilityTitle()?.contains("iPhone SE") == true { return view }
                return view.subviews.lazy.compactMap { replacementRow(in: $0) }.first
            }
            let replacement = try XCTUnwrap(replacementRow(in: content))
            XCTAssertTrue(replacement.accessibilityPerformPress())
            XCTAssertFalse(ThemedMenuPresenter.isMenuOpen(in: fixture.window))
            XCTAssertEqual(fixture.panel.currentSimulatorWorkspace?.state.members.count, 2)
        }
    }

    func testWebExtensionPanelRunsRealBrowserDevelopmentLoop() async throws {
        guard ProcessInfo.processInfo.environment["THREADING_WEBEXT_E2E"] == "1" else {
            throw XCTSkip("Set THREADING_WEBEXT_E2E=1 for the visible-browser panel journey")
        }
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let fixture = try makeFixture(appearance: .aqua, deviceFrame: makeDeviceFramePNG())
        defer { fixture.tearDown() }
        let id = try XCTUnwrap(fixture.panel.currentSessionID)
        let service = WebExtensionDevelopmentService(currentProject: { _ in project })
        defer { service.release(id) }
        guard case .success = await service.call(.init(action: .scaffold), sessionID: id, project: project) else {
            return XCTFail("Could not create the panel journey's extension")
        }
        let panel = try XCTUnwrap(fixture.panel.activateWebExtensions(for: id, project: project, service: service))
        func find(_ identifier: String, in view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == identifier { return view }
            return view.subviews.lazy.compactMap { find(identifier, in: $0) }.first
        }
        func waitUntil(_ condition: @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(150)
            while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            _ = try XCTUnwrap(condition() ? true : nil, "The real-browser panel operation did not finish")
        }
        let start = try XCTUnwrap(find("webExtensions.start", in: panel.view) as? ThemedButton)
        let reload = try XCTUnwrap(find("webExtensions.reload", in: panel.view) as? ThemedButton)
        let test = try XCTUnwrap(find("webExtensions.test", in: panel.view) as? ThemedButton)
        let stop = try XCTUnwrap(find("webExtensions.stop", in: panel.view) as? ThemedButton)
        func details(in view: NSView) -> ThemedTextView? {
            if let text = view as? ThemedTextView { return text }
            return view.subviews.lazy.compactMap { details(in: $0) }.first
        }
        let detail = try XCTUnwrap(details(in: panel.view))
        try await waitUntil { start.isEnabled }
        XCTAssertTrue(start.performPrimaryAction())
        try await waitUntil { reload.isEnabled }
        XCTAssertTrue(test.performPrimaryAction())
        try await waitUntil { test.isEnabled && detail.string.contains("Declared page assertions passed") }
        let background = project.appendingPathComponent("web-extension/background.js")
        let updated = try String(contentsOf: background, encoding: .utf8) + "\nconsole.info('panel-reload-marker');\n"
        try updated.write(to: background, atomically: true, encoding: .utf8)
        XCTAssertTrue(reload.performPrimaryAction())
        try await waitUntil { reload.isEnabled }
        XCTAssertTrue(test.performPrimaryAction())
        try await waitUntil { test.isEnabled && detail.string.contains("Declared page assertions passed") }
        XCTAssertTrue(stop.performPrimaryAction())
        try await waitUntil { start.isEnabled && !stop.isEnabled }
    }

    func testRendersWebExtensionWorkbenchInRightPanel() throws {
        try FileManager.default.createDirectory(at: Render.directory, withIntermediateDirectories: true)
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }
        let frame = try makeDeviceFramePNG()
        let variants: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua), ("system-dark", .system, .darkAqua),
            ("cyberpunk", try XCTUnwrap(AppThemeLibrary.stock.first { $0.name == "Cyberpunk" }), .darkAqua),
            ("swiss", try XCTUnwrap(AppThemeLibrary.stock.first { $0.name == "Swiss Minimalist" }), .aqua)
        ]
        for (name, theme, appearance) in variants {
            AppThemePalette.set(theme)
            let fixture = try makeFixture(appearance: appearance, deviceFrame: frame)
            defer { fixture.tearDown() }
            let sessionID = try XCTUnwrap(fixture.panel.currentSessionID)
            let service = RenderWebExtensionService()
            let panel = try XCTUnwrap(fixture.panel.activateWebExtensions(
                for: sessionID, project: FileManager.default.temporaryDirectory, service: service))
            eventually { service.actions.contains(.events) }
            func find(_ id: String, in view: NSView) -> NSView? {
                if view.accessibilityIdentifier() == id { return view }
                return view.subviews.lazy.compactMap { find(id, in: $0) }.first
            }
            let table = try XCTUnwrap(find("webExtensions.events", in: panel.view) as? NSTableView)
            XCTAssertEqual(table.numberOfRows, 3)
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            AppThemeRefresh.repaint(fixture.window.contentView!)
            settle(fixture.window)
            let content = try XCTUnwrap(fixture.window.contentView)
            let representation = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: representation)
            try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(
                to: Render.directory.appendingPathComponent("web-extension-\(name).png"))
            XCTAssertEqual(fixture.panel.view.bounds.width, Render.panelWidth, accuracy: 2)
            let reload = try XCTUnwrap(find("webExtensions.reload", in: panel.view) as? ThemedButton)
            XCTAssertTrue(reload.isEnabled)
            XCTAssertTrue(reload.performPrimaryAction())
            eventually { service.actions.contains(.reload) }
        }
    }

    /// A restarted helper numbers its events from 1 again. Rows from the earlier worker must go,
    /// or Open Source could resolve a stale row to a different event that reuses its ID.
    func testWebExtensionPanelDropsRowsFromARestartedWorker() throws {
        let fixture = try makeFixture(appearance: .aqua, deviceFrame: makeDeviceFramePNG())
        defer { fixture.tearDown() }
        let sessionID = try XCTUnwrap(fixture.panel.currentSessionID)
        let service = RestartingWebExtensionService()
        let panel = try XCTUnwrap(fixture.panel.activateWebExtensions(
            for: sessionID, project: FileManager.default.temporaryDirectory, service: service))
        func find(_ id: String, in view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == id { return view }
            return view.subviews.lazy.compactMap { find(id, in: $0) }.first
        }
        let table = try XCTUnwrap(find("webExtensions.events", in: panel.view) as? NSTableView)
        eventually { table.numberOfRows == 3 }
        let restartedAt = service.reads.count
        service.generation = "second"
        eventually(timeout: 5) { table.numberOfRows == 1 }
        XCTAssertEqual(table.numberOfRows, 1, "Rows from the earlier worker survived its restart")
        XCTAssertTrue(service.reads[restartedAt...].contains(0), "The new worker was not read from its first event")
    }

    private func makeFixture(
        appearance appearanceName: NSAppearance.Name,
        deviceFrame: Data,
        bootFailure: String? = nil,
        additionalDeviceCount: Int = 0,
        alternateFrame: Data? = nil,
        panelWidth: CGFloat = Render.panelWidth,
        androidSecond: Bool = false,
        docked: Bool = false,
        scenarioCheckout: URL? = nil
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
        let additionalDevices = (0..<additionalDeviceCount).map { index in
            if androidSecond, index == 0 {
                return SimulatorDevice(
                    id: SimulatorDeviceID.androidEmulator(avdName: "Pixel_8_API_36")!, name: "Pixel 8",
                    runtimeIdentifier: "android-36", runtimeName: "Android 16 · API 36",
                    deviceTypeIdentifier: "android.avd", family: .androidPhone, state: .booted, lastBootedAt: nil
                )
            }
            return SimulatorDevice(id: SimulatorDeviceID(String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                name: ["iPhone SE", "iPhone 16", "iPhone 17"][index],
                runtimeIdentifier: device.runtimeIdentifier, runtimeName: device.runtimeName,
                deviceTypeIdentifier: device.deviceTypeIdentifier, family: .iPhone,
                state: .booted, lastBootedAt: nil)
        }
        let control = SimulatorPaneRenderControl(
            device: device, additionalDevices: additionalDevices,
            frame: deviceFrame,
            bootFailure: bootFailure
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

        var framesByDevice: [SimulatorDeviceID: CGImage] = [:]
        if let alternateFrame, let second = additionalDevices.first,
           let image = NSImage(data: alternateFrame),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { framesByDevice[second.id] = cg }
        let streams = SimulatorPaneRenderStreamCoordinator(frame: liveFrame, framesByDevice: framesByDevice)
        let panel = DisplayPaneController(
            simulatorControl: control,
            simulatorStreamCoordinator: streams
        )
        if let scenarioCheckout { panel.simulatorScenarioCheckout = { _ in scenarioCheckout } }
        let split = SidebarSplitViewController()
        let dock = docked ? WorkspaceDockController(base: split, conversation: conversation, display: panel) : nil
        let conversationItem = NSSplitViewItem(viewController: dock?.conversationBranch ?? conversation)
        conversationItem.minimumThickness = 560
        let panelItem = NSSplitViewItem(viewController: dock?.displayBranch ?? panel)
        // The real main window applies its opening width when it reveals this item. This direct
        // shell fixture has no window coordinator to perform that reveal, so hold the same
        // review width here rather than accepting NSSplitViewController's fitting-size answer.
        panelItem.minimumThickness = panelWidth
        panelItem.maximumThickness = panelWidth
        split.addSplitViewItem(conversationItem)
        split.addSplitViewItem(panelItem)

        let host = WindowChromeHostViewController(workspace: dock ?? split)
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
            - panelWidth
            - split.splitView.dividerThickness
        split.splitView.setPosition(dividerPosition, ofDividerAt: 0)
        host.view.layoutSubtreeIfNeeded()

        dock?.showSession(session.id)
        panel.showSession(session.id)
        let simulator = try panel.activateSimulator(for: session.id, deviceID: device.id)
        for extra in additionalDevices { _ = try panel.activateSimulator(for: session.id, deviceID: extra.id) }
        conversation.scrollToConversationEnd()
        AppThemeRefresh.repaint(host.view)
        settle(window)

        return SimulatorPaneRenderFixture(
            window: window,
            panel: panel,
            simulator: simulator,
            control: control,
            streams: streams,
            dock: dock
        )
    }

    private func makePhysicalDeviceFixture(
        appearance appearanceName: NSAppearance.Name,
        deviceFrame: Data,
        missingTooling: Bool = false
    ) throws -> PhysicalDevicePaneRenderFixture {
        let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
        let device = PhysicalDevice(
            id: try XCTUnwrap(PhysicalDeviceID("00008140-000C208C1108801C")),
            coreDeviceIdentifier: try XCTUnwrap(
                UUID(uuidString: "ECE91967-105E-5BAE-9110-E49CBB0DEBD3")
            ),
            name: "David’s iPhone",
            productType: "iPhone17,1",
            osVersion: missingTooling ? "27.0.1" : "26.6.2",
            connection: .localNetwork,
            developerModeEnabled: true,
            developerServicesAvailable: true
        )
        let control = PhysicalDevicePaneRenderControl(
            device: device, frame: deviceFrame, missingTooling: missingTooling
        )
        let project = Project(
            name: "Threading",
            folderURL: FileManager.default.temporaryDirectory
        )
        let session = AgentSession(
            kind: .claude,
            title: "Test on my iPhone",
            usesNativeUI: true
        )
        let conversation = requireConversationViewController(
            agentSession: session,
            project: project,
            customizationLookup: { _ in .empty }
        )
        applyPhysicalDeviceConversationFixture(to: conversation)

        let panel = DisplayPaneController(physicalDeviceControl: control)
        let split = SidebarSplitViewController()
        let conversationItem = NSSplitViewItem(viewController: conversation)
        conversationItem.minimumThickness = 560
        let panelItem = NSSplitViewItem(viewController: panel)
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
        let realDevice = panel.activateRealDevice(for: session.id, deviceID: device.id)
        conversation.scrollToConversationEnd()
        AppThemeRefresh.repaint(host.view)
        settle(window)

        return PhysicalDevicePaneRenderFixture(
            window: window,
            panel: panel,
            realDevice: realDevice,
            sessionID: session.id
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

    private func applyPhysicalDeviceConversationFixture(
        to conversation: ConversationViewController
    ) {
        let events: [StreamEvent] = [
            .userMessage("Keep my paired iPhone visible here while we check the real-device UI."),
            .assistantMessage(blocks: [
                .thinking(
                    "I can keep the physical-device pane view-only until you grant input."
                ),
                .text(
                    "Your paired iPhone is open in the right panel. Use the pointer button to grant "
                    + "temporary tap, swipe, and keyboard control."
                )
            ]),
            .turnFinished(
                text: nil,
                outcome: .completed,
                metrics: TurnMetrics(
                    duration: 4.2,
                    outputTokens: 74,
                    effort: "high",
                    contextTokens: 18_900,
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
    let control: SimulatorPaneRenderControl
    let streams: SimulatorPaneRenderStreamCoordinator
    var dock: WorkspaceDockController? = nil

    func tearDown() {
        if let session = panel.currentSessionID {
            panel.removeSession(session)
            DisplayPaneStore.shared.removeSession(session)
        }
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }
}

@MainActor
private struct PhysicalDevicePaneRenderFixture {
    let window: NSWindow
    let panel: DisplayPaneController
    let realDevice: RealDevicePaneViewController
    let sessionID: SessionID

    func tearDown() {
        realDevice.terminate()
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
        DisplayPaneStore.shared.removeSession(sessionID)
    }
}

private actor PhysicalDevicePaneRenderControl: PhysicalDeviceControlling {
    private let device: PhysicalDevice
    private let frame: Data
    private let missingTooling: Bool

    init(device: PhysicalDevice, frame: Data, missingTooling: Bool = false) {
        self.device = device
        self.frame = frame
        self.missingTooling = missingTooling
    }

    func availableDevices() async throws -> [PhysicalDevice] { [device] }

    func controlSupport(of device: PhysicalDevice) async throws -> PhysicalDeviceControlSupport {
        missingTooling ? .unknown(.probeToolUnavailable) : .available(supportedMediaFeatures: 140)
    }

    func prepareControl(of device: PhysicalDevice) async throws {}

    func sendInput(_ input: PhysicalDeviceInput, to device: PhysicalDevice) async throws {}

    func screenshot(of device: PhysicalDevice) async throws -> Data {
        if missingTooling { throw PhysicalDeviceControlError.screenshotToolUnavailable }
        return frame
    }
}

private actor SimulatorPaneRenderControl: SimulatorControlling {
    private var unavailable: Set<SimulatorDeviceID> = []
    func makeUnavailable(_ id: SimulatorDeviceID) { unavailable.insert(id) }
    private var launchRefusal: SimulatorControlError?
    func refuseLaunches(_ error: SimulatorControlError?) { launchRefusal = error }

    func launchApp(_ launch: SimulatorAppLaunch, on deviceID: SimulatorDeviceID) async throws -> SimulatorLaunchReceipt {
        if let launchRefusal { throw launchRefusal }
        return SimulatorLaunchReceipt(deviceID: deviceID, bundleIdentifier: "com.example.shop", processIdentifier: nil)
    }

    func openAppLink(_ link: SimulatorAppLink, on deviceID: SimulatorDeviceID) async throws {}
    private let device: SimulatorDevice
    private let additionalDevices: [SimulatorDevice]
    private let frame: Data
    private let bootFailure: String?

    init(device: SimulatorDevice, additionalDevices: [SimulatorDevice] = [], frame: Data, bootFailure: String? = nil) {
        self.device = device
        self.additionalDevices = additionalDevices
        self.frame = frame
        self.bootFailure = bootFailure
    }

    func availableDevices() async throws -> [SimulatorDevice] { ([device] + additionalDevices).filter { !unavailable.contains($0.id) } }

    func prepare(deviceID: SimulatorDeviceID?) async throws -> SimulatorDeviceLease {
        if let bootFailure {
            throw SimulatorControlError.bootFailed(
                deviceName: device.name,
                detail: bootFailure
            )
        }
        return SimulatorDeviceLease(device: additionalDevices.first { $0.id == deviceID } ?? device, bootOwnership: .user)
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

    func screenshot(of deviceID: SimulatorDeviceID) async throws -> Data {
        if unavailable.contains(deviceID) {
            throw SimulatorControlError.deviceUnavailable(deviceID, detail: "Invalid device: \(deviceID.rawValue)")
        }
        return frame
    }

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
    private let frame: CGImage
    private let framesByDevice: [SimulatorDeviceID: CGImage]
    private let lock = NSLock()
    private var sessions: [SimulatorDeviceID: SimulatorPaneRenderStreamSession] = [:]

    func disconnect(_ id: SimulatorDeviceID) { lock.withLock { sessions[id] }?.disconnect() }

    init(frame: CGImage, framesByDevice: [SimulatorDeviceID: CGImage] = [:]) {
        self.frame = frame
        self.framesByDevice = framesByDevice
    }

    func openStream(
        for deviceID: SimulatorDeviceID
    ) async throws -> any SimulatorLiveStreamSession {
        let session = SimulatorPaneRenderStreamSession(frame: framesByDevice[deviceID] ?? frame)
        lock.withLock { sessions[deviceID] = session }
        return session
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
    func disconnect() { continuation.yield(.failed("The Simulator device became unavailable.")) }
    func sendInput(_ input: SimulatorBridgeInput) async throws {}
    func stop() { continuation.finish() }
}

/// Answers the Push Test tab for a render: who is in the chat and what a link opens are
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

/// Answers like a helper that restarts when `generation` changes: event IDs begin at 1 again, and a
/// cursor past the new journal is read from its start, as the worker does.
@MainActor
private final class RestartingWebExtensionService: WebExtensionServicing {
    var generation = "first"
    private(set) var reads: [Int] = []
    func isBusy(_ sessionID: SessionID) -> Bool { false }
    func release(_ sessionID: SessionID) {}
    func call(_ request: WebExtensionRequest, sessionID: SessionID, project: URL) async -> WebExtensionReply {
        var payload = WebExtensionPayload()
        payload.generation = generation
        guard request.action == .events else { return .success(payload, text: "{}") }
        let count = generation == "first" ? 3 : 1
        let requested = request.after ?? 0
        reads.append(requested)
        let after = requested > count ? 0 : requested
        payload.events = (1...count).filter { $0 > after }.map { id in
            WebExtensionEvent(id: id, target: "chrome", level: "info", kind: "console", message: "\(generation) \(id)",
                              stack: "", context: "background", contextID: "context", build: "build", url: "",
                              received: 0, tab: nil, frame: nil)
        }
        payload.cursor = count
        return .success(payload, text: "{}")
    }
}

@MainActor
private final class RenderWebExtensionService: WebExtensionServicing {
    var actions: [WebExtensionRequest.Action] = []
    func isBusy(_ sessionID: SessionID) -> Bool { false }
    func release(_ sessionID: SessionID) {}
    func call(_ request: WebExtensionRequest, sessionID: SessionID, project: URL) async -> WebExtensionReply {
        actions.append(request.action)
        var payload = WebExtensionPayload()
        if request.action == .inspect {
            payload.targets = [.init(id: "chrome", browser: "chrome", source: "dist/chrome", build: ["npm", "run", "build:chrome"])]
            payload.runs = [.init(target: "chrome", browser: "chrome", build: "bc032fedc581922a", status: "connected", directory: "/tmp/development", instructions: "Background, content script and popup connected.")]
        } else if request.action == .events {
            payload.cursor = 3
            payload.events = request.after == 0 ? [
                ("error", "background", "exception", "TypeError: Cannot read properties of undefined"),
                ("warning", "content-script", "network", "503 https://example.test/api/status"),
                ("info", "extension-page", "console", "Popup connected")
            ].enumerated().map { index, item in
                WebExtensionEvent(id: index + 1, target: "chrome", level: item.0, kind: item.2,
                    message: item.3, stack: "at refresh (background.js:42:7)", context: item.1,
                    contextID: "fixture-context", build: "bc032fedc581922a", url: "https://example.test",
                    received: 0, tab: 1, frame: 0)
            } : []
        }
        return .success(payload, text: "{}")
    }
}
