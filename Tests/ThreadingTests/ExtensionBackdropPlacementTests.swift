import AppKit
import Metal
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// `display.backdrop@1` and `composer.backdrop@1` as the host composes them: the sidebar's
/// backdrop contract at two more placements. Each plane sits directly above its surface's own
/// ground and beneath its content, takes no click, is composited at the legibility ceiling,
/// follows a republish, and builds its live surfaces at the contract's cadence.
@MainActor
final class ExtensionBackdropPlacementTests: HostedStoreTestCase {

    // MARK: - Fixtures

    private static let source = ComponentCustomizationSource(
        extensionIdentifier: "com.example.paper",
        processGeneration: "one",
        order: 0
    )

    private static let placements: [ExtensionBackdropPlaneView.Placement] = [
        .displayPanel,
        .composer
    ]

    private func registry(
        for placement: ExtensionBackdropPlaneView.Placement,
        publishing hook: ExtensionNode?
    ) throws -> ComponentCustomizationRegistry {
        let registry = ComponentCustomizationRegistry()
        try registry.register(placement.contract)
        if let hook {
            try registry.replacePatches(
                [.init(id: "paper", target: placement.target, hook: hook)],
                from: Self.source
            )
        }
        return registry
    }

    private static func picture(_ reference: ExtensionImageReference) -> ExtensionNode {
        .image(reference, role: .backdrop, accessibilityLabel: nil)
    }

    private static let underTheContent = ExtensionNode.overlay(
        base: picture(.extensionResource("Resources/paper.png")),
        overlay: .proceed
    )

