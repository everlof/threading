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

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !isInjectingRemoteInput { onUserInput?() }
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
        contextMenu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        contextMenu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        contextMenu.addItem(NSMenuItem.separator())
        contextMenu.addItem(withTitle: "Rename Session…", action: #selector(renameSession(_:)), keyEquivalent: "")
        menu = contextMenu
    }

    // MARK: - Mouse Handling

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    @objc private func renameSession(_ sender: Any?) {
        guard let sessionID = owningSessionID() else { return }

        let session = ProjectStore.shared.session(withID: sessionID)

        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.addButton(withTitle: "Rename")
        // The same button the sidebar's rename offers, for the same reason: returning to the
        // agent's own name is an action, and it was written out as an instruction.
        let hasCustomTitle = !(session?.customTitle ?? "").isEmpty
        if hasCustomTitle {
            alert.addButton(withTitle: "Use Agent's Name")
        }
        alert.addButton(withTitle: "Cancel")

        let textField = ThemedTextField(frame: NSRect(
            x: 0, y: 0,
            width: SidebarDefaults.renameFieldWidth,
            height: SidebarDefaults.renameFieldHeight
        ))
        textField.stringValue = session?.customTitle ?? ""
        textField.placeholderString = session?.displayTitle ?? ""
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()

        if hasCustomTitle, response == .alertSecondButtonReturn {
            ProjectStore.shared.renameSession(id: sessionID, to: "")
            return
        }

        guard response == .alertFirstButtonReturn else { return }

        // An empty value clears the custom name rather than being rejected.
        ProjectStore.shared.renameSession(
            id: sessionID,
            to: textField.stringValue.trimmingCharacters(in: .whitespaces)
        )
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
