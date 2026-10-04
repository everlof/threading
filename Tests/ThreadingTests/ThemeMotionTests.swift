import AppKit
import ThreadingRemoteKit
import XCTest
@testable import Threading

/// A theme that moves: its particles, its logo's gestures, its header band and the transition it
/// arrives with — the model and its wire forms, the gates, the budgets that keep a document from
/// asking for an unbounded emitter, the hold that stills it, the presenter that plays an arrival,
/// the tool loop, and the preview an agent looks at.
@MainActor
final class ThemeMotionTests: XCTestCase {

    private struct Snapshot {
        let theme: AppTheme
        let settings: DesignSettingsReading
        let windows: () -> [NSWindow]
    }

    /// XCTest's synchronous overrides are nonisolated. Keep their non-Sendable AppKit state on
    /// the main actor and pass only a Sendable test identity into the setup/teardown closures.
    private static var snapshots: [ObjectIdentifier: Snapshot] = [:]

    override func setUp() {
        super.setUp()
        let testID = ObjectIdentifier(self)
        MainActor.assumeIsolated {
            Self.snapshots[testID] = Snapshot(
                theme: AppThemeLibrary.current,
                settings: DesignSettings.current,
                windows: ThemeTransitionPresenter.shared.windowsProvider
            )
            DesignSettings.current = StubDesignSettings()
            Design.Motion.reduceMotionOverrideForTesting = false
            ThemeParticleHold.seenOverrideForTesting = true
        }
    }

    override func tearDown() {
        let testID = ObjectIdentifier(self)
        MainActor.assumeIsolated {
            guard let snapshot = Self.snapshots.removeValue(forKey: testID) else {
                preconditionFailure("theme motion fixture was not installed")
            }
            ThemeTransitionPresenter.shared.windowsProvider = snapshot.windows
            ThemeParticleHold.seenOverrideForTesting = nil
            Design.Motion.reduceMotionOverrideForTesting = nil
            DesignSettings.current = snapshot.settings
            AppThemeLibrary.apply(snapshot.theme)
            ThemeAssetStore.removeAll(for: Self.scratchThemeID)
        }
        super.tearDown()
    }

    private static let scratchThemeID = AppThemeID("custom-theme-motion-tests")

    private let red = NSColor(hex: "#E4000F")!
    private let white = NSColor(hex: "#FFFFFF")!

    // MARK: - Fixtures

    private func fizz(_ colors: [ThemeInk] = [.role(.accent), .color(NSColor(hex: "#FFFFFF")!)]) -> ThemeParticles {
        ThemeParticles(style: .fizz, colors: colors, density: 0.6)
    }

    /// A Christmas-based adaptive theme dressed with everything this suite exercises.
    private func dressedTheme(
        id: AppThemeID = scratchThemeID,
        band: SidebarStyle.Brand.Band? = nil,
        titleColor: NSColor? = nil,
        motion: SidebarStyle.Brand.LogoMotion? = nil,
        logo: SidebarStyle.Brand.Logo = .asset("dark-logo.png"),
        transition: ThemeTransition? = nil,
        ambient: ThemeParticles? = nil
    ) throws -> AppTheme {
        let base = AppThemeStyles.christmas
        var variants: [AppTheme.VariantKind: AppTheme.Variant] = [:]
        for kind in AppTheme.VariantKind.allCases {
            let brand = SidebarStyle.Brand(
                logo: logo,
                title: titleColor.map { SidebarStyle.Brand.Title(text: "Fizz", color: $0) },
                band: band,
                motion: motion
            )
            let sidebar = SidebarStyle(
                background: ambient.map { ThemeBackdrop(particles: $0) },
                brand: brand.isEmpty ? nil : brand
            )
            variants[kind] = AppThemeEditing.makeVariant(
                named: "Motion Fixture",
                from: base,
                kind: kind,
                sidebar: sidebar.isEmpty ? .inherit : .set(sidebar),
                transition: transition.map { .set($0) } ?? .inherit
            )
        }
        return try AppThemeEditing.assemble(
            id: id,
            name: "Motion Fixture",
            mode: .system,
            summary: nil,
            variants: variants
        )
    }

    private func redBand(ink: NSColor? = nil) -> SidebarStyle.Brand.Band {
        SidebarStyle.Brand.Band(
            gradient: SidebarStyle.Gradient(stops: [
                .init(color: red, position: 0),
                .init(color: NSColor(hex: "#B8000C")!, position: 1)
            ]),
            ink: ink
        )
    }

