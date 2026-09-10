import AppKit
import ThreadingExtensionKit

/// The `backdrop` image role: a picture that covers whatever it is pinned to.
///
/// Not an `NSImageView`, because an image view has an intrinsic size and a backdrop must have
/// none — an image view under the sidebar would have asked the column to be as wide as the
/// picture, and won, since nothing else in the column states a width. A bare layer with
/// aspect-fill gravity does the fitting, so a resize never re-decodes, and the view claims no
/// pointer: it answers nil to every hit test, which is what "under the content" has to mean
/// for the rows above it to stay clickable. It is not an accessibility element unless the
/// renderer gives it a label, the same rule the inline image roles follow.
final class ExtensionBackdropImageView: NSView {

    init(image: NSImage?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        if let image {
            var rect = CGRect(origin: .zero, size: image.size)
            layer?.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        // Never a vote in layout: a backdrop is sized by what it is pinned to.
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentHuggingPriority(.init(1), for: .vertical)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .vertical)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// Passive: the content this sits beneath owns every click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// Whether a picture is installed — what a test can ask without reading pixels.
    var showsPicture: Bool { layer?.contents != nil }
}
