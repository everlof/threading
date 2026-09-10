import AppKit
import Metal
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// `sidebar.backdrop@1` as the host composes it: the plane sits between the theme's ground and
/// the sidebar's content, takes no click, is composited below the legibility ceiling, follows a
/// republish, and builds its live surfaces at the contract's cadence.
@MainActor
final class SidebarExtensionBackdropTests: HostedStoreTestCase {

    // MARK: - Fixtures

    private static let source = ComponentCustomizationSource(
        extensionIdentifier: "com.example.aurora",
        processGeneration: "one",
        order: 0
    )

    private func registry(publishing hook: ExtensionNode?) throws -> ComponentCustomizationRegistry {
        let registry = ComponentCustomizationRegistry()
        try registry.register(HostComponentContracts.sidebarBackdrop)
        if let hook {
            try registry.replacePatches(
                [.init(id: "dunes", target: .sidebarBackdrop(), hook: hook)],
                from: Self.source
            )
        }
        return registry
    }

    private static func picture(_ reference: ExtensionImageReference) -> ExtensionNode {
        .image(reference, role: .backdrop, accessibilityLabel: nil)
    }

    private let swatch = NSImage(size: NSSize(width: 64, height: 32), flipped: false) { rect in
        NSColor.systemIndigo.setFill()
        rect.fill()
        return true
    }

    private func firstDescendant<View: NSView>(of type: View.Type, in root: NSView) -> View? {
        for child in root.subviews {
            if let match = child as? View { return match }
            if let match = firstDescendant(of: type, in: child) { return match }
        }
        return nil
    }

    // MARK: - The registry holds the contract's shape

    /// The window hook's shape — surface over proceed — is exactly what a backdrop may never
    /// be, and the registry refuses it before any view exists.
    func testTheRegistryRefusesContentOverTheRows() throws {
        let registry = ComponentCustomizationRegistry()
        try registry.register(HostComponentContracts.sidebarBackdrop)
        XCTAssertThrowsError(
            try registry.replacePatches(
                [.init(
                    id: "over",
                    target: .sidebarBackdrop(),
                    hook: .overlay(
                        base: .proceed,
                        overlay: Self.picture(.systemSymbol("cloud.fill"))
                    )
                )],
                from: Self.source
            )
        )
        XCTAssertNoThrow(
            try registry.replacePatches(
                [.init(
                    id: "under",
                    target: .sidebarBackdrop(),
                    hook: .overlay(
                        base: Self.picture(.systemSymbol("cloud.fill")),
                        overlay: .proceed
                    )
                )],
                from: Self.source
            )
        )
        XCTAssertEqual(registry.customization(for: .sidebarBackdrop()).hooks.count, 1)
    }

    // MARK: - The plane

