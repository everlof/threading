import AppKit

// Values from Core/Constants/TerminalConstants.swift's SidebarDefaults. That source also
// contains unrelated application constants and cannot be linked into this bounded UI host.
enum SidebarDefaults {
    static let rowHeight: CGFloat = 28
    static let projectCompactRowHeight: CGFloat = 30
    static let headingRowHeight: CGFloat = 32
    static let indentationPerLevel: CGFloat = 14
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

extension Design.Surface {
    static var selectionFill: NSColor { LinuxTheme.color("accent") }
    static var selectionFillUnemphasized: NSColor { LinuxTheme.color("accentMuted") }
}

extension Design.Text {
    static func on(_ background: NSColor) -> Design.Ink { Design.Ink(on: background) }
}

@MainActor
protocol OutlineDisclosureInkProviding: AnyObject {
    var outlineDisclosureInk: NSColor { get }
}

@MainActor
protocol SelectionStrengthStating: AnyObject {
    var drawsSelectionAtFullStrength: Bool { get }
}

extension NSOutlineView: SelectionStrengthStating {
    var drawsSelectionAtFullStrength: Bool { window?.isKeyWindow ?? true }
}

extension NSTableRowView {
    func listSelectionStrength(insteadOf appKitsAnswer: Bool) -> Bool {
        (superview as? SelectionStrengthStating)?.drawsSelectionAtFullStrength ?? appKitsAnswer
    }

    func adoptListSelectionStrength() {
        let strength = listSelectionStrength(insteadOf: isEmphasized)
        if isEmphasized != strength { isEmphasized = strength }
    }
}

extension NSView {
    func isPointerCovered(at pointInWindow: CGPoint) -> Bool {
        guard let hit = window?.contentView?.hitTest(pointInWindow) else { return false }
        return !hit.isDescendant(of: self) && !isDescendant(of: hit)
    }

    var isPointerCovered: Bool {
        guard let window else { return false }
        return isPointerCovered(at: window.mouseLocationOutsideOfEventStream)
    }
}

// The saved-runtime snapshot carries no truthful working state. Keep the production row's
// inactive beam contract explicit until the host can supply that fact. A nonzero workload is
// rejected rather than rendered as an invented Linux activity indicator.
struct AgentWorkload: Equatable {
    let workingCount: Int
    let anyAtTopEffort: Bool

    static let none = AgentWorkload(workingCount: 0, anyAtTopEffort: false)
}

@MainActor
final class AgentActivityBeamView: NSView {
    enum Surface { case sidebarRow }

    init(surface: Surface) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(workload: AgentWorkload) {
        precondition(workload == .none, "Linux sidebar has no verified working state")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
