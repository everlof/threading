import AppKit
import XCTest
@testable import Threading

/// Pixel evidence for the shared scroll-to-end target over the kind of live row that exposed it.
///
/// The reported picture was not a bad circle. A pane-wide surface happened to meet the circle at
/// its horizontal midpoint, used almost the same ink as the circle's edge, and therefore read as
/// a rectangular tail protruding from the control. Both native Conversation and Git Review use
/// `ThemedButton.floatingScrollToEnd`, so this fixture tests that one component directly under
/// every stock theme and appearance rather than testing two hosts against one chosen palette.
@MainActor
final class FloatingScrollTargetRenderTests: XCTestCase {

    private enum Fixture {
        static let size = NSSize(width: 112, height: 96)
        static let scale = 3
        static let target = NSRect(x: 36, y: 28, width: 40, height: 40)
        static let band = NSRect(x: 0, y: 20, width: size.width, height: 28)
        /// A session pane may keep the selected terminal palette behind a native conversation.
        /// Deliberately unlike every ordinary dark chrome ground, so a ring resolved from the
        /// app theme instead of the live window backdrop cannot pass by coincidence.
        static let terminalGround = NSColor(
            srgbRed: 5 / 255,
            green: 10 / 255,
            blue: 17 / 255,
            alpha: 1
        )
        /// The pane-wide live row from the reported dark screenshot.
        static let liveBand = NSColor(
            srgbRed: 35 / 255,
            green: 39 / 255,
            blue: 45 / 255,
            alpha: 1
        )
        static let colorTolerance: CGFloat = 0.025
        static let visibleBandDifference: CGFloat = 0.04
    }

    private final class BackdropView: NSView {
        let ground: NSColor
        let band: NSColor

        init(ground: NSColor, band: NSColor) {
            self.ground = ground
            self.band = band
            super.init(frame: NSRect(origin: .zero, size: Fixture.size))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func draw(_ dirtyRect: NSRect) {
            ground.setFill()
            dirtyRect.fill()
            band.setFill()
            Fixture.band.intersection(dirtyRect).fill()
        }
    }

    func testEveryStockThemeKeepsLiveContentOutsideTheTargetsSilhouette() throws {
        let previousTheme = AppThemePalette.current
        let previousBackdrop = WindowBackdrop.ground
        defer {
            AppThemePalette.set(previousTheme)
            WindowBackdrop.set(previousBackdrop)
        }

        var checkedVisibleBands = 0
        for theme in AppThemeLibrary.stock {
            for (suffix, appearance) in try appearances(of: theme) {
                AppThemePalette.set(theme)

                let ground = Fixture.terminalGround
                let band = Fixture.liveBand
                let plain = try render(
                    theme: theme,
                    appearance: appearance,
                    ground: ground,
                    band: ground
                )
                let crossed = try render(
                    theme: theme,
                    appearance: appearance,
                    ground: ground,
                    band: band
                )
                let name = "\(theme.name)\(suffix)"

                // The lower half sits over the band and the upper half does not. The target is
                // floating chrome, so changing what is behind it must change no interior pixel.
                for point in [
                    NSPoint(x: Fixture.target.midX - 8, y: Fixture.target.midY - 8),
                    NSPoint(x: Fixture.target.midX + 8, y: Fixture.target.midY - 8)
                ] {
                    XCTAssertLessThanOrEqual(
                        difference(try plain.color(at: point), try crossed.color(at: point)),
                        Fixture.colorTolerance,
                        "\(name): live content showed through the floating target at \(point)"
                    )
                }
                try writeEvidence(crossed.rep, theme: theme, suffix: suffix)

                // When the band is visibly distinct from the ground, one full point immediately
                // outside each side has to be ground again. That is the separation the reported
                // control lacked: its border met an equal-coloured row with no intervening pixel.
                guard difference(ground, band) > Fixture.visibleBandDifference else { continue }
                checkedVisibleBands += 1
                let farBand = try crossed.color(at: NSPoint(x: 4, y: Fixture.target.midY))
                let farGround = try plain.color(at: NSPoint(x: 4, y: Fixture.target.midY))
                for (side, x) in [
                    ("leading", Fixture.target.minX - 1),
                    ("trailing", Fixture.target.maxX + 1)
                ] {
                    let separation = try crossed.color(
                        at: NSPoint(x: x, y: Fixture.target.midY)
                    )
                    XCTAssertLessThanOrEqual(
                        difference(separation, farGround),
                        Fixture.colorTolerance,
                        "\(name): the \(side) isolation ring did not match the live window backdrop"
                    )
                    XCTAssertGreaterThan(
                        difference(separation, farBand),
                        Fixture.visibleBandDifference,
                        "\(name): the \(side) half of the row still joins the target's edge"
                    )
                }
            }
        }

        XCTAssertGreaterThan(
            checkedVisibleBands,
            0,
            "The stock sweep never exercised a band visible against its own theme ground"
        )
    }

