import AppKit

/// Exercise the shared Mac terminal content in a recycled Linux navigator slot at both
/// full navigator width and the narrow workspace sidebar width.
@MainActor
enum TerminalRowLayoutFixture {
    static func run() {
        let owner = NSWindow(backingScaleFactor: 2)
        let root = Specimen.Window(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        owner.contentView = root
        let accent = NSColor(red: 0.16, green: 0.42, blue: 0.78, alpha: 1)
        guard let icon = Design.Symbol.image("terminal", slot: SidebarRowDefaults.iconSlotWidth,
                                             pointSize: SidebarRowDefaults.iconSize,
                                             weight: .regular)
        else { preconditionFailure("terminal identity glyph is unavailable") }
        var retainedRow: Specimen.Row?
        var retainedContent: ThemedTerminalRowContentView?
        var retainedAction: ThemedIconButton?
        var wideTitleWidth: CGFloat = 0

        for width in [CGFloat(400), 160, 400] {
            root.prepareNavigatorFrame(NSRect(x: 0, y: 0, width: width, height: 240))
            root.mountNavigatorRow(frame: NSRect(x: 6, y: 175, width: width - 12, height: 22),
                                   accent: accent, selected: true, ink: Specimen.Ink(on: accent),
                                   showsMark: false)
            root.mountTerminalContent(title: "A saved shell with a long title", icon: icon,
                                      selected: true, running: true)
            let diagnosis = LayoutEngine.layout(root)
            precondition(diagnosis.solved, "shared terminal content broke navigator layout")
            guard let row = root.mountedRow(at: 0),
                  let content = row.subviews.compactMap({ $0 as? ThemedTerminalRowContentView }).first
            else { preconditionFailure("shared terminal content was not mounted") }
            guard let action = row.subviews.compactMap({ $0 as? ThemedIconButton }).first(where: {
                $0.accessibilityIdentifier() == "sidebar.terminal.actions"
            }) else { preconditionFailure("shared terminal action was not mounted") }
            precondition(abs(content.frame.midY - row.bounds.midY) < 0.5 &&
                         content.frame.minX == SidebarRowDefaults.leadingInset &&
                         content.frame.maxX <= action.frame.minX - SidebarRowDefaults.horizontalSpacing &&
                         action.frame.maxX == row.bounds.maxX
                            - max(0, SidebarRowDefaults.trailingInset - action.opticalHorizontalInset),
                         "shared terminal content lost its Mac row constraints")
            precondition(content.iconView.frame.width == SidebarRowDefaults.iconSlotWidth &&
                         content.iconView.image === icon,
                         "shared terminal icon was not laid out")
            precondition(content.titleLabel.stringValue == "A saved shell with a long title" &&
                         content.titleLabel.frame.width > 0,
                         "shared terminal title was not laid out")
            if width == 160 {
                precondition(content.titleLabel.frame.width < wideTitleWidth,
                             "narrow sidebar did not compress the terminal title")
            } else { wideTitleWidth = content.titleLabel.frame.width }
            if let retainedRow { precondition(row === retainedRow, "terminal slot was rebuilt") }
            if let retainedContent {
                precondition(content === retainedContent, "terminal content was rebuilt")
            }
            if let retainedAction {
                precondition(action === retainedAction, "terminal action was rebuilt")
            }
            retainedRow = row
            retainedContent = content
            retainedAction = action
        }
        print("PASS shared terminal row assembly in recycled navigator slot")
    }
}