    private let swatch = NSImage(size: NSSize(width: 64, height: 32), flipped: false) { rect in
        NSColor.systemTeal.setFill()
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

    // MARK: - The placements

    /// Each placement names its own contract and identifier, and states the sidebar's ceiling.
    func testEachPlacementIsTheSidebarContractAtItsOwnTarget() {
        XCTAssertEqual(ExtensionBackdropPlaneView.Placement.sidebar.target, .sidebarBackdrop())
        XCTAssertEqual(
            ExtensionBackdropPlaneView.Placement.displayPanel.target,
            .displayBackdrop()
        )
        XCTAssertEqual(ExtensionBackdropPlaneView.Placement.composer.target, .composerBackdrop())
        XCTAssertEqual(
            Set(
                ([ExtensionBackdropPlaneView.Placement.sidebar] + Self.placements)
                    .map(\.accessibilityIdentifier)
            ).count,
            3
        )
        XCTAssertEqual(
            ExtensionBackdropPlaneView.Placement.displayPanel.accessibilityIdentifier,
            "display.extension-backdrop"
        )
        XCTAssertEqual(
            ExtensionBackdropPlaneView.Placement.composer.accessibilityIdentifier,
            "composer.extension-backdrop"
        )
        for placement in Self.placements {
            XCTAssertEqual(
                placement.maximumFramesPerSecond,
                ExtensionBackdropPlaneView.Placement.sidebar.maximumFramesPerSecond
            )
            XCTAssertLessThan(
                placement.maximumFramesPerSecond,
                ExtensionMetalSurface.maximumFramesPerSecond
            )
        }
    }

    /// The window hook's shape — content over proceed — is refused at every placement before
    /// any view exists.
    func testTheRegistryRefusesContentOverTheHostsContent() throws {
        for placement in Self.placements {
            let registry = try registry(for: placement, publishing: nil)
            XCTAssertThrowsError(
                try registry.replacePatches(
                    [.init(
                        id: "over",
                        target: placement.target,
                        hook: .overlay(
                            base: .proceed,
                            overlay: Self.picture(.systemSymbol("cloud.fill"))
                        )
                    )],
                    from: Self.source
                ),
                placement.accessibilityIdentifier
            )
            XCTAssertNoThrow(
                try registry.replacePatches(
                    [.init(id: "under", target: placement.target, hook: Self.underTheContent)],
                    from: Self.source
                ),
                placement.accessibilityIdentifier
            )
            XCTAssertEqual(registry.customization(for: placement.target).hooks.count, 1)
        }
    }

    // MARK: - The plane

    func testAPublishedPictureDressesThePlanePassivelyBelowTheCeiling() throws {
        for placement in Self.placements {
            let registry = try registry(for: placement, publishing: Self.underTheContent)
            let plane = ExtensionBackdropPlaneView(
                placement: placement,
                lookup: registry.customization(for:),
                imageResolver: { [swatch] _, _ in swatch }
            )
            let name = placement.accessibilityIdentifier

            XCTAssertTrue(plane.isDressed, name)
            XCTAssertEqual(plane.alphaValue, ExtensionBackdropLimits.maximumOpacity, name)
            XCTAssertFalse(plane.isAccessibilityElement(), name)
            XCTAssertEqual(plane.accessibilityIdentifier(), name)
            XCTAssertNil(plane.hitTest(NSPoint(x: 10, y: 10)), name)

            let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
            host.addSubview(plane)
            plane.pinToEdges(of: host)
            host.layoutSubtreeIfNeeded()
            let picture = try XCTUnwrap(
                firstDescendant(of: ExtensionBackdropImageView.self, in: plane),
                name
            )
            XCTAssertTrue(picture.showsPicture, name)
            XCTAssertEqual(picture.frame.size, plane.bounds.size, name)
            XCTAssertNil(picture.hitTest(.zero), name)
            XCTAssertTrue(
                host.hitTest(NSPoint(x: 160, y: 240)) === host,
                "\(name): the click falls through the plane to what holds it"
            )
        }
    }

    /// A republish that takes the hook away leaves the plane empty, and an image the package
    /// cannot supply skips the hook atomically.
    func testRepublishAndUnresolvableImagesLeaveThePlaneUndressed() throws {
        for placement in Self.placements {
            let registry = try registry(for: placement, publishing: Self.underTheContent)
            let plane = ExtensionBackdropPlaneView(
                placement: placement,
                lookup: registry.customization(for:),
                imageResolver: { [swatch] _, _ in swatch }
            )
            XCTAssertTrue(plane.isDressed)
            try registry.replacePatches([], from: Self.source)
            XCTAssertFalse(plane.isDressed, "the registry's change event reaches the plane")

            let missing = ExtensionBackdropPlaneView(
                placement: placement,
                lookup: try self.registry(for: placement, publishing: Self.underTheContent)
                    .customization(for:),
                imageResolver: { _, _ in nil }
            )
            XCTAssertFalse(missing.isDressed, placement.accessibilityIdentifier)
        }
    }

    /// A patch for one placement does not dress another: the three planes answer to three
    /// targets.
    func testAPatchDressesOnlyItsOwnPlacement() throws {
        let registry = ComponentCustomizationRegistry()
        for contract in ThreadingComponentCatalog.backdropPlacements {
            try registry.register(contract)
        }
        try registry.replacePatches(
            [.init(id: "paper", target: .displayBackdrop(), hook: Self.underTheContent)],
            from: Self.source
        )
        func plane(_ placement: ExtensionBackdropPlaneView.Placement) -> ExtensionBackdropPlaneView {
            ExtensionBackdropPlaneView(
                placement: placement,
                lookup: registry.customization(for:),
                imageResolver: { [swatch] _, _ in swatch }
            )
        }
        XCTAssertTrue(plane(.displayPanel).isDressed)
        XCTAssertFalse(plane(.composer).isDressed)
        XCTAssertFalse(plane(.sidebar).isDressed)
    }

    // MARK: - Where the planes sit

    /// Above the panel's themed ground, below its tab row and content — checked in the real
    /// display pane rather than a plain host.
    func testTheDisplayPaneStacksThePlaneBetweenItsGroundAndItsContent() throws {
        let registry = try registry(for: .displayPanel, publishing: Self.underTheContent)
        let pane = DisplayPaneController(
            customizationLookup: registry.customization(for:),
            extensionBackdropImageResolver: { [swatch] _, _ in swatch }
        )
        let root = pane.view
        let plane = try XCTUnwrap(pane.extensionBackdrop)
        XCTAssertTrue(plane.isDressed)
        XCTAssertEqual(plane.placement, .displayPanel)

        let subviews = root.subviews
        let ground = try XCTUnwrap(subviews.firstIndex { $0 is ThemedSurfaceView })
        let extensionPlane = try XCTUnwrap(subviews.firstIndex { $0 === plane })
        let header = try XCTUnwrap(subviews.firstIndex { $0 is PaneHeaderView })
        XCTAssertEqual(ground, 0, "the theme's ground is the pane's first subview")
        XCTAssertEqual(extensionPlane, ground + 1, "the plane sits directly on the ground")
        XCTAssertLessThan(extensionPlane, header, "the tab row stays above")
        XCTAssertEqual(subviews.filter { $0 is ExtensionBackdropPlaneView }.count, 1)

        root.frame = NSRect(x: 0, y: 0, width: 360, height: 520)
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(plane.frame, root.bounds, "the plane covers the whole pane")
        XCTAssertFalse(
            root.hitTest(NSPoint(x: 180, y: 260)) === plane,
            "the pane's own content owns the click"
        )
    }

    /// The composer's root holds the plane first, beneath the greeting, chips and prompt.
    func testTheComposerHoldsThePlaneBeneathEverythingItDraws() throws {
        let registry = try registry(for: .composer, publishing: Self.underTheContent)
        let composer = SessionComposerViewController(
            customizationLookup: registry.customization(for:),
            extensionBackdropImageResolver: { [swatch] _, _ in swatch }
        )
        let root = composer.view
        let plane = try XCTUnwrap(composer.extensionBackdrop)
        XCTAssertTrue(plane.isDressed)
        XCTAssertEqual(plane.placement, .composer)
        XCTAssertTrue(root.subviews.first === plane, "the plane is the composer's first subview")
        XCTAssertEqual(root.subviews.filter { $0 is ExtensionBackdropPlaneView }.count, 1)

        root.frame = NSRect(x: 0, y: 0, width: 720, height: 560)
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(plane.frame, root.bounds, "the plane covers the whole composer")
        let promptPoint = composer.promptHandoffView.convert(
            NSPoint(
                x: composer.promptHandoffView.bounds.midX,
                y: composer.promptHandoffView.bounds.midY
            ),
            to: root
        )
        let hit = root.hitTest(promptPoint)
        XCTAssertNotNil(hit)
        XCTAssertFalse(hit === plane)
        XCTAssertTrue(
            hit?.isDescendant(of: composer.promptHandoffView) ?? false,
            "the prompt box keeps its clicks"
        )
    }

    // MARK: - Rendering

    /// What a dressed display pane and a dressed composer look like, light and dark: the
    /// pane's own ground beneath, the extension's picture at the host's ceiling, the pane's tab
    /// row and the composer's chips and prompt above. The PNGs land in `THREADING_RENDER_OUT`.
    func testRendersTheDressedDisplayPaneAndComposerToImages() throws {
        let directory = Self.renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousTheme = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previousTheme) }

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

