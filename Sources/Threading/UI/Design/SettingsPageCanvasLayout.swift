import AppKit

/// The Settings page's one-way width contract inside the workspace pane.
/// Both desktop hosts use this declaration so a narrow pane spends its margins before its copy.
enum SettingsPageCanvasLayout {
    static var width: CGFloat {
        Design.Size.settingsContentWidth + Design.Size.glowGutter * 2
    }

    @MainActor @discardableResult
    static func install(
        page content: NSView,
        in host: NSView,
        top: NSLayoutYAxisAnchor? = nil,
        width pageWidth: CGFloat = SettingsPageCanvasLayout.width
    ) -> [NSLayoutConstraint] {
        content.translatesAutoresizingMaskIntoConstraints = false
        if content.superview !== host { host.addSubview(content) }

        // The shell owns the pane measure. Only a <= relationship may mention the host width:
        // a page inside a split item must never supply that item's preferred measure.
        let insetWidth = content.widthAnchor.constraint(
            lessThanOrEqualTo: host.widthAnchor,
            constant: -Design.Spacing.large * 2
        )
        // One point above ordinary content compression, so readable labels spend their own
        // compression before the page spends the narrow pane's comfortable margin.
        insetWidth.priority = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.defaultHigh.rawValue + 1
        )

        // One step below the inset ceiling, keeping a sparse page at the shared canvas measure.
        let preferred = content.widthAnchor.constraint(equalToConstant: pageWidth)
        preferred.priority = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.defaultHigh.rawValue - 1
        )

        let constraints = [
            insetWidth,
            preferred,
            content.topAnchor.constraint(equalTo: top ?? host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: pageWidth),
            // No required negative inset: a host can start at zero width before its first layout.
            content.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor)
        ]
        NSLayoutConstraint.activate(constraints)
        return constraints
    }
}
