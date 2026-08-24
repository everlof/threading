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

    /// Whether this player chooses a document-shaped height or takes the height its product
    /// surface gives it. The canvas preserves the document inside either rectangle; the second
    /// form is for a resizable pane whose fold, not the movie, owns the available height.
    enum CanvasSizing {
        case documentAspect
        case fillAvailableSpace
    }

    /// Resolves a source to bytes. Host-side by construction: the extension supplies a handle and
    /// never learns a path, and the bytes never travel back across the boundary.
    typealias DocumentLoader = (ExtensionMediaSource) async -> Result<Data, MediaDocumentFailure>

    /// Resolves a source to a **file**, for the one kind of renderer that reads its own.
    ///
    /// Separate from `DocumentLoader` and optional on purpose. Only a surface that already knows
    /// a file behind its sources can answer — the attachments pane knows the attachment it is
    /// previewing, the lightbox knows the item it was opened on — and a surface whose media comes
    /// out of a signed package has no file to give and says so by not installing one. The URL is
    /// host-side and stays there: it never reaches the extension, and neither do the bytes it
    /// names.
    typealias FileLoader = (ExtensionMediaSource) async -> Result<URL, MediaDocumentFailure>

    enum Layout {
        /// A canvas short enough to leave room for the list beside it and tall enough that a
        /// square document is not a stamp.
        static let minimumCanvasHeight: CGFloat = 120
        static let defaultAspectRatio: CGFloat = 1
        /// The transport's own height plus the gap above it.
        static let transportSpacing = Design.Spacing.small
        /// Below this, preserving a useful movie canvas matters more than squeezing a scrubber
        /// into a strip too short to operate. The transport returns as soon as both fit again.
        static let compactTransportThreshold = MediaPlaybackOverlayView.Layout.target
            + transportSpacing
            + MediaTransportView.Layout.height
    }

    // MARK: - Contract

    /// Raised on `ready`, `completed`, `failed`, play/pause and scrub end. **Never per frame.**
    var onStateReport: ((ExtensionMediaStateReport) -> Void)?

    private(set) var document: ExtensionMediaDocument?
    private(set) var phase: ExtensionMediaPhase = .ready

    // MARK: - Views

    private let canvas = MediaDocumentCanvasView()
    private let transport = MediaTransportView(frame: .zero)
    private let playbackOverlay = MediaPlaybackOverlayView(frame: .zero)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var themeRedraw: ThemeRedraw?
    private var aspectConstraint: NSLayoutConstraint?
    private var minimumCanvasConstraint: NSLayoutConstraint?

    // MARK: - Playback

    private let loader: DocumentLoader
    private let fileLoader: FileLoader?
    private let limits: MediaDocumentLimits
    private let canvasSizing: CanvasSizing
    private var session: (any MediaDocumentPlaybackSession)?
    private var state = MediaPlaybackState()
    private var loadGeneration = 0
    private var isPingPongReversing = false

    /// Whether the user has silenced this player.
    ///
    /// Held across documents rather than inside `state`, which is rebuilt from the extension's
    /// intent every time one arrives: muting is an answer about the room, not about the file, and
    /// a panel that replaced its document would otherwise start talking again.
    private var isMuted = false

    /// Set by the surface hosting the player — a tab going away, a pane collapsing.
    private var isPresentationActive = true
    private var isWindowVisible = true
    private var transportRequestedVisible = true

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
    var playbackOverlayForTesting: MediaPlaybackOverlayView { playbackOverlay }
    var minimumCanvasPriorityForTesting: NSLayoutConstraint.Priority {
        minimumCanvasConstraint?.priority ?? .required
    }
    var isClockRunningForTesting: Bool { clock != nil || fallbackTimer != nil }
    var progressForTesting: Double { state.progress }
    var messageTextForTesting: String { message.isHidden ? "" : message.stringValue }

    // MARK: - Life cycle

    init(
        loader: @escaping DocumentLoader,
        fileLoader: FileLoader? = nil,
        limits: MediaDocumentLimits = .default,
        canvasSizing: CanvasSizing = .documentAspect
    ) {
        self.loader = loader
        self.fileLoader = fileLoader
        self.limits = limits
        self.canvasSizing = canvasSizing
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
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(playbackOverlay)

        let minimumCanvas = canvas.heightAnchor.constraint(
            greaterThanOrEqualToConstant: Layout.minimumCanvasHeight
        )
        minimumCanvas.priority = canvasSizing == .documentAspect
            ? .required
            : .fittingSizeCompression
        minimumCanvasConstraint = minimumCanvas

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.widthAnchor.constraint(equalTo: stack.widthAnchor),
            transport.widthAnchor.constraint(equalTo: stack.widthAnchor),
            minimumCanvas,
            playbackOverlay.topAnchor.constraint(equalTo: canvas.topAnchor),
            playbackOverlay.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            playbackOverlay.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            playbackOverlay.trailingAnchor.constraint(equalTo: canvas.trailingAnchor)
        ])
        applyAspectRatio(Layout.defaultAspectRatio)

        transport.onPlayPause = { [weak self] in self?.togglePlayback() }
        transport.onScrub = { [weak self] value in self?.scrub(to: value) }
        transport.onScrubEnd = { [weak self] value in self?.finishScrub(at: value) }
        transport.onToggleMute = { [weak self] in self?.toggleMute() }
        playbackOverlay.onToggle = { [weak self] in self?.togglePlayback() }
        playbackOverlay.onShowContextMenu = { [weak self] anchor in
            self?.canvas.presentContextMenu(at: anchor) ?? false
        }
        playbackOverlay.isHidden = true

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

    override func layout() {
        super.layout()
        updateTransportVisibility()
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
        transportRequestedVisible = newDocument.transport != .hidden
        transport.showsPlayControl = newDocument.format != .video
        playbackOverlay.isHidden = newDocument.format != .video || !transportRequestedVisible
        updateTransportVisibility()
        canvas.allowsFrameCopy = newDocument.allowsFrameCopy
        canvas.onCopyFrame = { [weak self] in self?.copyCurrentFrame() }

        if let ratio = newDocument.preferredAspectRatio, ratio.isFinite, ratio > 0 {
            applyAspectRatio(CGFloat(ratio))
        }

        let isSameDocument = previous?.id == newDocument.id
            && previous?.source == newDocument.source
            && previous?.format == newDocument.format
        if isSameDocument, session != nil {
            transport.isEnabled = true
            playbackOverlay.isEnabled = true
            applyPlaybackIntent(newDocument.playback, preservingPosition: true)
            return
        }

        transport.isEnabled = false
        playbackOverlay.isEnabled = false
        loadGeneration += 1
        stopClock()
        session?.invalidate()
        session = nil
        canvas.clear()
        state = resolvedState(from: newDocument.playback, currentProgress: 0)
        isPingPongReversing = false
        phase = .ready
        setPlaybackPresentation(isPlaying: false)
        transport.progress = 0
        transport.documentDuration = 0
        // Whether the *next* document can make a sound is not known until it is open, and a
        // speaker left over from the last one would offer to mute a silent animation.
        transport.showsAudioControl = false
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
        let fileLoader = fileLoader

        Task { @MainActor [weak self] in
            let opened = await Self.open(
                source,
                with: renderer,
                loader: loader,
                fileLoader: fileLoader,
                limits: limits
            )
            guard let self, self.loadGeneration == generation else {
                if case .success(let session) = opened { session.invalidate() }
                return
            }
            switch opened {
            case .success(let session):
                self.install(session)
            case .failure(let failure):
                self.fail(with: failure)
            }
        }
    }

    /// Opens one document by whichever route its renderer reads.
    ///
    /// Static, so the load can be in flight without the view being retained by it, and one
    /// function rather than two branches at the call site because the *only* difference between
    /// the routes is what a source resolves to. Parsing, archive expansion and reading a movie's
    /// tracks all complete away from the main actor; only the attachment and the first
    /// presentation happen on it.
    private static func open(
        _ source: ExtensionMediaSource,
        with renderer: any MediaDocumentRenderer,
        loader: DocumentLoader,
        fileLoader: FileLoader?,
        limits: MediaDocumentLimits
    ) async -> Result<any MediaDocumentPlaybackSession, MediaDocumentFailure> {
        do {
            if let fileRenderer = renderer as? any MediaDocumentFileRenderer {
                // A file-backed format is never handed bytes instead. A surface with no file for
                // this source refuses the document rather than reading it into memory to find out
                // the renderer cannot use it that way.
                guard let fileLoader else { return .failure(.unresolvedSource) }
                switch await fileLoader(source) {
                case .failure(let failure):
                    return .failure(failure)
                case .success(let url):
                    return .success(try await fileRenderer.open(fileAt: url, limits: limits))
                }
            }
            switch await loader(source) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let data):
                return .success(try await renderer.open(data, limits: limits))
            }
        } catch let failure as MediaDocumentFailure {
            return .failure(failure)
        } catch {
            return .failure(.invalidDocument(error.localizedDescription))
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
        transport.showsAudioControl = opened.hasAudio
        transport.isMuted = isMuted
        transport.isEnabled = true
        playbackOverlay.isEnabled = true
        opened.apply(state)
        opened.present(atProgress: state.progress)

        phase = .ready
        report(metadata: metadata)
        if state.isPlaying {
            startPlaying()
        } else {
            setPlaybackPresentation(isPlaying: false)
        }
    }

    private func fail(with failure: MediaDocumentFailure) {
        stopClock()
        session?.invalidate()
        session = nil
        canvas.clear()
        phase = .failed
        transport.isEnabled = false
        playbackOverlay.isEnabled = false
        setPlaybackPresentation(isPlaying: false)
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
            progress: playback.progress ?? currentProgress,
            isMuted: isMuted
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
            setPlaybackPresentation(isPlaying: false)
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
            setPlaybackPresentation(isPlaying: false)
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

    /// Silence is the user's answer and it outlives the document, so it is applied to the
    /// session rather than folded into a new playback intent.
    private func toggleMute() {
        isMuted.toggle()
        state.isMuted = isMuted
        transport.isMuted = isMuted
        session?.apply(state)
    }

    private func startPlaying() {
        phase = .playing
        setPlaybackPresentation(isPlaying: true)
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
            if session.hasReachedEnd {
                // Snapped rather than left where the engine's last sample landed: a movie stops a
                // frame short of its own duration, and a transport reading 0.998 is a Play button
                // that restarts nothing.
                state.progress = 1
                transport.progress = 1
                complete()
            }
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
        setPlaybackPresentation(isPlaying: false)
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

    private func setPlaybackPresentation(isPlaying: Bool) {
        transport.isPlaying = isPlaying
        playbackOverlay.isPlaying = isPlaying
    }

    /// A resizable attachment fold may leave less room than a usable timeline costs. The canvas
    /// yields first, and then the transport gets out of the way instead of becoming a required
    /// minimum that stops the fold. The centred play control remains the compact route.
    private func updateTransportVisibility() {
        let isCompressed = canvasSizing == .fillAvailableSpace
            && bounds.height < Layout.compactTransportThreshold
        let shouldHide = !transportRequestedVisible || isCompressed
        guard transport.isHidden != shouldHide else { return }
        transport.isHidden = shouldHide
    }

    private func applyAspectRatio(_ ratio: CGFloat) {
        aspectConstraint?.isActive = false
        let constraint = canvas.heightAnchor.constraint(
            equalTo: canvas.widthAnchor,
            multiplier: 1 / max(ratio, 0.01)
        )
        // A document-shaped standalone player prefers the aspect strongly. A player filling a
        // resizable pane takes that pane's rectangle instead; its render layer aspect-fits the
        // pixels inside it without making the movie's ratio a pane-size constraint.
        constraint.priority = canvasSizing == .documentAspect
            ? .defaultHigh
            : .fittingSizeCompression
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
