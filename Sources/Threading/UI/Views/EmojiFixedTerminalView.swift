import AppKit
import SwiftTerm

/// A subclass of LocalProcessTerminalView that fixes emoji rendering issues.
///
/// The issue: Apple Color Emoji glyphs rendered via CTFontDrawGlyphs don't properly
/// composite alpha when the backing buffer hasn't been cleared. This results in
/// white/opaque backgrounds behind emoji characters.
///
/// The fix: Use a custom CALayer subclass that fills the background before the
/// view draws its content, ensuring proper alpha compositing for color emoji.
///
/// The pre-fill couples this view to a change in our SwiftTerm fork: upstream draws each
/// cell's background with `.destinationOver`, which only shows over a transparent base.
/// Over our opaque pre-fill it lands behind everything, deleting every explicit background
/// (reverse video, 256-color, truecolor). The fork instead fills backgrounds normally, in
/// a separate pass before any of a line's glyphs — interleaved fills would erase a wide
/// emoji's overhang into the next run's cells. Re-syncing with upstream must keep both, or
/// agent status chips go black-on-black and emoji lose their right half again.
final class EmojiFixedTerminalView: LocalProcessTerminalView {

    // MARK: - Remote Viewport

    /// While an interactive phone is showing this terminal, its visible character grid owns
    /// the PTY. The Mac still renders the same bytes locally, but must not resize the process
    /// back to the much wider desktop frame on its next layout pass.
    private var remoteGrid: (cols: Int, rows: Int)?
    private var localGridBeforeRemoteControl: (cols: Int, rows: Int)?
    private var deferredLocalGrid: (cols: Int, rows: Int)?
    private var isApplyingRemoteGrid = false

    // MARK: - Activity Hooks

    /// Called with the size of each chunk of output the process produces.
    ///
    /// An idle agent produces no output at all, so this is what distinguishes a session
    /// that is working from one waiting at its prompt.
    var onOutput: ((Int) -> Void)?

    /// Called with the raw bytes of each output chunk, for the remote-access mirror.
    ///
    /// Kept separate from `onOutput` on purpose: `SessionActivityTracker` only ever needs the
    /// count, and most sessions have no remote subscriber, so the byte hook is nil and costs
    /// nothing. This runs on the main thread inside SwiftTerm's synchronous read hop — a
    /// consumer must copy and hand off, never block, or it stalls the PTY read loop.
    var onOutputBytes: ((ArraySlice<UInt8>) -> Void)?

    /// Called when the process rings the terminal bell, which agents use to signal that
    /// they want attention.
    var onBell: (() -> Void)?

    /// Called when a scroll wheel event is about to be forwarded to the process as mouse
    /// input. The repaint that answers it is output we caused, and must not read as the
    /// agent working.
    var onWheelForwarded: (() -> Void)?

    /// Local keyboard/paste input, excluding bytes injected by a remote controller.
    var onUserInput: (() -> Void)?
    private var isInjectingRemoteInput = false

