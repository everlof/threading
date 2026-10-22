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
            configuredImage = nil
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }
    open var imageScaling: NSImageScaling = .scaleProportionallyDown {
        didSet { needsDisplay = true }
    }
    /// Applied to a symbol image as AppKit applies it: the symbol is drawn at this size and
    /// weight, and that drawing is the view's intrinsic size.
    open var symbolConfiguration: NSImage.SymbolConfiguration? {
        didSet {
            configuredImage = nil
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }
    private var configuredImage: NSImage?
    private var displayedImage: NSImage? {
        guard let image, let symbolConfiguration, image.symbolName != nil else { return image }
        if let configuredImage { return configuredImage }
        let configured = image.withSymbolConfiguration(symbolConfiguration)
        configuredImage = configured
        return configured
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

    open override var intrinsicContentSize: NSSize {
        displayedImage?.size ?? NSSize(width: NSView.noIntrinsicMetric,
                                      height: NSView.noIntrinsicMetric)
    }

    open override func draw(_ dirtyRect: NSRect) {
        guard let image = displayedImage, image.size.width > 0, image.size.height > 0,
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
