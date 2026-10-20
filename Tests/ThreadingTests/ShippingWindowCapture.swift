import AppKit

/// Render a live shipping window through its own AppKit hierarchy. Window-server capture can
/// return opaque black under the test runner's Screen Recording permissions.
@MainActor
enum ShippingWindowCapture {
    static func pngData(for window: NSWindow) -> Data? {
        guard let content = window.contentView else { return nil }
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds.integral
        guard !bounds.isEmpty,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
