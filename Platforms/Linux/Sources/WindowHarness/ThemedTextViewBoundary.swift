import AppKit

// The Linux host links the production ThemedTextView unchanged. Its theme vocabulary is
// resolved from the checked Threading snapshot; the generic AppKit shim has no palette.
extension Design.Surface {
    static var ground: NSColor { LinuxTheme.color("ground") }
}

extension SelectionSurface {
    static func dynamic(_ ground: @escaping () -> NSColor) -> SelectionSurface {
        // Text selection uses the theme's selection role; list selection uses its accent.
        // The production component still owns the selected-text attributes.
        let fill = LinuxTheme.color("selection")
        return SelectionSurface(fill: fill, ink: Design.Ink(on: fill))
    }
}

extension NSView {
    func resolvedGround() -> NSColor { Design.Surface.ground }
}

@MainActor
public class ThemedScrollView: NSScrollView {}

// A field editor can arrive at ThemedTextSelection through the production API. No editable
// field is mounted yet; this type reserves its explicit well-ground contract for that path.
@MainActor
class ThemedTextField: NSTextField {
    func textSelectionGround() -> NSColor { LinuxTheme.color("controlResting") }
}
