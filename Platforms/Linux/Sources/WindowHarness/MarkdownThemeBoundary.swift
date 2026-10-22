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
        // The same reading measure as the production host; this host's typography scale is 1.
        static let readingSize: CGFloat = 14
        static let readingCodeSize: CGFloat = 13
        static let readingLineHeight: CGFloat = 1.625
        static let codeLineHeight: CGFloat = 1.45
        static func lineSpacing(for font: NSFont, multiple: CGFloat) -> CGFloat {
            let natural = (font.ascender - font.descender + font.leading).rounded(.up)
            return max(0, (font.pointSize * multiple).rounded() - natural)
        }
        static let columnMeasure: CGFloat = 52
        static var columnWidth: CGFloat {
            (readingSize * Design.Typography.scale * columnMeasure).rounded()
        }
        static var turnDivider: NSColor { LinuxTheme.color("divider") }
        static let turnDividerHeight = ConversationUserRowDefaults.turnDividerHeight
        static let bubbleMaxWidthFraction = ConversationUserRowDefaults.bubbleMaxWidthFraction
        static var bubbleFill: NSColor { LinuxTheme.color("accentMuted") }
        // The production tool row: nothing at rest, the control face under the pointer or open.
        static let toolIconWidth: CGFloat = 16
        static var toolRowResting: NSColor { .clear }
        static var toolRowActive: NSColor { LinuxTheme.color("controlResting") }
    }
}
extension Design.Typography {
    enum FontSurface { case chrome, conversation }
    static let scale: CGFloat = 1
    static func reading() -> NSFont { .systemFont(ofSize: Design.Chat.readingSize * scale) }
    static func readingCode() -> NSFont { .monospacedSystemFont(ofSize: Design.Chat.readingCodeSize * scale) }
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
    func applySurface(fill: NSColor, radius: SurfaceRadius, border: NSColor? = nil,
                      borderWidth: CGFloat = Design.Radius.border, glow: Bool = false,
                      bevel: SurfaceBevel = .automatic) {
        // The checked Threading material has neither a bevel nor a glow. Preserve the
        // production recipe's geometry and dynamic colors through the retained surface.
        setAppliedSurface(fill: fill, radius: radius.current, border: border, borderWidth: borderWidth)
    }
    func applyLayerBackground(_ fill: NSColor) { setAppliedSurface(fill: fill, radius: 0, border: nil) }
}
extension Design {
    // Recipes used by the shared conversation/Markdown rows in this fixed-theme host.
    enum FontRole: Equatable {
        case detail, body, reading, emphasizedBody, subheading, caption, heading
        case placeholderTitle, welcomeGreeting, controlRegular
        case code(weight: NSFont.Weight = .regular)
        static func detail() -> Self { .detail }

        func resolved(in surface: Design.Typography.FontSurface = .chrome) -> NSFont {
            switch self {
            case .reading: Design.Typography.reading()
            case .body: Design.Typography.body(surface: surface)
            case .emphasizedBody: .systemFont(ofSize: 13, weight: .semibold)
            case .detail: Design.Typography.detail()
            case .placeholderTitle: .systemFont(ofSize: 15, weight: .medium)
            case .welcomeGreeting: .systemFont(ofSize: 20, weight: .semibold)
            case .subheading: .systemFont(ofSize: 12, weight: .regular)
            case .caption: .systemFont(ofSize: 11, weight: .semibold)
            case .heading: Design.Typography.heading()
            case .controlRegular: Design.Typography.controlRegular()
            case .code(let weight): .monospacedSystemFont(ofSize: 11, weight: weight)
            }
        }
    }
}
extension NSTextView {
    func applyFont(_ role: Design.FontRole, in surface: Design.Typography.FontSurface = .chrome) {
        font = role.resolved(in: surface)
    }
}
extension NSTextField {
    typealias DocumentFontRole = Design.FontRole
    func applyFont(_ role: Design.FontRole) { applyFont(role, in: .chrome) }
    func applyFont(_ role: Design.FontRole, in surface: Design.Typography.FontSurface) {
        font = role.resolved(in: surface)
    }
}

extension ThemedButton {
    func applyFont(_ role: Design.FontRole) {
        font = role.resolved()
    }
}

extension L10n {
    static func format(_ value: String, _ arguments: CVarArg...) -> String {
        String(format: value, arguments: arguments)
    }
}
extension Design.Motion {
    // This host retains Core Animation values but has no animation compositor.
    static let transcriptArrive: TimeInterval = 0.26
}
