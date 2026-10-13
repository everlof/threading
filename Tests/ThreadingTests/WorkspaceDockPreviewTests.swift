import AppKit
import XCTest
@testable import Threading

/// The docking preview is a design component: it never takes the pointer, it says where a drop
/// lands, it paints the app's one drop wash from the live theme, and it glides — or, under
/// Reduce Motion, lands at once.
@MainActor
final class WorkspaceDockPreviewTests: XCTestCase {

  private let size = NSSize(width: 480, height: 300)

  override func tearDown() {
    MainActor.assumeIsolated {
      Design.Motion.reduceMotionOverrideForTesting = nil
    }
    super.tearDown()
  }

  private func makePreview() -> (WorkspaceDockPreview, region: NSView, badge: NSView) {
    let preview = WorkspaceDockPreview(frame: NSRect(origin: .zero, size: size))
    // Region first, then the caption's plate: the order the component adds them.
    return (preview, preview.subviews[0], preview.subviews[1])
  }

  func testItNeverHitTestsAndNamesTheLandingForAssistiveTechnology() {
    Design.Motion.reduceMotionOverrideForTesting = true
    let (preview, _, _) = makePreview()
    let title = L10n.string("Split Below") + " · " + L10n.string("Side panel")
    preview.present(NSRect(x: 0, y: 150, width: 480, height: 150), title: title)

    XCTAssertNil(preview.hitTest(NSPoint(x: 240, y: 225)))
    XCTAssertEqual(preview.accessibilityLabel(), title)
    preview.present(nil, title: "")
    XCTAssertNil(preview.landing)
    XCTAssertNil(preview.accessibilityLabel())
  }

  func testRegionSitsInsideItsLandingWithTheCaptionCentred() {
    Design.Motion.reduceMotionOverrideForTesting = true
    let (preview, region, badge) = makePreview()
    let landing = NSRect(x: 0, y: 150, width: 480, height: 150)
    preview.present(landing, title: L10n.string("Move Here") + " · " + L10n.string("This pane"))

    XCTAssertEqual(region.frame, landing.insetBy(dx: Design.Spacing.tight, dy: Design.Spacing.tight))
    XCTAssertEqual(region.alphaValue, 1)
    XCTAssertEqual(badge.alphaValue, 1)
    XCTAssertEqual(badge.frame.midX, region.frame.midX, accuracy: 1)
    XCTAssertEqual(badge.frame.midY, region.frame.midY, accuracy: 1)
    XCTAssertTrue(region.frame.contains(badge.frame))

    // A sliver too small for its words keeps the region and drops the caption.
    preview.present(NSRect(x: 0, y: 0, width: 480, height: 24), title: "Split Below")
    XCTAssertEqual(badge.alphaValue, 0)
    XCTAssertEqual(region.alphaValue, 1)
  }

  func testUnchangedLandingIsFreeAndAMoveGlidesRatherThanJumps() {
    Design.Motion.reduceMotionOverrideForTesting = false
    let (preview, region, _) = makePreview()
    let first = NSRect(x: 0, y: 0, width: 240, height: 300)
    preview.present(first, title: "Split Left")
    let settled = region.frame
    region.needsDisplay = false
    preview.present(first, title: "Split Left")
    XCTAssertEqual(region.frame, settled)
    XCTAssertFalse(region.needsDisplay, "a pointer moving within one landing must not touch the view")

    // The model frame moves at once; the layer animates there instead of snapping.
    let second = NSRect(x: 240, y: 0, width: 240, height: 300)
    preview.present(second, title: "Split Right")
    XCTAssertEqual(region.frame, second.insetBy(dx: Design.Spacing.tight, dy: Design.Spacing.tight))
    let keys = region.layer?.animationKeys() ?? []
    XCTAssertTrue(keys.contains { $0.contains("position") || $0.contains("bounds") || $0.contains("frame") },
      "moving between landings should animate the region, found \(keys)")
  }

  func testReduceMotionLandsWithoutAnimating() {
    Design.Motion.reduceMotionOverrideForTesting = true
    let (preview, region, _) = makePreview()
    preview.present(NSRect(x: 0, y: 0, width: 240, height: 300), title: "Split Left")
    preview.present(NSRect(x: 240, y: 0, width: 240, height: 300), title: "Split Right")
    XCTAssertTrue((region.layer?.animationKeys() ?? []).isEmpty)
    XCTAssertEqual(region.alphaValue, 1)
  }

