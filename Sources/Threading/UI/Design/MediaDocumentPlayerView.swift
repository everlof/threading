import AppKit
import ThreadingExtensionKit

/// The one place Threading plays a document that varies over time.
///
/// It owns everything an extension does not get to: the decoder (through
/// `MediaDocumentRendererRegistry`), the clock, the transport, the visibility lifecycle, the theme,
/// the accessibility, the ceilings and the pasteboard. The extension supplies an
/// `ExtensionMediaDocument` — which document, playing or not, how fast, how it loops — and receives
/// a coalesced `ExtensionMediaStateReport` back.
///
/// **The clock stops when nobody is looking.** A tab that is not selected, a collapsed pane, an
/// occluded or miniaturized window and a deselected session all stop it. This is the single most
/// likely defect in the whole feature — an animation quietly burning a core behind another tab —
/// and it has a test of its own rather than an assertion inside another one.
///
/// **Playback survives a document replacement with the same `id`.** An extension that replaces its
/// panel to update a label must not restart the animation; a *changed* id is what resets it.
@MainActor
final class MediaDocumentPlayerView: NSView, ThemedComponent {

    /// Resolves a source to bytes. Host-side by construction: the extension supplies a handle and
    /// never learns a path, and the bytes never travel back across the boundary.
    typealias DocumentLoader = (ExtensionMediaSource) async -> Result<Data, MediaDocumentFailure>

    enum Layout {
        /// A canvas short enough to leave room for the list beside it and tall enough that a
        /// square document is not a stamp.
        static let minimumCanvasHeight: CGFloat = 120
        static let defaultAspectRatio: CGFloat = 1
        /// The transport's own height plus the gap above it.
        static let transportSpacing = Design.Spacing.small
    }

    // MARK: - Contract

    /// Raised on `ready`, `completed`, `failed`, play/pause and scrub end. **Never per frame.**
    var onStateReport: ((ExtensionMediaStateReport) -> Void)?

    private(set) var document: ExtensionMediaDocument?
    private(set) var phase: ExtensionMediaPhase = .ready

    // MARK: - Views

    private let canvas = MediaDocumentCanvasView()
    private let transport = MediaTransportView(frame: .zero)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var themeRedraw: ThemeRedraw?
    private var aspectConstraint: NSLayoutConstraint?

    // MARK: - Playback

    private let loader: DocumentLoader
    private let limits: MediaDocumentLimits
    private var session: (any MediaDocumentPlaybackSession)?
    private var state = MediaPlaybackState()
    private var loadGeneration = 0
    private var isPingPongReversing = false

    /// Set by the surface hosting the player — a tab going away, a pane collapsing.
    private var isPresentationActive = true
    private var isWindowVisible = true

    /// Whether the window holding this player can actually be seen.
    ///
    /// A seam rather than a direct read, for a reason that is also the rule: an **unshown** window
    /// correctly reports that it is not visible, and every fast test in this repository builds a
    /// window it never orders on screen. Production keeps `defaultWindowVisibility`; a test states
    /// the answer, which is also how occlusion and miniaturization are exercised without a visible
    /// window to occlude.
    var windowVisibility: (NSWindow) -> Bool = MediaDocumentPlayerView.defaultWindowVisibility

    /// Occlusion covers "another window is over this one" and miniaturization covers the Dock;
    /// both are the same question for a clock, which is whether anyone can see the answer.
    static let defaultWindowVisibility: (NSWindow) -> Bool = { window in
        window.occlusionState.contains(.visible) && !window.isMiniaturized
    }

    private var clock: Any? // CADisplayLink, stored untyped for macOS 13
    private var fallbackTimer: Timer?
    private var lastTickTime: CFTimeInterval = 0
    /// The document's own frame rate, capped at the display's. A three-frame GIF has no reason to
    /// be asked for a frame sixty times a second.
    private var tickInterval: TimeInterval = 1.0 / 60.0

    private let events = AppEventObservations()

    // MARK: - Testing seams

    var canvasForTesting: MediaDocumentCanvasView { canvas }
    var transportForTesting: MediaTransportView { transport }
    var isClockRunningForTesting: Bool { clock != nil || fallbackTimer != nil }
    var progressForTesting: Double { state.progress }
    var messageTextForTesting: String { message.isHidden ? "" : message.stringValue }

    // MARK: - Life cycle