    // MARK: - Rendering

    private struct Raster {
        let rep: NSBitmapImageRep

        func color(at point: NSPoint) throws -> NSColor {
            let scale = CGFloat(rep.pixelsWide) / Fixture.size.width
            let x = Int((point.x * scale).rounded(.down))
            let y = Int(((Fixture.size.height - point.y) * scale).rounded(.down))
            let sampled = try XCTUnwrap(rep.colorAt(
                x: min(max(x, 0), rep.pixelsWide - 1),
                y: min(max(y, 0), rep.pixelsHigh - 1)
            ))
            return try XCTUnwrap(sampled.usingColorSpace(.deviceRGB))
        }
    }

    private func render(
        theme: AppTheme,
        appearance: NSAppearance,
        ground: NSColor,
        band: NSColor
    ) throws -> Raster {
        let root = BackdropView(ground: ground, band: band)
        root.appearance = appearance

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = root
        defer {
            window.contentView = nil
            window.close()
        }

        // Construct the target against app chrome, then switch the live session backdrop after
        // layout. The production pane can change palettes without a theme repaint; retaining the
        // old ring colour would recreate the reported bridge until some unrelated relayout.
        WindowBackdrop.set(.chrome)
        let button = ThemedButton.floatingScrollToEnd(
            accessibility: "Scroll to end",
            target: nil,
            action: nil
        )
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = Fixture.target
        root.addSubview(button)

        AppThemeRefresh.repaint(root)
        root.layoutSubtreeIfNeeded()
        button.layoutSubtreeIfNeeded()
        WindowBackdrop.set(.terminal(ground))

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(Fixture.size.width) * Fixture.scale,
            pixelsHigh: Int(Fixture.size.height) * Fixture.scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = Fixture.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        root.displayIgnoringOpacity(root.bounds, in: context)
        return Raster(rep: rep)
    }

    private func appearances(of theme: AppTheme) throws -> [(String, NSAppearance)] {
        if theme.isAdaptive {
            return [
                ("-light", try XCTUnwrap(NSAppearance(named: .aqua))),
                ("-dark", try XCTUnwrap(NSAppearance(named: .darkAqua)))
            ]
        }
        return [("", try XCTUnwrap(theme.mode.appearance))]
    }

    private func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
        guard let a = a.usingColorSpace(.deviceRGB),
              let b = b.usingColorSpace(.deviceRGB) else { return 0 }
        return max(
            abs(a.redComponent - b.redComponent),
            abs(a.greenComponent - b.greenComponent),
            abs(a.blueComponent - b.blueComponent),
            abs(a.alphaComponent - b.alphaComponent)
        )
    }

    private func writeEvidence(_ rep: NSBitmapImageRep, theme: AppTheme, suffix: String) throws {
        guard let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
              !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(
            "floating-scroll-target-\(theme.id.rawValue)\(suffix).png"
        )
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