    // MARK: - Wire forms

    func testThemeInkSpellsRolesAndColoursApartOnTheWire() throws {
        XCTAssertEqual(ThemeInk(wireValue: "accent"), .role(.accent))
        XCTAssertEqual(ThemeInk(wireValue: "#FFFFFF")?.wireValue, "#FFFFFF")
        XCTAssertNil(ThemeInk(wireValue: "fuchsia-ish"))

        let encoded = try JSONEncoder().encode([ThemeInk.role(.statusWarning), .color(red)])
        let decoded = try JSONDecoder().decode([ThemeInk].self, from: encoded)
        XCTAssertEqual(decoded.first, .role(.statusWarning))
        XCTAssertEqual(decoded.last?.wireValue, red.hexString)
    }

    func testEveryNewBlockRoundTripsAndOlderDocumentsDecodeWithoutThem() throws {
        let transition = ThemeTransition(particles: fizz(), duration: 1.4, wash: .role(.ground), shimmer: true)
        let theme = try dressedTheme(
            band: redBand(ink: white),
            titleColor: white,
            motion: .init(hover: .tilt, press: .pop, launch: .bounce, particles: fizz(), working: true),
            transition: transition,
            ambient: fizz()
        )
        let data = try JSONEncoder().encode(theme)
        let decoded = try JSONDecoder().decode(AppTheme.self, from: data)
        XCTAssertEqual(decoded, theme)

        let variant = try XCTUnwrap(decoded.variant(.dark))
        XCTAssertEqual(variant.transition?.shimmer, true)
        XCTAssertEqual(variant.sidebar?.brand?.motion?.press, .pop)
        XCTAssertEqual(variant.sidebar?.brand?.band?.ink?.hexString, "#FFFFFF")
        XCTAssertEqual(variant.sidebar?.background?.particles?.style, .fizz)

        // A document written before any of it existed has none of it.
        let stock = try JSONDecoder().decode(
            AppTheme.self,
            from: try JSONEncoder().encode(AppThemeStyles.christmas)
        )
        XCTAssertNil(stock.variant(.dark)?.transition)
        XCTAssertNil(stock.variant(.dark)?.sidebar?.brand?.motion)
    }

    func testReplacingCarriesTheTransitionThroughEveryEdit() throws {
        let theme = try dressedTheme(transition: ThemeTransition(particles: fizz()))
        let variant = try XCTUnwrap(theme.variant(.light))
        XCTAssertEqual(variant.replacing(roles: variant.roles).transition, variant.transition)
        XCTAssertEqual(variant.replacingSidebar(nil).transition, variant.transition)
        XCTAssertEqual(variant.replacingChrome(nil).transition, variant.transition)
        XCTAssertNil(variant.replacingTransition(nil).transition)
    }

    // MARK: - Gates

    func testParticleBoundsAreHeldWhereverTheyAreStated() {
        var tooDense = fizz()
        tooDense.density = 1.5
        XCTAssertThrowsError(try dressedTheme(ambient: tooDense))

        var tooManyInks = fizz()
        tooManyInks.colors = Array(repeating: .role(.accent), count: 5)
        XCTAssertThrowsError(
            try dressedTheme(transition: ThemeTransition(particles: tooManyInks))
        )

        XCTAssertThrowsError(
            try dressedTheme(transition: ThemeTransition(particles: fizz(), duration: 9))
        )
        XCTAssertThrowsError(
            try dressedTheme(transition: ThemeTransition(particles: fizz(), washOpacity: 1))
        )
    }

    func testTheBandsInkMustReadOnEveryStop() throws {
        XCTAssertNoThrow(try dressedTheme(band: redBand(ink: white)))
        // Coke red is dark enough for white and light enough for black; pale pink is neither
        // for white.
        let pale = SidebarStyle.Brand.Band(
            gradient: SidebarStyle.Gradient(stops: [
                .init(color: NSColor(hex: "#FFE9E8")!, position: 0),
                .init(color: NSColor(hex: "#FFFFFF")!, position: 1)
            ]),
            ink: white
        )
        XCTAssertThrowsError(try dressedTheme(band: pale)) { error in
            XCTAssertTrue(error.localizedDescription.contains("band"), error.localizedDescription)
        }
    }