    init(
        loader: @escaping DocumentLoader,
        limits: MediaDocumentLimits = .default
    ) {
        self.loader = loader
        self.limits = limits
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("media.player")
        themeRedraw = ThemeRedraw(self)
        // The canvas caps its own backing store, so it needs the same ceilings the player was
        // built with rather than the defaults.
        canvas.applyLimits(limits)

        message.applyFont(.detail())
        message.textColor = Design.Text.secondary
        message.isHidden = true
        message.setAccessibilityIdentifier("media.player.message")

        let stack = NSStackView(views: [canvas, transport, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Layout.transportSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.widthAnchor.constraint(equalTo: stack.widthAnchor),
            transport.widthAnchor.constraint(equalTo: stack.widthAnchor),
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumCanvasHeight)
        ])
        applyAspectRatio(Layout.defaultAspectRatio)

        transport.onPlayPause = { [weak self] in self?.togglePlayback() }
        transport.onScrub = { [weak self] value in self?.scrub(to: value) }
        transport.onScrubEnd = { [weak self] value in self?.finishScrub(at: value) }

        events.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Document

    /// Applies a document, keeping playback when only the intent around it changed.
    ///
    /// The `id` comparison is the whole contract: an extension replacing its panel to update a
    /// label passes the same document id and the animation stays where it was, exactly as the
    /// workspace navigator keeps selection across a refresh.
    func update(document newDocument: ExtensionMediaDocument) {
        let previous = document
        document = newDocument
        canvas.background = newDocument.background
        canvas.setAccessibilityLabel(newDocument.accessibilityLabel)
        setAccessibilityLabel(newDocument.accessibilityLabel)
        transport.isHidden = newDocument.transport == .hidden
        canvas.allowsFrameCopy = newDocument.allowsFrameCopy
        canvas.onCopyFrame = { [weak self] in self?.copyCurrentFrame() }

        if let ratio = newDocument.preferredAspectRatio, ratio.isFinite, ratio > 0 {
            applyAspectRatio(CGFloat(ratio))
        }

        let isSameDocument = previous?.id == newDocument.id
            && previous?.source == newDocument.source
            && previous?.format == newDocument.format
        if isSameDocument, session != nil {
            applyPlaybackIntent(newDocument.playback, preservingPosition: true)
            return
        }

        loadGeneration += 1
        stopClock()
        session?.invalidate()
        session = nil
        canvas.clear()
        state = resolvedState(from: newDocument.playback, currentProgress: 0)
        isPingPongReversing = false
        phase = .ready
        transport.isPlaying = false
        transport.progress = 0
        transport.documentDuration = 0
        showMessage(nil)
        load(newDocument)
    }

    private func load(_ document: ExtensionMediaDocument) {
        let generation = loadGeneration
        let format = document.format
        guard let renderer = MediaDocumentRendererRegistry.renderer(for: format) else {
            fail(with: .unsupportedFormat(format))
            return
        }
        let source = document.source
        let limits = limits
        let loader = loader

        Task { @MainActor [weak self] in
            let bytes = await loader(source)
            guard let self, self.loadGeneration == generation else { return }
            switch bytes {
            case .failure(let failure):
                self.fail(with: failure)
            case .success(let data):
                do {
                    // Parsing and archive expansion complete away from the main actor; only the
                    // attachment and the first presentation happen here.
                    let opened = try await renderer.open(data, limits: limits)
                    guard self.loadGeneration == generation else {
                        opened.invalidate()
                        return
                    }
                    self.install(opened)
                } catch let failure as MediaDocumentFailure {
                    guard self.loadGeneration == generation else { return }
                    self.fail(with: failure)
                } catch {
                    guard self.loadGeneration == generation else { return }
                    self.fail(with: .invalidDocument(error.localizedDescription))
                }
            }
        }
    }

    private func install(_ opened: any MediaDocumentPlaybackSession) {
        session = opened
        opened.attach(to: canvas)
        opened.setPresentationActive(isPresentationActive && isWindowVisible)

        let metadata = opened.metadata
        if metadata.pixelWidth > 0, metadata.pixelHeight > 0,
           document?.preferredAspectRatio == nil {
            applyAspectRatio(CGFloat(metadata.pixelWidth) / CGFloat(metadata.pixelHeight))
        }
        tickInterval = metadata.frameRate > 0
            ? 1.0 / min(max(metadata.frameRate, 1), 60)
            : 1.0 / 60.0
        transport.documentDuration = metadata.duration
        transport.progress = state.progress
        opened.apply(state)
        opened.present(atProgress: state.progress)

        phase = .ready
        report(metadata: metadata)
        if state.isPlaying {
            startPlaying()
        } else {
            transport.isPlaying = false
        }
    }

