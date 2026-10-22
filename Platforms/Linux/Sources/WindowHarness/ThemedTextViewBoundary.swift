import AppKit

// The Linux host links the production ThemedTextView unchanged. Its theme vocabulary is
// resolved from the checked Threading snapshot; the generic AppKit shim has no palette.
extension Design.Surface {
    static var background: NSColor { LinuxTheme.color("surface") }
    static var ground: NSColor { LinuxTheme.color("ground") }
}
