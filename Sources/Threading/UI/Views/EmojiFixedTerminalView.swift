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
    private(set) var remoteGrid: (cols: Int, rows: Int)?
    private var localGridBeforeRemoteControl: (cols: Int, rows: Int)?
    private var deferredLocalGrid: (cols: Int, rows: Int)?

    /// Diagnostic seam for the CLI resize fixtures. Called only when the view's pixel frame
    /// implies a different character grid, with whether that resize will reach the emulator.
    /// Nil in production, so ordinary terminal layout pays one predictable branch.
    var onFrameGridChangeDecision: ((Int, Int, Bool) -> Void)?

    /// Holds the terminal's context menu while it is up; released from its own dismissal.
    private var contextMenuSession: AnyObject?

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

    /// Called when a mouse event — a wheel tick, or a pointer move under any-event tracking —
    /// is about to be forwarded to the process as a mouse report. The repaint that answers it
    /// is output we caused, and must not read as the agent working.
    var onMouseReportForwarded: (() -> Void)?

    /// Local keyboard/paste input, excluding bytes injected by a remote controller.
    var onUserInput: (() -> Void)?
    /// Checked only for local gestures. Remote injection and terminal protocol replies bypass
    /// this gate, so focused control cannot break colour queries or other emulator responses.
    var acceptsLocalInput: (() -> Bool)?
    var onLocalInputBlocked: (() -> Void)?
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

    override func keyDown(with event: NSEvent) {
        guard acceptsLocalInput?() ?? true else {
            onLocalInputBlocked?()
            return
        }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard acceptsLocalInput?() ?? true else {
            onLocalInputBlocked?()
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any) {
        guard acceptsLocalInput?() ?? true else {
            onLocalInputBlocked?()
            return
        }
        super.paste(sender)
    }

    /// Mirrors the routing condition in the fork's `MacTerminalView.scrollWheel`: the wheel
    /// goes to the process when it tracks the mouse and option is not held.
    override func scrollWheel(with event: NSEvent) {
        let forwards = allowMouseReporting && terminalStateSnapshot().mouseMode != .off
            && !event.modifierFlags.contains(.option)
        if forwards, !(acceptsLocalInput?() ?? true) {
            onLocalInputBlocked?()
            let previous = allowMouseReporting
            allowMouseReporting = false
            defer { allowMouseReporting = previous }
            super.scrollWheel(with: event)
            return
        }
        if forwards {
            onMouseReportForwarded?()
        }
        super.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard shouldSuppressLocalMouseReporting else {
            super.mouseDown(with: event)
            return
        }
        onLocalInputBlocked?()
        allowMouseReporting = false
        defer { allowMouseReporting = true }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard shouldSuppressLocalMouseReporting else {
            super.mouseUp(with: event)
            return
        }
        onLocalInputBlocked?()
        allowMouseReporting = false
        defer { allowMouseReporting = true }
        super.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard shouldSuppressLocalMouseReporting else {
            if forwardsMotion { onMouseReportForwarded?() }
            super.mouseDragged(with: event)
            return
        }
        onLocalInputBlocked?()
        allowMouseReporting = false
        defer { allowMouseReporting = true }
        super.mouseDragged(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        // A position under an open dropdown is the menu's: the program in the terminal is not
        // told about motion it cannot see — see `NSView.uncoveredPointerLocation(in:)`.
        guard uncoveredPointerLocation(in: event) != nil else { return }
        guard shouldSuppressLocalMouseReporting else {
            if forwardsMotion { onMouseReportForwarded?() }
            super.mouseMoved(with: event)
            return
        }
        allowMouseReporting = false
        defer { allowMouseReporting = true }
        super.mouseMoved(with: event)
    }

    private var shouldSuppressLocalMouseReporting: Bool {
        allowMouseReporting && terminalStateSnapshot().mouseMode != .off
            && !(acceptsLocalInput?() ?? true)
    }

    /// Whether pointer movement reaches the process at all, mirroring the routing condition in
    /// the fork's `MacTerminalView.mouseMoved` the way `scrollWheel` above mirrors its own.
    ///
    /// Deliberately not the fork's second test — that the pointer crossed into a *new* cell,
    /// which is what decides whether a report is written. That state is the emulator's, and the
    /// condition this stands for is "the pointer is moving over a program that tracks it", which
    /// is when its repaints are ours. Jitter inside one cell reports nothing and repaints
    /// nothing, so counting it costs a slightly wider quiet window and nothing else.
    private var forwardsMotion: Bool {
        allowMouseReporting && terminalStateSnapshot().mouseMode.sendMotionEvent()
    }

    // MARK: - Copy on Select

    /// Puts a pointer-made selection on the clipboard, when the user has asked for that.
    ///
    /// The setting is read here rather than mirrored onto the view, so the next selection after
    /// a toggle already obeys it and nothing has to observe `AppSettingsDidChange` on the
    /// terminal's behalf — the same arrangement as the dropped-image conversion above.
    ///
    /// Goes through `copy(_:)` rather than writing the pasteboard itself, so ⌘C, the context
    /// menu and this all put text on the clipboard by one route — including its refusal to
    /// clear the clipboard for an empty selection, which is what keeps a click on blank screen
    /// from costing the user whatever they had copied.
    override func selectionGestureEnded() {
        super.selectionGestureEnded()
        guard AppSettings.copiesTerminalSelection else { return }
        copy(self)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // SwiftTerm 2 defaults to an overlay indicator. Threading's terminal chrome owns a
        // persistent themed track, so retain the pre-2.0 geometry explicitly at the host edge.
        scrollerStyle = .legacy
        installScroller(ThemedScroller(frame: .zero, inkSource: .backdrop))
        configureForEmojiRendering()
        setupContextMenu()
        registerForDraggedTypes([.fileURL, .png, .tiff, SessionReferencePasteboard.type])
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
        canAccept(sender.draggingPasteboard) ? .copy : []
    }

    /// Answered again for every movement of the gesture. AppKit does not carry the entry
    /// answer forward, and a destination that says nothing here rejects the drop it just
    /// accepted.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        accept(sender.draggingPasteboard)
    }

    /// Files for every reader; a dragged sidebar session only for an agent's terminal.
    ///
    /// The reference is a brief written for an agent — which tools take which id — and a shell
    /// has no agent to read it. Refused rather than pasted as some identifier: the sidebar's
    /// Copy submenu retired the item that copied "whichever id existed" precisely because a
    /// string that means different things on different rows is worse than none, and a drop
    /// that quietly chose one would bring that back. `dropReader` rather than
    /// `effectiveDropReader`: the image-conversion setting says nothing about who is reading.
    private func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        if PromptAttachment.canRead(pasteboard) { return true }
        return dropReader != .shell && SessionReferencePasteboard.canRead(pasteboard)
    }

    /// The drop itself, reachable without an `NSDraggingInfo` — what is worth testing here is
    /// the bytes a pasteboard turns into, and none of them come from the gesture.
    func accept(_ pasteboard: NSPasteboard) -> Bool {
        guard acceptsLocalInput?() ?? true else {
            onLocalInputBlocked?()
            return false
        }
        if dropReader != .shell {
            let referenced = SessionReferencePasteboard.sessionIDs(from: pasteboard)
            if !referenced.isEmpty {
                // Pasted, like a path, so the whole bracket arrives as one unit rather than
                // as keystrokes a TUI's own key bindings get to read one by one — and framed by
                // `SessionReferenceBrief`, which is where the words are decided.
                let text = SessionReferenceHandoff.terminalText(
                    referencing: referenced,
                    readBy: owningSessionID()
                )
                guard !text.isEmpty else { return false }
                pasteText(text)
                // The caret follows the reference, as it does in the native composer: a drop
                // is a deliberate act on this input, and what comes next is the sentence
                // about it. Files are left alone — a path may be the whole of what was meant.
                window?.makeFirstResponder(self)
                return true
            }
        }
        let paths = PromptAttachment.paths(from: pasteboard)
        guard !paths.isEmpty else { return false }

        // As a paste rather than as typing, which is the difference between a dropped
        // screenshot arriving as `[Image #1]` and arriving as the path it was written to.
        // Both CLIs read a paste of an image path as the image; neither watches typed
        // characters for one, and a drop is a paste in every terminal that has one.
        let readable = TerminalDropImage.readable(paths, for: effectiveDropReader)
        pasteText(TerminalDrop.text(for: readable))

        // Filed as the user's, because scanning cannot do it: the CLI swallows the path into
        // `[Image #1]`, so the one place this drop is still a path is right here.
        if let sessionID = owningSessionID(),
           let project = ProjectStore.shared.executionProject(forSessionID: sessionID) {
            PromptAttachment.record(
                paths: readable,
                sessionID: sessionID,
                projectRoot: URL(fileURLWithPath: project.folderPath, isDirectory: true)
            )
        }
        return true
    }

    /// Refuses the renderer's own frame-derived grid outright while the phone owns the PTY.
    ///
    /// This has to answer before the emulator is touched. Letting the resize run and undoing it
    /// afterwards reflowed the buffer to the desktop grid and back, and SwiftTerm's resize path
    /// ends in `softReset()` — so an ordinary layout pass, even one that set the identical
    /// frame, wiped the scrolling region out from under a full-screen agent and left its status
    /// footer drawn twice at two different widths.
    override func shouldApplyFrameSizeChange(newCols: Int, newRows: Int) -> Bool {
        if remoteGrid != nil {
            if newCols > 0, newRows > 0 {
                // Remember what the Mac would have chosen while the phone owned the process. This
                // means resizing the window during remote control restores the *new* desktop grid.
                deferredLocalGrid = (newCols, newRows)
            }
            onFrameGridChangeDecision?(newCols, newRows, false)
            return false
        }

        onFrameGridChangeDecision?(newCols, newRows, true)
        return true
    }

    /// The second gate, on the PTY rather than the renderer: a grid that reaches the child
    /// process while the phone is in control must be the phone's.
    override func shouldApplyProcessSizeChange(newCols: Int, newRows: Int) -> Bool {
        guard let remoteGrid else { return true }
        return newCols == remoteGrid.cols && newRows == remoteGrid.rows
    }

    /// Makes the remote renderer's visible grid authoritative and sends SIGWINCH through
    /// SwiftTerm's normal PTY path. Repeated calls cover rotation and split-screen changes.
    func setRemoteGrid(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if remoteGrid == nil {
            let current = terminalDimensions
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

    /// A repeat of the grid already in force is not a resize. `resize` soft-resets the emulator,
    /// so re-applying an unchanged lease would clear a running agent's scrolling region for no
    /// reason at all.
    private func applyRemoteGrid() {
        guard let remoteGrid else { return }
        let current = terminalDimensions
        guard current.cols != remoteGrid.cols || current.rows != remoteGrid.rows else { return }
        resize(cols: remoteGrid.cols, rows: remoteGrid.rows)
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

    /// The bell, minus SwiftTerm's beep.
    ///
    /// `super.bell` forwards to the view's `terminalDelegate`, which for a
    /// `LocalProcessTerminalView` is **the view itself** — and it does not implement `bell`, so
    /// the call lands on `TerminalViewDelegate`'s protocol-extension default, which is a bare
    /// `NSSound.beep()`. `LocalProcessTerminalViewDelegate` forwards four methods to
    /// `processDelegate` and the bell is not one of them, so there is no seam further down:
    /// implementing `bell` on the session would compile, satisfy nothing, and never be called.
    /// Not calling `super` is therefore the switch, and `onBell` — which Threading already owned
    /// for the activity edge — becomes the one path a bell takes.
    override func bell(source: Terminal) {
        onBell?()
    }

    private func updateLayerContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        layer?.contentsScale = scale
    }

    /// The terminal's own context menu is app-owned like every other in the window. Nothing
    /// native is given up: this is a fixed Copy/Paste/Rename, not a field editor's Services
    /// and spelling menu — those never lived on a terminal grid.
    private func setupContextMenu() {
        // SwiftTerm assigns no `menu`, but the property is cleared anyway so a future default
        // could not put a second, stock menu behind the themed one.
        menu = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        contextMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: [
                    .item(ThemedMenuItem(
                        title: L10n.string("Copy"),
                        onChoose: { [weak self] in
                            guard let self else { return }
                            self.copy(self)
                        }
                    )),
                    .item(ThemedMenuItem(
                        title: L10n.string("Paste"),
                        onChoose: { [weak self] in
                            guard let self else { return }
                            self.paste(self)
                        }
                    )),
                    .separator,
                    .item(ThemedMenuItem(
                        title: L10n.string("Rename Session…"),
                        onChoose: { [weak self] in self?.renameSession(nil) }
                    ))
                ],
                minimumWidth: SidebarDefaults.menuWidth
            ),
            from: self,
            anchor: .pointer(event.locationInWindow),
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.contextMenuSession = nil }
        )
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

        // A rename asks for no accelerated affirmative, so `.immediate` cannot arrive — and if
        // one were ever added, the name it carries is still the name.
        let result: ProjectMutationResult
        switch TextPromptAlert.ask(request) {
        case .text(let name), .immediate(let name):
            result = ProjectStore.shared.renameSession(id: sessionID, to: name)
        case .cleared:
            result = ProjectStore.shared.renameSession(id: sessionID, to: "")
        case nil: return
        }
        guard result.succeeded else {
            let alert = ThemedAlert()
            alert.messageText = L10n.string("Rename Session")
            alert.informativeText = L10n.string("The project data could not be saved.")
            alert.alertStyle = .informational
            alert.runModal()
            return
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
