import AppKit

/// Geometry of the AppKit inset outline style as measured by the Linux row host. These are
/// platform frame offsets, separate from the shared sidebar design defaults.
enum LinuxInsetOutlineMetrics {
    static let cellTrailingMargin: CGFloat = 16
    static let cellLeadingMargin: CGFloat = 25
    static let disclosureLeading: CGFloat = 12
}

// The installed Linux shell renders the production Threading style. This is the narrow
// theme vocabulary used by the unchanged sidebar row; the generic AppKit shim owns no theme.
@MainActor
enum AppThemeLibrary {
    static let current = Current()

    struct Current {
        let isSystem = false
    }
}

extension Design.Text {
    static func on(_ background: NSColor) -> Design.Ink { Design.Ink(on: background) }
}

extension NSOutlineView: SelectionStrengthStating {
    public var drawsSelectionAtFullStrength: Bool { window?.isKeyWindow ?? true }
}

extension NSView {
    func uncoveredPointerLocation(in event: NSEvent) -> NSPoint? {
        guard !isPointerCovered(at: event.locationInWindow) else { return nil }
        return convert(event.locationInWindow, from: nil)
    }

    func isPointerCovered(at pointInWindow: CGPoint) -> Bool {
        guard let hit = window?.contentView?.hitTest(pointInWindow) else { return false }
        return !hit.isDescendant(of: self) && !isDescendant(of: hit)
    }

    var isPointerCovered: Bool {
        guard let window else { return false }
        return isPointerCovered(at: window.mouseLocationOutsideOfEventStream)
    }
}