    private func fail(with failure: MediaDocumentFailure) {
        stopClock()
        session?.invalidate()
        session = nil
        canvas.clear()
        phase = .failed
        transport.isEnabled = false
        transport.isPlaying = false
        let extensionFailure = failure.extensionFailure
        showMessage(extensionFailure.message)
        report(failure: extensionFailure)
    }

    // MARK: - Playback intent

    /// Resolves what the extension asked for into what the host will do.
    ///
    /// Media playback is content, but **autoplay is motion the app chose**: under Reduce Motion a
    /// document requested as playing opens paused. An explicit Play still plays it, and the
    /// transport's focus, keyboard and VoiceOver behaviour are identical either way.
    private func resolvedState(
        from playback: ExtensionMediaPlayback,
        currentProgress: Double
    ) -> MediaPlaybackState {
        MediaPlaybackState(
            isPlaying: playback.isPlaying && !Design.Motion.reducesMotion,
            loop: playback.loop,
            speed: playback.speed,
            progress: playback.progress ?? currentProgress
        )
    }

    private func applyPlaybackIntent(
        _ playback: ExtensionMediaPlayback,
        preservingPosition: Bool
    ) {
        let wasPlaying = state.isPlaying
        state = resolvedState(
            from: playback,
            currentProgress: preservingPosition ? state.progress : 0
        )
        session?.apply(state)
        if !state.isPlaying {
            stopClock()
            session?.present(atProgress: state.progress)
            transport.isPlaying = false
            transport.progress = state.progress
            if wasPlaying {
                phase = .paused
                report()
            }
        } else if !wasPlaying {
            startPlaying()
        } else {
            transport.progress = state.progress
        }
    }

    private func togglePlayback() {
        guard session != nil else { return }
        if state.isPlaying {
            state.isPlaying = false
            stopClock()
            phase = .paused
            transport.isPlaying = false
            session?.apply(state)
            report()
        } else {
            // Restarting from the end is what a play button means at the end of a document;
            // otherwise the press appears to do nothing.
            if state.progress >= 1, state.loop == .once {
                state.progress = 0
                isPingPongReversing = false
            }
            state.isPlaying = true
            session?.apply(state)
            startPlaying()
        }
    }

    private func startPlaying() {
        phase = .playing
        transport.isPlaying = true
        startClock()
        report()
    }

    private func scrub(to value: Double) {
        state.progress = min(max(value, 0), 1)
        session?.present(atProgress: state.progress)
    }

    private func finishScrub(at value: Double) {
        state.progress = min(max(value, 0), 1)
        session?.apply(state)
        session?.present(atProgress: state.progress)
        report()
    }

    // MARK: - Clock

