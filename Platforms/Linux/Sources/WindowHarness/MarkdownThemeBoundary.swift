import AppKit
import Foundation

// Environment roles for the shared document renderer. Its content, block layout and paging
// remain production code; the AppKit shim contains no application palette or document policy.
extension Design.Size { static let readableWidth: CGFloat = 620 }
extension Design.Surface {
    static var panel: NSColor { LinuxTheme.color("panel") }
}
extension Design {
    enum Chat {
        static var turnDivider: NSColor { LinuxTheme.color("divider") }
        static let turnDividerHeight = ConversationUserRowDefaults.turnDividerHeight
        static let bubbleMaxWidthFraction = ConversationUserRowDefaults.bubbleMaxWidthFraction
        static var bubbleFill: NSColor { LinuxTheme.color("accentMuted") }
        static let blockSpacing = Design.Spacing.small
        static let arrivalRise = Design.Spacing.medium
    }
}
extension Design.Typography {
    enum FontSurface { case chrome, conversation }
    static let scale: CGFloat = 1
    static func documentHeading(level: Int, from base: NSFont, surface: FontSurface) -> NSFont {
        let steps: [CGFloat] = [11, 7, 3, 1]
        let step = steps[min(max(level, 1), steps.count) - 1]
        return .systemFont(ofSize: base.pointSize + step, weight: level <= 2 ? .bold : .semibold)
    }
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
extension Design {
    // Recipes used by the shared conversation/Markdown rows in this fixed-theme host.
    enum FontRole: Equatable {
        case detail, body, subheading, caption, placeholderTitle
        case code(weight: NSFont.Weight = .regular)
        static func detail() -> Self { .detail }
    }
}
extension NSTextField {
    typealias DocumentFontRole = Design.FontRole
    func applyFont(_ role: Design.FontRole) { applyFont(role, in: .chrome) }
    func applyFont(_ role: Design.FontRole, in surface: Design.Typography.FontSurface) {
        switch role {
        case .body: font = Design.Typography.body(surface: surface)
        case .detail: font = Design.Typography.detail()
        case .placeholderTitle: font = .systemFont(ofSize: 15, weight: .medium)
        case .subheading: font = .systemFont(ofSize: 12, weight: .regular)
        case .caption: font = .systemFont(ofSize: 11, weight: .semibold)
        case .code(let weight): font = .monospacedSystemFont(ofSize: 11, weight: weight)
        }
    }
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

extension Design.Motion {
    // This host retains Core Animation values but has no animation compositor.
    static let reducesMotion = true
    static let transcriptArrive: TimeInterval = 0.26
}
