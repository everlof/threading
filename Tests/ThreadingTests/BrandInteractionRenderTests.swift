import AppKit
import XCTest
@testable import Threading

/// The two transient top-left states in the shell that positions them: the held brand tumble at
/// its shipping 24pt size, and the native titlebar accepting an external screenshot.
///
/// An isolated mark cannot say whether the tumble is still legible beside the wordmark, and an
/// isolated wash cannot say whether its sentence clears the traffic lights. The actual
/// `TitlebarActionWindow`, sidebar backdrop and pane header are therefore the fixture.
@MainActor
final class BrandInteractionRenderTests: XCTestCase {

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let windowSize = NSSize(width: 520, height: 160)
    }

    private enum State: String, CaseIterable {
        case tumble
        case screenshotDrop = "screenshot-drop"
    }

    func testRendersHeldTumbleAndScreenshotDropTargetInNativeShell() throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        defer {
            AppThemePalette.set(.system)
            Design.Motion.reduceMotionOverrideForTesting = nil
        }
        AppThemePalette.set(.system)
        Design.Motion.reduceMotionOverrideForTesting = false

        var written = 0
        for appearanceName: NSAppearance.Name in [.aqua, .darkAqua] {
            let appearance = appearanceName == .aqua ? "light" : "dark"
            for state in State.allCases {
                let image = try XCTUnwrap(
                    shellImage(appearance: appearanceName, state: state),
                    "could not render \(state.rawValue) in \(appearance)"
                )
                try image.write(
                    to: Render.directory.appendingPathComponent(
                        "brand-interaction-\(state.rawValue)-\(appearance).png"
                    )
                )
                written += 1
            }
        }

        XCTAssertEqual(written, 4)
    }

    private func shellImage(appearance name: NSAppearance.Name, state: State) -> Data? {
        let appearance = NSAppearance(named: name)
        var data: Data?
        let render = {
            let window = TitlebarActionWindow(
                contentRect: NSRect(origin: .zero, size: Render.windowSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.appearance = appearance

            let root = NSView(frame: window.contentView?.bounds ?? .zero)
            root.autoresizingMask = [.width, .height]
            window.contentView = root

            let sidebar = SidebarBackdropView()
            sidebar.translatesAutoresizingMaskIntoConstraints = false
            let workspace = ThemedSurfaceView()
            workspace.translatesAutoresizingMaskIntoConstraints = false
            workspace.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
            root.addSubview(sidebar)
            root.addSubview(workspace)

            let brand = SidebarBrandView()
            if state == .tumble {
                brand.setHoverPresentation(weavePhase: 0.34, heldHoverPhase: 0.58)
            }
            let header = PaneHeaderView(leading: [brand])
            sidebar.addSubview(header)

            NSLayoutConstraint.activate([
                sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                sidebar.topAnchor.constraint(equalTo: root.topAnchor),
                sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                sidebar.widthAnchor.constraint(equalToConstant: SidebarDefaults.defaultWidth),

                workspace.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                workspace.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                workspace.topAnchor.constraint(equalTo: root.topAnchor),
                workspace.bottomAnchor.constraint(equalTo: root.bottomAnchor),

                header.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor)
            ])

            AppThemeRefresh.repaint(root)
            root.layoutSubtreeIfNeeded()
            if state == .screenshotDrop {
                // Configure the shipping route before presenting its accepted state. The
                // structural drop destination owns the design-system indicator in production;
                // without a listener there is deliberately no destination to render.
                window.onScreenshotDropped = { _ in }
                window.setScreenshotDropIndicatorPresentation(true)
            }
            root.layoutSubtreeIfNeeded()

            guard let frame = root.superview,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        appearance?.performAsCurrentDrawingAppearance(render)
        return data
    }
}
