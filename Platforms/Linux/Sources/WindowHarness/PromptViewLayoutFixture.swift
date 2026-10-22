import AppKit

/// Exercise the production composer against shim layout and rendered pixels. The outer
/// viewport is host geometry; PromptView owns its complete subtree.
@MainActor
enum PromptViewLayoutFixture {
    static func run(output: String) throws {
        LinuxSymbols.install()
        let emptyImage = NSImageView()
        precondition(emptyImage.intrinsicContentSize.width == NSView.noIntrinsicMetric,
                     "an unset image cannot conflict with a fixed symbol slot")
        for dark in [false, true] {
            let owner = NSWindow(backingScaleFactor: 2)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 260))
            root.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            owner.contentView = root

            let prompt = PromptView(frame: NSRect(x: 28, y: 32, width: 544, height: 92))
            prompt.placeholder = "Reply to this conversation"
            prompt.submitPlacement = .footer
            prompt.fontSurface = .conversation
            let model = ChipView()
            model.configure(symbolName: "cpu", title: "Default model")
            prompt.setFooterControls(leading: [model], trailing: [])
            root.addSubview(prompt)
            prompt.stringValue = "A reply with enough text to exercise the real editor and its footer."

            owner.layoutIfNeeded()
            let diagnosis = LayoutEngine.layout(root)
            owner.layoutIfNeeded()
            precondition(diagnosis.solved, "production prompt layout failed")
            precondition(prompt.bounds.height >= Design.Size.inputHeight,
                         "production prompt lost its resting height")
            precondition(descendants(of: prompt).compactMap { $0 as? PromptTextView }
                .contains { !$0.visibleRect.intersection($0.textUsedRect).isEmpty },
                "production editor text is outside its visible viewport")
            precondition(descendants(of: prompt).contains {
                $0.accessibilityIdentifier() == "composer.prompt.submit"
            }, "production submit control was not mounted")
            var submitted: String?
            prompt.onSubmit = { submitted = $0 }
            prompt.submit()
            precondition(submitted == prompt.stringValue,
                         "production prompt changed the submitted text")

            try render(root, background: dark ? .black : .white,
                       to: "\(output)-\(dark ? "dark" : "light").png")
        }
        print("PASS production PromptView mounts and submits in light and dark Linux appearances")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
