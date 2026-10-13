import AppKit
import AVFoundation
import XCTest
@testable import Threading

@MainActor
final class RealDevicePaneTests: HostedStoreTestCase {
    func testLiveDragCoalescesMovesButPreservesDownUpAndQueuedTaps() async throws {
        let control = RealDeviceControlFake(support: .available(supportedMediaFeatures: 140), liveTouch: true)
        let authorizer = PhysicalDeviceInputAuthorizerFake(approval: true)
        let controller = RealDevicePaneViewController(control: control, inputAuthorizer: authorizer)
        _ = controller.view
        defer { controller.terminate() }
        controller.setPresented(true)
        try await eventually { controller.frameImageForTesting != nil && controller.controlSupportForTesting != nil }
        XCTAssertTrue(controller.controlButtonForTesting.performPrimaryAction())
        try await eventually { controller.screenInteractionStateForTesting == .ready(touch: true, keyboard: false) }
        let screen = controller.screenViewForTesting
        screen.onTouchBegan?(CGPoint(x: 0.1, y: 0.2))
        for index in 0..<1000 { screen.onTouchMoved?(CGPoint(x: Double(index) / 1000, y: 0.5)) }
        screen.onTouchEnded?(CGPoint(x: 0.9, y: 0.5))
        screen.onTap?(CGPoint(x: 0.3, y: 0.4))
        screen.onTap?(CGPoint(x: 0.6, y: 0.7))
        try await eventually { await control.inputs().count == 5 }
        let events = await control.inputs()
        XCTAssertEqual(events, [
            .touchDown(x: 0.1, y: 0.2), .touchMove(x: 0.999, y: 0.5), .touchUp(x: 0.9, y: 0.5),
            .tap(x: 0.3, y: 0.4), .tap(x: 0.6, y: 0.7),
        ])
        controller.setPresented(false)
        screen.onTap?(CGPoint(x: 0.5, y: 0.5))
        await Task.yield()
        let after = await control.inputs()
        XCTAssertEqual(after, events)
    }
    func testMissingToolingOffersSetupInsteadOfAnUnrelatedConnectionInstruction() async throws {
        let control = RealDeviceControlFake(
            support: .unknown(.probeToolUnavailable),
            screenshotFailure: .screenshotToolUnavailable
        )
        let controller = RealDevicePaneViewController(control: control)
        _ = controller.view
        defer { controller.terminate() }
        var settingsOpens = 0
        controller.onOpenToolingSettings = { settingsOpens += 1 }

        controller.setPresented(true)
        try await eventually { controller.statusForTesting.contains("Setup required") }
        XCTAssertFalse(controller.toolingButtonForTesting.isHidden)
        XCTAssertEqual(controller.toolingButtonForTesting.title, "Install iPhone Tooling…")
        XCTAssertFalse(controller.emptyLabelForTesting.stringValue.contains("Connect and unlock"))
        XCTAssertTrue(controller.toolingButtonForTesting.performPrimaryAction())
        XCTAssertEqual(settingsOpens, 1)
        let counts = await control.counts()
        XCTAssertEqual(counts.preparations, 0, "Opening Settings cannot prepare or control a phone")
        let inputs = await control.inputs()
        XCTAssertTrue(inputs.isEmpty)
    }

    func testOlderToolOffersUpdateAndPreservesAnExistingPreview() async throws {
        let controller = RealDevicePaneViewController(control: RealDeviceControlFake(
            support: .unknown(.probeVersionUnsupported)
        ))
        _ = controller.view
        defer { controller.terminate() }
        var settingsOpens = 0
        controller.onOpenToolingSettings = { settingsOpens += 1 }
        controller.setPresented(true)
        try await eventually {
            controller.frameImageForTesting != nil && controller.controlSupportForTesting != nil
        }
        XCTAssertEqual(controller.toolingButtonForTesting.title, "Update iPhone Tooling…")
        XCTAssertEqual(controller.controlButtonForTesting.toolTip, "Update iPhone Tooling…")
        XCTAssertTrue(controller.controlButtonForTesting.performPrimaryAction())
        XCTAssertEqual(settingsOpens, 1)
        XCTAssertNotNil(controller.frameImageForTesting)
    }