    func testTheBandRefusesADriftItWouldNeverPlay() {
        var drifting = redBand(ink: white)
        drifting.gradient.drift = ThemeGradientDrift()
        XCTAssertThrowsError(try dressedTheme(band: drifting)) { error in
            XCTAssertTrue(error.localizedDescription.contains("drift"), error.localizedDescription)
        }
    }

    func testTheTitleColourIsMeasuredAgainstWhatItSitsOn() {
        // White on the red band reads.
        XCTAssertNoThrow(try dressedTheme(band: redBand(ink: white), titleColor: white))
        // White straight on Christmas's pale daylight sidebar does not.
        XCTAssertThrowsError(try dressedTheme(titleColor: white))
    }

    func testLogoMotionNeedsTheThemesOwnLogo() {
        let motion = SidebarStyle.Brand.LogoMotion(hover: .tilt)
        XCTAssertNoThrow(try dressedTheme(motion: motion))
        XCTAssertThrowsError(try dressedTheme(motion: motion, logo: .mark))

        let astray = SidebarStyle.Brand.LogoMotion(origin: .init(x: 1.4, y: 0))
        XCTAssertThrowsError(try dressedTheme(motion: astray))
    }

    // MARK: - Budgets

    func testNoPlacementCanBeAskedForAnUnboundedEmitter() {
        var dense = fizz()
        dense.density = 1
        for style in ThemeParticles.Style.allCases {
            dense.style = style
            let huge = CGSize(width: 4_000, height: 3_000)
            let ambient = ThemeParticleEmitter.ambientRate(for: dense, region: huge)
            let ambientLifetime = Double(
                ThemeParticleMotion(particles: dense, placement: .ambient, region: huge).lifetime
            )
            XCTAssertLessThanOrEqual(
                ambient * ambientLifetime,
                Double(ThemeParticleBudget.ambientMaximumAlive) + 0.5,
                "\(style) ambient"
            )

            let arrival = ThemeParticleEmitter.transitionRate(for: dense, region: huge, duration: 2.4)
            let arrivalLifetime = Double(
                ThemeParticleMotion(
                    particles: dense,
                    placement: .transition(duration: 2.4),
                    region: huge
                ).lifetime
            )
            XCTAssertLessThanOrEqual(
                arrival * arrivalLifetime,
                Double(ThemeParticleBudget.transitionMaximumAlive) + 0.5,
                "\(style) transition"
            )
        }
        XCTAssertLessThanOrEqual(
            ThemeParticleEmitter.streamRate(for: dense, intensity: 1),
            ThemeParticleBudget.pointMaximumRate
        )
        XCTAssertLessThanOrEqual(
            ThemeParticleEmitter.burstCount(for: dense),
            ThemeParticleBudget.burstMaximumCount
        )
        XCTAssertEqual(ThemeParticleEmitter.streamRate(for: dense, intensity: 0), 0)
    }

