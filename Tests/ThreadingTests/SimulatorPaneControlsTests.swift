import AppKit
import Foundation
import ThreadingSimulatorKit
import XCTest
import os
@testable import Threading

/// The pane's capture, recording, touch, annotation and presenter controls, driven through the
/// shipping controller over the recovery tests' fake stream. Nothing here orders a window on
/// screen: the presenter window is built and mirrored, never shown.
@MainActor
final class SimulatorPaneControlsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var preferences: SimulatorTouchPreferences!
    private var recordingDirectory: URL!
    private var revealed: [URL] = []
    private var shownPresenters: [SimulatorPresenterWindowController] = []

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "codes.threading.tests.simulator-controls.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        preferences = SimulatorTouchPreferences(defaults: defaults)
        recordingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("simulator-controls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recordingDirectory,
            withIntermediateDirectories: true
        )
        revealed = []
        shownPresenters = []
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: recordingDirectory)
        SimulatorAnnotationStore.shared.setAnnotations([], for: simulatorRecoveryFirstDevice.id)
        try await super.tearDown()
    }

    // MARK: - Touch preferences

    func testTouchPreferencesStartQuietAndRememberEveryChoice() {
        XCTAssertFalse(preferences.showsLiveTouches, "A device screen is the person's content")
        XCTAssertEqual(preferences.style, .standard)

        let notifications = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: SimulatorTouchPreferences.didChange,
            object: preferences,
            queue: nil
        ) { _ in notifications.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        preferences.showsLiveTouches = true
        preferences.style = SimulatorTouchStyle(color: .yellow, size: .large, showsTrail: false)
        preferences.style = SimulatorTouchStyle(color: .yellow, size: .large, showsTrail: false)

        let reread = SimulatorTouchPreferences(defaults: defaults)
        XCTAssertTrue(reread.showsLiveTouches)
        XCTAssertEqual(reread.style, SimulatorTouchStyle(color: .yellow, size: .large, showsTrail: false))
        XCTAssertEqual(
            notifications.withLock { $0 }, 2,
            "An unchanged write must not redraw every pane"
        )
    }

    func testTouchToggleIsOneRememberedChoiceAcrossPanes() async throws {
        let first = makeController(session: SimulatorRecoveryStreamSessionFake())
        let second = makeController(session: SimulatorRecoveryStreamSessionFake())
        _ = first.view
        _ = second.view
        defer {
            first.terminate()
            second.terminate()
        }

        first.toggleShowTouches()

        XCTAssertTrue(preferences.showsLiveTouches)
        XCTAssertTrue(second.showsTouchesForCommands)
        XCTAssertTrue(second.showTouchesButtonForTesting.isSelected)
        XCTAssertEqual(
            second.showTouchesButtonForTesting.accessibilityTitle(),
            L10n.string("Hide Touches")
        )
    }

    // MARK: - Screen context menu

    func testScreenMenuOffersEverythingThePaneDoesToTheDevice() async throws {
        let session = SimulatorRecoveryStreamSessionFake()
        let controller = makeController(session: session)
        _ = controller.view
        defer { controller.terminate() }
        controller.setPresented(true)
        let frames = session.emitFramesContinuously(width: 40, height: 80)
        defer { frames.cancel() }
        try await eventually { controller.frameImageForTesting != nil }

        let entries = controller.screenMenuEntries(
            for: .init(anchor: .control, point: CGPoint(x: 0.4, y: 0.6), noteID: nil),
            includesNotes: true
        )
        let titles = Self.titles(entries)
        for expected in [
            "Copy Screenshot", "Save Screenshot", "Save Screenshot As…",
            "Record Video", "Record High-Quality Video",
            "Add Note Here", "Annotate Device",
            "Show Touches", "Touch Style", "Inspect Elements", "Open Presenter Window",
        ] {
            XCTAssertTrue(titles.contains(L10n.string(expected)), "Missing \(expected) in \(titles)")
        }
        XCTAssertTrue(Self.item(L10n.string("Add Note Here"), in: entries)?.isEnabled == true)
        // With no notes, the device's menu leaves note actions out rather than listing them greyed.
        XCTAssertFalse(titles.contains(L10n.string("Clear All Notes")))

        // The presenter's own menu is the device alone: no notes, no inspector, its own window.
        let presenterTitles = Self.titles(controller.screenMenuEntries(
            for: .init(anchor: .control, point: CGPoint(x: 0.4, y: 0.6), noteID: nil),
            includesNotes: false
        ))
        XCTAssertFalse(presenterTitles.contains(L10n.string("Add Note Here")))
        XCTAssertFalse(presenterTitles.contains(L10n.string("Inspect Elements")))
        XCTAssertTrue(presenterTitles.contains(L10n.string("Keep on Top")))
    }

    func testAddingANoteFromTheMenuThenDeletingItFromThePinsMenu() async throws {
        let session = SimulatorRecoveryStreamSessionFake()
        let controller = makeController(session: session)
        _ = controller.view
        defer { controller.terminate() }
        controller.setPresented(true)
        let frames = session.emitFramesContinuously(width: 40, height: 80)
        defer { frames.cancel() }
        try await eventually { controller.frameImageForTesting != nil }

        let point = CGPoint(x: 0.3, y: 0.7)
        let menu = controller.screenMenuEntries(
            for: .init(anchor: .control, point: point, noteID: nil),
            includesNotes: true
        )
        Self.item(L10n.string("Add Note Here"), in: menu)?.onChoose?()
        let screen = controller.screenViewForTesting
        XCTAssertEqual(screen.noteMarks.count, 1)
        XCTAssertEqual(screen.noteMarks.first?.point, point)
        XCTAssertFalse(screen.isAnnotatingNotes, "A note from the menu must not switch modes")

        let noteID = try XCTUnwrap(screen.noteMarks.first?.id)
        XCTAssertTrue(Self.titles(controller.screenMenuEntries(
            for: .init(anchor: .control, point: point, noteID: nil),
            includesNotes: true
        )).contains(L10n.string("Clear All Notes")), "Once there are notes, their actions appear")
        let pinMenu = controller.screenMenuEntries(
            for: .init(anchor: .control, point: point, noteID: noteID),
            includesNotes: true
        )
        guard case .header(let header) = pinMenu.first else {
            return XCTFail("A pin's menu must name the pin before anything else")
        }
        XCTAssertEqual(header, L10n.format("Note %lld", Int64(1)))
        Self.item(L10n.string("Delete Note"), in: pinMenu)?.onChoose?()
        XCTAssertTrue(screen.noteMarks.isEmpty)
    }

    func testAnnotationModeExplainsItselfInABandInsteadOfCoveringTheDevice() async throws {
        let session = SimulatorRecoveryStreamSessionFake()
        let controller = makeController(session: session)
        _ = controller.view
        defer { controller.terminate() }
        controller.setPresented(true)
        let frames = session.emitFramesContinuously(width: 40, height: 80)
        defer { frames.cancel() }
        try await eventually { controller.frameImageForTesting != nil }

        XCTAssertNil(controller.annotationBandForTesting)
        controller.setAnnotatingNotes(true)
        let band = try XCTUnwrap(controller.annotationBandForTesting)
        XCTAssertTrue(band.isDescendant(of: controller.view))
        XCTAssertEqual(
            controller.annotateButtonForTesting.accessibilityTitle(),
            L10n.string("Stop Annotating")
        )
        controller.setAnnotatingNotes(false)
        XCTAssertNil(controller.annotationBandForTesting)
        XCTAssertNil(band.superview)
    }

    // MARK: - Recording

    func testARecordingIsVisibleOnTheDeviceAndItsButtonUntilTheMovieIsSaved() async throws {
        let session = SimulatorRecoveryStreamSessionFake()
        let controller = makeController(session: session)
        _ = controller.view
        defer { controller.terminate() }
        controller.setPresented(true)
        let frames = session.emitFramesContinuously(width: 40, height: 80)
        defer { frames.cancel() }
        try await eventually { controller.frameImageForTesting != nil }

        XCTAssertTrue(controller.recordingBadgeForTesting.isHidden)
        controller.toggleRecording()

        XCTAssertTrue(controller.isRecordingForCommands)
        XCTAssertFalse(controller.recordingBadgeForTesting.isHidden)
        XCTAssertTrue(controller.screenViewForTesting.isRecording)
        XCTAssertTrue(controller.recordButtonForTesting.isSelected)
        XCTAssertTrue(controller.statusForTesting.hasPrefix(L10n.format("Recording %@", "0:0")))

        try await Task.sleep(for: .milliseconds(200))
        controller.toggleRecording()
        XCTAssertEqual(controller.recordingBadgeForTesting.phase, .finishing)
        XCTAssertFalse(controller.screenViewForTesting.isRecording)

        try await eventually(timeout: 5) { !self.revealed.isEmpty }
        XCTAssertFalse(controller.isRecordingForCommands)
        XCTAssertTrue(controller.recordingBadgeForTesting.isHidden)
        let movie = try XCTUnwrap(revealed.first)
        XCTAssertEqual(movie.deletingLastPathComponent().standardizedFileURL,
                       recordingDirectory.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path))
    }

    func testClosingThePaneFinishesARunningRecording() async throws {
        let session = SimulatorRecoveryStreamSessionFake()
        let controller = makeController(session: session)
        _ = controller.view
        controller.setPresented(true)
        let frames = session.emitFramesContinuously(width: 40, height: 80)
        defer { frames.cancel() }
        try await eventually { controller.frameImageForTesting != nil }

        controller.toggleRecording()
        try await Task.sleep(for: .milliseconds(150))
        controller.terminate()

        try await eventually(timeout: 5) { !self.revealed.isEmpty }
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(revealed.first).path))
    }

    // MARK: - Presenter window

    func testPresenterWindowMirrorsTheDeviceAndKeepsItLiveWhileThePaneIsHidden() async throws {
        let session = SimulatorRecoveryStreamSessionFake()
        let coordinator = SimulatorRecoveryStreamCoordinatorFake([.success(session)])
        let controller = makeController(coordinator: coordinator, hiddenTransportGrace: .milliseconds(40))
        _ = controller.view
        defer { controller.terminate() }
        controller.setPresented(true)
        let frames = session.emitFramesContinuously(width: 40, height: 80)
        defer { frames.cancel() }
        try await eventually { controller.frameImageForTesting != nil }

        controller.togglePresenterWindow()
        let presenter = try XCTUnwrap(shownPresenters.first)
        XCTAssertTrue(controller.isPresenterWindowOpen)
        XCTAssertTrue(controller.presenterButtonForTesting.isSelected)
        XCTAssertEqual(presenter.window?.title, L10n.format("%@ Simulator", simulatorRecoveryFirstDevice.name))
        XCTAssertEqual(presenter.window?.sharingType, .readOnly)
        try await eventually { presenter.screenView.image != nil }

        // Switching to another session hides the pane; a person sharing the window keeps a device.
        controller.setPresented(false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(session.visibilityChanges.last, true)
        XCTAssertFalse(session.didStop)
        let before = presenter.screenView.image
        try await eventually { presenter.screenView.image !== before }

        // Closing the window is then the last viewer leaving: frames stop, the grace releases.
        controller.togglePresenterWindow()
        XCTAssertFalse(controller.isPresenterWindowOpen)
        XCTAssertEqual(session.visibilityChanges.last, false)
        try await eventually { session.didStop }
        let opens = await coordinator.openCount
        XCTAssertEqual(opens, 1)
    }

    func testAGestureOnThePresenterReachesTheDeviceThroughTheSameSession() async throws {
        let session = SimulatorRecoveryStreamSessionFake()
        let controller = makeController(session: session, initialDecision: true)
        _ = controller.view
        defer { controller.terminate() }
        controller.setPresented(true)
        let frames = session.emitFramesContinuously(width: 40, height: 80)
        defer { frames.cancel() }
        try await eventually { controller.frameImageForTesting != nil }

        controller.togglePresenterWindow()
        let mirror = try XCTUnwrap(shownPresenters.first).screenView
        try await eventually { mirror.interactionState != .unavailable }
        mirror.onTap?(CGPoint(x: 0.25, y: 0.75))

        try await eventually { !session.inputs.isEmpty }
        guard case .tap(let x, let y) = session.inputs.last else {
            return XCTFail("The presenter's tap did not reach the device")
        }
        XCTAssertEqual(x, 0.25, accuracy: 0.001)
        XCTAssertEqual(y, 0.75, accuracy: 0.001)
    }

    // MARK: - Helpers

    private func makeController(
        session: SimulatorRecoveryStreamSessionFake? = nil,
        coordinator: SimulatorRecoveryStreamCoordinatorFake? = nil,
        initialDecision: Bool? = nil,
        hiddenTransportGrace: Duration? = nil
    ) -> SimulatorPaneViewController {
        let control = SimulatorRecoveryControlFake()
        return SimulatorPaneViewController(
            preferredDeviceID: simulatorRecoveryFirstDevice.id,
            control: control,
            leaseManager: SimulatorLeaseManager(control: control, releaseGraceNanoseconds: 1_000_000),
            streamCoordinator: coordinator
                ?? SimulatorRecoveryStreamCoordinatorFake([.success(session ?? SimulatorRecoveryStreamSessionFake())]),
            inputAuthorizer: SimulatorRecoveryInputAuthorizerFake(initialDecision: initialDecision),
            hiddenTransportGrace: hiddenTransportGrace,
            touchPreferences: preferences,
            recordingDirectory: recordingDirectory,
            revealCapture: { [weak self] url in self?.revealed.append(url) },
            showPresenterWindow: { [weak self] controller in self?.shownPresenters.append(controller) }
        )
    }

    private static func titles(_ entries: [ThemedMenuEntry]) -> [String] {
        entries.compactMap { entry in
            if case .item(let item) = entry { return item.title }
            return nil
        }
    }

    private static func item(_ title: String, in entries: [ThemedMenuEntry]) -> ThemedMenuItem? {
        for entry in entries {
            if case .item(let item) = entry, item.title == title { return item }
        }
        return nil
    }

    private func eventually(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for Simulator control state.")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