    func testSuccessfulInstallationRetriesOnlyPresentedPanesWithoutGrantingControl() async throws {
        let center = NotificationCenter()
        let control = RealDeviceControlFake(
            support: .unknown(.probeToolUnavailable),
            screenshotFailure: .screenshotToolUnavailable
        )
        let controller = RealDevicePaneViewController(control: control, notificationCenter: center)
        _ = controller.view
        defer { controller.terminate() }
        controller.setPresented(true)
        try await eventually { controller.statusForTesting.contains("Setup required") }

        controller.setPresented(false)
        let before = await control.counts()
        center.post(Pymobiledevice3ToolDidInstall())
        await Task.yield()
        let after = await control.counts()
        XCTAssertEqual(before.available, after.available)
        XCTAssertEqual(before.screenshots, after.screenshots)

        controller.setPresented(true)
        try await eventually { controller.statusForTesting.contains("Setup required") }
        await control.installTooling()
        center.post(Pymobiledevice3ToolDidInstall())
        try await eventually {
            controller.frameImageForTesting != nil
                && controller.controlSupportForTesting == .available(supportedMediaFeatures: 140)
        }
        XCTAssertTrue(controller.toolingButtonForTesting.isHidden)
        XCTAssertEqual(controller.screenInteractionStateForTesting, .unavailable)
    }

    func testUnrelatedCaptureFailureDoesNotOfferToolInstallation() async throws {
        let controller = RealDevicePaneViewController(control: RealDeviceControlFake(
            screenshotFailure: .invalidScreenshot
        ))
        _ = controller.view
        defer { controller.terminate() }
        controller.setPresented(true)
        try await eventually { controller.statusForTesting.contains("valid screenshot") }
        XCTAssertTrue(controller.toolingButtonForTesting.isHidden)
    }

    func testCaptureRunsOnlyWhileThePaneIsPresented() async throws {
        let control = RealDeviceControlFake()
        let controller = RealDevicePaneViewController(control: control)
        _ = controller.view
        defer { controller.terminate() }

        XCTAssertEqual(controller.presentationState, .idle)
        let initialCounts = await control.counts()
        XCTAssertEqual(initialCounts.screenshots, 0)

        controller.setPresented(true)
        try await eventually {
            controller.frameImageForTesting != nil
                && controller.controlSupportForTesting != nil
        }
        XCTAssertEqual(controller.selectedDeviceID, physicalDeviceTestFixture.id)
        XCTAssertTrue(controller.statusForTesting.contains("View only"))
        XCTAssertTrue(controller.statusForTesting.contains("Preview fallback"))
        XCTAssertTrue(controller.statusForTesting.contains("Media streaming unavailable"))
        XCTAssertEqual(
            controller.controlSupportForTesting,
            .unavailable(.mediaStreamingUnavailable)
        )

        var openedLogsFor: PhysicalDeviceID?
        controller.onOpenDeviceLogs = { openedLogsFor = $0 }
        XCTAssertTrue(controller.logsButtonForTesting.performPrimaryAction())
        XCTAssertEqual(openedLogsFor, physicalDeviceTestFixture.id)

        controller.setPresented(false)
        let hiddenCount = await control.counts().screenshots
        try await Task.sleep(for: .milliseconds(1_100))
        let finalCounts = await control.counts()
        XCTAssertEqual(finalCounts.screenshots, hiddenCount)
        XCTAssertFalse(controller.isPresentedForTesting)
    }

    func testDiscoveryFailureStaysInsideThePane() async throws {
        let control = RealDeviceControlFake(failure: .noAvailableIPhones)
        let controller = RealDevicePaneViewController(control: control)
        _ = controller.view
        defer { controller.terminate() }

        controller.setPresented(true)
        try await eventually {
            if case .failed = controller.presentationState { return true }
            return false
        }

        XCTAssertTrue(controller.statusForTesting.contains("No paired iPhone"))
        XCTAssertTrue(controller.isPresentedForTesting)
        XCTAssertFalse(controller.emptyLabelForTesting.isHidden)
    }

    func testSelectingADeviceWhileHiddenDoesNotDiscoverIt() async {
        let control = RealDeviceControlFake()
        let controller = RealDevicePaneViewController(control: control)
        _ = controller.view
        defer { controller.terminate() }

        controller.selectDevice(physicalDeviceTestFixture.id)

        let counts = await control.counts()
        XCTAssertEqual(counts.available, 0)
        XCTAssertEqual(counts.screenshots, 0)
        XCTAssertEqual(controller.selectedDeviceID, physicalDeviceTestFixture.id)
        XCTAssertEqual(controller.presentationState, .idle)
    }

