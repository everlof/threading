import AppKit
@testable import CoreSlice

/// Keep the shared native session content mounted at a real size in the recycled navigator
/// slot. A stack without a sized host can compile yet paint only the diagnostic status text.
@MainActor
enum SessionRowLayoutFixture {
    static func run() {
        let owner = NSWindow(backingScaleFactor: 2)
        let root = Specimen.Window(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        owner.contentView = root
        let accent = NSColor(red: 0.16, green: 0.42, blue: 0.78, alpha: 1)
        let icon = ProviderMarks.image(for: .codex, selected: true)

        root.prepareNavigatorFrame(root.frame)
        root.mountNavigatorRow(frame: NSRect(x: 6, y: 60, width: 148, height: 22),
                               accent: accent, selected: true, ink: Specimen.Ink(on: accent),
                               showsMark: false)
        root.mountSessionContent(title: "A saved agent", icon: icon, selected: true)
        let diagnosis = LayoutEngine.layout(root)
        precondition(diagnosis.solved, "shared session content broke navigator layout")
        guard let row = root.mountedRow(at: 0),
              let stack = row.subviews.compactMap({ $0 as? NSStackView }).first(where: {
                  $0.accessibilityIdentifier() == "sidebar.session.content-stack"
              }),
              let content = stack.arrangedSubviews.compactMap({ $0 as? ThemedSessionRowContentView }).first
        else { preconditionFailure("shared session content stack was not mounted") }
        guard let slot = row.subviews.compactMap({ $0 as? SidebarSessionTrailingSlot }).first
        else { preconditionFailure("shared session trailing slot was not mounted") }
        guard let status = slot.subviews.first(where: {
            $0.accessibilityIdentifier() == "sidebar.session.status"
        }) else { preconditionFailure("shared session status slot was not mounted") }
        precondition(abs(stack.frame.midY - row.bounds.midY) < 0.5 &&
                     stack.frame.minX == SidebarRowDefaults.leadingInset &&
                     stack.frame.maxX <= slot.frame.minX - SidebarRowDefaults.horizontalSpacing &&
                     slot.frame.maxX == row.bounds.maxX - SidebarRowDefaults.trailingInset,
                     "shared session content lost its Mac row constraints")
        precondition(status.frame.width == SidebarRowDefaults.sessionStatusSize &&
                     status.frame.height == SidebarRowDefaults.sessionStatusSize &&
                     abs(status.frame.midX - (slot.frame.width - SidebarRowDefaults.trailingSlotSize / 2)) < 0.5 &&
                     abs(status.frame.midY - slot.bounds.midY) < 0.5,
                     "shared session status lost its Mac trailing-slot constraints")
        row.configureProductionActivity(.awaitingUser, phase: 0)
        precondition(LayoutEngine.layout(root).solved, "blocked activity broke the session slot")
        guard let mark = status.subviews.first(where: {
            $0.accessibilityIdentifier() == "sidebar.session.activity"
        }) else { preconditionFailure("blocked session mark was not mounted") }
        precondition(mark.frame == status.bounds && !mark.isHidden &&
                     mark.accessibilityLabel() == "Session waiting for an answer",
                     "blocked status lost the shared status-content constraints")
        row.configureProductionActivity(.working, phase: 0.5)
        precondition(mark.accessibilityLabel() == "Session working" && !mark.isHidden,
                     "working status did not reuse the mounted mark")
        precondition(content.titleLabel.frame.width > 20 &&
                     content.titleLabel.stringValue == "A saved agent",
                     "shared session title was not laid out")
        precondition(content.iconView.frame.width == SidebarRowDefaults.iconSlotWidth &&
                     content.iconView.image != nil,
                     "shared session icon was not laid out")
        row.configureProductionSession(
            title: "Ångström Codex 日本語 — A saved conversation with a long title",
            icon: icon, selected: true)
        root.mountSessionStatus("Snoozed", color: accent)
        let longTitleDiagnosis = LayoutEngine.layout(root)
        precondition(longTitleDiagnosis.solved, "long session title broke navigator layout")
        guard let attention = stack.arrangedSubviews.compactMap({ $0 as? NSTextField }).first(where: {
            $0.accessibilityIdentifier() == "sidebar.session.attention-overlay"
        }) else { preconditionFailure("shared attention label was not mounted") }
        precondition(slot.frame.width == SidebarRowDefaults.trailingSlotSize &&
                     attention.stringValue == "Snoozed" && !attention.isHidden &&
                     abs(attention.frame.minX - content.frame.maxX - SidebarRowDefaults.horizontalSpacing) < 0.5 &&
                     content.titleLabel.frame.maxX <= content.bounds.maxX &&
                     stack.frame.maxX <= slot.frame.minX - SidebarRowDefaults.horizontalSpacing,
                     "long session title and attention lost their Mac stack slots")
        root.mountSessionStatus(nil, color: accent)
        row.configureProductionActivity(.idle, phase: 0)
        precondition(LayoutEngine.layout(root).solved && attention.isHidden &&
                     slot.frame.width == SidebarRowDefaults.trailingSlotSize && mark.isHidden,
                     "recycled session kept a stale attention label")
        print("PASS shared session content layout in the native navigator slot")
    }
}