            let displayRegistry = try registry(for: .displayPanel, publishing: Self.underTheContent)
            let pane = DisplayPaneController(
                customizationLookup: displayRegistry.customization(for:),
                extensionBackdropImageResolver: { _, _ in picture }
            )
            let paneView = pane.view
            XCTAssertTrue(pane.extensionBackdrop?.isDressed ?? false, name)
            try Self.render(
                paneView,
                size: NSSize(width: 360, height: 480),
                appearance: appearance,
                to: directory.appendingPathComponent("display-extension-backdrop-\(name).png")
            )
            written += 1

            let composerRegistry = try registry(for: .composer, publishing: Self.underTheContent)
            let composer = SessionComposerViewController(
                customizationLookup: composerRegistry.customization(for:),
                extensionBackdropImageResolver: { _, _ in picture }
            )
            let composerView = composer.view
            XCTAssertTrue(composer.extensionBackdrop?.isDressed ?? false, name)
            try Self.render(
                composerView,
                size: NSSize(width: 720, height: 520),
                appearance: appearance,
                to: directory.appendingPathComponent("composer-extension-backdrop-\(name).png")
            )
            written += 1
        }
        XCTAssertEqual(written, 4)
    }

    private static func render(
        _ root: NSView,
        size: NSSize,
        appearance: NSAppearance,
        to url: URL
    ) throws {
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.appearance = appearance
        root.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: host.topAnchor),
            root.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }
        }
        try XCTUnwrap(data, "Failed to render \(url.lastPathComponent)").write(to: url)
    }

    private static func wallpaper(tint: NSColor, on ground: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 360, height: 480), flipped: false) { rect in
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

    // MARK: - Cadence and the hold

    private func auroraSource() throws -> String {
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

    /// Each placement's ceiling wins over the patch's ask, and a surface nobody can see holds
    /// its frames — through the plane, in a window that is built but never shown.
    func testALiveSurfaceIsClampedToThePlacementAndHeldWhileUnseen() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        let source = try auroraSource()
        for placement in Self.placements {
            let registry = try registry(
                for: placement,
                publishing: .overlay(
                    base: .customSurface(
                        .metal(ExtensionMetalSurface(
                            shaderResource: "Resources/aurora.metal",
                            preferredFramesPerSecond: placement.maximumFramesPerSecond,
                            inputs: [
                                .init(name: "energy", value: .constant(0.6)),
                                .init(name: "opacity", value: .constant(0.5))
                            ]
                        )),
                        accessibilityLabel: nil
                    ),
                    overlay: .proceed
                )
            )
            var built: ExtensionMetalSurfaceView?
            let plane = ExtensionBackdropPlaneView(
                placement: placement,
                lookup: registry.customization(for:),
                customSurfaceResolver: { surface, _ in
                    guard case .metal(let specification) = surface else { return nil }
                    // What the default resolver does, minus the package read: the
                    // placement's ceiling, never the patch's own number.
                    let view = try? ExtensionMetalSurfaceView(
                        specification: ExtensionMetalSurface(
                            shaderResource: specification.shaderResource,
                            preferredFramesPerSecond: ExtensionMetalSurface.maximumFramesPerSecond,
                            inputs: specification.inputs
                        ),
                        source: source,
                        maximumFramesPerSecond: placement.maximumFramesPerSecond,
                        signalProvider: { _, _ in nil }
                    )
                    built = view
                    return view
                }
            )
            XCTAssertTrue(plane.isDressed, placement.accessibilityIdentifier)
            let surface = try XCTUnwrap(built, placement.accessibilityIdentifier)
            try await surface.waitForPreparation()
            XCTAssertEqual(surface.preferredFramesPerSecond, placement.maximumFramesPerSecond)
            XCTAssertNil(surface.hitTest(.zero))

            surface.updateVisibilityHold()
            XCTAssertTrue(surface.isHeldForVisibility, "no window means nobody can see it")
            XCTAssertTrue(surface.isPaused)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                styleMask: [.borderless],
                backing: .buffered,
                defer: true
            )
            window.contentView?.addSubview(plane)
            surface.updateVisibilityHold()
            XCTAssertTrue(surface.isHeldForVisibility, "a window never ordered in is not seen")
            XCTAssertTrue(surface.isPaused)
            plane.removeFromSuperview()

            XCTAssertNotNil(surface.snapshotImage(size: NSSize(width: 64, height: 64), time: 1))
        }
    }
}