    func testAnEmitterIsOneCellPerInkTintedAndHeadedByTheAxis() {
        let emitter = CAEmitterLayer()
        ThemeParticleEmitter.configure(
            emitter,
            particles: fizz(),
            colors: [red, white],
            placement: .ambient,
            region: CGRect(x: 0, y: 0, width: 260, height: 520),
            scale: 2,
            rate: 4,
            opacity: 0.5,
            up: 1
        )
        let cells = emitter.emitterCells ?? []
        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(cells.first?.birthRate ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(cells.first?.color?.alpha ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(cells.first?.emissionLongitude ?? 0, .pi / 2, accuracy: 0.001)
        XCTAssertNotNil(cells.first?.contents)
        XCTAssertEqual(emitter.emitterShape, .rectangle, "a line source is a one-point rectangle")

        ThemeParticleEmitter.configure(
            emitter,
            particles: fizz(),
            colors: [red],
            placement: .ambient,
            region: CGRect(x: 0, y: 0, width: 260, height: 520),
            scale: 2,
            rate: 4,
            opacity: 1,
            up: -1
        )
        XCTAssertEqual(emitter.emitterCells?.first?.emissionLongitude ?? 0, -.pi / 2, accuracy: 0.001)
        XCTAssertGreaterThan(emitter.emitterPosition.y, 520, "a flipped layer's bottom is its max y")
    }

    func testAStillFrameIsTheSameScatterEveryTime() throws {
        let first = try XCTUnwrap(ThemeParticleStill.tile(
            particles: fizz(), colors: [red, white], side: 120, scale: 1, opacity: 0.6
        ))
        let second = try XCTUnwrap(ThemeParticleStill.tile(
            particles: fizz(), colors: [red, white], side: 120, scale: 1, opacity: 0.6
        ))
        XCTAssertEqual(
            NSBitmapImageRep(cgImage: first).representation(using: .png, properties: [:]),
            NSBitmapImageRep(cgImage: second).representation(using: .png, properties: [:])
        )
    }

    // MARK: - The hold

    func testAFieldMovesOnlyWhileMotionIsAllowedAndItsWindowIsSeen() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let field = ThemeParticleFieldLayer()
        field.frame = host.bounds
        let particles = SidebarAppearance.Background.Particles(spec: fizz(), colors: [red])

        field.apply(particles, host: host)
        XCTAssertEqual(field.state, .running)

        ThemeParticleHold.seenOverrideForTesting = false
        field.refresh()
        XCTAssertEqual(field.state, .paused, "an unseen window freezes its field in time")

        ThemeParticleHold.seenOverrideForTesting = true
        field.refresh()
        XCTAssertEqual(field.state, .running)

        Design.Motion.reduceMotionOverrideForTesting = true
        field.refresh()
        XCTAssertEqual(field.state, .still, "Reduce Motion stills a field rather than blanking it")

        Design.Motion.reduceMotionOverrideForTesting = false
        var settings = StubDesignSettings()
        settings.playsThemeMotion = false
        DesignSettings.current = settings
        field.refresh()
        XCTAssertEqual(field.state, .still, "the Theme animations setting does the same")

        field.apply(nil, host: host)
        XCTAssertEqual(field.state, .empty)
        XCTAssertTrue(field.isHidden)
    }

    func testAPreviewDrawsStillFramesWithoutStillingTheLiveWindow() {
        XCTAssertTrue(ThemeParticleHold.motionAllowed)
        ThemeParticleHold.withStillFrames {
            XCTAssertFalse(ThemeParticleHold.motionAllowed)
        }
        XCTAssertTrue(ThemeParticleHold.motionAllowed)
    }

    func testALogoStreamsWhileHoveredAndAsAgentsWork() throws {
        let logo = ThemeLogoView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        logo.layout()
        let motion = SidebarAppearance.Brand.LogoMotion(
            spec: .init(hover: .tilt, particles: fizz(), working: true),
            particles: .init(spec: fizz(), colors: [white])
        )
        logo.configure(image: NSImage(size: NSSize(width: 24, height: 24)), motion: motion)
        XCTAssertEqual(logo.streamRate, 0, "a logo at rest gives nothing off")

        logo.setHovered(true)
        XCTAssertEqual(logo.streamRate, 1, accuracy: 0.001)
        logo.setHovered(false)
        XCTAssertEqual(logo.streamRate, 0)

        logo.setWorkingIntensity(0.5)
        XCTAssertGreaterThan(logo.streamRate, 0)
        XCTAssertLessThan(logo.streamRate, 1, "half as busy fizzes less than a hover")

        Design.Motion.reduceMotionOverrideForTesting = true
        logo.refreshParticleMotion()
        XCTAssertEqual(logo.streamRate, 0, "Reduce Motion stops the stream")
    }

    // MARK: - Presenter

    func testTheArrivalResolvesTheIncomingVariantsInks() throws {
        let theme = try dressedTheme(
            transition: ThemeTransition(particles: fizz([.role(.accent)]), shimmer: true)
        )
        let palette = try XCTUnwrap(ThemeTransitionPresenter.palette(for: theme))
        let appearance = ThemeTransitionPresenter.arrivalAppearance(for: theme)
        XCTAssertEqual(
            palette.particleColors.first?.hexString,
            theme.resolved(.accent, appearance: appearance).hexString
        )
        XCTAssertEqual(palette.wash.hexString, theme.resolved(.ground, appearance: appearance).hexString)
        XCTAssertNil(ThemeTransitionPresenter.palette(for: AppThemeStyles.christmas))
    }

    func testASwitchWithNothingToPlayOnAppliesAtOnce() throws {
        let theme = try dressedTheme(transition: ThemeTransition(particles: fizz()))
        ThemeTransitionPresenter.shared.windowsProvider = { [] }
        ThemeTransitionPresenter.shared.present(theme)
        XCTAssertFalse(ThemeTransitionPresenter.shared.isPlaying)
        XCTAssertEqual(AppThemeLibrary.current.id, theme.id)
    }

    func testAnArrivalPlaysOverTheWindowAndASecondPickFinishesTheFirst() throws {
        let first = try dressedTheme(transition: ThemeTransition(particles: fizz(), duration: 2))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        ThemeTransitionPresenter.shared.windowsProvider = { [window] }

        ThemeTransitionPresenter.shared.present(first)
        XCTAssertTrue(ThemeTransitionPresenter.shared.isPlaying)
        XCTAssertNotEqual(AppThemeLibrary.current.id, first.id, "the swap waits for the wash")
        XCTAssertTrue(
            window.contentView?.subviews.contains { $0 is ThemeTransitionOverlayView } == true
        )
        XCTAssertNil(window.contentView?.subviews.last?.hitTest(NSPoint(x: 10, y: 10)))

        // A second pick lands the first one and starts from it — nothing queues.
        ThemeTransitionPresenter.shared.present(AppThemeStyles.christmas)
        XCTAssertEqual(AppThemeLibrary.current.id, AppThemeStyles.christmas.id)
        XCTAssertFalse(
            window.contentView?.subviews.contains { $0 is ThemeTransitionOverlayView } == true,
            "the first arrival's overlay is gone"
        )
    }

    func testReduceMotionAppliesWithoutPlaying() throws {
        Design.Motion.reduceMotionOverrideForTesting = true
        let theme = try dressedTheme(transition: ThemeTransition(particles: fizz()))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        ThemeTransitionPresenter.shared.windowsProvider = { [window] }
        ThemeTransitionPresenter.shared.present(theme)
        XCTAssertFalse(ThemeTransitionPresenter.shared.isPlaying)
        XCTAssertEqual(AppThemeLibrary.current.id, theme.id)
    }

    // MARK: - Tools

    private func coordinator() -> AgentToolCoordinator {
        AgentToolCoordinator(
            displayPaneController: DisplayPaneController(),
            visibleSessionID: { nil },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )
    }

    func testAgentCanDressAThemeInMotionAndReadItBack() async throws {
        let name = "Motion Tool Theme \(UUID().uuidString)"
        let logo = NSImage(size: NSSize(width: 16, height: 32), flipped: false) { rect in
            NSColor(srgbRed: 0.9, green: 0, blue: 0.05, alpha: 1).setFill()
            rect.fill()
            return true
        }
        let png = try XCTUnwrap(
            NSBitmapImageRep(data: try XCTUnwrap(logo.tiffRepresentation))?
                .representation(using: .png, properties: [:])
        )
        let variant = AppThemeVariantArguments(
            sidebar: AppThemeSidebarArguments(
                particles: AppThemeParticlesArguments(style: "fizz", colors: ["accent", "#FFFFFF"]),
                logo: .image(AppThemeImageArguments(path: nil, base64: png.base64EncodedString())),
                logoMotion: AppThemeLogoMotionArguments(
                    hover: "tilt",
                    press: "pop",
                    particles: AppThemeParticlesArguments(style: "fizz"),
                    working: true
                ),
                title: AppThemeSidebarTitleArguments(text: "Fizz", color: "#FFFFFF"),
                band: AppThemeSidebarBandArguments(
                    gradient: AppThemeGradientArguments(
                        angleDegrees: 180,
                        stops: [
                            AppThemeGradientStopArguments(color: "#E4000F", position: 0),
                            AppThemeGradientStopArguments(color: "#B8000C", position: 1)
                        ]
                    ),
                    ink: "#FFFFFF"
                )
            ),
            transition: AppThemeTransitionArguments(
                particles: AppThemeParticlesArguments(style: "fizz", density: 0.8),
                shimmer: true
            )
        )
        let create = CreateAppThemeArguments(
            name: name,
            baseID: AppThemeStyles.christmas.id.rawValue,
            appearance: "adaptive",
            mode: nil,
            summary: nil,
            variants: ["light": variant, "dark": variant],
            roles: nil,
            material: nil,
            terminalColors: nil,
            apply: false
        )
        let created = await coordinator().createAppTheme(create)
        XCTAssertFalse(created.isError, created.text)
        let theme = try XCTUnwrap(AppThemeLibrary.all.first { $0.name == name })
        defer {
            if let latest = AppThemeLibrary.theme(withID: theme.id) {
                _ = AppThemeLibrary.delete(latest)
            }
        }

        let dark = try XCTUnwrap(theme.variant(.dark))
        XCTAssertEqual(dark.sidebar?.brand?.motion?.hover, .tilt)
        XCTAssertEqual(dark.sidebar?.brand?.band?.ink?.hexString, "#FFFFFF")
        XCTAssertEqual(dark.sidebar?.background?.particles?.colors.count, 2)
        XCTAssertEqual(dark.transition?.particles.density, 0.8)

        let get = coordinator().getAppTheme(AppThemeReferenceArguments(themeID: theme.id.rawValue))
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(get.text.utf8)) as? [String: Any]
        )
        let variants = try XCTUnwrap(document["variants"] as? [String: Any])
        let darkDocument = try XCTUnwrap(variants["dark"] as? [String: Any])
        let transition = try XCTUnwrap(darkDocument["transition"] as? [String: Any])
        XCTAssertEqual(transition["shimmer"] as? Bool, true)
        let sidebar = try XCTUnwrap(darkDocument["sidebar"] as? [String: Any])
        XCTAssertNotNil(sidebar["band"])
        XCTAssertNotNil(sidebar["logo_motion"])
        XCTAssertNotNil(sidebar["particles"])

