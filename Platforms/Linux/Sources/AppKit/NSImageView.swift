import Foundation

public enum NSImageScaling: Int, Sendable {
    case scaleProportionallyDown = 0
    case scaleAxesIndependently = 1
    case scaleNone = 2
    case scaleProportionallyUpOrDown = 3
}

/// A bounded image leaf. Decoding and symbol lookup belong to the platform image service;
/// this view owns AppKit's sizing, proportional placement and template tint behavior.
@MainActor
open class NSImageView: NSView {
    open var image: NSImage? {
        didSet {
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }
    open var imageScaling: NSImageScaling = .scaleProportionallyDown {
        didSet { needsDisplay = true }
    }
    open var symbolConfiguration: NSImage.SymbolConfiguration? {
        didSet { needsDisplay = true }
    }
    open var contentTintColor: NSColor? {
        didSet { needsDisplay = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(false)
    }

    open override var intrinsicContentSize: NSSize { image?.size ?? .zero }

    open override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        let destination: NSRect
        switch imageScaling {
        case .scaleAxesIndependently:
            destination = bounds
        case .scaleNone, .scaleProportionallyDown, .scaleProportionallyUpOrDown:
            let ratio = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let scale = imageScaling == .scaleNone ? 1 :
                imageScaling == .scaleProportionallyDown ? min(1, ratio) : ratio
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            destination = NSRect(x: bounds.midX - size.width / 2,
                                 y: bounds.midY - size.height / 2,
                                 width: size.width, height: size.height)
        }
        guard let tint = contentTintColor, image.isTemplate,
              let context = NSGraphicsContext.current?.cgContext else {
            image.draw(in: destination)
            return
        }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: destination)
        tint.set()
        bounds.fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
