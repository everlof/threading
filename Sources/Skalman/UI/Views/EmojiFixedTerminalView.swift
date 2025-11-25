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
final class EmojiFixedTerminalView: LocalProcessTerminalView {

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
    }

    private func setupContextMenu() {
        let contextMenu = NSMenu()
        contextMenu.addItem(withTitle: "Rename Window...", action: #selector(renameWindow(_:)), keyEquivalent: "")
        menu = contextMenu
    }

    @objc private func renameWindow(_ sender: Any?) {
        // Walk up the responder chain to find the window controller
        guard let windowController = window?.windowController as? TerminalWindowController else { return }
        windowController.showSetTitleDialog()
    }

    override public func viewWillDraw() {
        layer?.backgroundColor = nativeBackgroundColor.cgColor
        super.viewWillDraw()
    }

    override public func makeBackingLayer() -> CALayer {
        return EmojiFixedBackingLayer(terminalView: self)
    }
}

/// Custom backing layer that ensures proper background fill before drawing.
/// This fixes emoji rendering by filling the dirty region with the background
/// color before CoreText draws color emoji glyphs.
private class EmojiFixedBackingLayer: CALayer {
    weak var terminalView: EmojiFixedTerminalView?

    init(terminalView: EmojiFixedTerminalView) {
        self.terminalView = terminalView
        super.init()
    }

    override init(layer: Any) {
        if let other = layer as? EmojiFixedBackingLayer {
            self.terminalView = other.terminalView
        }
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(in ctx: CGContext) {
        // Fill with background color before the view draws
        // This ensures emoji alpha compositing works correctly
        if let bgColor = terminalView?.nativeBackgroundColor.cgColor {
            ctx.setFillColor(bgColor)
            ctx.fill(bounds)
        }
        super.draw(in: ctx)
    }
}
