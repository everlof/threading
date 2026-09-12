import AppKit
import XCTest
@testable import Threading

/// The material's backdrop: its wire form, the gates that refuse a wash the user could not read
/// their way out of, the resolution that turns a stated block into drawable values, and the
/// layer `applySurface` hangs under every participating ground.
@MainActor
final class ThemeBackdropTests: XCTestCase {

    private var previousTheme: AppTheme!

    override func setUp() async throws {
        try await super.setUp()
        previousTheme = AppThemeLibrary.current
    }

    override func tearDown() async throws {
        AppThemeLibrary.apply(previousTheme)
        ThemeAssetStore.removeAll(for: Self.scratchThemeID)
        try await super.tearDown()
    }

    private static let scratchThemeID = AppThemeID("custom-theme-backdrop-tests")

    // MARK: - Fixtures

    /// A custom theme derived from a stock one whose material states the given backdrop.
    @MainActor
    private func themed(
        _ backdrop: ThemeBackdrop?,
        pattern: AppTheme.Material.BackdropPattern? = nil,
        base: AppTheme = AppThemeStyles.cyberpunk
    ) throws -> AppTheme {
        let kind = base.availableVariants[0]
        var material = base.variant(kind)?.material ?? base.material
        material.backdrop = backdrop
        if let pattern { material.backdropPattern = pattern }
        return try AppThemeEditing.assemble(
            id: Self.scratchThemeID,
            name: "Backdrop Fixture",
            mode: kind == .dark ? .dark : .light,
            summary: nil,
            variants: [
                kind: AppThemeEditing.makeVariant(
                    named: "Backdrop Fixture", from: base, kind: kind, material: material
                )
            ]
        )
    }

    private func png(_ color: NSColor, side: CGFloat = 8) throws -> Data {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        return try XCTUnwrap(
            NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
                .representation(using: .png, properties: [:])
        )
    }

    // MARK: - Wire forms

    func testAMaterialBackdropRoundTripsThroughItsDocumentForm() throws {
        var material = AppTheme.Material()
        material.backdrop = ThemeBackdrop(
            gradient: .init(
                stops: [
                    .init(color: NSColor(hex: "#101020")!, position: 0),
                    .init(color: NSColor(hex: "#202040")!, position: 1)
                ],
                angleDegrees: 135
            ),
            image: .init(asset: "dark-backdrop.png", mode: .fit, opacity: 0.25)
        )

        let data = try JSONEncoder().encode(material)
        let decoded = try JSONDecoder().decode(AppTheme.Material.self, from: data)
        XCTAssertEqual(decoded.backdrop, material.backdrop)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let wire = try XCTUnwrap(json["backdrop"] as? [String: Any])
        let gradient = try XCTUnwrap(wire["gradient"] as? [String: Any])
        XCTAssertEqual(gradient["angleDegrees"] as? Double, 135)
        let stops = try XCTUnwrap(gradient["stops"] as? [[String: Any]])
        XCTAssertEqual(stops.first?["color"] as? String, "#101020")
        let image = try XCTUnwrap(wire["image"] as? [String: Any])
        XCTAssertEqual(image["mode"] as? String, "fit")
    }

