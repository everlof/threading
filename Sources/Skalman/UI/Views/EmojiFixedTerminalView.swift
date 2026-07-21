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

    // MARK: - Activity Hooks

    /// Called with the size of each chunk of output the process produces.
    ///
    /// An idle agent produces no output at all, so this is what distinguishes a session
    /// that is working from one waiting at its prompt.
    var onOutput: ((Int) -> Void)?

    /// Called when the process rings the terminal bell, which agents use to signal that
    /// they want attention.
    var onBell: (() -> Void)?

    /// Called when a scroll wheel event is about to be forwarded to the process as mouse
    /// input. The repaint that answers it is output we caused, and must not read as the
    /// agent working.
    var onWheelForwarded: (() -> Void)?

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
        alert.informativeText = "Leave empty to use the name reported by the terminal."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(
            x: 0, y: 0,
            width: SidebarDefaults.renameFieldWidth,
            height: SidebarDefaults.renameFieldHeight
        ))
        textField.stringValue = session?.customTitle ?? ""
        textField.placeholderString = session?.displayTitle ?? ""
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // An empty value clears the custom name rather than being rejected.
        ProjectStore.shared.renameSession(
            id: sessionID,
            to: textField.stringValue.trimmingCharacters(in: .whitespaces)
        )
    }

    /// Finds the session hosting this terminal by walking the responder chain, which
    /// includes the owning view controller.
    private func owningSessionID() -> UUID? {
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
        layer?.backgroundColor = nativeBackgroundColor.cgColor
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