    private func startClock() {
        guard clock == nil, fallbackTimer == nil,
              isPresentationActive, isWindowVisible,
              !isHiddenOrHasHiddenAncestor,
              state.isPlaying,
              session != nil else { return }
        lastTickTime = CACurrentMediaTime()
        if #available(macOS 14.0, *) {
            let link = displayLink(target: self, selector: #selector(tick))
            // A three-frame GIF asked for a frame sixty times a second is fifty-seven decodes
            // nobody sees. `CAFrameRateRange` is the platform's own way to say so.
            let preferred = Float(1.0 / tickInterval)
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: max(1, preferred / 2),
                maximum: preferred,
                preferred: preferred
            )
            link.add(to: .main, forMode: .common)
            clock = link
        } else {
            let timer = Timer(
                timeInterval: tickInterval,
                target: self,
                selector: #selector(tick),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    private func stopClock() {
        if #available(macOS 14.0, *) {
            (clock as? CADisplayLink)?.invalidate()
        }
        clock = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    @objc private func tick() {
        advance(now: CACurrentMediaTime())
    }

    /// One frame of the timeline, split from the tick so tests can drive the clock by hand rather
    /// than by waiting on a run loop.
    func advance(now: CFTimeInterval) {
        guard let session, state.isPlaying else { return }
        let elapsed = max(0, now - lastTickTime)
        lastTickTime = now

        guard !session.drivesItsOwnClock else {
            // A self-clocked engine owns its position; the player only mirrors it into the
            // transport, which is a Double read and a label — not a decode.
            state.progress = session.currentProgress
            transport.progress = state.progress
            return
        }

        let duration = session.metadata.duration
        guard duration > 0 else {
            session.present(atProgress: state.progress)
            return
        }

        let step = elapsed * state.speed / duration
        var next = state.progress + (isPingPongReversing ? -step : step)

        switch state.loop {
        case .once:
            if next >= 1 {
                next = 1
                state.progress = next
                transport.progress = next
                session.present(atProgress: next)
                complete()
                return
            }
        case .loop:
            if next >= 1 { next = next.truncatingRemainder(dividingBy: 1) }
        case .pingPong:
            if next >= 1 {
                next = max(0, 2 - next)
                isPingPongReversing = true
            } else if next <= 0 {
                next = min(1, -next)
                isPingPongReversing = false
            }
        }

        state.progress = min(max(next, 0), 1)
        transport.progress = state.progress
        session.present(atProgress: state.progress)
    }

    private func complete() {
        state.isPlaying = false
        stopClock()
        phase = .completed
        transport.isPlaying = false
        session?.apply(state)
        report()
    }

    // MARK: - Visibility

    /// The surface hosting the player states whether it is on screen: a display-pane tab going
    /// away, a pane collapsing, a session being deselected.
    func setPresentationActive(_ isActive: Bool) {
        guard isPresentationActive != isActive else { return }
        isPresentationActive = isActive
        applyVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else {
            isWindowVisible = false
            applyVisibility()
            return
        }
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowVisibilityChanged),
                name: name,
                object: window
            )
        }
        updateWindowVisibility()
    }

    override func viewDidHide() {
        super.viewDidHide()
        applyVisibility()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        applyVisibility()
    }

    @objc private func windowVisibilityChanged() {
        updateWindowVisibility()
    }

    private func updateWindowVisibility() {
        guard let window else {
            isWindowVisible = false
            applyVisibility()
            return
        }
        isWindowVisible = windowVisibility(window)
        applyVisibility()
    }

    /// Re-asks the visibility question. Production is driven by the window's own notifications;
    /// a test that changes what the probe answers uses this to say so.
    func refreshWindowVisibility() {
        updateWindowVisibility()
    }

    private func applyVisibility() {
        let visible = isPresentationActive && isWindowVisible && !isHiddenOrHasHiddenAncestor
        session?.setPresentationActive(visible)
        if visible, state.isPlaying {
            startClock()
        } else {
            stopClock()
        }
    }

    // MARK: - Reports

    private func report(
        metadata: ExtensionMediaMetadata? = nil,
        failure: ExtensionMediaFailure? = nil
    ) {
        guard let document, document.stateActionID != nil else { return }
        onStateReport?(ExtensionMediaStateReport(
            documentID: document.id,
            phase: phase,
            progress: state.progress,
            metadata: metadata,
            failure: failure
        ))
    }

    // MARK: - Pasteboard

    /// Host-owned for the same authority reason everything else here is: the extension asks for
    /// the affordance, and neither the rendered bytes nor pasteboard access cross the boundary.
    /// The action report carries no pixels either.
    private func copyCurrentFrame() {
        guard let session, document?.allowsFrameCopy == true else { return }
        guard let frame = try? session.copyCurrentFrame(
            maximumPixels: limits.maximumCopiedFramePixels
        ) else {
            showMessage(L10n.string("The current frame could not be copied."))
            return
        }
        let image = NSImage(
            cgImage: frame,
            size: NSSize(width: frame.width, height: frame.height)
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    // MARK: - Presentation

    private func applyAspectRatio(_ ratio: CGFloat) {
        aspectConstraint?.isActive = false
        let constraint = canvas.heightAnchor.constraint(
            equalTo: canvas.widthAnchor,
            multiplier: 1 / max(ratio, 0.01)
        )
        // Below required, so the minimum height and the pane's own width can both hold when a
        // very wide document would otherwise force a canvas one pixel tall.
        constraint.priority = .defaultHigh
        constraint.isActive = true
        aspectConstraint = constraint
    }

    private func showMessage(_ text: String?) {
        guard let text, !text.isEmpty else {
            message.stringValue = ""
            message.isHidden = true
            return
        }
        message.stringValue = text
        message.textColor = phase == .failed ? Design.Status.negative : Design.Text.secondary
        message.isHidden = false
    }
}

private extension ExtensionMediaDocument {
    var background: ExtensionMediaBackground { playback.background }
}