  func testSurfacesFollowTheLiveThemeAndUseTheDropRole() throws {
    Design.Motion.reduceMotionOverrideForTesting = true
    let previous = AppThemePalette.current
    defer { AppThemePalette.set(previous) }
    let (preview, region, badge) = makePreview()
    preview.appearance = NSAppearance(named: .aqua)
    preview.present(NSRect(x: 0, y: 0, width: 480, height: 300), title: "Split Below")

    func fill(_ view: NSView) throws -> NSColor {
      let color = try XCTUnwrap(view.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) })
      return try XCTUnwrap(color.usingColorSpace(.sRGB))
    }
    func expected(_ color: NSColor) throws -> NSColor {
      var resolved: NSColor?
      preview.effectiveAppearance.performAsCurrentDrawingAppearance {
        resolved = NSColor(cgColor: color.cgColor)?.usingColorSpace(.sRGB)
      }
      return try XCTUnwrap(resolved)
    }
    for theme in [AppTheme.system, AppThemeStyles.swissMinimalist, AppThemeStyles.cyberpunk] {
      AppThemePalette.set(theme)
      AppThemeRefresh.repaint(preview)
      let wash = try fill(region), want = try expected(Design.Surface.dropTarget)
      XCTAssertEqual(wash.redComponent, want.redComponent, accuracy: 0.01, "\(theme.id)")
      XCTAssertEqual(wash.greenComponent, want.greenComponent, accuracy: 0.01, "\(theme.id)")
      XCTAssertEqual(wash.blueComponent, want.blueComponent, accuracy: 0.01, "\(theme.id)")
      XCTAssertEqual(wash.alphaComponent, want.alphaComponent, accuracy: 0.01,
        "the region is the shared, held-back drop wash rather than its own louder tint")
      let plate = try fill(badge), floating = try expected(Design.Surface.floating)
      XCTAssertEqual(plate.redComponent, floating.redComponent, accuracy: 0.01, "\(theme.id)")
      XCTAssertEqual(region.layer?.cornerRadius ?? -1, Design.Radius.control, accuracy: 0.01, "\(theme.id)")
    }
  }

  func testCaptionIsRefittedWhenTheThemeChangesItsTypeface() throws {
    Design.Motion.reduceMotionOverrideForTesting = true
    let previous = AppThemePalette.current
    defer { AppThemePalette.set(previous) }
    AppThemePalette.set(.system)
    let (preview, _, badge) = makePreview()
    preview.present(NSRect(x: 0, y: 0, width: 480, height: 300),
      title: L10n.string("Split Below") + " · " + L10n.string("Whole workspace"))
    let caption = try XCTUnwrap(badge.subviews.first as? NSTextField)
    for theme in [AppThemeStyles.swissMinimalist, AppThemeStyles.cyberpunk, AppTheme.system] {
      AppThemePalette.set(theme)
      AppThemeRefresh.repaint(preview)
      preview.layoutSubtreeIfNeeded()
      let needed = try XCTUnwrap(caption.cell?.cellSize.width)
      XCTAssertGreaterThanOrEqual(caption.frame.width + 0.5, needed, "\(theme.id): the caption truncated")
      XCTAssertTrue(badge.bounds.contains(caption.frame))
    }
  }

  func testRendersTheLandingOnLightAndDarkGrounds() throws {
    Design.Motion.reduceMotionOverrideForTesting = true
    let directory: URL = {
      if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
      }
      return FileManager.default.temporaryDirectory.appendingPathComponent("ThreadingRenders", isDirectory: true)
    }()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let previous = AppThemePalette.current
    defer { AppThemePalette.set(previous) }

    for (name, theme, appearance) in [
      ("system-dark", AppTheme.system, NSAppearance.Name.darkAqua),
      ("system-light", AppTheme.system, NSAppearance.Name.aqua),
      ("swiss", AppThemeStyles.swissMinimalist, NSAppearance.Name.aqua),
    ] {
      AppThemePalette.set(theme)
      let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: appearance)
      let ground = ThemedSurfaceView()
      ground.frame = NSRect(origin: .zero, size: size)
      window.contentView = ground
      let preview = WorkspaceDockPreview(frame: ground.bounds)
      ground.addSubview(preview)
      window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
      window.animationBehavior = .none
      window.orderFront(nil)
      defer { window.orderOut(nil) }
      AppThemeRefresh.repaint(ground)
      preview.present(NSRect(x: 0, y: 150, width: 480, height: 150),
        title: L10n.string("Split Below") + " · " + L10n.string("Whole workspace"))
      window.displayIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))

      let image = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow,
        CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .nominalResolution]))
      let bitmap = NSBitmapImageRep(cgImage: image)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        .write(to: directory.appendingPathComponent("workspace-dock-preview-\(name).png"))

      // Image rows run top-down, as does the flipped preview: the wash covers the lower half
      // and leaves the upper half on the plain ground.
      let washed = try XCTUnwrap(bitmap.colorAt(x: 40, y: 260)?.usingColorSpace(.sRGB))
      let plain = try XCTUnwrap(bitmap.colorAt(x: 40, y: 60)?.usingColorSpace(.sRGB))
      let difference = abs(washed.redComponent - plain.redComponent)
        + abs(washed.greenComponent - plain.greenComponent)
        + abs(washed.blueComponent - plain.blueComponent)
      XCTAssertGreaterThan(difference, 0.03, "\(name): the landing must be visible on its ground")
      XCTAssertLessThan(difference, 0.6, "\(name): the wash must stay a wash, not a slab")
    }
  }
}