    /// Every chunk sent upstream to the child — keystrokes, paste, and the terminal's own
    /// answers (query replies, colour-scheme reports) alike. `TerminalColorQueryTests` reads
    /// the answers off this to pin the wire contract; nil costs nothing.
    var onInputBytes: ((ArraySlice<UInt8>) -> Void)?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !isInjectingRemoteInput { onUserInput?() }
        onInputBytes?(data)
        super.send(source: source, data: data)
    }

    func sendRemote(_ data: ArraySlice<UInt8>) {
        isInjectingRemoteInput = true
        defer { isInjectingRemoteInput = false }
        send(data: data)
    }

    /// Mirrors the routing condition in the fork's `MacTerminalView.scrollWheel`: the wheel
    /// goes to the process when it tracks the mouse and option is not held.
    override func scrollWheel(with event: NSEvent) {
        if allowMouseReporting && getTerminal().mouseMode != .off
            && !event.modifierFlags.contains(.option) {
            onWheelForwarded?()
        }
        super.scrollWheel(with: event)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureForEmojiRendering()
        setupContextMenu()
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    // MARK: - Dropped Files

    /// Who is on the other end of a drop. Set by the surface that owns this terminal; a shell
    /// is the safe default, because it is the reader that wants the path left alone.
    var dropReader: TerminalDropReader = .shell

    /// The reader a drop is actually answered for.
    ///
    /// Turning the setting off makes every terminal answer the way the shell drawer already
    /// does — paths, exactly as dropped — because "do not convert" and "hand this to something
    /// that only reads text" are the same instruction. That is what someone debugging their own
    /// HEIC handling wants: the agent given their file, not a PNG of it.
    private var effectiveDropReader: TerminalDropReader {
        AppSettings.convertsDroppedImages ? dropReader : .shell
    }

    /// Dropping a file on the terminal pastes its path, which is what every other terminal
    /// does and what makes an image reachable by an agent at all: neither CLI can be handed
    /// pixels, so a path is the whole vocabulary.
    ///
    /// SwiftTerm's view registers no dragged types of its own, so before this the terminal
    /// pane refused every drop while the composer beside it accepted them — the one surface
    /// in the app where an image was most likely to be dropped.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PromptAttachment.canRead(sender.draggingPasteboard) ? .copy : []
    }

    /// Answered again for every movement of the gesture. AppKit does not carry the entry
    /// answer forward, and a destination that says nothing here rejects the drop it just
    /// accepted.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        PromptAttachment.canRead(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        accept(sender.draggingPasteboard)
    }

    /// The drop itself, reachable without an `NSDraggingInfo` — what is worth testing here is
    /// the bytes a pasteboard turns into, and none of them come from the gesture.
    func accept(_ pasteboard: NSPasteboard) -> Bool {
        let paths = PromptAttachment.paths(from: pasteboard)
        guard !paths.isEmpty else { return false }

        // As a paste rather than as typing, which is the difference between a dropped
        // screenshot arriving as `[Image #1]` and arriving as the path it was written to.
        // Both CLIs read a paste of an image path as the image; neither watches typed
        // characters for one, and a drop is a paste in every terminal that has one.
        pasteText(TerminalDrop.text(for: TerminalDropImage.readable(paths, for: effectiveDropReader)))
        return true
    }

    override var frame: NSRect {
        get { super.frame }
        set {
            super.frame = newValue
            applyRemoteGrid()
        }
    }

    override func shouldApplyProcessSizeChange(newCols: Int, newRows: Int) -> Bool {
        guard let remoteGrid else { return true }
        let matchesRemote = newCols == remoteGrid.cols && newRows == remoteGrid.rows
        if !matchesRemote, newCols > 0, newRows > 0 {
            // Remember what the Mac would have chosen while the phone owned the process. This
            // means resizing the window during remote control restores the *new* desktop grid.
            deferredLocalGrid = (newCols, newRows)
        }
        return matchesRemote
    }

    /// Makes the remote renderer's visible grid authoritative and sends SIGWINCH through
    /// SwiftTerm's normal PTY path. Repeated calls cover rotation and split-screen changes.
    func setRemoteGrid(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if remoteGrid == nil {
            let current = getTerminal().getDims()
            localGridBeforeRemoteControl = (current.cols, current.rows)
            deferredLocalGrid = nil
        }
        remoteGrid = (cols, rows)
        applyRemoteGrid()
    }

    /// Returns process ownership to the Mac. If the window moved while the phone was in
    /// control, the last natural desktop grid wins over the stale pre-control snapshot.
    func clearRemoteGrid() {
        guard remoteGrid != nil else { return }
        remoteGrid = nil
        let restore = deferredLocalGrid ?? localGridBeforeRemoteControl
        deferredLocalGrid = nil
        localGridBeforeRemoteControl = nil
        guard let restore, restore.cols > 0, restore.rows > 0 else { return }
        resize(cols: restore.cols, rows: restore.rows)
    }

    private func applyRemoteGrid() {
        guard !isApplyingRemoteGrid, let remoteGrid else { return }
        let current = getTerminal().getDims()
        guard current.cols != remoteGrid.cols || current.rows != remoteGrid.rows else { return }
        isApplyingRemoteGrid = true
        resize(cols: remoteGrid.cols, rows: remoteGrid.rows)
        isApplyingRemoteGrid = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureForEmojiRendering()
        setupContextMenu()
    }

    private func configureForEmojiRendering() {
        wantsLayer = true
        layer?.isOpaque = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        updateLayerContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayerContentsScale()
    }

    // MARK: - Activity Observation

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?(slice.count)
        onOutputBytes?(slice)
    }

    override func bell(source: Terminal) {
        super.bell(source: source)
        onBell?()
    }

    private func updateLayerContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        layer?.contentsScale = scale
    }

    private func setupContextMenu() {
        let contextMenu = NSMenu()
        contextMenu.addItem(
            withTitle: L10n.string("Copy"),
            action: #selector(copy(_:)),
            keyEquivalent: ""
        )
        contextMenu.addItem(
            withTitle: L10n.string("Paste"),
            action: #selector(paste(_:)),
            keyEquivalent: ""
        )
        contextMenu.addItem(NSMenuItem.separator())
        contextMenu.addItem(
            withTitle: L10n.string("Rename Session…"),
            action: #selector(renameSession(_:)),
            keyEquivalent: ""
        )
        menu = contextMenu
    }

    // MARK: - Mouse Handling

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    @objc private func renameSession(_ sender: Any?) {
        guard let sessionID = owningSessionID() else { return }

        let session = ProjectStore.shared.session(withID: sessionID)

        // The same button the sidebar's rename offers, for the same reason: returning to the
        // agent's own name is an action, and it was written out as an instruction.
        let hasCustomTitle = !(session?.customTitle ?? "").isEmpty
        let request = TextPromptRequest(
            title: L10n.string("Rename Session"),
            confirmTitle: L10n.string("Rename"),
            clearTitle: hasCustomTitle ? L10n.string("Use Agent's Name") : nil,
            current: session?.customTitle ?? "",
            placeholder: session?.displayTitle ?? "",
            // An empty value clears the custom name rather than being rejected.
            allowsEmpty: true,
            fieldSize: NSSize(
                width: SidebarDefaults.renameFieldWidth,
                height: SidebarDefaults.renameFieldHeight
            )
        )

        switch TextPromptAlert.ask(request) {
        case .text(let name): ProjectStore.shared.renameSession(id: sessionID, to: name)
        case .cleared: ProjectStore.shared.renameSession(id: sessionID, to: "")
        case nil: return
        }
    }

    /// Finds the session hosting this terminal by walking the responder chain, which
    /// includes the owning view controller.
    private func owningSessionID() -> SessionID? {
        var responder: NSResponder? = nextResponder

        while let current = responder {
            if let controller = current as? AgentSessionViewController {
                return controller.sessionID
            }
            responder = current.nextResponder
        }

        return nil
    }

    override public func viewWillDraw() {
        applyLayerBackground(nativeBackgroundColor)
        super.viewWillDraw()
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            super.draw(dirtyRect)
            return
        }

        // Fill background FIRST for proper emoji alpha compositing
        context.setFillColor(nativeBackgroundColor.cgColor)
        context.fill(dirtyRect)

        // Now let SwiftTerm draw on top (selection will overwrite background where needed)
        super.draw(dirtyRect)
    }
}

// MARK: - Theme Boundary

extension EmojiFixedTerminalView: SystemChromeBoundary {

    /// The terminal is a self-contained SwiftTerm rendering surface that brings its own
    /// `NSScroller` — window-server chrome we contain rather than draw, the same shape as a
    /// themed scroll view permitting AppKit's overlay scroller. Without this the runtime theme
    /// audit fatals in a debug build the moment a terminal session shows a scroller. Scoped to
    /// the scroller alone (SwiftTerm's only always-present chrome; its search is a headless
    /// service and its caret a custom view) so a stray control ever added to the terminal
    /// subtree still fails the audit rather than riding this exemption.
    func permitsSystemChrome(_ view: NSView) -> Bool {
        view is NSScroller
    }
}
