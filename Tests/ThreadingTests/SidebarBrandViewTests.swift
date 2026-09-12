import AppKit
import XCTest
@testable import Threading

/// The brand row and the mark that anchors it: what the sidebar's top-left shows by default,
/// how a chrome restates it, and how the launch flourish behaves when motion is reduced.
final class SidebarBrandViewTests: XCTestCase {

    private var previousTheme: AppTheme!

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            previousTheme = AppThemeLibrary.current
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            AppThemeLibrary.apply(previousTheme)
            Design.Motion.reduceMotionOverrideForTesting = nil
        }
        super.tearDown()
    }

    // MARK: - The mark

    func testTheMarkStatesItsGeometryAtAnySize() {
        let box = CGRect(x: 0, y: 0, width: 64, height: 64)
        XCTAssertFalse(ThreadingMarkGeometry.outlinePath(in: box).isEmpty)
        XCTAssertFalse(ThreadingMarkGeometry.corePath(in: box).isEmpty)

        let strands = ThreadingMarkGeometry.strandPaths(in: box)
        XCTAssertEqual(strands.count, ThreadingMarkGeometry.strandCount)
        for strand in strands {
            XCTAssertFalse(strand.isEmpty)
            XCTAssertTrue(
                box.insetBy(dx: -1, dy: -1).contains(strand.boundingBoxOfPath),
                "a strand escaped the box it was asked to draw in"
            )
        }
    }

    func testParticleGeometrySamplesTheShieldThreadsAndCoreIndividually() {
        let seeds = ThreadingMarkGeometry.particleSeeds(outlineCount: 18, strandCount: 4)

        XCTAssertEqual(seeds.filter { $0.role == .outline }.count, 18)
        XCTAssertEqual(seeds.filter { $0.role == .core }.count, 7)
        for index in 0..<ThreadingMarkGeometry.strandCount {
            XCTAssertEqual(seeds.filter { $0.role == .strand(index) }.count, 4)
        }
        XCTAssertEqual(seeds.count, 49)
        for seed in seeds {
            XCTAssertTrue((0...1).contains(seed.point.x))
            XCTAssertTrue((0...1).contains(seed.point.y))
        }
    }

    /// Dots are separate layers rather than one dashed stroke. That is what lets outline,
    /// thread, core, strand and path position each carry their own tint and phase.
    @MainActor
    func testParticleMarkBuildsAddressableTintedDots() throws {
        let mark = ThreadingMarkView(particleMotion: .weave)
        mark.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        mark.layoutSubtreeIfNeeded()

        let (_, _, dots) = try particleLayers(in: mark)
        XCTAssertEqual(dots.count, 49, "the compact mark should keep its measured density")
        XCTAssertTrue(dots.allSatisfy { $0 is CAShapeLayer && ($0 as? CAShapeLayer)?.fillColor != nil })

        let inks = Set(dots.compactMap { layer -> String? in
            guard let components = (layer as? CAShapeLayer)?.fillColor?.components else { return nil }
            return components.map { String(format: "%.4f", $0) }.joined(separator: ",")
        })
        XCTAssertGreaterThan(inks.count, 2, "individual points collapsed to one frozen tint")
    }

    @MainActor
    func testHoverCrossfadesIntoParticlesAndStopsThemOnExit() throws {
        let mark = ThreadingMarkView(particleMotion: .weave)
        mark.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        Design.Motion.reduceMotionOverrideForTesting = false
        mark.layoutSubtreeIfNeeded()

        let (container, field, dots) = try particleLayers(in: mark)
        mark.setHovered(true)
        XCTAssertEqual(container.opacity, 1)
        XCTAssertTrue(
            dots.contains { $0.animation(forKey: "particle.position") != nil },
            "weave never sent a dot down the shield or a strand"
        )
        mark.playPress()
        XCTAssertNotNil(container.animation(forKey: "press"))
        XCTAssertNil(
            field.animation(forKey: "press"),
            "the field must stay free to rotate while its outer container handles the click"
        )
        XCTAssertEqual(
            dots.filter { $0.animation(forKey: "pressPulse") != nil }.count,
            dots.count,
            "the click did not cascade through every addressable point"
        )

        mark.setHovered(false)
        XCTAssertEqual(container.opacity, 0)
        XCTAssertNil(field.animation(forKey: "particle.orbit"))
        XCTAssertNil(field.animation(forKey: "particle.boxTumble"))
        XCTAssertTrue(dots.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    }

    /// A pass across the brand only weaves. Holding it tumbles the complete implied box through
    /// varied directions in perspective, on a nested layer so a click can tug it without
    /// replacing that tumble.
    @MainActor
    func testHeldHoverAddsVariedBoxTumbleWithoutFightingThePress() throws {
        Design.Motion.reduceMotionOverrideForTesting = false
        let passing = ThreadingMarkView(particleMotion: .weave, heldHoverDelay: 60)
        passing.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        passing.layoutSubtreeIfNeeded()
        let (_, passingField, _) = try particleLayers(in: passing)
        passing.setHovered(true)
        XCTAssertNil(
            passingField.animation(forKey: "particle.boxTumble"),
            "the tumble began before the pointer had actually held the brand"
        )
        passing.setHovered(false)

        let held = ThreadingMarkView(particleMotion: .weave, heldHoverDelay: 0)
        held.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        held.layoutSubtreeIfNeeded()
        let (container, field, dots) = try particleLayers(in: held)
        held.setHovered(true)

        let boxTumble = try XCTUnwrap(
            field.animation(forKey: "particle.boxTumble") as? CAKeyframeAnimation
        )
        XCTAssertEqual(boxTumble.keyPath, "transform")
        XCTAssertEqual(boxTumble.duration, Design.Motion.brandParticleBoxTumbleCycle)
        let transforms = try XCTUnwrap(boxTumble.values as? [NSValue]).map(\.caTransform3DValue)
        XCTAssertGreaterThan(transforms.count, 60, "the varied route collapsed to a few poses")
        XCTAssertTrue(
            transforms.contains {
                abs($0.m13) > 0.001 || abs($0.m23) > 0.001
                    || abs($0.m31) > 0.001 || abs($0.m32) > 0.001
            },
            "the box tumble stayed in the dots' flat Z-axis plane"
        )
        XCTAssertTrue(
            transforms.contains {
                abs($0.m14) > 0.001 || abs($0.m24) > 0.001 || abs($0.m34) > 0.001
            },
            "the box tumble carried no perspective"
        )
        XCTAssertTrue(
            transforms.contains { $0.m13 > 0.03 } && transforms.contains { $0.m13 < -0.03 },
            "yaw never changed direction"
        )
        XCTAssertTrue(
            transforms.contains { $0.m23 > 0.03 } && transforms.contains { $0.m23 < -0.03 },
            "pitch never changed direction"
        )
        XCTAssertTrue(
            transforms.contains { $0.m12 > 0.03 } && transforms.contains { $0.m12 < -0.03 },
            "the smaller roll never changed direction"
        )
        XCTAssertTrue(
            transforms.allSatisfy { abs($0.m33) > 0.65 },
            "the 24pt face turned close enough to edge-on to collapse into a line"
        )
        let first = try XCTUnwrap(transforms.first)
        let last = try XCTUnwrap(transforms.last)
        XCTAssertEqual(first.m11, last.m11, accuracy: 0.000_001)
        XCTAssertEqual(first.m12, last.m12, accuracy: 0.000_001)
        XCTAssertEqual(first.m13, last.m13, accuracy: 0.000_001)
        XCTAssertEqual(first.m21, last.m21, accuracy: 0.000_001)
        XCTAssertEqual(first.m22, last.m22, accuracy: 0.000_001)
        XCTAssertEqual(first.m23, last.m23, accuracy: 0.000_001)
        XCTAssertEqual(first.m31, last.m31, accuracy: 0.000_001)
        XCTAssertEqual(first.m32, last.m32, accuracy: 0.000_001)
        XCTAssertEqual(first.m33, last.m33, accuracy: 0.000_001)
        XCTAssertNil(
            field.animation(forKey: "particle.orbit"),
            "the held hover reused the planar particle orbit"
        )
        XCTAssertTrue(
            dots.contains { $0.animation(forKey: "particle.position") != nil },
            "the box tumble replaced Weave instead of carrying it inside"
        )

        held.playPress()
        XCTAssertNotNil(container.animation(forKey: "press"))
        XCTAssertNotNil(
            field.animation(forKey: "particle.boxTumble"),
            "clicking replaced the box tumble because both motions owned one layer"
        )

        held.setHovered(false)
        XCTAssertNil(field.animation(forKey: "particle.orbit"))
        XCTAssertNil(field.animation(forKey: "particle.boxTumble"))
        XCTAssertTrue(dots.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    }

    @MainActor
    func testEveryParticleTreatmentRendersADistinctFrame() throws {
        var frames: [Data] = []
        let renderDirectory = ProcessInfo.processInfo.environment["THREADING_MARK_RENDER_DIR"]

        for motion in ThreadingMarkParticleMotion.allCases {
            let mark = ThreadingMarkView(particleMotion: motion)
            mark.frame = NSRect(x: 0, y: 0, width: 64, height: 64)
            mark.layoutSubtreeIfNeeded()
            mark.setParticlePresentation(
                phase: 0.34,
                heldHoverPhase: motion == .weave ? 0.58 : nil
            )

            let frame = try XCTUnwrap(png(of: mark))
            XCTAssertGreaterThan(frame.count, 500)
            frames.append(frame)

            if let renderDirectory {
                let directory = URL(fileURLWithPath: renderDirectory, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                try frame.write(to: directory.appendingPathComponent("\(motion.rawValue).png"))
            }
        }

        XCTAssertEqual(Set(frames).count, ThreadingMarkParticleMotion.allCases.count)
    }

    /// Under Reduce Motion the launch is the finished mark simply being there — no animation
    /// is even constructed, which is what the theme-boundary exception for this view promises.
    @MainActor
    func testTheDrawInConstructsNoAnimationUnderReduceMotion() throws {
        let mark = ThreadingMarkView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))

        Design.Motion.reduceMotionOverrideForTesting = true
        mark.playDrawIn()
        XCTAssertTrue(animatedLayers(of: mark).isEmpty)

        Design.Motion.reduceMotionOverrideForTesting = false
        mark.playDrawIn()
        XCTAssertEqual(
            animatedLayers(of: mark).count,
            ThreadingMarkGeometry.strandCount + 2,
            "the outline, each strand, and the core should each carry the draw-in"
        )
    }

    private func animatedLayers(of view: NSView, key: String = "drawIn") -> [CALayer] {
        (view.layer?.sublayers ?? []).filter { $0.animation(forKey: key) != nil }
    }

    @MainActor
    private func particleLayers(
        in mark: ThreadingMarkView
    ) throws -> (container: CALayer, field: CALayer, dots: [CALayer]) {
        let container = try XCTUnwrap(
            mark.layer?.sublayers?.first { $0.name == "ThreadingMarkParticles" }
        )
        let field = try XCTUnwrap(
            container.sublayers?.first { $0.name == "ThreadingMarkParticleField" }
        )
        return (container, field, try XCTUnwrap(field.sublayers))
    }

    @MainActor
    private func png(of mark: ThreadingMarkView) -> Data? {
        let canvasSide: CGFloat = 88
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvasSide * 2),
            pixelsHigh: Int(canvasSide * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: canvasSide, height: canvasSide)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        mark.displayIfNeeded()
        CATransaction.flush()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.setFillColor(NSColor(
            srgbRed: 0.055, green: 0.059, blue: 0.067, alpha: 1
        ).cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: canvasSide, height: canvasSide))
        context.cgContext.translateBy(x: 12, y: 12)
        mark.layer?.displayIfNeeded()
        mark.layer?.render(in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// The blur. A shape layer added by hand keeps `contentsScale` 1 — only the backing layer
    /// AppKit makes for the view is given the display's — so every path was rasterised at 1x
    /// and enlarged by the compositor.
    @MainActor
    func testEveryShapeLayerRasterisesAtTheDisplaysScale() throws {
        let mark = ThreadingMarkView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let expected = NSScreen.main?.backingScaleFactor ?? 2

        let shapes = try XCTUnwrap(mark.layer?.sublayers)
        XCTAssertEqual(shapes.count, ThreadingMarkGeometry.strandCount + 2)
        for shape in shapes {
            XCTAssertEqual(
                shape.contentsScale,
                expected,
                "a shape layer left at 1x draws the mark soft on a Retina display"
            )
        }
    }

    /// Hover holds a lift on the model — it has to survive the animation, since the pointer can
    /// rest there — and lands the core's one beat on top of it.
    @MainActor
    func testHoverLiftsTheMarkAndSettlesBack() throws {
        let mark = ThreadingMarkView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        Design.Motion.reduceMotionOverrideForTesting = false

        mark.setHovered(true)
        let lifted = try XCTUnwrap(mark.layer?.sublayers?.first)
        XCTAssertGreaterThan(lifted.transform.m11, 1, "the mark did not lift under the pointer")
        XCTAssertEqual(animatedLayers(of: mark, key: "hover").count, 1, "the core is the one beat")

        mark.setHovered(false)
        XCTAssertEqual(lifted.transform.m11, 1, accuracy: 0.001, "the lift never settled back")
    }

    /// The press turns the whole mark by one strand-step. Six-fold symmetry is what makes that
    /// legal: the model value stays put, so the mark is where it started when the turn is over.
    @MainActor
    func testThePressTurnsEveryLayerAndLeavesNoneRotated() throws {
        let mark = ThreadingMarkView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))

        Design.Motion.reduceMotionOverrideForTesting = true
        mark.playPress()
        XCTAssertTrue(animatedLayers(of: mark, key: "press").isEmpty)

        Design.Motion.reduceMotionOverrideForTesting = false
        mark.playPress()
        XCTAssertEqual(
            animatedLayers(of: mark, key: "press").count,
            ThreadingMarkGeometry.strandCount + 2,
            "the shield, every strand and the core turn together or the mark comes apart"
        )
        for layer in try XCTUnwrap(mark.layer?.sublayers) {
            XCTAssertEqual(layer.transform.m12, 0, accuracy: 0.001, "a layer was left rotated")
        }
    }

    /// Under Reduce Motion the pointer changes nothing at all — no lift to settle back from.
    @MainActor
    func testHoverConstructsNothingUnderReduceMotion() throws {
        let mark = ThreadingMarkView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let particleMark = ThreadingMarkView(particleMotion: .weave)
        particleMark.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        particleMark.layoutSubtreeIfNeeded()
        Design.Motion.reduceMotionOverrideForTesting = true

        mark.setHovered(true)
        particleMark.setHovered(true)
        XCTAssertTrue(animatedLayers(of: mark, key: "hover").isEmpty)
        for layer in try XCTUnwrap(mark.layer?.sublayers) {
            XCTAssertEqual(layer.transform.m11, 1, accuracy: 0.001)
        }
        let (container, field, dots) = try particleLayers(in: particleMark)
        XCTAssertEqual(container.opacity, 0)
        XCTAssertNil(field.animation(forKey: "particle.orbit"))
        XCTAssertNil(field.animation(forKey: "particle.boxTumble"))
        XCTAssertTrue(dots.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    }

    /// The whole row is the pointer target, not the 24pt logo alone.
    @MainActor
    func testTheRowTracksThePointerForTheMark() {
        let brand = SidebarBrandView(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
        brand.layoutSubtreeIfNeeded()
        brand.updateTrackingAreas()

        XCTAssertFalse(brand.trackingAreas.isEmpty, "nothing would ever tell the mark to lift")
    }

    // MARK: - The brand row

    @MainActor
    func testTheDefaultRowShowsTheMarkBesideTheAppsName() {
        AppThemeLibrary.apply(.system)
        let brand = SidebarBrandView(frame: .zero)
        brand.layoutSubtreeIfNeeded()

        let mark = try? XCTUnwrap(descendant(of: brand, as: ThreadingMarkView.self))
        let analyzer = try? XCTUnwrap(
            descendant(of: brand, as: AgentWorkloadAnalyzerView.self)
        )
        XCTAssertEqual(mark?.isHidden, false)
        XCTAssertEqual(analyzer?.isHidden, true)
        XCTAssertEqual(brand.accessibilityLabel(), AppInfo.name)
    }

    @MainActor
    func testClassicPlayerReplacesTheBrandWithTheWorkloadAnalyzer() throws {
        AppThemeLibrary.apply(AppThemeStyles.classicPlayer)
        let brand = SidebarBrandView(frame: .zero)
        brand.layoutSubtreeIfNeeded()

        let mark = try XCTUnwrap(descendant(of: brand, as: ThreadingMarkView.self))
        let analyzer = try XCTUnwrap(
            descendant(of: brand, as: AgentWorkloadAnalyzerView.self)
        )
        let wordmark = try XCTUnwrap(descendant(of: brand, as: MorphingTitleLabel.self))

        XCTAssertTrue(mark.isHidden)
        XCTAssertTrue(wordmark.isHidden)
        XCTAssertFalse(analyzer.isHidden)
        XCTAssertEqual(brand.accessibilityLabel(), AppInfo.name)
        XCTAssertEqual(brand.accessibilityValue() as? String, L10n.string("No agents working"))
    }

    @MainActor
    func testWorkloadAnalyzerStatesCountAndTopEffortWithoutExposingItsPixels() throws {
        AppThemeLibrary.apply(AppThemeStyles.classicPlayer)
        let brand = SidebarBrandView(frame: NSRect(x: 0, y: 0, width: 180, height: 40))
        let intensity = AgentIntensity(
            workload: AgentWorkload(workingCount: 3, anyAtTopEffort: true),
            recentActivity: 0.75,
            measuredAt: 10
        )
        NotificationCenter.default.post(AgentIntensityDidChange(intensity: intensity))

        let analyzer = try XCTUnwrap(
            descendant(of: brand, as: AgentWorkloadAnalyzerView.self)
        )
        analyzer.freezePresentationForTesting(intensity: intensity, phase: 0.31)

        XCTAssertEqual(
            brand.accessibilityValue() as? String,
            L10n.format("%@, top effort active", L10n.format("%lld agents working", Int64(3)))
        )
        XCTAssertFalse(analyzer.isAccessibilityElement())
        XCTAssertNil(analyzer.hitTest(NSPoint(x: 20, y: 10)))
        XCTAssertTrue(analyzer.displayedCellCountsForTesting.allSatisfy { $0 > 0 })
        XCTAssertTrue(analyzer.displayedCellCountsForTesting.allSatisfy {
            $0 <= Design.WorkloadAnalyzer.cellCount
        })

        analyzer.freezePresentationForTesting(
            intensity: AgentIntensity(
                workload: AgentWorkload(workingCount: 120, anyAtTopEffort: false),
                recentActivity: 0,
                measuredAt: 10
            ),
            phase: 0
        )
        XCTAssertEqual(analyzer.readingTitleForTesting, "99+")
    }

    @MainActor
    func testSwitchingAwayFromClassicPlayerRestoresTheBrand() throws {
        AppThemeLibrary.apply(AppThemeStyles.classicPlayer)
        let brand = SidebarBrandView(frame: .zero)
        let analyzer = try XCTUnwrap(
            descendant(of: brand, as: AgentWorkloadAnalyzerView.self)
        )
        XCTAssertFalse(analyzer.isHidden)

        AppThemeLibrary.apply(.system)

        let mark = try XCTUnwrap(descendant(of: brand, as: ThreadingMarkView.self))
        XCTAssertTrue(analyzer.isHidden)
        XCTAssertFalse(mark.isHidden)
        XCTAssertNil(brand.accessibilityValue())
    }

    @MainActor
    func testEveryStockThemeFollowsTheSemanticSpectrumGate() throws {
        for theme in [AppTheme.system] + AppThemeStyles.all {
            AppThemeLibrary.apply(theme)
            let brand = SidebarBrandView(frame: .zero)
            let analyzer = try XCTUnwrap(
                descendant(of: brand, as: AgentWorkloadAnalyzerView.self)
            )
            let expectsAnalyzer = Design.Chart.style == .spectrum

            XCTAssertEqual(
                analyzer.isHidden,
                !expectsAnalyzer,
                "\(theme.name) disagreed with its own chart material"
            )
        }
    }

    @MainActor
    func testReduceMotionRemovesTheAnalyzersFrameDriver() {
        AppThemeLibrary.apply(AppThemeStyles.classicPlayer)
        Design.Motion.reduceMotionOverrideForTesting = true
        let analyzer = AgentWorkloadAnalyzerView()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.addSubview(analyzer)
        analyzer.setPresented(true)
        analyzer.update(intensity: AgentIntensity(
            workload: AgentWorkload(workingCount: 1, anyAtTopEffort: false),
            recentActivity: 0.4,
            measuredAt: 10
        ))

        XCTAssertFalse(analyzer.hasFrameDriverForTesting)
    }

    /// A chrome that renames the row renames it live — the same theme switch that repaints
    /// the window reconfigures the brand, with no host wiring.
    @MainActor
    func testAChromeStatingABrandReconfiguresTheRowOnApply() throws {
        AppThemeLibrary.apply(.system)
        let brand = SidebarBrandView(frame: .zero)

        let base = AppThemeStyles.cyberpunk
        let kind = base.availableVariants[0]
        let themed = try AppThemeEditing.assemble(
            id: AppThemeID("custom-sidebar-brand-view-tests"),
            name: "Signed",
            mode: kind == .dark ? .dark : .light,
            summary: nil,
            variants: [kind: AppThemeEditing.makeVariant(
                named: "Signed",
                from: base,
                kind: kind,
                sidebar: .set(SidebarStyle(
                    brand: .init(logo: .hidden, title: .init(text: "Atelier"))
                ))
            )]
        )
        AppThemeLibrary.apply(themed)

        let mark = try XCTUnwrap(descendant(of: brand, as: ThreadingMarkView.self))
        XCTAssertTrue(mark.isHidden, "the chrome hid the logo and the row kept drawing it")
        XCTAssertEqual(brand.accessibilityLabel(), "Atelier")
    }

    // MARK: - The sidebar's shape

    /// The header carries the brand at its leading edge and the list's two controls at its
    /// trailing one; the footer carries global destinations, icon and word, from the leading
    /// margin.
    @MainActor
    func testTheSidebarPlacesBrandAddAndSettingsWhereTheDesignSays() throws {
        AppThemeLibrary.apply(.system)
        let sidebar = ProjectSidebarViewController()
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.view.layoutSubtreeIfNeeded()

        let brand = try XCTUnwrap(descendant(of: sidebar.view, as: SidebarBrandView.self))
        let header = try XCTUnwrap(ancestor(of: brand, as: PaneHeaderView.self))

        let add = try XCTUnwrap(
            descendants(of: sidebar.view)
                .compactMap { $0 as? ThemedIconButton }
                .first { $0.accessibilityTitle() == L10n.string("Add Project") },
            "the header has no + to add a project"
        )
        XCTAssertNotNil(
            ancestor(of: add, as: PaneHeaderView.self),
            "the + belongs in the header band beside the list it adds to"
        )
        XCTAssertEqual(header, ancestor(of: add, as: PaneHeaderView.self))

        let settings = try XCTUnwrap(
            descendants(of: sidebar.view)
                .compactMap { $0 as? ThemedButton }
                .first { $0.title == L10n.string("Settings") },
            "the footer has no titled Settings button"
        )
        let footer = try XCTUnwrap(ancestor(of: settings, as: PaneFooterView.self))
        let triggers = try XCTUnwrap(
            descendants(of: sidebar.view)
                .compactMap { $0 as? ThemedButton }
                .first { $0.title == L10n.string("Triggers") },
            "the footer has no titled Triggers destination"
        )
        XCTAssertEqual(footer, ancestor(of: triggers, as: PaneFooterView.self))
        XCTAssertLessThan(
            footer.convert(triggers.frame, from: triggers.superview).minX,
            footer.convert(settings.frame, from: settings.superview).minX,
            "global destinations no longer read from the footer's leading edge"
        )
    }

    /// Current Theme opens into the *trailing* panel, so its door stays on that panel's `+` rather
    /// than becoming a third global destination here. Asserted with theme tools deliberately on,
    /// which is the state that used to reveal the row.
    @MainActor
    func testTheFooterCarriesOnlyGlobalDestinationsEvenWhileThemeToolsAreEnabled() throws {
        let settings = AppSettings.shared
        let previous = settings.disabledToolGroupIDs
        defer { settings.disabledToolGroupIDs = previous }
        settings.setToolGroup(MCPToolCatalog.appearance.id, enabled: true)

        let sidebar = ProjectSidebarViewController()
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.view.layoutSubtreeIfNeeded()

        let buttons = descendants(of: sidebar.view).compactMap { $0 as? ThemedButton }
        XCTAssertNil(
            buttons.first { $0.title == L10n.string("Current Theme") },
            "the sidebar grew a permanent door to a surface it does not host"
        )

        let settingsButton = try XCTUnwrap(buttons.first { $0.title == L10n.string("Settings") })
        XCTAssertNotNil(buttons.first { $0.title == L10n.string("Triggers") })
        let footer = try XCTUnwrap(ancestor(of: settingsButton, as: PaneFooterView.self))
        XCTAssertFalse(footer.isHidden)
        XCTAssertEqual(
            descendants(of: sidebar.view).compactMap { $0 as? PaneFooterView }.count,
            1,
            "the second footer band outlived the row it was stacked for"
        )
    }

    /// The brand and the first global destination sit on the **list's** margin, not on the
    /// platform's.
    ///
    /// Both bands run the sidebar's full width, so the corner-adapted region they used to
    /// measure from held the window controls clear for their whole height — see
    /// `PaneHeaderTests`. Neither band's ink goes anywhere near the traffic lights, and taking
    /// the allowance anyway indented the brand and the gear some eighty points past every row
    /// between them: one column read as three.
    @MainActor
    func testTheBrandAndFirstDestinationSitOnTheSameMarginAsTheList() throws {
        AppThemeLibrary.apply(.system)
        let sidebar = ProjectSidebarViewController()
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.view.layoutSubtreeIfNeeded()

        let brand = try XCTUnwrap(descendant(of: sidebar.view, as: SidebarBrandView.self))
        let firstDestination = try XCTUnwrap(
            descendants(of: sidebar.view)
                .compactMap { $0 as? ThemedButton }
                .first { $0.title == L10n.string("Triggers") }
        )

        let brandInk = sidebar.view.convert(brand.bounds, from: brand).minX
        let destinationInk = sidebar.view.convert(
            firstDestination.bounds,
            from: firstDestination
        ).minX + firstDestination.opticalHorizontalInset

        XCTAssertEqual(brandInk, Design.Spacing.inset, accuracy: 0.5)
        XCTAssertEqual(
            destinationInk,
            brandInk,
            accuracy: 1,
            "the top of the column and the bottom of it should start on one line"
        )
    }

    /// Settings mode hides the list's controls — they act on a list that is not on screen —
    /// but the band and the brand stay: the brand is the window's signature, not a list tool.
    @MainActor
    func testSettingsModeKeepsTheBrandAndHidesTheListControls() throws {
        AppThemeLibrary.apply(.system)
        let sidebar = ProjectSidebarViewController()
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.view.layoutSubtreeIfNeeded()

        let brand = try XCTUnwrap(descendant(of: sidebar.view, as: SidebarBrandView.self))
        let header = try XCTUnwrap(ancestor(of: brand, as: PaneHeaderView.self))
        let add = try XCTUnwrap(
            descendants(of: sidebar.view)
                .compactMap { $0 as? ThemedIconButton }
                .first { $0.accessibilityTitle() == L10n.string("Add Project") }
        )
        let arrange = try XCTUnwrap(
            descendants(of: sidebar.view)
                .compactMap { $0 as? ThemedIconButton }
                .first { $0.accessibilityTitle() == SidebarStrings.arrangementOptions }
        )

        sidebar.setSettingsMode(true)
        XCTAssertFalse(header.isHidden, "settings mode took the whole band and the logo with it")
        XCTAssertFalse(brand.isHidden)
        XCTAssertTrue(add.isHidden)
        XCTAssertTrue(arrange.isHidden)

        sidebar.setSettingsMode(false)
        XCTAssertFalse(add.isHidden)
        XCTAssertFalse(arrange.isHidden)
    }

    // MARK: - Helpers

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func descendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        descendants(of: view).compactMap { $0 as? T }.first
    }

    private func ancestor<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        var current = view.superview
        while let candidate = current {
            if let match = candidate as? T { return match }
            current = candidate.superview
        }
        return nil
    }
}
