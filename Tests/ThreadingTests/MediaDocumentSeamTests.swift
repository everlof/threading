import AppKit
import XCTest
@testable import Threading
@testable import ThreadingExtensionKit

/// The media-document seam: the values that cross the boundary, the authorities that gate them,
/// and the player's own contract.
@MainActor
final class MediaDocumentSeamTests: XCTestCase {

    private var restoreRenderer: (any MediaDocumentRenderer)?

    override func setUp() {
        super.setUp()
        Design.Motion.reduceMotionOverrideForTesting = false
    }

    override func tearDown() {
        for window in retainedWindows {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        retainedWindows.removeAll()
        Design.Motion.reduceMotionOverrideForTesting = nil
        if let restoreRenderer {
            MediaDocumentRendererRegistry.setRendererForTesting(restoreRenderer, for: .lottie)
            self.restoreRenderer = nil
        }
        super.tearDown()
    }

    // MARK: - Values

    func testAMediaNodeRoundTripsThroughJSON() throws {
        let node = ExtensionNode.media(ExtensionMediaDocument(
            id: "hero",
            source: .fileHandle("abc123"),
            format: .lottie,
            playback: ExtensionMediaPlayback(
                isPlaying: true,
                loop: .pingPong,
                speed: 1.5,
                progress: 0.25,
                background: .checkerboard
            ),
            transport: .hidden,
            allowsFrameCopy: true,
            accessibilityLabel: "Hero animation",
            preferredAspectRatio: 1.5,
            stateActionID: "hero-state"
        ))
        let data = try JSONEncoder().encode(node)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionNode.self, from: data), node)
    }

    /// A newer manifest stays inspectable on an older host: an unknown format decodes as itself
    /// so Threading can say *this format is not carried by this version* rather than failing to
    /// decode the panel around it.
    func testAPanelCarryingAnUnknownMediaFormatStillDecodes() throws {
        let json = """
        {
          "type": "media",
          "document": {
            "id": "clip",
            "source": {"type": "fileHandle", "value": "handle"},
            "format": "usdz",
            "accessibilityLabel": "A model"
          }
        }
        """
        let node = try JSONDecoder().decode(ExtensionNode.self, from: Data(json.utf8))
        guard case .media(let document) = node else {
            return XCTFail("the node did not decode as media")
        }
        XCTAssertEqual(document.format, ExtensionMediaFormat(rawValue: "usdz"))
        XCTAssertFalse(MediaDocumentRendererRegistry.supports(document.format))
        // The defaults are what an older host draws with when the newer fields are absent.
        XCTAssertEqual(document.transport, .hostOwned)
        XCTAssertFalse(document.playback.isPlaying)
        XCTAssertNil(document.playback.progress)
    }

    func testAManifestCarryingAnUnknownCapabilityRemainsInspectable() throws {
        let json = """
        {
          "formatVersion": 1,
          "identifier": "codes.threading.future",
          "name": "Future",
          "version": "1.0",
          "runtime": "webAssembly",
          "executable": "bin/future.wasm",
          "capabilities": ["ui.media-documents", "ui.holograms"]
        }
        """
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
        XCTAssertTrue(manifest.capabilities.contains(.mediaDocuments))
        XCTAssertTrue(manifest.capabilities.contains(ExtensionCapability(
            rawValue: "ui.holograms"
        )))
    }

    func testAStateReportSurvivesTheActionValueItTravelsAs() throws {
        let report = ExtensionMediaStateReport(
            documentID: "hero",
            phase: .ready,
            progress: 0.5,
            metadata: ExtensionMediaMetadata(
                duration: 2,
                frameRate: 30,
                frameCount: 60,
                pixelWidth: 200,
                pixelHeight: 100,
                layerCount: 4,
                markers: [ExtensionMediaMarker(name: "beat", time: 1)],
                notes: [LottieDocument.Note.expressionsDisabled]
            )
        )
        let decoded = try XCTUnwrap(ExtensionMediaStateReport(actionValue: report.actionValue))
        XCTAssertEqual(decoded.documentID, "hero")
        XCTAssertEqual(decoded.phase, .ready)
        XCTAssertEqual(decoded.metadata?.layerCount, 4)
        XCTAssertEqual(decoded.metadata?.markers.first?.name, "beat")
        XCTAssertEqual(decoded.metadata?.notes, [LottieDocument.Note.expressionsDisabled])
    }

    func testMarkersAreCappedWhereTheContractSaysTheyAre() {
        let metadata = ExtensionMediaMetadata(
            duration: 1,
            frameRate: 30,
            frameCount: 30,
            pixelWidth: 10,
            pixelHeight: 10,
            layerCount: 1,
            markers: (0..<200).map { ExtensionMediaMarker(name: "m\($0)", time: Double($0)) }
        )
        XCTAssertEqual(metadata.markers.count, ExtensionMediaMarker.maximumCount)
    }

    // MARK: - Capability gating

    /// Independent of `panels`, so no existing contract silently gains a player: a package that
    /// registers one without disclosing it is refused at validation.
    func testAPanelWithAMediaNodeRequiresTheMediaCapability() throws {
        let panel = ExtensionPanel(
            id: "animations",
            title: "Animations",
            root: .stack(axis: .vertical, spacing: .small, children: [
                .text("An animation", role: .body),
                .media(ExtensionMediaDocument(
                    id: "hero",
                    source: .extensionResource("animations/hero.json"),
                    format: .lottie,
                    accessibilityLabel: "Hero animation"
                ))
            ])
        )
        let registration = ExtensionRegistration(panels: [panel])

        let withoutCapability = manifest(capabilities: [.panels])
        XCTAssertThrowsError(try registration.validate(for: withoutCapability)) { error in
            let issues = (error as? ExtensionValidationError)?.issues ?? []
            XCTAssertTrue(
                issues.contains { $0.message.contains("ui.media-documents") },
                "the refusal did not name the missing capability: \(issues)"
            )
        }

        let withCapability = manifest(capabilities: [.panels, .mediaDocuments])
        XCTAssertNoThrow(try registration.validate(for: withCapability))
    }

    /// The second gate: a surface has to opt in as well, so a compact component contract cannot
    /// grow a canvas with a clock because an extension declared a capability.
    func testAComponentVocabularyRefusesMediaUnlessItOptsIn() {
        let document = ExtensionMediaDocument(
            id: "hero",
            source: .extensionResource("hero.json"),
            format: .lottie,
            accessibilityLabel: "Hero animation"
        )
        let closed = ExtensionComponentNodeConstraints(
            maximumDepth: 4,
            maximumNodes: 20,
            maximumTextLength: 100,
            allowedStackAxes: [.horizontal, .vertical],
            allowedTextRoles: ExtensionTextRole.allCases
        )
        XCTAssertFalse(closed.allowsMedia, "media must be closed by default")
        XCTAssertThrowsError(try closed.validate(.media(document)))

        let open = ExtensionComponentNodeConstraints(
            maximumDepth: 4,
            maximumNodes: 20,
            maximumTextLength: 100,
            allowedStackAxes: [.horizontal, .vertical],
            allowedTextRoles: ExtensionTextRole.allCases,
            allowsMedia: true
        )
        XCTAssertNoThrow(try open.validate(.media(document)))
        XCTAssertTrue(ExtensionPanel.nodeConstraints.allowsMedia)
    }

    func testAMediaDocumentValidatesItsOwnFields() {
        let issues = ExtensionMediaDocument(
            id: "Not An ID",
            source: .extensionResource("../escape.json"),
            format: ExtensionMediaFormat(rawValue: ""),
            playback: ExtensionMediaPlayback(speed: 99, progress: 4),
            accessibilityLabel: "  ",
            preferredAspectRatio: 0,
            stateActionID: "Nope"
        ).validationIssues(path: "document")

        let paths = Set(issues.map(\.path))
        XCTAssertTrue(paths.contains("document.id"))
        XCTAssertTrue(paths.contains("document.source.value"))
        XCTAssertTrue(paths.contains("document.format"))
        XCTAssertTrue(paths.contains("document.playback.speed"))
        XCTAssertTrue(paths.contains("document.playback.progress"))
        XCTAssertTrue(paths.contains("document.accessibilityLabel"))
        XCTAssertTrue(paths.contains("document.preferredAspectRatio"))
        XCTAssertTrue(paths.contains("document.stateActionID"))
    }

    func testTheNodeRendererRefusesMediaOnASurfaceWithNoPlayer() {
        let node = ExtensionNode.media(ExtensionMediaDocument(
            id: "hero",
            source: .extensionResource("hero.json"),
            format: .lottie,
            accessibilityLabel: "Hero animation"
        ))
        XCTAssertThrowsError(
            try ExtensionNodeRenderer.render(node, onAction: { _ in })
        ) { error in
            XCTAssertEqual(
                error as? ExtensionNodeRenderer.RenderError,
                .mediaPlayerUnavailable
            )
        }
    }

    // MARK: - The player

    func testTheReadyReportCarriesTheDocumentsMetadata() {
        let player = makePlayer()
        let ready = expectation(description: "ready")
        var reports: [ExtensionMediaStateReport] = []
        player.onStateReport = {
            reports.append($0)
            if $0.phase == .ready { ready.fulfill() }
        }
        player.update(document: document(playing: false))
        wait(for: [ready], timeout: 5)

        let report = reports.first { $0.phase == .ready }
        XCTAssertEqual(report?.metadata?.pixelWidth, 100)
        XCTAssertEqual(report?.metadata?.layerCount, 1)
        XCTAssertEqual(report?.documentID, "hero")
    }

    /// The load-bearing contract: an extension replacing its panel to update a label must not
    /// restart the animation. A *changed* id is what resets it.
    func testPlaybackIsPreservedAcrossADocumentReplacementWithTheSameID() {
        let player = makePlayer()
        loadAndWait(player, document(playing: false))

        player.transportForTesting.scrubberForTesting.value = 0.5
        player.advance(now: 0)
        player.update(document: document(playing: false, label: "Renamed"))
        XCTAssertNotNil(player.document)
        XCTAssertEqual(player.progressForTesting, 0, accuracy: 0.0001)

        // Scrub, then replace again: the position survives.
        scrub(player, to: 0.4)
        player.update(document: document(playing: false, label: "Renamed again"))
        XCTAssertEqual(player.progressForTesting, 0.4, accuracy: 0.0001)
    }

    func testAChangedDocumentIDResetsPlayback() {
        let player = makePlayer()
        loadAndWait(player, document(playing: false))
        scrub(player, to: 0.6)
        XCTAssertEqual(player.progressForTesting, 0.6, accuracy: 0.0001)

        loadAndWait(player, document(playing: false, id: "second"))
        XCTAssertEqual(player.progressForTesting, 0, accuracy: 0.0001)
    }

    /// The single most likely defect in the whole feature, so it gets its own test rather than an
    /// assertion inside another one.
    func testTheClockStopsWhenNobodyCanSeeIt() {
        let player = makePlayer()
        loadAndWait(player, document(playing: true))
        XCTAssertTrue(player.isClockRunningForTesting, "the clock never started")

        player.setPresentationActive(false)
        XCTAssertFalse(player.isClockRunningForTesting, "a deselected tab kept its clock running")

        player.setPresentationActive(true)
        XCTAssertTrue(player.isClockRunningForTesting)

        player.isHidden = true
        player.viewDidHide()
        XCTAssertFalse(player.isClockRunningForTesting, "a collapsed pane kept its clock running")

        player.isHidden = false
        player.viewDidUnhide()
        XCTAssertTrue(player.isClockRunningForTesting)

        // Occlusion and miniaturization reach the clock through the same probe the window
        // answers in production, so both are stated here without a visible window to occlude.
        player.windowVisibility = { _ in false }
        player.refreshWindowVisibility()
        XCTAssertFalse(
            player.isClockRunningForTesting,
            "an occluded or miniaturized window kept its clock running"
        )

        player.windowVisibility = { _ in true }
        player.refreshWindowVisibility()
        XCTAssertTrue(player.isClockRunningForTesting)

        player.removeFromSuperview()
        XCTAssertFalse(player.isClockRunningForTesting, "a player with no window kept its clock")
    }

    /// Media playback is content, but **autoplay is motion the app chose**.
    func testAutoplayOpensPausedUnderReduceMotion() {
        Design.Motion.reduceMotionOverrideForTesting = true
        let player = makePlayer()
        loadAndWait(player, document(playing: true))

        XCTAssertEqual(player.phase, .ready)
        XCTAssertFalse(player.isClockRunningForTesting, "autoplay ran under Reduce Motion")
        XCTAssertFalse(player.transportForTesting.isPlaying)

        // An explicit Play still plays it, and the transport behaves identically either way.
        XCTAssertTrue(player.transportForTesting.playButtonForTesting.performPrimaryAction())
        XCTAssertTrue(player.isClockRunningForTesting)
        XCTAssertEqual(player.phase, .playing)
    }

    func testTheTimelineLoopsWrapsAndCompletes() {
        let player = makePlayer()
        loadAndWait(player, document(playing: true, loop: .once))
        player.advance(now: 0)
        player.advance(now: 10)
        XCTAssertEqual(player.phase, .completed)
        XCTAssertEqual(player.progressForTesting, 1, accuracy: 0.0001)
        XCTAssertFalse(player.isClockRunningForTesting)

        let looping = makePlayer()
        loadAndWait(looping, document(playing: true, loop: .loop))
        looping.advance(now: 0)
        looping.advance(now: 1.5)
        XCTAssertEqual(looping.phase, .playing)
        XCTAssertLessThan(looping.progressForTesting, 1)
        XCTAssertTrue(looping.isClockRunningForTesting)
    }

    func testAnUnsupportedFormatFailsWithAStatedReasonAndNoCanvas() {
        let player = makePlayer()
        let failed = expectation(description: "failed")
        var failure: ExtensionMediaFailure?
        player.onStateReport = { report in
            if report.phase == .failed {
                failure = report.failure
                failed.fulfill()
            }
        }
        player.update(document: ExtensionMediaDocument(
            id: "hero",
            source: .extensionResource("hero.usdz"),
            format: ExtensionMediaFormat(rawValue: "usdz"),
            accessibilityLabel: "A model",
            stateActionID: "state"
        ))
        wait(for: [failed], timeout: 5)

        XCTAssertEqual(failure?.reason, .unsupportedFormat)
        XCTAssertFalse(failure?.message.isEmpty ?? true)
        XCTAssertFalse(player.messageTextForTesting.isEmpty, "the pane said nothing")
        XCTAssertNil(player.canvasForTesting.presentedFrameForTesting)
    }

    func testAnUnresolvedSourceFailsRatherThanDrawingNothingSilently() {
        let player = MediaDocumentPlayerView(loader: { _ in .failure(.unresolvedSource) })
        host(player)
        let failed = expectation(description: "failed")
        var failure: ExtensionMediaFailure?
        player.onStateReport = { report in
            if report.phase == .failed {
                failure = report.failure
                failed.fulfill()
            }
        }
        player.update(document: document(playing: false))
        wait(for: [failed], timeout: 5)
        XCTAssertEqual(failure?.reason, .unresolvedSource)
    }

    /// Copy Frame is host-owned: the extension asks for the affordance, and neither the rendered
    /// bytes nor pasteboard access cross the boundary — including in the report it raises.
    func testCopyFrameWritesToThePasteboardWithoutPuttingPixelsInTheReport() {
        let player = makePlayer()
        var reports: [ExtensionMediaStateReport] = []
        player.onStateReport = { reports.append($0) }
        loadAndWait(player, document(playing: false, allowsFrameCopy: true))

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(player.canvasForTesting.allowsFrameCopy)
        player.canvasForTesting.onCopyFrame?()

        XCTAssertNotNil(
            NSImage(pasteboard: pasteboard),
            "Copy Frame put nothing on the pasteboard"
        )
        for report in reports {
            let encoded = try? JSONEncoder().encode(report)
            let text = encoded.map { String(decoding: $0, as: UTF8.self) } ?? ""
            XCTAssertFalse(
                text.contains("image") || text.contains("base64"),
                "a state report carried pixel data: \(text.prefix(200))"
            )
        }
    }

    func testTheCanvasCapsItsBackingStore() {
        let canvas = MediaDocumentCanvasView()
        var limits = MediaDocumentLimits.default
        limits.maximumBackingPixels = 10_000
        limits.maximumPixelDimension = 200
        canvas.applyLimits(limits)
        canvas.frame = NSRect(x: 0, y: 0, width: 4_000, height: 3_000)

        let size = canvas.renderPixelSize
        XCTAssertLessThanOrEqual(size.width, 200)
        XCTAssertLessThanOrEqual(size.height, 200)
        XCTAssertLessThanOrEqual(Int(size.width * size.height), 10_000)
        XCTAssertGreaterThan(size.width, 0)
    }

    /// A `sessionAttachment` handle is valid only inside `attachments.preview@1`; replaying one
    /// into a panel is refused rather than quietly resolved.
    func testAnAttachmentHandleIsRefusedOutsideThePreviewContract() {
        var requested: ExtensionMediaSource?
        let player = MediaDocumentPlayerView(loader: { source in
            requested = source
            guard case .extensionResource = source else { return .failure(.unresolvedSource) }
            return .success(LottieFixture.spinningDot())
        })
        host(player)
        let failed = expectation(description: "failed")
        player.onStateReport = { if $0.phase == .failed { failed.fulfill() } }
        player.update(document: ExtensionMediaDocument(
            id: "hero",
            source: .sessionAttachment("attachment-1"),
            format: .lottie,
            accessibilityLabel: "Hero animation",
            stateActionID: "state"
        ))
        wait(for: [failed], timeout: 5)
        XCTAssertEqual(requested, .sessionAttachment("attachment-1"))
    }

    // MARK: - Fixtures

    private func manifest(capabilities: Set<ExtensionCapability>) -> ExtensionManifest {
        ExtensionManifest(
            identifier: "codes.threading.animations",
            name: "Animations",
            version: "1.0",
            runtime: .webAssembly,
            executable: "bin/animations.wasm",
            capabilities: capabilities
        )
    }

    private func document(
        playing: Bool,
        id: String = "hero",
        label: String = "Hero animation",
        loop: ExtensionMediaLoopMode = .loop,
        allowsFrameCopy: Bool = false
    ) -> ExtensionMediaDocument {
        ExtensionMediaDocument(
            id: id,
            source: .extensionResource("animations/hero.json"),
            format: .lottie,
            playback: ExtensionMediaPlayback(isPlaying: playing, loop: loop, speed: 1),
            allowsFrameCopy: allowsFrameCopy,
            accessibilityLabel: label,
            stateActionID: "hero-state"
        )
    }

    private func makePlayer() -> MediaDocumentPlayerView {
        let player = MediaDocumentPlayerView(loader: { _ in
            .success(LottieFixture.spinningDot())
        })
        host(player)
        return player
    }

    /// A player needs a window to have a visible one: the clock's own gate asks the window
    /// whether anyone can see it, and a view with no window answers no.
    private func host(_ player: MediaDocumentPlayerView, windowIsVisible: Bool = true) {
        player.windowVisibility = { _ in windowIsVisible }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentLayoutRect)
        root.addSubview(player)
        NSLayoutConstraint.activate([
            player.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            player.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            player.topAnchor.constraint(equalTo: root.topAnchor)
        ])
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        retainedWindows.append(window)
    }

    private var retainedWindows: [NSWindow] = []

    private func loadAndWait(
        _ player: MediaDocumentPlayerView,
        _ document: ExtensionMediaDocument
    ) {
        let ready = expectation(description: "ready")
        let previous = player.onStateReport
        player.onStateReport = { report in
            previous?(report)
            if report.phase == .ready { ready.fulfill() }
        }
        player.update(document: document)
        wait(for: [ready], timeout: 5)
        player.onStateReport = previous
    }

    private func scrub(_ player: MediaDocumentPlayerView, to value: Double) {
        let scrubber = player.transportForTesting.scrubberForTesting
        scrubber.value = value
        scrubber.onChange?(value)
        scrubber.onScrubEnd?(value)
    }
}