    func testPhysicalDeviceInputRequiresApprovalAndIsRevokedWhenHidden() async throws {
        let control = RealDeviceControlFake(
            support: .available(supportedMediaFeatures: 140)
        )
        let authorizer = PhysicalDeviceInputAuthorizerFake(approval: true)
        let controller = RealDevicePaneViewController(
            control: control,
            inputAuthorizer: authorizer
        )
        _ = controller.view
        defer { controller.terminate() }

        controller.setPresented(true)
        try await eventually {
            controller.frameImageForTesting != nil
                && controller.controlSupportForTesting != nil
        }
        XCTAssertEqual(controller.screenInteractionStateForTesting, .unavailable)
        XCTAssertTrue(controller.statusForTesting.contains("Click to enable control"))

        XCTAssertTrue(controller.controlButtonForTesting.performPrimaryAction())
        XCTAssertEqual(
            controller.screenInteractionStateForTesting,
            .ready(touch: true, keyboard: false)
        )
        XCTAssertTrue(controller.statusForTesting.contains("Control ready"))

        XCTAssertTrue(controller.screenViewForTesting.performPrimaryAction())
        try await eventually { await control.inputs() == [.tap(x: 0.5, y: 0.5)] }

        controller.setPresented(false)
        XCTAssertEqual(controller.screenInteractionStateForTesting, .unavailable)
        XCTAssertNil(authorizer.decision(for: physicalDeviceTestFixture.id))
    }

    func testApprovedPhysicalDeviceKeyboardTypesOnlyWhilePaneOwnsControl() async throws {
        let control = RealDeviceControlFake(
            support: .available(supportedMediaFeatures: 140),
            liveTouch: true,
            keyboardInput: true
        )
        let controller = RealDevicePaneViewController(
            control: control,
            inputAuthorizer: PhysicalDeviceInputAuthorizerFake(approval: true)
        )
        _ = controller.view
        defer { controller.terminate() }

        controller.setPresented(true)
        try await eventually {
            controller.frameImageForTesting != nil
                && controller.controlSupportForTesting != nil
        }
        XCTAssertTrue(controller.controlButtonForTesting.performPrimaryAction())
        try await eventually {
            controller.screenInteractionStateForTesting == .ready(touch: true, keyboard: true)
        }

        controller.screenViewForTesting.onText?("Az!")
        try await eventually { await control.inputs().count == 3 }
        let typed = await control.inputs()
        XCTAssertEqual(typed, [
            .key(usage: 0x04, shift: true),
            .key(usage: 0x1D, shift: false),
            .key(usage: 0x1E, shift: true),
        ])

        controller.setPresented(false)
        controller.screenViewForTesting.onText?("x")
        await Task.yield()
        let afterHide = await control.inputs()
        XCTAssertEqual(afterHide.count, 3)
    }

    func testFailedProbeOffersExplicitDeveloperSupportPreparation() async throws {
        let control = RealDeviceControlFake(
            support: .unknown(.probeFailed),
            preparedSupport: .available(supportedMediaFeatures: 140)
        )
        let controller = RealDevicePaneViewController(
            control: control,
            inputAuthorizer: PhysicalDeviceInputAuthorizerFake(approval: true)
        )
        _ = controller.view
        defer { controller.terminate() }

        controller.setPresented(true)
        try await eventually {
            controller.controlSupportForTesting == .unknown(.probeFailed)
        }
        XCTAssertEqual(
            controller.controlButtonForTesting.toolTip,
            "Prepare iPhone Control"
        )

        XCTAssertTrue(controller.controlButtonForTesting.performPrimaryAction())
        try await eventually {
            controller.controlSupportForTesting == .available(supportedMediaFeatures: 140)
        }
        let counts = await control.counts()
        XCTAssertEqual(counts.preparations, 1)
    }