    /// A document written before the field existed decodes to no backdrop, and every stock
    /// theme — none of which states one — keeps drawing byte-identically.
    func testAMaterialWithoutABackdropDecodesToNone() throws {
        let decoded = try JSONDecoder().decode(
            AppTheme.Material.self,
            from: Data(#"{"panelRadius": 10}"#.utf8)
        )
        XCTAssertNil(decoded.backdrop)
        for theme in AppThemeStyles.all {
            for kind in theme.availableVariants {
                XCTAssertNil(theme.variant(kind)?.material.backdrop, theme.name)
            }
        }
    }

    /// The sidebar's block is the same vocabulary under its own names; a sidebar document
    /// written against them decodes unchanged.
    func testTheSidebarBackgroundIsTheSharedBackdropVocabulary() throws {
        let style = SidebarStyle(
            background: SidebarStyle.Background(
                gradient: SidebarStyle.Gradient(stops: [
                    .init(color: NSColor(hex: "#000000")!, position: 0),
                    .init(color: NSColor(hex: "#FFFFFF")!, position: 1)
                ]),
                image: SidebarStyle.ImageLayer(asset: "dark-background.png")
            )
        )
        let decoded = try JSONDecoder().decode(
            SidebarStyle.self,
            from: try JSONEncoder().encode(style)
        )
        XCTAssertEqual(decoded.background, style.background)
        let shared: ThemeBackdrop? = decoded.background
        XCTAssertNotNil(shared)
    }

    /// `replacing` carries the backdrop by value: an edit that changed a colour cannot strip
    /// the wallpaper, which is the trap the sidebar and chrome blocks each pin for themselves.
    @MainActor
    func testAnEditThroughReplacingKeepsTheBackdrop() throws {
        let theme = try themed(ThemeBackdrop(image: .init(asset: "dark-backdrop.png")))
        let kind = theme.availableVariants[0]
        let variant = try XCTUnwrap(theme.variant(kind))
        let recoloured = variant.replacing(roles: [.accent: .systemPink])
        XCTAssertEqual(recoloured.material.backdrop, variant.material.backdrop)
    }

    // MARK: - Gates

    /// A wash the label cannot read against is refused, measured against the ground the panes
    /// actually sit on — the same floor the sidebar and the terminal palette are held to.
    @MainActor
    func testAGradientStopTheLabelCannotReadIsRefused() throws {
        let base = AppThemeStyles.cyberpunk
        let kind = base.availableVariants[0]
        let label = base.resolved(.label, appearance: kind.appearance ?? .currentDrawing())
        XCTAssertThrowsError(
            try themed(ThemeBackdrop(gradient: .init(stops: [
                .init(color: label, position: 0),
                .init(color: label, position: 1)
            ])))
        ) { error in
            XCTAssertTrue(
                "\(error.localizedDescription)".contains("backdrop gradient stop"),
                error.localizedDescription
            )
        }
    }

    @MainActor
    func testGradientAndImageBoundsAreEnforced() throws {
        let base = AppThemeStyles.cyberpunk
        let kind = base.availableVariants[0]
        let ground = base.resolved(.ground, appearance: kind.appearance ?? .currentDrawing())

        XCTAssertThrowsError(
            try themed(ThemeBackdrop(gradient: .init(stops: [.init(color: ground, position: 0)]))),
            "one stop is not a gradient"
        )
        XCTAssertThrowsError(
            try themed(ThemeBackdrop(gradient: .init(stops: [
                .init(color: ground, position: 0),
                .init(color: ground, position: 1.5)
            ]))),
            "a stop past the run's end"
        )
        XCTAssertThrowsError(
            try themed(ThemeBackdrop(image: .init(asset: "x.png", opacity: 1.2))),
            "opacity past one"
        )
        XCTAssertThrowsError(
            try themed(ThemeBackdrop(image: .init(asset: "   "))),
            "an image naming no asset"
        )
        XCTAssertNoThrow(
            try themed(ThemeBackdrop(gradient: .init(stops: [
                .init(color: ground, position: 1),
                .init(color: ground, position: 0)
            ]))),
            "the ground itself always passes, whatever order the stops arrive in"
        )
    }

    // MARK: - Assets

    func testTheBackdropSlotIsNamedPerVariantAndHasItsOwnCeilings() {
        XCTAssertEqual(ThemeAssetSlot.backdrop.fileName(for: .dark), "dark-backdrop.png")
        XCTAssertEqual(ThemeAssetSlot.backdrop.fileName(for: .light), "light-backdrop.png")
        XCTAssertEqual(
            ThemeAssetSlot.backdrop.maximumImageBytes,
            ThemeBackdropLimits.maximumImageBytes
        )
        XCTAssertGreaterThan(
            ThemeAssetSlot.backdrop.maximumImageBytes,
            ThemeAssetSlot.background.maximumImageBytes,
            "a pane is a bigger picture than a column"
        )
        XCTAssertGreaterThanOrEqual(
            ThemeAssetDefaults.maximumStoredBytes,
            ThemeBackdropLimits.maximumImageBytes,
            "the read side must accept what the write side stored"
        )
        XCTAssertEqual(ThemeAssetSlot.background.rawValue, SidebarAssetSlot.background.rawValue)
    }

    @MainActor
    func testAStoredBackdropResolvesAndADanglingNameDegrades() throws {
        let kind = AppThemeStyles.cyberpunk.availableVariants[0]
        let stored = try XCTUnwrap(ThemeAssetStore.store(
            imageData: try png(.systemOrange),
            for: Self.scratchThemeID,
            slot: .backdrop,
            variant: kind
        ))
        XCTAssertEqual(stored, "\(kind.rawValue)-backdrop.png")

        let ground = AppThemeStyles.cyberpunk.resolved(
            .ground, appearance: kind.appearance ?? .currentDrawing()
        )
        let theme = try themed(ThemeBackdrop(
            gradient: .init(stops: [
                .init(color: ground, position: 1),
                .init(color: ground, position: 0)
            ]),
            image: .init(asset: stored, mode: .tile, opacity: 0.5)
        ))
        AppThemeLibrary.apply(theme)

        let appearance = kind.appearance ?? .currentDrawing()
        let resolved = try XCTUnwrap(ThemeBackdropAppearance.material(for: appearance))
        XCTAssertEqual(resolved.gradient?.locations, [0, 1], "stops should arrive sorted")
        XCTAssertEqual(resolved.image?.opacity, 0.5)
        XCTAssertNotNil(resolved.image?.image)

        let dangling = try themed(ThemeBackdrop(image: .init(asset: "never-stored.png")))
        AppThemeLibrary.apply(dangling)
        XCTAssertNil(
            ThemeBackdropAppearance.material(for: appearance),
            "a name that resolves to nothing is the plain ground, not an error"
        )

        AppThemeLibrary.apply(AppThemeStyles.cyberpunk)
        XCTAssertNil(ThemeBackdropAppearance.material(for: appearance))
    }

    // MARK: - Rendering

    /// What a wallpapered pane looks like, light and dark: the ground, the wash, the picture,
    /// the dot field over it, and ordinary content — a heading, a card, a button — on top.
    /// This is how the feature is reviewed; the PNGs land in `THREADING_RENDER_OUT`.
    @MainActor
    func testRendersADressedPaneToImages() throws {
        let directory = Self.renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written = 0
        for (name, base, appearanceName) in [
            ("dark", AppThemeStyles.cyberpunk, NSAppearance.Name.darkAqua),
            ("light", AppThemeStyles.newsprint, .aqua)
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let kind = base.availableVariants[0]
            let ground = base.resolved(.ground, appearance: appearance)
            let panel = base.resolved(.panel, appearance: appearance)
            let accent = base.resolved(.accent, appearance: appearance)

            let stored = try XCTUnwrap(ThemeAssetStore.store(
                imageData: try wallpaperPNG(tint: accent, on: ground),
                for: Self.scratchThemeID,
                slot: .backdrop,
                variant: kind
            ))
            let theme = try themed(
                ThemeBackdrop(
                    gradient: .init(stops: [
                        .init(color: ground, position: 0),
                        .init(color: ground.composited(under: panel), position: 1)
                    ], angleDegrees: 160),
                    image: .init(asset: stored, mode: .fill, opacity: 0.35)
                ),
                pattern: AppTheme.Material.BackdropPattern(kind: .dots, spacing: 18),
                base: base
            )
            AppThemeLibrary.apply(theme)

            let pane = ThemedSurfaceView()
            pane.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)

            let heading = NSTextField(labelWithString: "Attachments")
            heading.font = Design.Typography.heading()
            heading.textColor = Design.Text.label
            let card = ThemedSurfaceView()
            card.applySurface(fill: Design.Surface.panel, radius: .panel, border: Design.Surface.border)
            let cardLabel = NSTextField(labelWithString: "A card keeps its own ground.")
            cardLabel.font = Design.Typography.body()
            cardLabel.textColor = Design.Text.label
            cardLabel.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(cardLabel)
            NSLayoutConstraint.activate([
                cardLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Design.Spacing.medium),
                cardLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -Design.Spacing.medium),
                cardLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: Design.Spacing.medium),
                cardLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Design.Spacing.medium)
            ])
            let button = ThemedButton(title: "Open in Finder", target: nil, action: nil)
            let column = NSStackView(views: [heading, card, button])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = Design.Spacing.medium
            column.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

            let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
            host.wantsLayer = true
            host.appearance = appearance
            host.addSubview(pane)
            host.addSubview(column)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: host.topAnchor),
                pane.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                pane.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                column.topAnchor.constraint(equalTo: host.topAnchor, constant: Design.Spacing.large),
                column.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Design.Spacing.large),
                column.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Design.Spacing.large)
            ])

            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                host.layoutSubtreeIfNeeded()
                AppThemeRefresh.repaint(pane)
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    data = rep.representation(using: .png, properties: [:])
                }
            }
            let url = directory.appendingPathComponent("theme-backdrop-pane-\(name).png")
            try XCTUnwrap(data, "Failed to render the dressed pane in \(name)").write(to: url)
            written += 1

            let dressing = try XCTUnwrap(
                pane.layer?.sublayers?.first { $0.name == ThemeBackdropDressingLayer.layerName }
                    as? ThemeBackdropDressingLayer
            )
            XCTAssertTrue(dressing.showsGradient)
            XCTAssertTrue(dressing.showsPicture, "\(name): the stored picture did not resolve")
        }
        XCTAssertEqual(written, 2)
    }

    /// A soft diagonal wash in the theme's accent, so the picture is visibly a picture and
    /// still something a row can be read on.
    private func wallpaperPNG(tint: NSColor, on ground: NSColor) throws -> Data {
        let size = NSSize(width: 480, height: 300)
        let image = NSImage(size: size, flipped: false) { rect in
            ground.setFill()
            rect.fill()
            for index in 0..<7 {
                let path = NSBezierPath()
                let offset = CGFloat(index) * 90 - 120
                path.move(to: NSPoint(x: offset, y: 0))
                path.line(to: NSPoint(x: offset + 60, y: 0))
                path.line(to: NSPoint(x: offset + 260, y: rect.height))
                path.line(to: NSPoint(x: offset + 200, y: rect.height))
                path.close()
                tint.withAlphaComponent(index.isMultiple(of: 2) ? 0.9 : 0.45).setFill()
                path.fill()
            }
            return true
        }
        return try XCTUnwrap(
            NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
                .representation(using: .png, properties: [:])
        )
    }

    private static var renderDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
    }

    // MARK: - Drawing

    /// The dressing rides `applySurface`'s backdrop participation exactly as the pattern does:
    /// installed under a theme that states one, stripped when the theme leaves, and never on a
    /// surface that did not opt in.
    @MainActor
    func testParticipatingSurfacesWearTheDressingAndShedItWithTheTheme() throws {
        let kind = AppThemeStyles.cyberpunk.availableVariants[0]
        let ground = AppThemeStyles.cyberpunk.resolved(
            .ground, appearance: kind.appearance ?? .currentDrawing()
        )
        let dressed = try themed(
            ThemeBackdrop(gradient: .init(stops: [
                .init(color: ground, position: 0),
                .init(color: ground, position: 1)
            ])),
            pattern: AppTheme.Material.BackdropPattern(kind: .dots)
        )
        AppThemeLibrary.apply(dressed)

        let pane = ThemedSurfaceView()
        pane.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)
        let sublayers = try XCTUnwrap(pane.layer?.sublayers)
        let dressing = try XCTUnwrap(
            sublayers.firstIndex { $0.name == ThemeBackdropDressingLayer.layerName },
            "a participating ground wears the theme's backdrop"
        )
        let pattern = try XCTUnwrap(
            sublayers.firstIndex { $0.name == "threading.backdropPattern" }
        )
        XCTAssertLessThan(dressing, pattern, "the pattern reads over the wash, not under it")
        let layer = try XCTUnwrap(sublayers[dressing] as? ThemeBackdropDressingLayer)
        XCTAssertTrue(layer.showsGradient)
        XCTAssertFalse(layer.showsPicture)

        let card = ThemedSurfaceView()
        card.applySurface(fill: Design.Surface.panel, radius: .panel)
        XCTAssertNil(
            card.layer?.sublayers?.first { $0.name == ThemeBackdropDressingLayer.layerName },
            "a card never inherits the backdrop"
        )

        AppThemeLibrary.apply(AppThemeStyles.cyberpunk)
        AppThemeRefresh.repaint(pane)
        XCTAssertNil(
            pane.layer?.sublayers?.first { $0.name == ThemeBackdropDressingLayer.layerName },
            "leaving the theme strips the wallpaper from every ground it dressed"
        )
    }
}