        // A patch that names one field merges; a remove takes the block back.
        let update = UpdateAppThemeArguments(
            themeID: theme.id.rawValue,
            name: nil,
            appearance: nil,
            mode: nil,
            summary: nil,
            variants: ["dark": AppThemeVariantArguments(
                sidebar: AppThemeSidebarArguments(
                    particles: AppThemeParticlesArguments(density: 0.9),
                    removeBand: true
                ),
                removeTransition: true
            )],
            roles: nil,
            material: nil,
            terminalColors: nil,
            apply: false
        )
        let updated = await coordinator().updateAppTheme(update)
        XCTAssertFalse(updated.isError, updated.text)
        let after = try XCTUnwrap(AppThemeLibrary.theme(withID: theme.id)?.variant(.dark))
        XCTAssertEqual(after.sidebar?.background?.particles?.density, 0.9)
        XCTAssertEqual(after.sidebar?.background?.particles?.style, .fizz)
        XCTAssertNil(after.sidebar?.brand?.band)
        XCTAssertNil(after.transition)
        XCTAssertNotNil(after.sidebar?.brand?.motion, "a patch that did not name it keeps it")
    }

    func testTheLogoSchemaAcceptsAWordOrAnImage() throws {
        let data = try JSONEncoder().encode(MCPPropertySchema(
            type: .stringOrObject,
            description: "logo"
        ))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("[\"string\",\"object\"]"), json)
    }

    func testPreviewDrawsEveryVariantOfATheme() throws {
        let originalTheme = try XCTUnwrap(Self.snapshots[ObjectIdentifier(self)]?.theme)
        let theme = try dressedTheme(
            band: redBand(ink: white),
            titleColor: white,
            ambient: fizz()
        )
        let rendered = try XCTUnwrap(AppThemePreviewService.render(theme, kinds: [.light, .dark]))
        let png = try XCTUnwrap(AppThemePreviewService.pngData(rendered))
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(image.pixelsWide, 1140)
        XCTAssertEqual(image.pixelsHigh, 1410, "two appearances, stacked")
        XCTAssertEqual(AppThemePalette.current.id, originalTheme.id, "the palette is put back")

        // The band is where it was drawn: the sidebar's top-left, in the band's red. The PNG is
        // tagged sRGB, so its samples are read as they are — converting an sRGB sample to sRGB
        // again through `NSColor` added a fifth of green that was never in the file.
        XCTAssertEqual(image.colorSpace.colorSpaceModel, .rgb)
        let corner = try XCTUnwrap(image.colorAt(x: 6, y: 6))
        XCTAssertGreaterThan(corner.redComponent, 0.8)
        XCTAssertLessThan(corner.greenComponent, 0.2)
        XCTAssertLessThan(corner.blueComponent, 0.15)

        if let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("theme-motion-preview.png"))
        }
    }
}