    func testPreparationFailureExplainsThatTheExactPhoneNeedsUSB() async throws {
        let control = RealDeviceControlFake(
            support: .unknown(.probeFailed),
            preparationFailure: .controlPreparationRequiresUSB
        )
        let controller = RealDevicePaneViewController(control: control)
        _ = controller.view
        defer { controller.terminate() }

        controller.setPresented(true)
        try await eventually {
            controller.controlSupportForTesting == .unknown(.probeFailed)
        }

        XCTAssertTrue(controller.controlButtonForTesting.performPrimaryAction())
        try await eventually {
            controller.statusForTesting.contains(
                "Connect this iPhone with a cable, unlock it, then retry."
            )
        }
        let counts = await control.counts()
        XCTAssertEqual(counts.preparations, 1)
    }

    func testPhysicalDeviceConsentIsExactDeviceScopedAndRevocable() throws {
        var presentedRequest: ConfirmationRequest?
        var presentedCompletion: (@MainActor (Bool) -> Void)?
        let authorizer = PhysicalDeviceInputConsentController { request, _, completion in
            presentedRequest = request
            presentedCompletion = completion
        }

        var result: Bool?
        authorizer.authorize(device: physicalDeviceTestFixture, in: nil) { result = $0 }

        XCTAssertEqual(presentedRequest?.prompt, .controlPhysicalDevice)
        XCTAssertTrue(presentedRequest?.message.contains("exact iPhone") == true)
        XCTAssertTrue(presentedRequest?.message.contains("type") == true)
        XCTAssertNil(authorizer.decision(for: physicalDeviceTestFixture.id))
        try XCTUnwrap(presentedCompletion)(true)
        XCTAssertEqual(result, true)
        XCTAssertEqual(authorizer.decision(for: physicalDeviceTestFixture.id), true)

        authorizer.revokeDecision(for: physicalDeviceTestFixture.id)
        XCTAssertNil(authorizer.decision(for: physicalDeviceTestFixture.id))
    }

    func testPhysicalDeviceConsentDenialDoesNotRepromptUntilExplicitReset() throws {
        var presentationCount = 0
        var presentedCompletion: (@MainActor (Bool) -> Void)?
        let authorizer = PhysicalDeviceInputConsentController { _, _, completion in
            presentationCount += 1
            presentedCompletion = completion
        }

        var firstResult: Bool?
        authorizer.authorize(device: physicalDeviceTestFixture, in: nil) { firstResult = $0 }
        try XCTUnwrap(presentedCompletion)(false)
        XCTAssertEqual(firstResult, false)

        var rememberedResult: Bool?
        authorizer.authorize(device: physicalDeviceTestFixture, in: nil) {
            rememberedResult = $0
        }
        XCTAssertEqual(rememberedResult, false)
        XCTAssertEqual(presentationCount, 1)

        authorizer.resetDecision(for: physicalDeviceTestFixture.id)
        authorizer.authorize(device: physicalDeviceTestFixture, in: nil) { _ in }
        XCTAssertEqual(presentationCount, 2)
    }

    func testDisplayPanePersistsOnePhysicalDeviceTabAndRestoresItLazily() async throws {
        let sessionID = SessionID()
        defer { DisplayPaneStore.shared.removeSession(sessionID) }
        let control = RealDeviceControlFake()
        let pane = DisplayPaneController(physicalDeviceControl: control)

        let first = pane.activateRealDevice(
            for: sessionID,
            deviceID: physicalDeviceTestFixture.id
        )
        let second = pane.activateRealDevice(for: sessionID)

        XCTAssertTrue(first === second)
        XCTAssertEqual(pane.tabs(for: sessionID).filter { $0.realDevice != nil }.count, 1)
        let stored = try XCTUnwrap(
            DisplayPaneStore.shared.loadLayout(for: sessionID)?.panelTabs.first
        )
        XCTAssertEqual(stored.kind, .realDevice)
        XCTAssertEqual(stored.physicalDeviceID, physicalDeviceTestFixture.id.rawValue)
        XCTAssertEqual(
            DisplayPaneStore.shared.loadLayout(for: sessionID)?.requiredFormatVersion,
            4
        )
        let unpresentedCounts = await control.counts()
        XCTAssertEqual(unpresentedCounts.available, 0)

        let restoredControl = RealDeviceControlFake()
        let restored = DisplayPaneController(physicalDeviceControl: restoredControl)
        let restoredTab = try XCTUnwrap(restored.tabs(for: sessionID).first)
        XCTAssertEqual(restoredTab.realDevice?.selectedDeviceID, physicalDeviceTestFixture.id)
        let restoredCounts = await restoredControl.counts()
        XCTAssertEqual(restoredCounts.available, 0)
    }

