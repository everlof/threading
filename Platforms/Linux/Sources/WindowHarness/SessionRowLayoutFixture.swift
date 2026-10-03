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
        root.mountSessionContent(title: "A saved agent", icon: icon, selected: true,
                                 trailingInset: 12)
        let diagnosis = LayoutEngine.layout(root)
        precondition(diagnosis.solved, "shared session content broke navigator layout")
        guard let row = root.mountedRow(at: 0),
              let content = row.subviews.compactMap({ $0 as? ThemedSessionRowContentView }).first
        else { preconditionFailure("shared session content was not mounted") }
        precondition(content.frame.width > 100 && content.frame.height == row.frame.height,
                     "shared session content lost its host frame")
        precondition(content.titleLabel.frame.width > 20 &&
                     content.titleLabel.stringValue == "A saved agent",
                     "shared session title was not laid out")
        precondition(content.iconView.frame.width == SidebarRowDefaults.iconSlotWidth &&
                     content.iconView.image != nil,
                     "shared session icon was not laid out")
        print("PASS shared session content layout in the native navigator slot")
    }
}
