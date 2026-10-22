import AppKit

// Values from Core/Constants/TerminalConstants.swift's SidebarDefaults. That source also
// contains unrelated application constants and cannot be linked into this bounded UI host.
enum SidebarDefaults {
    static let defaultWidth: CGFloat = 240
    // Measured AppKit inset-style cell band; see window-chrome.md, "The trailing side".
    static let insetCellTrailingMargin: CGFloat = 16
    // Production inset outline at depth zero; checked by SidebarWidthDensityTests.
    static let insetCellLeadingMargin: CGFloat = 25
    static let insetDisclosureLeading: CGFloat = 12
    static let contentTopInset: CGFloat = 4
    static let emptyStateSpacing: CGFloat = 4
    static let emptyStateInset: CGFloat = 20
    static let rowHeight: CGFloat = 28
    static let projectCompactRowHeight: CGFloat = 30
    static let headingRowHeight: CGFloat = 32
    static let indentationPerLevel: CGFloat = 14
    static let collapsedRepositoriesKey = "sidebarCollapsedRepositories"
    static let tightIndentationPerLevel: CGFloat = 6
    static let relaxedDensityWidth: CGFloat = 240
    static let tightDensityWidth: CGFloat = 180
    static let tightTrailingCellReclaim: CGFloat = 8
    static let compactGroupRuleOffset: CGFloat = Design.Spacing.tight
    static let compactGroupRuleHeight: CGFloat = 1
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

@MainActor
protocol OutlineDisclosureInkProviding: AnyObject {
    var outlineDisclosureInk: NSColor { get }
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

// The saved-runtime snapshot carries no truthful working state. The shared beam stays inactive
// until the host can supply an agent workload.
struct AgentWorkload: Equatable {
    let workingCount: Int
    let anyAtTopEffort: Bool

    static let none = AgentWorkload(workingCount: 0, anyAtTopEffort: false)
}