    func testScreenshotSavesDisplayedFrameWithoutGrantingInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = RealDeviceControlFake(frame: try captureFrame())
        var saved: URL?
        let controller = RealDevicePaneViewController(control: control, captureDirectory: directory,
            revealCapture: { saved = $0 })
        _ = controller.view
        defer { controller.terminate() }
        controller.setPresented(true)
        try await eventually { controller.canCapture }
        XCTAssertEqual(controller.captureButtonForTesting.accessibilityTitle(), L10n.string("Save Screenshot"))
        XCTAssertTrue(controller.captureButtonForTesting.performPrimaryAction())
        try await eventually { saved != nil }
        let image = try XCTUnwrap(NSImage(contentsOf: XCTUnwrap(saved)))
        XCTAssertEqual(image.size, NSSize(width: 48, height: 64))
        let inputs = await control.inputs()
        XCTAssertTrue(inputs.isEmpty)
        XCTAssertEqual(controller.screenInteractionStateForTesting, .unavailable)
    }

    func testRecordingSurvivesHiddenPaneAndFinishesAPlayableMovie() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = RealDeviceControlFake(support: .available(supportedMediaFeatures: 140),
            frame: try captureFrame(), interval: .milliseconds(40))
        var saved: URL?
        let controller = RealDevicePaneViewController(control: control,
            inputAuthorizer: PhysicalDeviceInputAuthorizerFake(approval: true),
            captureDirectory: directory, revealCapture: { saved = $0 })
        _ = controller.view
        defer { controller.terminate() }
        controller.setPresented(true)
        try await eventually { controller.canRecord && controller.controlSupportForTesting != nil }
        XCTAssertTrue(controller.controlButtonForTesting.performPrimaryAction())
        XCTAssertTrue(controller.recordButtonForTesting.performPrimaryAction())
        try await eventually { controller.recordingHasStartedForTesting }
        XCTAssertFalse(controller.recordingBadgeForTesting.isHidden)
        XCTAssertTrue(controller.screenViewForTesting.isRecording)
        controller.setPresented(false)
        XCTAssertEqual(controller.screenInteractionStateForTesting, .unavailable)
        let before = await control.counts().screenshots
        try await eventually { await control.counts().screenshots >= before + 3 }
        controller.stopRecording()
        try await eventually { controller.recordingHasFinishedForTesting }
        XCTAssertTrue(controller.recordingBadgeForTesting.isHidden)
        let asset = AVURLAsset(url: try XCTUnwrap(saved))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 48, height: 64))
        let after = await control.counts().screenshots
        try await Task.sleep(for: .milliseconds(160))
        let stopped = await control.counts().screenshots
        XCTAssertEqual(after, stopped)
    }

    func testPresenterKeepsPreviewButCannotKeepInputConsentWhenPaneHides() async throws {
        let control = RealDeviceControlFake(support: .available(supportedMediaFeatures: 140),
            frame: try captureFrame(), interval: .milliseconds(40))
        var presenter: SimulatorPresenterWindowController?
        let controller = RealDevicePaneViewController(control: control,
            inputAuthorizer: PhysicalDeviceInputAuthorizerFake(approval: true),
            showPresenter: { presenter = $0 })
        _ = controller.view
        defer { controller.terminate() }
        controller.setPresented(true)
        try await eventually { controller.canCapture && controller.controlSupportForTesting != nil }
        XCTAssertTrue(controller.controlButtonForTesting.performPrimaryAction())
        XCTAssertTrue(controller.presenterButtonForTesting.performPrimaryAction())
        let mirror = try XCTUnwrap(presenter).screenView
        XCTAssertEqual(mirror.image?.size, controller.frameImageForTesting?.size)
        controller.setPresented(false)
        XCTAssertEqual(mirror.interactionState, .unavailable)
        mirror.onTap?(CGPoint(x: 0.5, y: 0.5))
        let inputs = await control.inputs()
        XCTAssertTrue(inputs.isEmpty)
        let before = await control.counts().screenshots
        try await eventually { await control.counts().screenshots > before }
        controller.togglePresenterWindow()
        let closed = await control.counts().screenshots
        try await Task.sleep(for: .milliseconds(160))
        let after = await control.counts().screenshots
        XCTAssertEqual(closed, after)
    }

    func testTouchOverlayOnlyDrawsAuthorizedInputAndClearsOnRevocation() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SimulatorTouchPreferences(defaults: defaults)
        preferences.showsLiveTouches = true
        let controller = RealDevicePaneViewController(
            control: RealDeviceControlFake(support: .available(supportedMediaFeatures: 140)),
            inputAuthorizer: PhysicalDeviceInputAuthorizerFake(approval: true), touchPreferences: preferences)
        _ = controller.view
        defer { controller.terminate() }
        controller.setPresented(true)
        try await eventually { controller.canCapture && controller.controlSupportForTesting != nil }
        let screen = controller.screenViewForTesting
        screen.onTap?(CGPoint(x: 0.2, y: 0.3))
        XCTAssertNil(screen.touchIndicators)
        XCTAssertTrue(controller.controlButtonForTesting.performPrimaryAction())
        screen.onTap?(CGPoint(x: 0.2, y: 0.3))
        XCTAssertEqual(screen.touchIndicators?.ripples.first?.point, CGPoint(x: 0.2, y: 0.3))
        controller.setPresented(false)
        XCTAssertNil(screen.touchIndicators)
    }

    func testCaptureFailureFinishesRecordingAndDisablesNewCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = RealDeviceControlFake(frame: try captureFrame(), interval: .milliseconds(40))
        var saved: URL?
        let controller = RealDevicePaneViewController(control: control, captureDirectory: directory,
            revealCapture: { saved = $0 })
        _ = controller.view
        defer { controller.terminate() }
        controller.setPresented(true)
        try await eventually { controller.canRecord }
        controller.toggleRecording()
        try await eventually { controller.recordingHasStartedForTesting }
        await control.failScreenshot()
        try await eventually { controller.recordingHasFinishedForTesting && !controller.canCapture }
        XCTAssertNotNil(saved)
        XCTAssertFalse(controller.recordButtonForTesting.isEnabled)
        XCTAssertFalse(controller.captureButtonForTesting.isEnabled)
    }

    func testImmediateStopFinalizesStartupWithoutLeavingRecordingActive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var saved: [URL] = []
        let controller = RealDevicePaneViewController(control: RealDeviceControlFake(frame: try captureFrame()),
            captureDirectory: directory, revealCapture: { saved.append($0) })
        _ = controller.view
        defer { controller.terminate() }
        controller.setPresented(true)
        try await eventually { controller.canRecord }
        for count in 1...3 {
            controller.toggleRecording()
            controller.stopRecording()
            try await eventually { controller.recordingHasFinishedForTesting }
            XCTAssertEqual(saved.count, count)
            XCTAssertTrue(controller.canRecord)
            XCTAssertFalse(controller.screenViewForTesting.isRecording)
        }
    }

    func testRotationFinishesMovieAndRevokesControl() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = RealDeviceControlFake(support: .available(supportedMediaFeatures: 140),
            frame: try captureFrame(), interval: .milliseconds(40))
        var saved: URL?
        let controller = RealDevicePaneViewController(control: control,
            inputAuthorizer: PhysicalDeviceInputAuthorizerFake(approval: true),
            captureDirectory: directory, revealCapture: { saved = $0 })
        _ = controller.view
        defer { controller.terminate() }
        controller.setPresented(true)
        try await eventually { controller.canRecord && controller.controlSupportForTesting != nil }
        XCTAssertTrue(controller.controlButtonForTesting.performPrimaryAction())
        controller.toggleRecording()
        try await eventually { controller.recordingHasStartedForTesting }
        await control.replaceFrame(try captureFrame(width: 64, height: 48))
        try await eventually { controller.frameImageForTesting?.size == NSSize(width: 64, height: 48) }
        try await eventually { controller.recordingHasFinishedForTesting }
        XCTAssertEqual(controller.screenInteractionStateForTesting, .unavailable)
        let asset = AVURLAsset(url: try XCTUnwrap(saved))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 48, height: 64), "A new orientation must not be stretched into the old movie")
    }

    private func captureFrame(width: Int = 48, height: Int = 64) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func eventually(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for the physical-device pane.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private let physicalDeviceTestFixture = PhysicalDevice(
    id: PhysicalDeviceID("00008140-000C208C1108801C")!,
    coreDeviceIdentifier: UUID(uuidString: "ECE91967-105E-5BAE-9110-E49CBB0DEBD3")!,
    name: "David’s iPhone",
    productType: "iPhone17,1",
    osVersion: "26.6.2",
    connection: .localNetwork,
    developerModeEnabled: true,
    developerServicesAvailable: true
)

private actor RealDeviceControlFake: PhysicalDeviceControlling {
    nonisolated let frameInterval: Duration
    private var frame: Data?
    nonisolated let supportsLiveTouch: Bool
    nonisolated let supportsKeyboardInput: Bool
    struct Counts: Sendable {
        var available = 0
        var screenshots = 0
        var preparations = 0
    }

    private let failure: PhysicalDeviceControlError?
    private var support: PhysicalDeviceControlSupport
    private var screenshotFailure: PhysicalDeviceControlError?
    private let preparedSupport: PhysicalDeviceControlSupport?
    private let preparationFailure: PhysicalDeviceControlError?
    private var callCounts = Counts()
    private var sentInputs: [PhysicalDeviceInput] = []

    init(
        failure: PhysicalDeviceControlError? = nil,
        support: PhysicalDeviceControlSupport = .unavailable(.mediaStreamingUnavailable),
        preparedSupport: PhysicalDeviceControlSupport? = nil,
        preparationFailure: PhysicalDeviceControlError? = nil,
        screenshotFailure: PhysicalDeviceControlError? = nil,
        liveTouch: Bool = false,
        keyboardInput: Bool = false,
        frame: Data? = nil,
        interval: Duration = .seconds(1)
    ) {
        self.frame = frame
        frameInterval = interval
        self.failure = failure
        self.support = support
        self.preparedSupport = preparedSupport
        self.preparationFailure = preparationFailure
        self.screenshotFailure = screenshotFailure
        supportsLiveTouch = liveTouch
        supportsKeyboardInput = keyboardInput
    }

    func replaceFrame(_ frame: Data) { self.frame = frame }

    func failScreenshot() { screenshotFailure = .invalidScreenshot }

    func installTooling() {
        screenshotFailure = nil
        support = .available(supportedMediaFeatures: 140)
    }

    func counts() -> Counts { callCounts }
    func inputs() -> [PhysicalDeviceInput] { sentInputs }

    func availableDevices() async throws -> [PhysicalDevice] {
        callCounts.available += 1
        if let failure { throw failure }
        return [physicalDeviceTestFixture]
    }

    func controlSupport(of device: PhysicalDevice) async throws -> PhysicalDeviceControlSupport {
        if callCounts.preparations > 0, let preparedSupport { return preparedSupport }
        return support
    }

    func prepareControl(of device: PhysicalDevice) async throws {
        callCounts.preparations += 1
        if let preparationFailure { throw preparationFailure }
    }

    func sendInput(_ input: PhysicalDeviceInput, to device: PhysicalDevice) async throws {
        sentInputs.append(input)
    }

    func screenshot(of device: PhysicalDevice) async throws -> Data {
        callCounts.screenshots += 1
        if let screenshotFailure { throw screenshotFailure }
        return frame ?? Data(base64Encoded: Self.onePixelPNG)!
    }

    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/"
        + "ScLhWQAAAABJRU5ErkJggg=="
}

@MainActor
private final class PhysicalDeviceInputAuthorizerFake: PhysicalDeviceInputAuthorizing {
    private let approval: Bool
    private var decisions: [PhysicalDeviceID: Bool] = [:]

    init(approval: Bool) {
        self.approval = approval
    }

    func decision(for deviceID: PhysicalDeviceID) -> Bool? {
        decisions[deviceID]
    }

    func resetDecision(for deviceID: PhysicalDeviceID) {
        decisions.removeValue(forKey: deviceID)
    }

    func revokeDecision(for deviceID: PhysicalDeviceID) {
        decisions.removeValue(forKey: deviceID)
    }

    func authorize(
        device: PhysicalDevice,
        in window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        decisions[device.id] = approval
        completion(approval)
    }
}
