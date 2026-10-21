import AppKit

/// Renders the production completion panel under both system appearances and verifies its
/// selected row and unavailable command remain represented in the retained view tree.
@MainActor
enum PromptCompletionLayoutFixture {
    static func run(output: String) throws {
        let items = [
            PromptCompletionItem(id: "review", title: "/review", detail: "Review the current changes",
                                 kind: "Command", isEnabled: true),
            PromptCompletionItem(id: "deploy", title: "/deploy", detail: "Unavailable in this workspace",
                                 kind: "Command", isEnabled: false),
            PromptCompletionItem(id: "search", title: "$search", detail: "Find files and symbols",
                                 kind: "Skill", isEnabled: true)
        ]
        for dark in [false, true] {
            let owner = NSWindow(backingScaleFactor: 2)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 250))
            root.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            owner.contentView = root
            let panel = PromptCompletionPresenter().makeInlinePreview(items: items, selectedIndex: 0)
            root.addSubview(panel)
            // Place the diagnostic preview in its capture viewport. The panel's own size and
            // content layout remain the unchanged production constraints.
            panel.frame = NSRect(x: 30, y: 26, width: 360, height: 174)
            let diagnosis = LayoutEngine.layout(root)
            precondition(diagnosis.solved, "production completion panel layout failed")
            let rows = descendants(of: panel).filter { $0.accessibilityRole() == .menuItem }
            precondition(rows.count == items.count, "completion items were not mounted")
            precondition(rows[0].isAccessibilitySelected(), "selected completion row lost its state")
            guard let unavailable = rows[1] as? ThemedControl else {
                preconditionFailure("completion row lost its production control type")
            }
            precondition(!unavailable.isEnabled, "unavailable completion item became enabled")
            let suffix = dark ? "dark" : "light"
            try render(root, background: dark ? .black : .white, to: "\(output)-\(suffix).png")
        }
        print("PASS production completion panel renders in light and dark appearances")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
