import AppKit

// Environment values for the exact production diff palette and renderer. Derivation remains
// in DiffInk/PerceptualColor; the host supplies checked theme roles and its diagnostic scale.
extension Design {
    @MainActor enum Diff {
        static var added: NSColor { LinuxTheme.color("diffAdded") }
        static var removed: NSColor { LinuxTheme.color("diffRemoved") }
    }
    @MainActor enum Syntax {
        static var keyword: NSColor { LinuxTheme.color("syntaxKeyword") }
        static var type: NSColor { LinuxTheme.color("syntaxType") }
        static var string: NSColor { LinuxTheme.color("syntaxString") }
        static var number: NSColor { LinuxTheme.color("syntaxNumber") }
    }
}
extension Design.Accessibility { static let increasesContrast = false }
extension Design.Typography {
    static func code() -> NSFont { .monospacedSystemFont(ofSize: 11) }
}
