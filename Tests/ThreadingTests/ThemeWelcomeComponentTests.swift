import AppKit
import XCTest
@testable import Threading

/// The three components the welcome draws with — the ground, the mark and the scrims — and the
/// two type roles it sets its words in: behaviour, accessibility, a live theme switch, and the
/// components drawn together light and dark.
@MainActor
final class ThemeWelcomeComponentTests: XCTestCase {

    private var previousTheme: AppTheme!
    private var previousMotion: Bool?
    private var previousSeen: Bool?

    override func setUp() async throws {
        try await super.setUp()
        previousTheme = AppThemeLibrary.current
        previousMotion = Design.Motion.reduceMotionOverrideForTesting
        previousSeen = ThemeParticleHold.seenOverrideForTesting
    }

    override func tearDown() async throws {
        AppThemeLibrary.apply(previousTheme)
        Design.Motion.reduceMotionOverrideForTesting = previousMotion
        ThemeParticleHold.seenOverrideForTesting = previousSeen
        ThemeAssetStore.removeAll(for: ThemeWelcomeFixtures.themeID)
        try await super.tearDown()
    }

    private func gradientWelcome(particles: Bool = false) -> ThemeWelcome {
        ThemeWelcome(backdrop: ThemeBackdrop(
            gradient: ThemeBackdrop.Gradient(stops: [
                .init(color: Design.Surface.ground, position: 0),
                .init(color: Design.Surface.accentMuted, position: 1)
            ]),
            particles: particles
                ? ThemeParticles(style: .snow, colors: [.role(.label)])
                : nil
        ))
    }

    // MARK: - Ground

    /// The ground wears the theme's welcome backdrop and sheds it when the theme leaves —
    /// through the theme notification, with nobody telling it.
    func testTheGroundWearsTheWelcomeAndShedsItWithTheTheme() throws {
        AppThemeLibrary.apply(.system)
        let ground = ThemeWelcomeGroundView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertFalse(ground.isDressed, "System states no welcome")

        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(gradientWelcome()))
        XCTAssertTrue(ground.isDressed)
        XCTAssertTrue(ground.backdrop.showsGradient)
        XCTAssertFalse(ground.backdrop.showsPicture)

