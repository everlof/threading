import AppKit
import XCTest
@testable import Threading

@MainActor
final class BrowserAnnotationContrastTests: XCTestCase {
    func testOutlineHasAContrastingPolarityAcrossTheRGBGamut() {
        for r in stride(from: 0.0, through: 1.0, by: 1.0 / 16) {
            for g in stride(from: 0.0, through: 1.0, by: 1.0 / 16) {
                for b in stride(from: 0.0, through: 1.0, by: 1.0 / 16) {
                    let ground = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
                    XCTAssertGreaterThanOrEqual(max(
                        ThemeContrast.ratio(Design.Annotation.darkEdge, ground),
                        ThemeContrast.ratio(Design.Annotation.lightEdge, ground)
                    ), 4.5)
                }
            }
        }
    }

    func testPinsAndOutlinesKeepBothEdgesOverMatchingAndBusyGrounds() throws {
        let original = AppThemePalette.current
        defer { AppThemePalette.set(original) }
        for (themeIndex, theme) in [AppTheme.system, AppThemeStyles.pure, AppThemeStyles.cyberpunk,
                      AppThemeStyles.swissMinimalist].enumerated() {
            AppThemePalette.set(theme)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try XCTUnwrap(NSAppearance(named: name))
                var failure: Error?
                appearance.performAsCurrentDrawingAppearance {
                    do {
                        let root = AnnotationContrastBackdrop(frame: CGRect(x: 0, y: 0, width: 400, height: 220))
                        let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.appearance = appearance
                        window.contentView = root
                        defer { window.contentView = nil }
                        let overlay = BrowserAnnotationOverlay(frame: root.bounds)
                        overlay.isAnnotating = true
                        overlay.markers = [.init(id: 1, point: CGPoint(x: 100, y: 100))]
                        overlay.hoveredTarget = .init(rect: CGRect(x: 150, y: 60, width: 120, height: 80), label: "Target")
                        root.addSubview(overlay)
                        for (groundIndex, ground) in [NSColor.black, .white, .systemPink, .systemGreen, Design.Annotation.fill].enumerated() {
                            for busy in [false, true] {
                                root.ground = ground; root.busy = busy
                                let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                                root.cacheDisplay(in: root.bounds, to: rep)
                                // Sample the actual raster's solid bands, not only the palette values.
                                let pinLeft = 100 - Design.Size.chipHeight / 2
                                let band = Design.Annotation.edgeWidth
                                for x in [pinLeft - 1.5 * band, 150 + band / 2] {
                                    XCTAssertLessThan(try pixel(rep, root, x, 100).whiteComponent, 0.1)
                                    XCTAssertGreaterThan(try pixel(rep, root, x + band, 100).whiteComponent, 0.9)
                                }
                                if groundIndex == 4, busy,
                                   let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                                    window.setContentSize(CGSize(width: 760, height: 480))
                                    overlay.frame = root.bounds
                                    overlay.showEditor(BrowserAnnotationEditor(
                                        identifier: 1, note: "Keep the annotation readable over this image", isExisting: true
                                    ), at: CGPoint(x: 370, y: 250))
                                    root.layoutSubtreeIfNeeded()
                                    let capture = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                                    root.cacheDisplay(in: root.bounds, to: capture)
                                    let directory = URL(fileURLWithPath: output)
                                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                                    try XCTUnwrap(capture.representation(using: .png, properties: [:])).write(to:
                                        directory.appendingPathComponent("contrast-component-\(themeIndex)-\(name.rawValue).png"))
                                }
                            }
                        }
                    } catch { failure = error }
                }
                if let failure { throw failure }
            }
        }
    }

    func testEditorSurfaceStaysOpaqueWithAContrastingBoundary() throws {
        let root = AnnotationContrastBackdrop(frame: CGRect(x: 0, y: 0, width: 400, height: 220))
        let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.contentView = nil }
        let surface = BrowserAnnotationSurfaceView(frame: CGRect(x: 20, y: 20, width: 360, height: 160))
        root.addSubview(surface)
        var previous: NSColor?
        for ground in [NSColor.black, .white, .systemPink, Design.Annotation.editorFill] {
            root.ground = ground; root.busy = true
            let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            let fill = try pixel(rep, root, 200, 100)
            if let previous { XCTAssertEqual(fill, previous, "Page pixels must never affect the editor face") }
            previous = fill
            XCTAssertLessThan(try pixel(rep, root, 20.5, 100).whiteComponent, 0.1)
            XCTAssertGreaterThan(try pixel(rep, root, 21.5, 100).whiteComponent, 0.9)
        }
    }

    private func pixel(_ rep: NSBitmapImageRep, _ root: NSView, _ x: CGFloat, _ y: CGFloat) throws -> NSColor {
        try XCTUnwrap(rep.colorAt(
            x: Int(x * CGFloat(rep.pixelsWide) / root.bounds.width),
            y: Int(y * CGFloat(rep.pixelsHigh) / root.bounds.height)
        )?.usingColorSpace(.deviceGray))
    }
}

private final class AnnotationContrastBackdrop: NSView {
    override var isFlipped: Bool { true }
    var ground = NSColor.white { didSet { needsDisplay = true } }
    var busy = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        ground.setFill(); bounds.fill()
        if busy {
            for y in stride(from: 0, to: Int(bounds.height), by: 6) {
                for x in stride(from: 0, to: Int(bounds.width), by: 6) {
                    ((x + y) % 12 == 0 ? NSColor.black : .white).setFill()
                    CGRect(x: x, y: y, width: 3, height: 6).fill()
                }
            }
        }
    }
}
