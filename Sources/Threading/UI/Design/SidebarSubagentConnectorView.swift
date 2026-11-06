import AppKit

/// The relationship occupies its own slot, so it survives compact indentation and an extension
/// replacing the provider mark. Virtual row reuse owns its lifetime; nothing draws off viewport.
final class SidebarSubagentConnectorView: NSView, ThemedComponent {
    var isLastChild = true { didSet { needsDisplay = true } }
    var contrastGround: (() -> NSColor)?
    private var redraw: ThemeRedraw?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        redraw = ThemeRedraw(self)
        setAccessibilityElement(false)
        setAccessibilityIdentifier("sidebar.session.subagent-connector")
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Design.Spacing.inset),
            heightAnchor.constraint(equalToConstant: SidebarDefaults.rowHeight)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let ink = Design.Text.on(contrastGround?() ?? Design.Surface.background).secondary
        ink.setStroke()
        let path = NSBezierPath()
        let x = Design.Spacing.hairline
        path.lineWidth = Design.Radius.border
        path.move(to: NSPoint(x: x, y: bounds.maxY))
        path.line(to: NSPoint(x: x, y: isLastChild ? bounds.midY : bounds.minY))
        path.move(to: NSPoint(x: x, y: bounds.midY))
        path.line(to: NSPoint(x: bounds.maxX, y: bounds.midY))
        path.stroke()
    }
}
