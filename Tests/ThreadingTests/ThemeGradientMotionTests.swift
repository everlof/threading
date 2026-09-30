import AppKit
import ThreadingRemoteKit
import XCTest
@testable import Threading

@MainActor
final class ThemeGradientMotionTests: HostedStoreTestCase {
    func testRendersDriftInTheShippingSidebarAndPane() throws {
        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previous) }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
                            ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for light in [false, true] {
            let kind: AppTheme.VariantKind = light ? .light : .dark
            let appearance = try XCTUnwrap(kind.appearance)
            let backdrop = ThemeBackdrop(gradient: .init(stops: [
                .init(color: NSColor(hex: light ? "#E1EDF2" : "#101827")!, position: 0),
                .init(color: NSColor(hex: light ? "#E5DEF1" : "#1E3F4C")!, position: 0.55),
                .init(color: NSColor(hex: light ? "#F4E7D5" : "#352E51")!, position: 1)
            ], angleDegrees: 135, drift: .init(duration: 24, distance: 0.18)))
            var material = AppTheme.Material.system
            material.backdrop = backdrop
            let variant = AppThemeEditing.makeVariant(
                named: "Drift", from: .system, kind: kind, material: material
            ).replacingSidebar(SidebarStyle(background: backdrop))
            let theme = try AppThemeEditing.assemble(
                id: AppThemeID("custom-drift-render"), name: "Drift", mode: light ? .light : .dark,
                summary: nil, variants: [kind: variant]
            )
            AppThemeLibrary.apply(theme)
            let sidebar = ProjectSidebarViewController(defersInitialTreeMount: true)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 540))
            root.appearance = appearance
            let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = root
            window.appearance = appearance
            let column = sidebar.view
            column.translatesAutoresizingMaskIntoConstraints = false
            let pane = ThemedSurfaceView()
            root.addSubview(column)
            root.addSubview(pane)
            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                column.topAnchor.constraint(equalTo: root.topAnchor),
                column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                column.widthAnchor.constraint(equalToConstant: 260),
                pane.leadingAnchor.constraint(equalTo: column.trailingAnchor),
                pane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                pane.topAnchor.constraint(equalTo: root.topAnchor),
                pane.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])
            pane.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)
            root.layoutSubtreeIfNeeded()
            func hold(_ view: NSView, phase: Double) {
                if let observer = view as? ThemeBackdropMotionView {
                    observer.configure(angleDegrees: 135, drift: .init(duration: 24, distance: 0.18), frozenPhase: phase)
                }
                for child in view.subviews { hold(child, phase: phase) }
            }
            for (name, phase) in [("rest", 0.0), ("quarter", 0.25)] {
                hold(root, phase: phase)
                let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                appearance.performAsCurrentDrawingAppearance {
                    root.cacheDisplay(in: root.bounds, to: rep)
                }
                let image = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try image.write(to: directory.appendingPathComponent("theme-drift-\(name)-\(light ? "light" : "dark").png"))
            }
        }
    }

    func testBackdropLifecycleStopsForHiddenDetachedReducedMotionAndPowerPolicy() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let owner = try XCTUnwrap(window.contentView)
        let gradient = CAGradientLayer()
        let observer = ThemeBackdropMotionView(gradient: gradient)
        observer.windowIsVisible = { _ in true }
        observer.permitsMotion = { true }
        owner.addSubview(observer)
        observer.configure(angleDegrees: 135, drift: .init())
        func isAnimating() -> Bool { gradient.animation(forKey: ThemeGradientAnimator.animationKey) != nil }
        XCTAssertTrue(isAnimating())
        owner.isHidden = true
        XCTAssertFalse(isAnimating())
        owner.isHidden = false
        XCTAssertTrue(isAnimating())
        observer.permitsMotion = { false }
        observer.refreshMotion()
        XCTAssertFalse(isAnimating())
        observer.permitsMotion = { true }
        observer.windowIsVisible = { _ in false }
        observer.refreshMotion()
        XCTAssertFalse(isAnimating())
        observer.windowIsVisible = { _ in true }
        observer.refreshMotion()
        XCTAssertTrue(isAnimating())
        observer.removeFromSuperview()
        XCTAssertFalse(isAnimating())
        XCTAssertNil(observer.hitTest(.zero))
        XCTAssertFalse(observer.isAccessibilityElement())
    }

    func testLiveRecipeReplacementAndStaticFallbackRemoveOnlyDecorativeMotion() throws {
        let layer = CAGradientLayer()
        let animator = ThemeGradientAnimator(layer: layer)
        animator.configure(angleDegrees: 90, flipped: false, drift: .init())
        animator.setActive(true)
        let moving = try XCTUnwrap(layer.animation(forKey: ThemeGradientAnimator.animationKey))
        XCTAssertEqual(moving.duration, 24)
        animator.configure(angleDegrees: 180, flipped: false, drift: nil)
        XCTAssertNil(layer.animation(forKey: ThemeGradientAnimator.animationKey))
        XCTAssertEqual(layer.startPoint.y, 1, accuracy: 0.000001)
        animator.configure(angleDegrees: 90, flipped: false, drift: .init(), frozenPhase: 0.25)
        XCTAssertNil(layer.animation(forKey: ThemeGradientAnimator.animationKey))
        XCTAssertEqual(layer.startPoint.x, 0.12, accuracy: 0.000001)
        animator.configure(angleDegrees: 90, flipped: false, drift: .init(duration: 0))
        XCTAssertNil(layer.animation(forKey: ThemeGradientAnimator.animationKey))
    }
}
