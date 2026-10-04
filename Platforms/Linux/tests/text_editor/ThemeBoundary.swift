import AppKit

// The production component stays byte-identical. These are its host-owned theme facts.
@MainActor protocol ThemedComponent: AnyObject {}

@MainActor enum Design {
    enum Text {
        static let label = NSColor(white: 0.08, alpha: 1)
        static let tertiary = NSColor(white: 0.35, alpha: 1)
    }
    enum Surface {
        static let ground = NSColor(white: 1, alpha: 1)
        static let accent = NSColor(red: 0.18, green: 0.36, blue: 0.84, alpha: 1)
    }
    enum Typography {
        static func body() -> NSFont { .systemFont(ofSize: 13) }
    }
}

@MainActor struct SelectionSurface {
    let fill: NSColor
    let ink: Ink
    struct Ink { let label: NSColor }
    static func dynamic(over ground: @escaping () -> NSColor) -> SelectionSurface {
        _ = ground
        return SelectionSurface(fill: NSColor(red: 0.75, green: 0.82, blue: 1, alpha: 1),
                                ink: Ink(label: .black))
    }
}

@MainActor class ThemedTextField: NSView {
    func textSelectionGround() -> NSColor { Design.Surface.ground }
}

extension NSView {
    func resolvedGround() -> NSColor { Design.Surface.ground }
}

@MainActor final class ThemeRedraw {
    init(_ view: NSView) { _ = view }
}

@MainActor public class ThemedScrollView: NSScrollView {}
