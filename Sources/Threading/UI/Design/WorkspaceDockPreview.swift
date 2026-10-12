import AppKit

/// Passive geometry feedback. It cannot steal the tracking gesture or focus from a tab.
final class WorkspaceDockPreview: NSView {
  var landing: NSRect? { didSet { needsDisplay = true } }
  var title = "" { didSet { needsDisplay = true; setAccessibilityLabel(title) } }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    guard let landing, landing.width > 10, landing.height > 10 else { return }
    let rect = landing.insetBy(dx: 5, dy: 5)
    let path = NSBezierPath(roundedRect: rect, xRadius: Design.Radius.control,
      yRadius: Design.Radius.control)
    let accent = Design.Surface.accent
    accent.withAlphaComponent(0.2).setFill()
    path.fill()
    accent.setStroke()
    path.lineWidth = 2
    path.stroke()
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
      .font: Design.Typography.body(),
      .foregroundColor: Design.Text.label,
      .paragraphStyle: paragraph,
    ]
    let text = title as NSString
    let size = text.size(withAttributes: attributes)
    let labelWidth = min(size.width, max(0, rect.width - 24))
    let label = NSRect(x: rect.midX - labelWidth / 2, y: rect.midY - size.height / 2,
      width: labelWidth, height: size.height)
    Design.Surface.background.withAlphaComponent(0.95).setFill()
    NSBezierPath(roundedRect: label.insetBy(dx: -12, dy: -7),
      xRadius: Design.Radius.control, yRadius: Design.Radius.control).fill()
    text.draw(in: label, withAttributes: attributes)
  }
}