        AppThemeLibrary.apply(.system)
        XCTAssertFalse(ground.isDressed, "leaving the theme took its welcome with it")
        XCTAssertFalse(ground.backdrop.showsGradient)
        XCTAssertFalse(ground.isAccessibilityElement())
    }

    /// AppKit may put a subview's layer beneath everything; the dressing goes back under it.
    func testTheDressingStaysBeneathEverySubview() throws {
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(gradientWelcome()))
        let ground = ThemeWelcomeGroundView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let first = NSView(frame: ground.bounds)
        first.wantsLayer = true
        ground.addSubview(first)
        let below = NSView(frame: ground.bounds)
        below.wantsLayer = true
        ground.addSubview(below, positioned: .below, relativeTo: nil)
        ground.layoutSubtreeIfNeeded()

        XCTAssertEqual(ground.layer?.sublayers?.first?.name, ThemeWelcomeGroundView.layerName)
        XCTAssertTrue(ground.subviews.first === below, "the subview order is AppKit's")
    }

    /// An adaptive theme states a welcome per variant; an appearance flip is a variant change.
    func testEachAppearanceWearsItsOwnVariantsWelcome() throws {
        let base = AppThemeStyles.threading
        let light = try XCTUnwrap(base.variant(.light)).replacingWelcome(gradientWelcome())
        let dark = try XCTUnwrap(base.variant(.dark)).replacingWelcome(nil)
        AppThemeLibrary.apply(AppTheme(
            id: ThemeWelcomeFixtures.themeID,
            name: "Half Welcome",
            mode: .system,
            summary: nil,
            variants: [.light: light, .dark: dark]
        ))
        let ground = ThemeWelcomeGroundView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        ground.appearance = NSAppearance(named: .aqua)
        ground.viewDidChangeEffectiveAppearance()
        XCTAssertTrue(ground.isDressed)
        var flipped = false
        ground.onAppearanceChange = { flipped = true }
        ground.appearance = NSAppearance(named: .darkAqua)
        ground.viewDidChangeEffectiveAppearance()
        XCTAssertFalse(ground.isDressed, "the dark variant states no welcome")
        XCTAssertTrue(flipped, "the host hears about the flip")
    }

    /// The field is the shared particle layer, so it answers the hold: a still scatter under
    /// Reduce Motion, a moving field otherwise.
    func testTheGroundsParticlesAnswerTheHold() throws {
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(gradientWelcome(particles: true)))
        ThemeParticleHold.seenOverrideForTesting = true

        Design.Motion.reduceMotionOverrideForTesting = true
        let still = ThemeWelcomeGroundView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        still.layoutSubtreeIfNeeded()
        still.backdrop.layoutIfNeeded()
        still.backdrop.particles.frame = still.bounds
        still.backdrop.particles.refresh()
        XCTAssertTrue(still.backdrop.showsParticles)
        XCTAssertEqual(still.backdrop.particles.state, .still, "Reduce Motion leaves a still frame")

        Design.Motion.reduceMotionOverrideForTesting = false
        ThemeParticleHold.shared.refreshAll()
        XCTAssertEqual(still.backdrop.particles.state, .running)
    }

    /// The ground says when it can be seen — in a window and not hidden — and only on a change.
    func testTheGroundReportsWhenItCanBeSeen() {
        let ground = ThemeWelcomeGroundView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        var reports: [Bool] = []
        ground.onVisibilityChange = { reports.append($0) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = ground
        XCTAssertEqual(reports, [true])

        ground.isHidden = true
        ground.isHidden = false
        window.contentView = NSView()
        XCTAssertEqual(reports, [true, false, true, false])
    }

    // MARK: - Scrim

    /// A veil holds its peak over the whole region and reaches exactly a pane margin past each
    /// of its corners before it is gone.
    func testAVeilHoldsItsPeakOverTheRegionAndEndsAPaneMarginPast() throws {
        let region = CGRect(x: 100, y: 40, width: 400, height: 120)
        let veil = try XCTUnwrap(ThemeWelcomeScrimView.veil(behind: region, opacity: 0.6))
        func radius(of point: CGPoint) -> CGFloat {
            let x = (point.x - veil.ellipse.midX) / (veil.ellipse.width / 2)
            let y = (point.y - veil.ellipse.midY) / (veil.ellipse.height / 2)
            return (x * x + y * y).squareRoot()
        }
        XCTAssertEqual(radius(of: CGPoint(x: region.maxX, y: region.maxY)), veil.peakRadius, accuracy: 0.0001)
        let reach = ThemeWelcomeScrimView.reach
        XCTAssertEqual(reach, Design.Spacing.pane)
        XCTAssertEqual(
            radius(of: CGPoint(x: region.maxX + reach, y: region.maxY + reach)),
            1,
            accuracy: 0.0001,
            "the veil ends at the inflated frame's corner"
        )
        XCTAssertLessThan(veil.peakRadius, 1)
        XCTAssertEqual(veil.opacity, 0.6)
        XCTAssertNil(ThemeWelcomeScrimView.veil(behind: .zero, opacity: 0.6))
        XCTAssertNil(ThemeWelcomeScrimView.veil(behind: region, opacity: 0))
    }

    /// Strengths are the theme's, held to the ceiling; a scrim with none hides; a veil takes no
    /// click and is no accessibility element; a theme switch shows and hides it.
    func testTheScrimFollowsTheThemeAndTakesNothing() throws {
        AppThemeLibrary.apply(.system)
        let scrim = ThemeWelcomeScrimView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrim.heroRegion = CGRect(x: 100, y: 180, width: 200, height: 60)
        scrim.promptRegion = CGRect(x: 40, y: 20, width: 320, height: 100)
        XCTAssertTrue(scrim.isHidden, "no theme scrim, no veil")
        XCTAssertTrue(scrim.veils.isEmpty)

        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(
            ThemeWelcome(scrim: ThemeWelcome.Scrim(hero: 2, prompt: -1))
        ))
        XCTAssertFalse(scrim.isHidden)
        XCTAssertEqual(scrim.scrim.hero, 0.9, "held to the ceiling")
        XCTAssertEqual(scrim.scrim.prompt, 0)
        XCTAssertEqual(scrim.veils.count, 1)
        XCTAssertNil(scrim.hitTest(NSPoint(x: 200, y: 200)))
        XCTAssertFalse(scrim.isAccessibilityElement())

        AppThemeLibrary.apply(.system)
        XCTAssertTrue(scrim.isHidden)
    }

    /// Drawn, the veil is the ground at its peak over the region and nothing past its reach.
    func testTheVeilDrawsTheGroundAtItsPeakAndNothingPastItsReach() throws {
        AppThemeLibrary.apply(.system)
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        host.appearance = appearance
        host.wantsLayer = true
        let magenta = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        host.layer?.backgroundColor = magenta.cgColor
        let scrim = ThemeWelcomeScrimView(frame: host.bounds)
        host.addSubview(scrim)
        scrim.preview = ThemeWelcome(scrim: ThemeWelcome.Scrim(prompt: 0.9))
        scrim.promptRegion = CGRect(x: 150, y: 120, width: 100, height: 60)

        func render() throws -> NSBitmapImageRep {
            var bitmap: NSBitmapImageRep?
            appearance.performAsCurrentDrawingAppearance {
                bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
                if let bitmap { host.cacheDisplay(in: host.bounds, to: bitmap) }
            }
            return try XCTUnwrap(bitmap)
        }
        // The bare backdrop first, read back through the same capture: a capture stores its
        // own colour space, so the veil is measured against what the backdrop *reads as*.
        scrim.preview = ThemeWelcome(scrim: ThemeWelcome.Scrim())
        XCTAssertTrue(scrim.isHidden)
        let bare = try render()
        scrim.preview = ThemeWelcome(scrim: ThemeWelcome.Scrim(prompt: 0.9))
        let veiled = try render()
        try veiled.representation(using: .png, properties: [:])?.write(
            to: ThemeWelcomeFixtures.renderDirectory.appendingPathComponent("theme-welcome-veil.png")
        )

        var ground = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            ground = Design.Surface.ground.usingColorSpace(.sRGB) ?? .black
        }
        let scale = CGFloat(veiled.pixelsWide) / host.bounds.width
        func pixel(_ rep: NSBitmapImageRep, _ x: CGFloat, _ yFromBottom: CGFloat) -> NSColor {
            let color = rep.colorAt(
                x: Int(x * scale),
                y: Int((host.bounds.height - yFromBottom) * scale)
            )
            return color?.usingColorSpace(.sRGB) ?? .clear
        }
        func assertColor(_ actual: NSColor, _ expected: NSColor, _ message: String, line: UInt = #line) {
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.03, message, line: line)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.03, message, line: line)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.03, message, line: line)
        }

        // At the region's centre and its corner: the ground at the full peak.
        let region = scrim.promptRegion
        for point in [CGPoint(x: region.midX, y: region.midY), CGPoint(x: region.maxX - 1, y: region.maxY - 1)] {
            assertColor(
                pixel(veiled, point.x, point.y),
                ground.withAlphaComponent(0.9).composited(over: pixel(bare, point.x, point.y)),
                "the region is under the full veil at \(point)"
            )
        }
        // A pane margin past the corner, and anywhere further: nothing.
        let reach = ThemeWelcomeScrimView.reach
        for point in [
            CGPoint(x: region.maxX + reach, y: region.maxY + reach),
            CGPoint(x: 10, y: 10),
            CGPoint(x: 390, y: 290)
        ] {
            assertColor(
                pixel(veiled, point.x, point.y),
                pixel(bare, point.x, point.y),
                "the veil reached past its margin at \(point)"
            )
        }
    }

    // MARK: - Mark

    /// The app's mark at the host's size until a theme says otherwise.
    func testTheMarkIsTheAppsUntilAThemeSaysOtherwise() {
        AppThemeLibrary.apply(.system)
        let mark = ThemeWelcomeMarkView(defaultSide: 40)
        XCTAssertEqual(mark.shown, .app)
        XCTAssertEqual(mark.side, 40)
        XCTAssertFalse(mark.appMark.isHidden)
        XCTAssertFalse(mark.isHidden)
        XCTAssertFalse(mark.isAccessibilityElement(), "the greeting carries the words")
        XCTAssertNil(mark.hitTest(NSPoint(x: 20, y: 20)))
    }

    /// Each mark the theme names — and the app's mark in place of one it cannot draw.
    func testEachMarkTheThemeNamesAndTheirFallbacks() throws {
        let mark = ThemeWelcomeMarkView(defaultSide: 40)
        for (stated, drawn) in [
            (ThemeWelcome.Mark.logo, ThemeWelcomeMarkView.Shown.logo),
            (.mascot, .mascot),
            (.hidden, .hidden),
            (.app, .app)
        ] {
            AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(
                ThemeWelcome(mark: stated),
                logo: true,
                mascot: true
            ))
            XCTAssertEqual(mark.shown, drawn, "\(stated)")
            XCTAssertEqual(mark.isHidden, drawn == .hidden)
        }
        XCTAssertNil(mark.figure.pose, "a mascot no longer shown holds no pose")

        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(
            ThemeWelcome(mark: .mascot),
            mascot: true
        ))
        XCTAssertNotNil(mark.figure.pose, "the mascot stands in its mood's pose")

        for stated in [ThemeWelcome.Mark.logo, .mascot] {
            AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(ThemeWelcome(mark: stated)))
            XCTAssertEqual(mark.shown, .app, "\(stated) with nothing to draw is the app's mark")
        }
    }

    /// The side is the theme's within its bounds; a mascot keeps its proportions at it.
    func testTheMarkSideIsTheThemesWithinItsBounds() throws {
        let mark = ThemeWelcomeMarkView(defaultSide: 40)
        for (stated, side) in [(72.0, 72.0), (500, 160), (4, 16)] {
            AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(ThemeWelcome(markSize: stated)))
            XCTAssertEqual(mark.side, CGFloat(side), "\(stated)")
            XCTAssertEqual(mark.fittingSize.width, CGFloat(side))
        }
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(
            ThemeWelcome(mark: .mascot, markSize: 64),
            mascot: true
        ))
        XCTAssertEqual(mark.fittingSize.height, 64)
        XCTAssertEqual(mark.fittingSize.width, 48, "the 48×64 mascot keeps its proportions")

        AppThemeLibrary.apply(.system)
        XCTAssertEqual(mark.side, 40, "back to the host's size with the theme")
        XCTAssertEqual(mark.shown, .app)
    }

    // MARK: - Type

    /// With no style the roles are exactly the app's heading and body.
    func testTheWelcomeRolesAreTheAppsUntilAThemeSetsThem() {
        AppThemeLibrary.apply(.system)
        XCTAssertEqual(Design.Typography.welcomeGreeting(), Design.Typography.heading())
        XCTAssertEqual(Design.Typography.welcomeCaption(), Design.Typography.body())
    }

    /// A stated style scales, weighs and faces the line; a family this Mac has wins over a
    /// system design, and one it lacks falls through to it.
    func testTheWelcomeRolesFollowTheThemesStyle() throws {
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(ThemeWelcome(
            greeting: ThemeWelcome.Wording(
                lines: [.init(text: "Hi.")],
                style: .init(scale: 2, weight: .heavy, typeface: .monospaced)
            ),
            caption: ThemeWelcome.Wording(
                lines: [.init(text: "Below.")],
                style: .init(scale: 0.1, fontFamily: "Menlo", typeface: .serif)
            )
        )))
        let greeting = Design.Typography.welcomeGreeting()
        XCTAssertEqual(greeting.pointSize, Design.Typography.heading().pointSize * 2, accuracy: 0.01)
        XCTAssertTrue(greeting.fontDescriptor.symbolicTraits.contains(.monoSpace))
        let caption = Design.Typography.welcomeCaption()
        XCTAssertEqual(caption.familyName, "Menlo")
        XCTAssertEqual(
            caption.pointSize,
            Design.Typography.body().pointSize * 0.5,
            accuracy: 0.01,
            "a scale below the floor is held to it"
        )

        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(ThemeWelcome(
            caption: ThemeWelcome.Wording(
                lines: [.init(text: "Below.")],
                style: .init(fontFamily: "No Such Family Anywhere", typeface: .monospaced)
            )
        )))
        XCTAssertTrue(
            Design.Typography.welcomeCaption().fontDescriptor.symbolicTraits.contains(.monoSpace),
            "a family the Mac lacks falls to the stated design"
        )
    }

    /// A label recording the role takes the next theme's style on the sweep.
    func testTheSweepResolvesTheRoleAgainstTheNextTheme() throws {
        AppThemeLibrary.apply(.system)
        let label = NSTextField(labelWithString: "Hi.")
        label.applyFont(.welcomeGreeting)
        XCTAssertEqual(label.font, Design.Typography.heading())

        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(ThemeWelcome(
            greeting: ThemeWelcome.Wording(lines: [.init(text: "Hi.")], style: .init(scale: 1.5))
        )))
        label.reapplyRecordedFontForTesting()
        XCTAssertEqual(
            label.font?.pointSize ?? 0,
            Design.Typography.heading().pointSize * 1.5,
            accuracy: 0.01
        )
    }

    // MARK: - Render

    /// The three together, light and dark, as the composer stacks them: the ground with a wash
    /// and snow, a veil behind each region, the four marks over a heading, and a box. The PNGs
    /// land in `THREADING_RENDER_OUT` as `theme-welcome-components-<appearance>.png`.
    func testRendersTheComponentsTogether() throws {
        let directory = ThemeWelcomeFixtures.renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(
            ThemeWelcomeFixtures.dressedWelcome(mark: .app),
            logo: true,
            mascot: true
        ))

        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let data: Data? = ThemeParticleHold.withStillFrames {
                let stage = ThemeWelcomeGroundView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
                stage.appearance = appearance
                stage.viewDidChangeEffectiveAppearance()
                let scrim = ThemeWelcomeScrimView(frame: stage.bounds)
                stage.addSubview(scrim)

                let marks = [ThemeWelcome.Mark.app, .logo, .mascot, .hidden].map { stated in
                    let mark = ThemeWelcomeMarkView(defaultSide: 40)
                    mark.previewSide = 56
                    mark.preview = ThemeWelcomeAppearance.mark(
                        ThemeWelcome(mark: stated),
                        appearance: appearance
                    )
                    return mark as NSView
                }
                let row = NSStackView(views: marks)
                row.spacing = Design.Spacing.large
                row.alignment = .bottom
                let heading = NSTextField(labelWithString: "Good evening, Ada.")
                heading.applyFont(.welcomeGreeting)
                heading.textColor = ThemeWelcomeAppearance.ink(
                    .greeting,
                    of: ThemeWelcomeAppearance.welcome(for: appearance),
                    appearance: appearance
                )
                let hero = NSStackView(views: [row, heading])
                hero.orientation = .vertical
                hero.spacing = Design.Spacing.inset
                hero.translatesAutoresizingMaskIntoConstraints = false
                let box = ThemedSurfaceView()
                box.applySurface(fill: Design.Surface.panel, radius: .panel, border: Design.Surface.border)
                box.translatesAutoresizingMaskIntoConstraints = false
                stage.addSubview(hero)
                stage.addSubview(box)
                NSLayoutConstraint.activate([
                    hero.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
                    hero.topAnchor.constraint(equalTo: stage.topAnchor, constant: Design.Spacing.pane),
                    box.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: Design.Spacing.pane),
                    box.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -Design.Spacing.pane),
                    box.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -Design.Spacing.pane),
                    box.heightAnchor.constraint(equalToConstant: 72)
                ])
                var data: Data?
                appearance.performAsCurrentDrawingAppearance {
                    stage.layoutSubtreeIfNeeded()
                    AppThemeRefresh.repaint(stage)
                    scrim.heroRegion = hero.frame
                    scrim.promptRegion = box.frame
                    guard let rep = stage.bitmapImageRepForCachingDisplay(in: stage.bounds) else {
                        return
                    }
                    stage.layer?.backgroundColor = AppThemePalette.current
                        .resolved(.ground, appearance: appearance).cgColor
                    stage.cacheDisplay(in: stage.bounds, to: rep)
                    data = rep.representation(using: .png, properties: [:])
                }
                XCTAssertEqual(scrim.veils.count, 2)
                XCTAssertEqual(
                    marks.compactMap { ($0 as? ThemeWelcomeMarkView)?.shown },
                    [.app, .logo, .mascot, .hidden]
                )
                return data
            }
            try XCTUnwrap(data).write(
                to: directory.appendingPathComponent("theme-welcome-components-\(suffix).png")
            )
        }
    }
}
