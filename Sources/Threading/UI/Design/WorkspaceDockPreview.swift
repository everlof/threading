import AppKit

/// Passive geometry feedback for a dragged workspace tab: the space it would take, and a caption
/// naming what the drop does there.
///
/// The region is the same drop-target wash every other drop in the app paints — the accent held
/// back to `Design.Surface.dropTarget`, edged in the accent — because it lies over content the
/// reader still has to see: which pane is about to change is the whole question it answers. Both
/// surfaces go through `applySurface`, so a theme switch, an appearance flip and Increase
/// Contrast each resolve them again, and a theme's corner and edge weight shape them.
///
/// Moving between landings glides at `Design.Motion.quick`, which Reduce Motion makes immediate;
/// the first landing fades in where it is rather than flying in from the last one. Nothing here
/// hit-tests, so the preview can never take the tracking gesture or focus from the tab.
@MainActor
final class WorkspaceDockPreview: NSView, ThemedComponent, ThemeDerivedContent {

  private enum Layout {
    /// The region sits just inside the space it names, so its edge reads apart from the
    /// dividers already drawn there.
    static let regionInset = Design.Spacing.tight
    static let captionPadding = NSSize(width: Design.Spacing.inset, height: Design.Spacing.small)
  }

  /// The landing in this view's coordinates, or nil while nothing would happen.
  private(set) var landing: NSRect?
  private(set) var title = ""

  private let region = NSView()
  private let badge = NSView()
  private let caption = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    for surface in [region, badge] {
      surface.wantsLayer = true
      surface.alphaValue = 0
      addSubview(surface)
    }
    caption.applyFont(.control)
    caption.textColor = Design.Text.label
    caption.alignment = .center
    caption.lineBreakMode = .byTruncatingTail
    caption.setAccessibilityElement(false)
    // Placed explicitly for each caption: autoresizing would apply the plate's change in size a
    // second time on top of the frame already fitted to the new words.
    caption.autoresizingMask = []
    badge.autoresizesSubviews = false
    badge.addSubview(caption)
    setAccessibilityElement(false)
    applySurfaces()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var isFlipped: Bool { true }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applySurfaces()
    needsLayout = true
  }

  /// A theme states a typeface as well as a palette. The sweep re-applies the caption's font
  /// after this view, so the caption is re-fitted on the layout pass that follows rather than
  /// measured here against the font it is about to lose.
  func rederiveThemedContent() {
    needsLayout = true
  }

  override func layout() {
    super.layout()
    guard let landing else { return }
    let regionFrame = landing.insetBy(dx: Layout.regionInset, dy: Layout.regionInset)
    let plate = captionFrame(centredIn: regionFrame)
    badge.frame = plate
    badge.alphaValue = plate.isEmpty ? 0 : 1
  }

  /// Shows `landing` with its caption, or clears the preview. Unchanged input does nothing, so a
  /// pointer moving inside one landing costs no layout, drawing or animation.
  func present(_ landing: NSRect?, title: String) {
    guard landing != self.landing || title != self.title else { return }
    let wasShowing = self.landing != nil
    self.landing = landing
    self.title = title

    guard let landing else {
      setAccessibilityLabel(nil)
      animate { [region, badge] in
        region.animator().alphaValue = 0
        badge.animator().alphaValue = 0
      }
      return
    }

    caption.stringValue = title
    setAccessibilityLabel(title)
    let regionFrame = landing.insetBy(dx: Layout.regionInset, dy: Layout.regionInset)
    let badgeFrame = captionFrame(centredIn: regionFrame)
    let showsCaption = !badgeFrame.isEmpty
    if wasShowing {
      animate { [region, badge] in
        region.animator().frame = regionFrame
        badge.animator().frame = badgeFrame
        badge.animator().alphaValue = showsCaption ? 1 : 0
      }
    } else {
      region.frame = regionFrame
      badge.frame = badgeFrame
      animate { [region, badge] in
        region.animator().alphaValue = 1
        badge.animator().alphaValue = showsCaption ? 1 : 0
      }
    }
    NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
      .announcement: title,
      .priority: NSAccessibilityPriorityLevel.medium.rawValue,
    ])
  }

  /// The caption's plate, centred and fitted to its words; empty when the region is too small
  /// to hold it beside its own padding.
  private func captionFrame(centredIn region: NSRect) -> NSRect {
    let text = caption.cell?.cellSize ?? caption.intrinsicContentSize
    let padding = Layout.captionPadding
    let width = min(ceil(text.width) + padding.width * 2, region.width - padding.width * 2)
    let height = ceil(text.height) + padding.height * 2
    guard width > padding.width * 2, height <= region.height - padding.height * 2 else { return .zero }
    let plate = NSRect(x: region.midX - width / 2, y: region.midY - height / 2, width: width, height: height)
    caption.frame = NSRect(origin: .zero, size: plate.size).insetBy(dx: padding.width, dy: padding.height)
    return backingAlignedRect(plate, options: .alignAllEdgesNearest)
  }

  private func animate(_ changes: @escaping () -> Void) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Design.Motion.quick
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      context.allowsImplicitAnimation = true
      changes()
    }
  }

  private func applySurfaces() {
    // Neither is a control: no bevel, whatever the material, so a period theme raises no button
    // out of the space a pane is about to take, and the caption reads as the plain infotip its
    // floating surface is authored for.
    region.applySurface(fill: Design.Surface.dropTarget, radius: .control,
      border: Design.Surface.accent, bevel: .none)
    badge.applySurface(fill: Design.Surface.floating, radius: .control,
      border: Design.Surface.border, bevel: .none)
  }
}