    func testAPublishedPictureDressesThePlaneAndFillsIt() throws {
        let registry = try registry(publishing: .overlay(
            base: Self.picture(.extensionResource("Resources/dunes.png")),
            overlay: .proceed
        ))
        let plane = SidebarExtensionBackdropView(
            lookup: registry.customization(for:),
            imageResolver: { [swatch] _, _ in swatch }
        )

        XCTAssertTrue(plane.isDressed)
        XCTAssertEqual(plane.alphaValue, ExtensionBackdropLimits.maximumOpacity)
        XCTAssertFalse(plane.isAccessibilityElement())
        XCTAssertNil(plane.hitTest(NSPoint(x: 10, y: 10)))

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        host.addSubview(plane)
        NSLayoutConstraint.activate([
            plane.topAnchor.constraint(equalTo: host.topAnchor),
            plane.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            plane.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            plane.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()

        let picture = try XCTUnwrap(
            firstDescendant(of: ExtensionBackdropImageView.self, in: plane),
            "the backdrop role renders as a fill, not an icon slot"
        )
        XCTAssertTrue(picture.showsPicture)
        XCTAssertEqual(picture.frame.size, plane.bounds.size, "a fill covers the whole column")
        XCTAssertEqual(picture.intrinsicContentSize.width, NSView.noIntrinsicMetric)
        XCTAssertNil(picture.hitTest(.zero))
    }

    /// A republish that takes the hook away leaves the plane empty — the theme's own dressing
    /// beneath it is what was there all along.
    func testARepublishWithoutTheHookUndressesThePlane() throws {
        let registry = try registry(publishing: .overlay(
            base: Self.picture(.systemSymbol("cloud.fill")),
            overlay: .proceed
        ))
        let plane = SidebarExtensionBackdropView(
            lookup: registry.customization(for:),
            imageResolver: { [swatch] _, _ in swatch }
        )
        XCTAssertTrue(plane.isDressed)

        try registry.replacePatches([], from: Self.source)
        XCTAssertFalse(plane.isDressed, "the registry's change event reaches the plane")
    }

    /// An image the package cannot supply skips the hook atomically rather than drawing a hole
    /// where a wallpaper should be.
    func testAnUnresolvableImageLeavesThePlaneUndressed() throws {
        let registry = try registry(publishing: .overlay(
            base: Self.picture(.extensionResource("Resources/missing.png")),
            overlay: .proceed
        ))
        let plane = SidebarExtensionBackdropView(
            lookup: registry.customization(for:),
            imageResolver: { _, _ in nil }
        )
        XCTAssertFalse(plane.isDressed)
    }

    // MARK: - Where the plane sits

    /// Above the theme's ground, below the list: the depth the contract promises, checked in
    /// the real sidebar rather than a plain host.
    func testTheSidebarStacksThePlaneBetweenItsGroundAndItsList() throws {
        let registry = try registry(publishing: .overlay(
            base: Self.picture(.systemSymbol("cloud.fill")),
            overlay: .proceed
        ))
        let sidebar = ProjectSidebarViewController(
            defersInitialTreeMount: true,
            extensionBackdropLookup: registry.customization(for:)
        )
        let root = sidebar.view
        let plane = try XCTUnwrap(sidebar.extensionBackdrop)
        XCTAssertTrue(plane.isDressed)

        let subviews = root.subviews
        let ground = try XCTUnwrap(subviews.firstIndex { $0 is SidebarBackdropView })
        let extensionPlane = try XCTUnwrap(subviews.firstIndex { $0 === plane })
        let list = try XCTUnwrap(subviews.firstIndex { $0 is NSScrollView })
        XCTAssertLessThan(ground, extensionPlane, "the theme's ground stays beneath")
        XCTAssertLessThan(extensionPlane, list, "the rows stay above")
    }

    // MARK: - Rendering

    /// What a dressed sidebar looks like, light and dark, in the real sidebar: the theme's own
    /// ground beneath, the extension's picture at the host's ceiling, the brand row, the empty
    /// list's prompt and the footer above. The PNGs land in `THREADING_RENDER_OUT`.
    func testRendersTheDressedSidebarToImages() throws {
        let directory = Self.renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousTheme = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previousTheme) }

        let registry = try registry(publishing: .overlay(
            base: Self.picture(.extensionResource("Resources/dunes.png")),
            overlay: .proceed
        ))

        var written = 0
        for (name, theme, appearanceName) in [
            ("dark", AppThemeStyles.cyberpunk, NSAppearance.Name.darkAqua),
            ("light", AppThemeStyles.newsprint, .aqua)
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            AppThemeLibrary.apply(theme)
            let picture = Self.wallpaper(
                tint: theme.resolved(.accent, appearance: appearance),
                on: theme.resolved(.surface, appearance: appearance)
            )
            let sidebar = ProjectSidebarViewController(
                defersInitialTreeMount: true,
                extensionBackdropLookup: registry.customization(for:),
                extensionBackdropImageResolver: { _, _ in picture }
            )
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 560))
            host.wantsLayer = true
            host.appearance = appearance
            let root = sidebar.view
            root.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(root)
            NSLayoutConstraint.activate([
                root.topAnchor.constraint(equalTo: host.topAnchor),
                root.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                root.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: host.trailingAnchor)
            ])
            XCTAssertTrue(sidebar.extensionBackdrop?.isDressed ?? false, name)

            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    data = rep.representation(using: .png, properties: [:])
                }
            }
            let url = directory.appendingPathComponent("sidebar-extension-backdrop-\(name).png")
            try XCTUnwrap(data, "Failed to render the dressed sidebar in \(name)").write(to: url)
            written += 1
        }
        XCTAssertEqual(written, 2)
    }

    private static func wallpaper(tint: NSColor, on ground: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 260, height: 560), flipped: false) { rect in
            ground.setFill()
            rect.fill()
            for index in 0..<6 {
                let radius = 40 + CGFloat(index) * 34
                let circle = NSBezierPath(ovalIn: NSRect(
                    x: rect.width - radius * 1.1,
                    y: rect.height * 0.55 - radius * 0.9,
                    width: radius * 2,
                    height: radius * 2
                ))
                tint.withAlphaComponent(0.55 - CGFloat(index) * 0.08).setFill()
                circle.fill()
            }
            return true
        }
    }

    private static var renderDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
    }

    // MARK: - Cadence

    private func rainSource() throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repository.appendingPathComponent(
                "Packages/ThreadingExtensionKit/Examples/SidebarAuroraExtension/Resources/aurora.metal"
            ),
            encoding: .utf8
        )
    }

    /// The contract's ceiling wins over the patch's ask, and a surface nobody can see holds
    /// its frames.
    func testALiveSurfaceIsClampedToTheContractAndHeldWhileUnseen() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        let cap = try XCTUnwrap(
            HostComponentContracts.sidebarBackdrop.hookConstraints?
                .maximumCustomSurfaceFramesPerSecond
        )
        let surface = try ExtensionMetalSurfaceView(
            specification: ExtensionMetalSurface(
                shaderResource: "Resources/aurora.metal",
                preferredFramesPerSecond: ExtensionMetalSurface.maximumFramesPerSecond,
                inputs: [
                    .init(name: "energy", value: .constant(0.6)),
                    .init(name: "opacity", value: .constant(0.5)),
                    .init(name: "hour", value: .constant(0.25))
                ]
            ),
            source: try rainSource(),
            maximumFramesPerSecond: cap,
            signalProvider: { _ in nil }
        )
        XCTAssertEqual(surface.preferredFramesPerSecond, cap)
        XCTAssertLessThan(cap, ExtensionMetalSurface.maximumFramesPerSecond)

        surface.updateVisibilityHold()
        XCTAssertTrue(surface.isHeldForVisibility, "no window means nobody can see it")
        XCTAssertTrue(surface.isPaused)

        // The aurora draws at the example's own inputs; a compiled pipeline is the proof.
        XCTAssertNotNil(surface.snapshotImage(size: NSSize(width: 64, height: 128), time: 2))
    }
}
