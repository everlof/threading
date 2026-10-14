import AppKit
import ImageIO
import ThreadingSimulatorKit
import XCTest
@testable import Threading

@MainActor
final class SimulatorWorkspaceTests: HostedStoreTestCase {
    func testAutomaticLayoutUsesPortraitRowsAndLandscapeColumns() {
        let size = CGSize(width: 420, height: 600)
        let portraits = plan(size: size, aspects: [0.46, 0.46])
        XCTAssertEqual(portraits.layout, .row)
        XCTAssertEqual(portraits.frames[0].minY, portraits.frames[1].minY)
        XCTAssertLessThan(portraits.frames[0].maxX, portraits.frames[1].minX)
        let landscapes = plan(size: size, aspects: [2.17, 2.17])
        XCTAssertEqual(landscapes.layout, .column)
        XCTAssertEqual(landscapes.frames[0].minX, landscapes.frames[1].minX)
        XCTAssertLessThan(landscapes.frames[0].maxY, landscapes.frames[1].minY)
    }

    func testManualLayoutPersistsAcrossAspectAndSizeChanges() {
        for size in [CGSize(width: 420, height: 600), CGSize(width: 900, height: 300)] {
            let result = plan(size: size, aspects: [2.17, 0.46], layout: .row)
            XCTAssertEqual(result.layout, .row)
        }
        let focused = plan(size: CGSize(width: 260, height: 500), aspects: [0.46, 2.17], layout: .focus, selected: 1)
        XCTAssertEqual(focused.visibleIndices, [1])
        XCTAssertEqual(focused.frames[1].size, CGSize(width: 260, height: 500))
    }

