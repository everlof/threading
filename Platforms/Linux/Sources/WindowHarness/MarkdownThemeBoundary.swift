import AppKit
import Foundation

// Environment roles for the shared document renderer. Its content, block layout and paging
// remain production code; the AppKit shim contains no application palette or document policy.
extension Design.Size { static let readableWidth: CGFloat = 620 }
extension Design.Surface {
    static var panel: NSColor { LinuxTheme.color("panel") }
}
extension Design {
    enum Chat { static let blockSpacing = Design.Spacing.small }
}
extension Design.Typography {
    enum FontSurface { case chrome, conversation }
    static func body(surface: FontSurface) -> NSFont { body() }
    static func inlineCode() -> NSFont { .monospacedSystemFont(ofSize: 12) }
    static func markdownHeading(from font: NSFont, surface: FontSurface) -> NSFont {
        .systemFont(ofSize: font.pointSize + 3, weight: .semibold)
    }
}
extension SurfaceRadius {
    static var control: Self { .fixed(Design.Radius.control) }
    static var panel: Self { .fixed(Design.Radius.panel) }
}
extension NSView {
    func applySurface(fill: NSColor, radius: SurfaceRadius) {
        setAppliedSurface(fill: fill, radius: radius.current, border: nil)
    }
    func applyLayerBackground(_ fill: NSColor) { setAppliedSurface(fill: fill, radius: 0, border: nil) }
}
extension NSTextField {
    enum DocumentFontRole {
        case detail
        static func detail() -> Self { .detail }
    }
    func applyFont(_ role: DocumentFontRole) { font = Design.Typography.detail() }
}
extension L10n {
    static func format(_ value: String, _ arguments: CVarArg...) -> String {
        String(format: value, arguments: arguments)
    }
}
extension ThemedScrollView {
    enum VerticalScrollHandoff { case never, always, atContentEnds }
    var verticalScrollHandoff: VerticalScrollHandoff {
        get { forwardsVerticalScroll ? .always : .never }
        set { forwardsVerticalScroll = newValue == .always }
    }
}
