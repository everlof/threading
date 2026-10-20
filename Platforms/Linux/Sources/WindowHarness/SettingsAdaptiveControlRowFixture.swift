#if os(Linux)
import AppKit

/// Exercise the production Settings row against the Linux constraint solver at the widths
/// that force each of its two arrangements. The full Settings mode will mount this same view.
@MainActor
enum SettingsAdaptiveControlRowFixture {
    static func run() {
        NSFont.prepareSystemFonts()
        let title = NSTextField(wrappingLabelWithString: "Ask before closing a running session")
        let detail = NSTextField(wrappingLabelWithString:
            "Closing ends the agent and keeps the session in the sidebar to resume.")
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.small
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toggle = ThemedToggle()
        let row = SettingsAdaptiveControlRow(labels: labels, control: toggle)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 180))
        root.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: root.topAnchor),
            row.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])
        let window = NSWindow(backingScaleFactor: 1)
        window.contentView = root

        for (width, stacked) in [(CGFloat(220), true), (CGFloat(420), false),
                                 (CGFloat(220), true)] {
            root.frame = NSRect(x: 0, y: 0, width: width, height: 180)
            window.layoutIfNeeded()
            precondition(row.isStacked == stacked,
                         "Settings row did not adapt at width \(width)")
            let labelsFrame = labels.convert(labels.bounds, to: row)
            let controlFrame = toggle.convert(toggle.bounds, to: row)
            if stacked {
                precondition(controlFrame.maxY <= labelsFrame.minY,
                             "Stacked Settings control was not below its words")
            } else {
                precondition(controlFrame.minX >= labelsFrame.maxX,
                             "Wide Settings control was not beside its words")
            }
        }
        print("PASS shared Settings row narrow/wide/narrow constraints")
    }
}
#endif