    func testFourDeviceGridFitsItsActualViewport() {
        let size = CGSize(width: 420, height: 600)
        let result = plan(size: size, aspects: [0.46, 0.46, 0.46, 0.46], layout: .grid)
        XCTAssertEqual(result.visibleIndices, [0, 1, 2, 3])
        for frame in result.frames {
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(frame))
        }
        XCTAssertEqual(result.frames[0].width, result.frames[3].width)
    }

    func testWorkspaceAddsDistinctDevicesAndReusesExactMembers() throws {
        let pane = DisplayPaneController(simulatorControl: WorkspaceControlFake())
        let session = SessionID()
        defer { pane.removeSession(session); DisplayPaneStore.shared.removeSession(session) }
        let first = try pane.activateSimulator(for: session, deviceID: device(1))
        let second = try pane.activateSimulator(for: session, deviceID: device(2))
        XCTAssertFalse(first === second)
        XCTAssertTrue(try pane.activateSimulator(for: session, deviceID: device(1)) === first)
        let workspace = try XCTUnwrap(pane.simulatorWorkspace(for: session))
        XCTAssertEqual(workspace.state.members.compactMap(\.deviceID), [device(1), device(2)])
        XCTAssertEqual(pane.tabs(for: session).count, 1)

        workspace.setLayout(.column)
        let saved = try XCTUnwrap(DisplayPaneStore.shared.loadLayout(for: session))
        XCTAssertEqual(saved.requiredFormatVersion, 5)
        XCTAssertEqual(saved.panelTabs[0].simulatorWorkspace?.layout, .column)
        let restored = DisplayPaneController(simulatorControl: WorkspaceControlFake())
        defer { restored.removeSession(session) }
        let restoredWorkspace = try XCTUnwrap(restored.simulatorWorkspace(for: session))
        XCTAssertEqual(restoredWorkspace.state, workspace.state)
    }

    func testAdmissionCapsBeforeConstructingAViewerAndRemovingPreservesOtherMembers() throws {
        var constructed = 0
        let workspace = SimulatorWorkspaceViewController(state: SimulatorWorkspaceState(deviceID: device(1))) { id in
            constructed += 1
            return SimulatorPaneViewController(preferredDeviceID: id, isWorkspaceMember: true, control: WorkspaceControlFake())
        }
        defer { workspace.terminate() }
        let original = workspace.selectedSimulator
        for index in 2...4 { _ = try workspace.adopt(device(index)) }
        XCTAssertThrowsError(try workspace.adopt(device(5)))
        XCTAssertEqual(constructed, 4)
        XCTAssertEqual(workspace.state.members.count, 4)
        workspace.removeSelected()
        XCTAssertEqual(workspace.state.members.count, 3)
        XCTAssertTrue(try workspace.adopt(device(1)) === original)
    }

    func testARequestedWorkspaceKeepsTheDevicesAlreadyShownAndAskingAgainChangesNothing() throws {
        let workspace = SimulatorWorkspaceViewController(state: SimulatorWorkspaceState(deviceID: device(1))) { id in
            SimulatorPaneViewController(preferredDeviceID: id, isWorkspaceMember: true, control: WorkspaceControlFake())
        }
        defer { workspace.terminate() }
        let first = workspace.selectedSimulator
        let second = try workspace.adopt(device(2))
        try workspace.setDevices([device(3), device(2)], selecting: device(2))
        XCTAssertEqual(workspace.state.members.compactMap(\.deviceID), [device(3), device(2)])
        XCTAssertTrue(workspace.simulators[1] === second, "the device already shown keeps its pane and stream")
        XCTAssertFalse(workspace.simulators.contains { $0 === first }, "a device not named leaves")
        XCTAssertTrue(workspace.selectedSimulator === second)

        let state = workspace.state
        let panes = workspace.simulators
        var changes = 0
        workspace.onChange = { changes += 1 }
        try workspace.setDevices([device(3), device(2)], selecting: device(2))
        XCTAssertEqual(workspace.state, state)
        XCTAssertTrue(zip(panes, workspace.simulators).allSatisfy { $0 === $1 })
        XCTAssertEqual(changes, 0, "the workspace it already is")
        XCTAssertThrowsError(try workspace.setDevices((1...5).map(device), selecting: device(1)))
        XCTAssertEqual(workspace.state, state)
    }

    func testANamedDeviceTakesTheMembersPlaceWithoutAddingOne() throws {
        let workspace = SimulatorWorkspaceViewController(state: SimulatorWorkspaceState(deviceID: device(1))) { id in
            SimulatorPaneViewController(preferredDeviceID: id, isWorkspaceMember: true, control: WorkspaceControlFake())
        }
        defer { workspace.terminate() }
        let first = workspace.selectedSimulator
        _ = try workspace.adopt(device(2))
        XCTAssertTrue(workspace.replace(device(1), with: device(3)) === first)
        XCTAssertEqual(workspace.state.members.compactMap(\.deviceID), [device(3), device(2)])
        XCTAssertEqual(first.selectedDeviceID, device(3))
        XCTAssertTrue(workspace.selectedSimulator === first)
        XCTAssertNil(workspace.replace(device(9), with: device(4)), "no member shows that device")
        XCTAssertNil(workspace.replace(device(3), with: device(2)), "a device on show is never shown twice")
        XCTAssertEqual(workspace.state.members.compactMap(\.deviceID), [device(3), device(2)])
    }

    func testEachTileOffersRemovalBesidePeersAndNoneAlone() throws {
        let workspace = SimulatorWorkspaceViewController(state: SimulatorWorkspaceState(deviceID: device(1))) { id in
            SimulatorPaneViewController(preferredDeviceID: id, isWorkspaceMember: true, control: WorkspaceControlFake())
        }
        defer { workspace.terminate() }
        workspace.view.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
        let first = workspace.selectedSimulator
        let second = try workspace.adopt(device(2))
        workspace.view.layoutSubtreeIfNeeded()
        let remove = try XCTUnwrap(removeButton(in: second))
        XCTAssertFalse(remove.isHidden)
        XCTAssertEqual(remove.alphaValue, 0, "it shows while the pointer is over the tile")
        XCTAssertEqual(remove.accessibilityTitle(),
                       L10n.format("Remove %@ from Workspace", second.workspaceDeviceName),
                       "a screen reader reaches it whether or not it shows")
        XCTAssertTrue(remove.accessibilityPerformPress())
        XCTAssertEqual(workspace.state.members.compactMap(\.deviceID), [device(1)])
        XCTAssertTrue(workspace.selectedSimulator === first)
        XCTAssertEqual(removeButton(in: first)?.isHidden, true, "the last device stays")
    }

    private func removeButton(in pane: SimulatorPaneViewController) -> ThemedIconButton? {
        func find(_ view: NSView) -> ThemedIconButton? {
            if let button = view as? ThemedIconButton,
               button.accessibilityIdentifier() == "simulator.workspace.memberRemove" { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(pane.view)
    }

    func testRecoveryChoiceOfAnExistingMemberSelectsItWithoutDuplicatingTheDevice() throws {
        let workspace = SimulatorWorkspaceViewController(state: SimulatorWorkspaceState(deviceID: device(1))) { id in
            SimulatorPaneViewController(preferredDeviceID: id, isWorkspaceMember: true, control: WorkspaceControlFake())
        }
        defer { workspace.terminate() }
        let original = workspace.selectedSimulator
        let second = try workspace.adopt(device(2))
        workspace.select(workspace.state.members[0].id)
        original.selectRecoveryDevice(device(2))
        XCTAssertTrue(workspace.selectedSimulator === second)
        XCTAssertEqual(workspace.state.members.compactMap(\.deviceID), [device(1), device(2)])
        XCTAssertEqual(original.selectedDeviceID, device(1))
    }

    func testSharedHardwareControlsKeepFullTargetsAtNarrowWidths() {
        let buttons = (0..<6).map { index in
            ThemedIconButton(symbolName: "house", accessibility: "Button \(index)", target: .device, inkSource: .chrome)
        }
        let controls = SimulatorHardwareControlsView(buttons: buttons)
        for width in [CGFloat(396), 236] {
            let height = controls.preferredHeight(for: width)
            controls.frame = NSRect(x: 0, y: 0, width: width, height: height)
            controls.layoutSubtreeIfNeeded()
            for button in buttons {
                XCTAssertEqual(button.bounds.size, ThemedIconButton.Target.device.size)
                XCTAssertTrue(controls.bounds.contains(button.frame))
            }
        }
        XCTAssertEqual(controls.preferredHeight(for: 236), 90)
    }

    func testSharedToolbarScopeClaimsDeviceShortcutsDuringReconnect() throws {
        let workspace = SimulatorWorkspaceViewController(state: SimulatorWorkspaceState(deviceID: device(1))) { id in
            SimulatorPaneViewController(preferredDeviceID: id, isWorkspaceMember: true, control: WorkspaceControlFake())
        }
        defer { workspace.terminate() }
        let scope = try XCTUnwrap(workspace.view as? KeyEquivalentScopeView)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
        XCTAssertEqual(scope.onKeyEquivalent?(event), true,
                       "A focused shared toolbar must not route the Simulator side-button chord to Browser.")
    }

    func testKeyboardRoutingFollowsTheFocusedMemberAfterAnotherMemberWasSelected() throws {
        let workspace = SimulatorWorkspaceViewController(state: SimulatorWorkspaceState(deviceID: device(1))) { id in
            SimulatorPaneViewController(preferredDeviceID: id, isWorkspaceMember: true, control: WorkspaceControlFake())
        }
        defer { workspace.terminate() }
        let first = workspace.selectedSimulator
        _ = try workspace.adopt(device(2))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = workspace
        window.setContentSize(NSSize(width: 420, height: 600))
        workspace.view.layoutSubtreeIfNeeded()
        workspace.canvasForTesting.layout()
        XCTAssertTrue(first.view.window === window, "The member must be mounted in the routing fixture.")
        let field = SimulatorWorkspaceFocusView()
        first.view.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let scope = try XCTUnwrap(first.view as? KeyEquivalentScopeView)
        XCTAssertTrue(scope.containsKeyboardFocus)
        XCTAssertFalse(workspace.selectedSimulator === first)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
        let root = try XCTUnwrap(workspace.view as? KeyEquivalentScopeView)
        XCTAssertEqual(root.onKeyEquivalent?(event), true)
        XCTAssertTrue(workspace.selectedSimulator === first)
        window.contentViewController = nil
    }

    func testDecoderRefusesDuplicateDevicesAndMissingSelection() throws {
        var state = SimulatorWorkspaceState(deviceID: device(1))
        state.members.append(.init(id: UUID(), deviceID: device(1)))
        XCTAssertThrowsError(try JSONDecoder().decode(SimulatorWorkspaceState.self, from: JSONEncoder().encode(state)))
        state = SimulatorWorkspaceState(deviceID: device(1))
        state.selectedID = UUID()
        XCTAssertThrowsError(try JSONDecoder().decode(SimulatorWorkspaceState.self, from: JSONEncoder().encode(state)))
    }

    func testDeviceTargetArgumentSurvivesWireDecoding() throws {
        let payload = Data("{\"x\":0.5,\"y\":0.5,\"device_id\":\"\(device(2).rawValue)\"}".utf8)
        let tap = try JSONDecoder().decode(SimulatorTapArguments.self, from: payload)
        XCTAssertEqual(tap.deviceID, device(2).rawValue)
        XCTAssertEqual(tap.x, 0.5)
        let text = try JSONDecoder().decode(SimulatorTypeTextArguments.self,
            from: Data("{\"text\":\"Hello\",\"device_id\":\"\(device(2).rawValue)\"}".utf8))
        XCTAssertEqual(text.deviceID, device(2).rawValue)
        XCTAssertEqual(text.text, "Hello")
    }

    func testSelectionAndLayoutDoNotReBriefTheAgent() throws {
        let pane = DisplayPaneController(simulatorControl: WorkspaceControlFake())
        let session = SessionID()
        defer { pane.removeSession(session); DisplayPaneStore.shared.removeSession(session) }
        _ = try pane.activateSimulator(for: session, deviceID: device(1))
        _ = try pane.activateSimulator(for: session, deviceID: device(2))
        let workspace = try XCTUnwrap(pane.simulatorWorkspace(for: session))
        let briefed = try XCTUnwrap(DisplayPaneStore.shared.loadLayout(for: session)?.signature)
        workspace.select(try XCTUnwrap(workspace.state.members.first?.id))
        workspace.setLayout(.grid)
        XCTAssertEqual(DisplayPaneStore.shared.loadLayout(for: session)?.signature, briefed,
                       "Agents never follow the person's selection or layout, so neither re-briefs them.")
        _ = try pane.activateSimulator(for: session, deviceID: device(3))
        XCTAssertNotEqual(DisplayPaneStore.shared.loadLayout(for: session)?.signature, briefed)
        let brief = try XCTUnwrap(DisplayPaneStore.shared.loadLayout(for: session)?.agentDescription)
        XCTAssertTrue(brief.contains(device(3).rawValue) && brief.contains("device_id"), brief)
    }

    func testALoneDeviceChooserSwitchesTheDeviceAndAddKeepsTheOther() throws {
        let workspace = SimulatorWorkspaceViewController(state: SimulatorWorkspaceState(deviceID: device(1))) { id in
            SimulatorPaneViewController(preferredDeviceID: id, isWorkspaceMember: true, control: WorkspaceControlFake())
        }
        defer { workspace.terminate() }
        _ = workspace.view
        let chooser = try XCTUnwrap(workspace.headerForTesting.leadingViews.first as? ChipView)
        chooser.onSelect?(ThemedMenuItem(title: "Second", representedValue: SimulatorWorkspaceViewController.ChooserChoice.device(device(2))))
        XCTAssertEqual(workspace.state.members.compactMap(\.deviceID), [device(2)],
                       "Alone, choosing another device switches it, as the single pane always did.")
        _ = try workspace.adopt(device(3))
        XCTAssertEqual(workspace.state.members.compactMap(\.deviceID), [device(2), device(3)])
        let first = try XCTUnwrap(workspace.state.members.first?.id)
        chooser.onSelect?(ThemedMenuItem(title: "First", representedValue: SimulatorWorkspaceViewController.ChooserChoice.member(first)))
        XCTAssertEqual(workspace.state.selectedID, first, "Beside peers, the chooser selects a member.")
        XCTAssertEqual(workspace.state.members.count, 2)
    }

    func testRemovingTheSelectedMemberSelectsItsNeighbour() throws {
        let workspace = SimulatorWorkspaceViewController(state: SimulatorWorkspaceState(deviceID: device(1))) { id in
            SimulatorPaneViewController(preferredDeviceID: id, isWorkspaceMember: true, control: WorkspaceControlFake())
        }
        defer { workspace.terminate() }
        for number in 2...4 { _ = try workspace.adopt(device(number)) }
        let third = workspace.state.members[2].id
        _ = try workspace.adopt(device(2))
        workspace.removeSelected()
        XCTAssertEqual(workspace.state.selectedID, third)
        XCTAssertEqual(workspace.state.members.compactMap(\.deviceID), [device(1), device(3), device(4)])
        workspace.select(try XCTUnwrap(workspace.state.members.last?.id))
        workspace.removeSelected()
        XCTAssertEqual(workspace.state.members.last?.id, workspace.state.selectedID)
    }

    func testEachDeviceMenuRemovesItsOwnMemberAndSharedMenuKeepsSharedSettings() throws {
        let workspace = SimulatorWorkspaceViewController(state: SimulatorWorkspaceState(deviceID: device(1))) { id in
            SimulatorPaneViewController(preferredDeviceID: id, isWorkspaceMember: true, control: WorkspaceControlFake())
        }
        defer { workspace.terminate() }
        _ = workspace.view
        let first = workspace.selectedSimulator
        let second = try workspace.adopt(device(2))
        let headerItems = first.workspaceHeaderMenuEntries().compactMap { entry -> ThemedMenuItem? in
            if case .item(let item) = entry { return item }
            return nil
        }
        XCTAssertEqual(headerItems.map(\.title), SimulatorWorkspaceLayout.allCases.map(\.displayTitle)
                       + [L10n.string("Show Touches"), L10n.string("Touch Style")])
        XCTAssertFalse(headerItems.contains { $0.title.contains("Remove") })
        first.workspaceHeaderShowsLayout = true
        let wideHeaderItems = first.workspaceHeaderMenuEntries().compactMap { entry -> ThemedMenuItem? in
            if case .item(let item) = entry { return item }
            return nil
        }
        XCTAssertEqual(wideHeaderItems.map(\.title), [L10n.string("Show Touches"), L10n.string("Touch Style")])

        func memberMenu(in simulator: SimulatorPaneViewController) -> ThemedIconButton? {
            let button = simulator.view.subviews.compactMap { $0 as? NSStackView }
                .flatMap(\.arrangedSubviews)
                .first { $0.accessibilityIdentifier() == "simulator.workspace.memberOptions" }
            return button as? ThemedIconButton
        }
        let firstMenu = try XCTUnwrap(memberMenu(in: first))
        let secondMenu = try XCTUnwrap(memberMenu(in: second))
        XCTAssertFalse(firstMenu.isHidden)
        XCTAssertFalse(secondMenu.isHidden)
        XCTAssertTrue(secondMenu.accessibilityTitle()?.contains(second.workspaceDeviceName) == true)
        let deviceTitles = second.memberMenuEntries().compactMap { entry -> String? in
            if case .item(let item) = entry { return item.title }
            return nil
        }
        XCTAssertTrue(deviceTitles.contains { $0.hasPrefix("Remove ") })
        XCTAssertFalse(deviceTitles.contains(L10n.string("Show Touches")))
        XCTAssertFalse(deviceTitles.contains(L10n.string("Touch Style")))

        let secondExtras = second.workspaceMenuExtras?() ?? []
        let removeSecond = try XCTUnwrap(secondExtras.compactMap { entry -> ThemedMenuItem? in
            if case .item(let item) = entry { return item }
            return nil
        }.first)
        workspace.select(workspace.state.members[0].id)
        removeSecond.onChoose?()
        XCTAssertEqual(workspace.state.members.compactMap(\.deviceID), [device(1)])
        XCTAssertTrue(workspace.selectedSimulator === first)
    }

    func testPublicCapturesTurnUprightInTheAxesInputMapsBackThrough() throws {
        for orientation in SimulatorScreenOrientation.allCases {
            let capture = try XCTUnwrap(SimulatorUprightCapture.uprightNow(try markedNativePNG(), orientation: orientation))
            XCTAssertEqual(capture.image.width, orientation.swapsAxes ? 4 : 2)
            XCTAssertEqual(capture.image.height, orientation.swapsAxes ? 2 : 4)
            let marked = try XCTUnwrap(redPixel(in: capture.image))
            let native = orientation.nativePoint(x: (Double(marked.x) + 0.5) / Double(capture.image.width),
                                                 y: (Double(marked.y) + 0.5) / Double(capture.image.height))
            XCTAssertEqual(native.x, 0.25, accuracy: 0.001, "\(orientation)")
            XCTAssertEqual(native.y, 0.125, accuracy: 0.001, "\(orientation)")
        }
    }

    /// A 2×4 native framebuffer whose only red pixel is its top-left one.
    private func markedNativePNG() throws -> Data {
        var pixels = [UInt8](repeating: 255, count: 2 * 4 * 4)
        pixels[1] = 0; pixels[2] = 0
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func redPixel(in image: CGImage) -> (x: Int, y: Int)? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                if pixels[offset] > 200, pixels[offset + 1] < 60, pixels[offset + 2] < 60 { return (x, y) }
            }
        }
        return nil
    }

    func testStressViewportResizingKeepsBoundedStableDeviceViews() throws {
        guard ProcessInfo.processInfo.environment["THREADING_STRESS"] == "1" else { throw XCTSkip("Opt-in workspace resize fixture.") }
        // Sixteen retained member values across four sessions; only the selected workspace mounts.
        var workspaces: [SimulatorWorkspaceViewController] = []
        for _ in 0..<4 {
            let workspace = SimulatorWorkspaceViewController(state: SimulatorWorkspaceState(deviceID: device(1))) { id in
                SimulatorPaneViewController(preferredDeviceID: id, isWorkspaceMember: true, control: WorkspaceControlFake())
            }
            for number in 2...4 { _ = try workspace.adopt(device(number)) }
            workspaces.append(workspace)
        }
        defer { workspaces.forEach { $0.terminate() } }
        for count in [1, 2, 4] {
            let workspace = SimulatorWorkspaceViewController(state: SimulatorWorkspaceState(deviceID: device(1))) { id in
                SimulatorPaneViewController(preferredDeviceID: id, isWorkspaceMember: true, control: WorkspaceControlFake())
            }
            if count > 1 { for number in 2...count { _ = try workspace.adopt(device(number)) } }
            defer { workspace.terminate() }
            let identities = workspace.simulators.map(ObjectIdentifier.init)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = workspace
            workspace.view.layoutSubtreeIfNeeded()
            var times: [Double] = []
            for step in 0..<500 {
                let start = Date.timeIntervalSinceReferenceDate
                window.setContentSize(NSSize(width: 420 + step % 200, height: 600 + step % 80))
                workspace.view.layoutSubtreeIfNeeded()
                times.append((Date.timeIntervalSinceReferenceDate - start) * 1_000)
            }
            XCTAssertEqual(workspace.simulators.map(ObjectIdentifier.init), identities)
            XCTAssertEqual(workspace.canvasForTesting.tiles.count, count)
            XCTAssertTrue(workspaces.allSatisfy { !$0.isViewLoaded })
            times.sort()
            let p95 = times[times.count * 95 / 100]
            XCTAssertLessThan(p95, 16, "Bounded workspace resizing must fit an ordinary frame budget.")
            print("Simulator workspace resize: members=\(count) median=\(times[times.count / 2]) ms p95=\(p95) ms max=\(times.last ?? 0) ms; background members=16")
            window.contentViewController = nil
        }
    }

    private func plan(size: CGSize, aspects: [CGFloat], layout: SimulatorWorkspaceLayout = .automatic, selected: Int = 0) -> SimulatorWorkspaceGeometry.Plan {
        SimulatorWorkspaceGeometry.plan(size: size, aspects: aspects, layout: layout, selectedIndex: selected,
                                        gap: 10, titleHeight: 26)
    }

    private func device(_ number: Int) -> SimulatorDeviceID {
        SimulatorDeviceID(String(format: "00000000-0000-0000-0000-%012d", number))!
    }
}

private actor WorkspaceControlFake: SimulatorControlling {
    func availableDevices() async throws -> [SimulatorDevice] { [] }
    func prepare(deviceID: SimulatorDeviceID?) async throws -> SimulatorDeviceLease { throw SimulatorControlError.noAvailableIOSDevices }
    func installAndLaunch(applicationURL: URL, bundleIdentifier: String, on deviceID: SimulatorDeviceID, arguments: [String]) async throws -> SimulatorLaunchReceipt {
        throw SimulatorControlError.deviceNotFound(deviceID)
    }
    func screenshot(of deviceID: SimulatorDeviceID) async throws -> Data { throw SimulatorControlError.invalidScreenshot }
    func release(_ lease: SimulatorDeviceLease) async throws {}
}

private final class SimulatorWorkspaceFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
