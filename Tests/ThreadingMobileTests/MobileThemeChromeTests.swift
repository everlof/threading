import SwiftUI
import ThreadingRemoteKit
import ThreadingExtensionKit
import SwiftTerm
import MetalKit
import UIKit
import XCTest
@testable import ThreadingMobile

@MainActor
final class MobileOptionalThemeRenderingTests: XCTestCase {
    func testReviewedShaderPreparesAndStopsForFrozenHiddenAndOverBudgetStates() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        defer { MobileThemeMetalSurface.forgetWithdrawnShadersForTesting() }
        let (recipe, _) = MobileThemeAssets.evidenceSurface()
        let surface = try XCTUnwrap(MobileThemeMetalSurface(recipe: recipe, source: MobileThemeAssets.evidenceSurfaceSource))
        surface.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        surface.layoutIfNeeded()
        XCTAssertLessThanOrEqual(max(surface.drawableSize.width, surface.drawableSize.height), 1_290)
        XCTAssertEqual(surface.preferredFramesPerSecond, 24)
        XCTAssertNil(surface.hitTest(.zero, with: nil))
        surface.setPresentation(visible: true, moving: true)
        await surface.waitForPreparation()
        XCTAssertFalse(surface.isPaused, "the reviewed fragment must compile through the shared wrapper")
        surface.setPresentation(visible: true, moving: false)
        XCTAssertTrue(surface.isPaused)
        XCTAssertFalse(surface.isHidden)
        surface.setPresentation(visible: false, moving: true)
        XCTAssertTrue(surface.isPaused)
        XCTAssertTrue(surface.isHidden)
        surface.setPresentation(visible: true, moving: true)
        surface.recordGPUTime(0.005)
        surface.recordGPUTime(0.001)
        surface.recordGPUTime(0.005)
        surface.recordGPUTime(0.005)
        XCTAssertFalse(surface.exceedsFrameBudget, "isolated slow frames do not permanently withdraw a surface")
        surface.recordGPUTime(0.005)
        XCTAssertTrue(surface.exceedsFrameBudget)
        XCTAssertTrue(surface.isPaused)
        XCTAssertTrue(surface.isHidden)
        surface.setPresentation(visible: true, moving: true)
        XCTAssertTrue(surface.isPaused, "only replacing the recipe can restore an over-budget shader")
    }

    /// Every pushed page and sheet builds its own surface. A shader withdrawn for its GPU cost
    /// stays withdrawn on all of them, including one already built, until its source changes.
    func testAWithdrawnShaderStaysWithdrawnOnEveryLaterScreen() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        defer { MobileThemeMetalSurface.forgetWithdrawnShadersForTesting() }
        let (recipe, _) = MobileThemeAssets.evidenceSurface()
        let source = MobileThemeAssets.evidenceSurfaceSource
        let covered = try XCTUnwrap(MobileThemeMetalSurface(recipe: recipe, source: source))
        let first = try XCTUnwrap(MobileThemeMetalSurface(recipe: recipe, source: source))
        for _ in 0..<3 { first.recordGPUTime(0.005) }
        XCTAssertTrue(first.exceedsFrameBudget)

        XCTAssertNil(MobileThemeMetalSurface(recipe: recipe, source: source),
                     "the next screen must not rebuild a withdrawn shader")
        covered.setPresentation(visible: true, moving: true)
        XCTAssertTrue(covered.isHidden, "a screen uncovered by a pop must not resume it either")

        let replaced = RemoteThemeSurface(
            sourceDigest: String(repeating: "ab", count: 32), specification: recipe.specification
        )
        XCTAssertNotNil(MobileThemeMetalSurface(recipe: replaced, source: source),
                        "a changed source is a new shader and may be tried again")
    }

    /// With activity reactions off the Mac reads a reactive binding as no reading, so it falls
    /// back to its idle value. The phone used to feed zero, which the mapping then moved.
    func testReactiveBindingsReadTheirFallbackWithReactionsOff() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let defaults = UserDefaults.standard
        let keys = [MobileThemeMotionPreferences.reactionsKey, MobileThemeMotionPreferences.strengthKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let (evidence, _) = MobileThemeAssets.evidenceSurface()
        let recipe = RemoteThemeSurface(sourceDigest: evidence.sourceDigest, specification: .init(
            shaderResource: "usage-rain.metal", preferredFramesPerSecond: 24,
            inputs: [
                .init(name: "count", value: .signal(.workloadWorkingCount,
                    mapping: .init(inputMinimum: 0, inputMaximum: 4, fallback: 0.7))),
                .init(name: "intensity", value: .signal(.workloadIntensity, mapping: .init(fallback: 0.3))),
            ]
        ))
        let surface = try XCTUnwrap(MobileThemeMetalSurface(
            recipe: recipe, source: MobileThemeAssets.evidenceSurfaceSource
        ))
        let theme = RemoteThemePalette(nil)

        defaults.set(false, forKey: keys[0])
        surface.configure(theme: theme, workingCount: 3, texture: nil)
        XCTAssertEqual(Array(surface.inputUniformsForTesting.prefix(2)), [0.7, 0.3])

        defaults.set(true, forKey: keys[0])
        defaults.set(100, forKey: keys[1])
        surface.configure(theme: theme, workingCount: 3, texture: nil)
        XCTAssertEqual(surface.inputUniformsForTesting[0], 0.75, accuracy: 0.0001)
        XCTAssertEqual(Double(surface.inputUniformsForTesting[1]),
                       MobileThemeMotionPreferences.reaction(workingCount: 3), accuracy: 0.0001)
    }

    /// The time-of-day binding is read per frame, against the day's real length.
    func testDayClockFollowsTheClockAcrossMidnight() throws {
        var clock = MobileThemeDayClock()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let noon = try XCTUnwrap(calendar.date(byAdding: .hour, value: 12, to: start))
        let length = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start)).timeIntervalSince(start)
        XCTAssertEqual(clock.fraction(at: noon), noon.timeIntervalSince(start) / length, accuracy: 0.0001)
        let nextMorning = try XCTUnwrap(calendar.date(byAdding: .hour, value: 30, to: start))
        XCTAssertLessThan(clock.fraction(at: nextMorning), 0.5, "a new day starts the fraction again")
    }

    func testTerminalGlowUsesMetalAndLowPowerRetiresItsAdditionalPasses() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let view = RemoteTerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let window = UIWindow(frame: view.bounds)
        window.addSubview(view)
        let theme = RemoteTerminalThemeDTO(id: "glow", name: "Glow", foreground: "#00FF80",
            background: "#101010", cursor: "#FFFFFF", selection: "#224422",
            ansi: Array(repeating: "#00FF80", count: 16), glow: .init(radius: 4, opacity: 0.6))
        view.noteAppliedTheme(theme)
        view.refreshThemeGlow(lowPower: false)
        XCTAssertEqual(view.textGlow, TerminalTextGlow(radius: 4, opacity: 0.6))
        XCTAssertTrue(view.isUsingMetalRenderer)
        view.refreshThemeGlow(lowPower: true)
        XCTAssertNil(view.textGlow)
        XCTAssertFalse(view.isUsingMetalRenderer)
        view.refreshThemeGlow(lowPower: false)
        XCTAssertTrue(view.isUsingMetalRenderer)
        view.noteAppliedTheme(nil)
        XCTAssertNil(view.textGlow)
        XCTAssertFalse(view.isUsingMetalRenderer)
        view.removeFromSuperview()
    }
}

@MainActor
final class MobileThemeIdentityInkTests: XCTestCase {
    func testTranscriptReadingSurfacesStayOpaqueOverThemeDecoration() {
        let theme = RemoteThemePalette(.init(id: "reading", name: "Reading", mode: .dark,
            colors: ["ground": "#101020", "control_resting": "#FFFFFF12"],
            material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1)))
        XCTAssertEqual(theme.uiConversationGround.cgColor.alpha, 1)
        XCTAssertEqual(theme.uiUserMessageSurface.cgColor.alpha, 1)
        XCTAssertNotEqual(theme.uiUserMessageSurface, theme.uiControlResting)
    }

    /// Thinking, notice, tool and permission rows stand on the moving backdrop too. A System
    /// theme's panel is a faint wash, so each row's plate must be opaque whatever the role says.
    func testEveryTranscriptRowStandsOnAnOpaquePlateOverADecoratedGround() throws {
        let decorated = RemoteThemePalette(.init(id: "wash", name: "Wash", mode: .dark,
            colors: ["ground": "#101020", "panel": "#FFFFFF10"],
            material: .init(panelRadius: 9, controlRadius: 4, borderWidth: 1,
                backdropGradient: .init(stops: [.init(color: "#101020", position: 0),
                                                .init(color: "#304050", position: 1)],
                                        angleDegrees: 135, drift: nil))))
        XCTAssertTrue(decorated.hasBackdropDecoration)
        let thinking = RemoteExpandableMessageView(
            title: "Reasoning", text: "Because", isExpanded: true, theme: decorated, toggle: {}
        )
        let notice = RemoteNoticeMessageView(
            row: .init(id: "notice", kind: .notice, text: "Heads up"), theme: decorated
        )
        let tool = RemoteToolMessageView(
            row: .init(id: "tool", kind: .tool, toolName: "Bash", summary: "ls"),
            isExpanded: false, theme: decorated, toggle: {}
        )
        let permission = RemoteConversationPermissionCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        permission.configure(
            permission: .init(id: "permission", toolName: "Bash", summary: "rm -rf build"),
            theme: decorated, decide: { _ in }
        )
        let permissionPanel = try XCTUnwrap(permission.contentView.subviews.first)
        for (name, view) in [("thinking", thinking as UIView), ("notice", notice),
                             ("tool", tool), ("permission", permissionPanel)] {
            XCTAssertEqual(view.backgroundColor?.cgColor.alpha, 1, "\(name) lets the backdrop through")
        }
        XCTAssertEqual(thinking.layer.cornerRadius, 9, "a reading plate over decoration is a card")
        XCTAssertEqual(notice.layer.cornerRadius, 9)

        let plain = RemoteThemePalette(.init(id: "plain", name: "Plain", mode: .dark,
            colors: ["ground": "#101020"], material: .init(panelRadius: 9, controlRadius: 4, borderWidth: 1)))
        let plainNotice = RemoteNoticeMessageView(
            row: .init(id: "notice", kind: .notice, text: "Heads up"), theme: plain
        )
        XCTAssertEqual(plainNotice.layer.cornerRadius, 0, "over a plain ground the plate is the ground")
        XCTAssertEqual(plainNotice.backgroundColor, plain.uiConversationGround)
    }

    /// A theme's font and typeface reach titles and chrome only. Content steps back out of the
    /// root's statement: under a monospaced theme, content text is proportional again.
    func testContentTypographyStepsOutOfTheThemesTypeface() throws {
        let theme = RemoteThemePalette(.init(id: "mono", name: "Mono", mode: .dark,
            colors: ["ground": "#000000", "label": "#FFFFFF"],
            material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1, typeface: .monospaced)))
        func inkRatio(content: Bool) throws -> Double {
            func width(_ text: String) throws -> Int {
                let line = Text(verbatim: text).fixedSize()
                let view = Group {
                    if content { line.mobileContentTypography() } else { line }
                }.mobileTheme(theme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                return try XCTUnwrap(renderer.cgImage).width
            }
            return Double(try width("iiiiiiii")) / Double(try width("WWWWWWWW"))
        }
        XCTAssertGreaterThan(try inkRatio(content: false), 0.85, "chrome takes the monospaced hint")
        XCTAssertLessThan(try inkRatio(content: true), 0.6, "content keeps the platform's typography")
    }

    func testSystemTypefaceHintUsesTheNativeChromeFontDesign() {
        let theme = RemoteThemePalette(.init(id: "mono", name: "Mono", mode: .dark,
            colors: [:], material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1,
                                        typeface: .monospaced)))
        let font = theme.chromeFont(forTextStyle: .caption1)
        let narrowWidth = ("iiii" as NSString).size(withAttributes: [.font: font]).width
        let wideWidth = ("WWWW" as NSString).size(withAttributes: [.font: font]).width
        // Preferred text-style descriptors can omit traitMonoSpace even for SF Mono.
        // Measure the glyphs the label actually draws instead of that advisory flag.
        XCTAssertEqual(narrowWidth, wideWidth, accuracy: 0.01, font.fontName)
        XCTAssertEqual(font.pointSize, UIFont.preferredFont(forTextStyle: .caption1).pointSize)
    }

    func testClaudeMarkTakesThemeInkAndResolvedAccountChoicesKeepTheirPixels() throws {
        func palette(_ tinted: Bool) -> RemoteThemePalette {
            RemoteThemePalette(.init(id: "ink", name: "Ink", mode: .dark,
                colors: ["accent": "#00FF00", "panel": "#101010"],
                material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1,
                                identityMarks: tinted ? "tinted" : "natural")))
        }
        let greenMark = try render(MobileAgentMarkGlyph(identity: .claude).mobileTheme(palette(true)))
        let naturalMark = try render(MobileAgentMarkGlyph(identity: .claude).mobileTheme(palette(false)))
        XCTAssertGreaterThan(try greenPixels(greenMark), 30)
        XCTAssertEqual(try greenPixels(naturalMark), 0)
        func chip(_ color: String) -> RemoteSessionAccountDTO {
            .init(name: "Account", glyph: "D", isEmoji: false, hue: nil,
                  backgroundHex: color, foregroundHex: "#FFFFFF", badgeHidden: false)
        }
        let generated = try render(MobileAccountChip(account: chip("#00FF00")).mobileTheme(palette(true)))
        let chosen = try render(MobileAccountChip(account: chip("#FF0000")).mobileTheme(palette(true)))
        XCTAssertGreaterThan(try greenPixels(generated), 10)
        XCTAssertEqual(try greenPixels(chosen), 0)
    }

    private func render<V: View>(_ view: V) throws -> CGImage {
        let renderer = ImageRenderer(content: view.padding(4))
        renderer.scale = 3
        return try XCTUnwrap(renderer.cgImage)
    }

    private func greenPixels(_ image: CGImage) throws -> Int {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        return stride(from: 0, to: image.width * image.height * 4, by: 4).filter {
            bytes[$0 + 1] > 160 && bytes[$0] < 80 && bytes[$0 + 2] < 80 && bytes[$0 + 3] > 200
        }.count
    }
}

@MainActor
final class MobileThemeBackdropTests: XCTestCase {
    func testCompleteMovingThemeSurvivesTheReconnectCache() throws {
        let suite = "backdrop-cache-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MobileThemeCacheStore(defaults: defaults)
        let source = try XCTUnwrap(theme(drift: .init()).source)
        XCTAssertTrue(store.remember(source, for: "paired-mac"))
        XCTAssertEqual(MobileThemeCacheStore(defaults: defaults).theme(for: "paired-mac"), source)
    }

    /// A newer Mac may state a drift or a stop count this build does not accept. The renderer
    /// already declines to draw it; the cache must still keep the theme rather than calling the
    /// archive corrupt and reporting that saved themes outgrew their storage.
    func testADecorationFromANewerMacIsStillCached() throws {
        let suite = "backdrop-cache-newer-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MobileThemeCacheStore(defaults: defaults)
        let wider = try XCTUnwrap(theme(drift: .init(duration: 400, distance: 0.6), count: 12).source)
        XCTAssertTrue(store.remember(wider, for: "paired-mac"))
        XCTAssertNil(store.recoveryMessage)
        XCTAssertEqual(MobileThemeCacheStore(defaults: defaults).theme(for: "paired-mac"), wider)

        let backdrop = MobileThemeBackdropView()
        backdrop.apply(RemoteThemePalette(wider))
        XCTAssertFalse(backdrop.isAnimating, "what this build cannot draw it does not animate")
    }

    func testRecipeChangesAndLifecycleLeaveAStaticLegibleFallback() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let backdrop = MobileThemeBackdropView(frame: window.bounds)
        backdrop.permitsMotion = { true }
        backdrop.sceneIsActive = { _ in true }
        window.addSubview(backdrop)
        backdrop.isPresentationActive = true
        backdrop.apply(theme(drift: .init()))
        XCTAssertTrue(backdrop.showsGradient)
        XCTAssertTrue(backdrop.isAnimating)
        XCTAssertFalse(backdrop.isUserInteractionEnabled)
        XCTAssertTrue(backdrop.accessibilityElementsHidden)
        backdrop.isPresentationActive = false
        XCTAssertFalse(backdrop.isAnimating)
        backdrop.isPresentationActive = true
        XCTAssertTrue(backdrop.isAnimating)
        backdrop.permitsMotion = { false }
        backdrop.refreshMotion()
        XCTAssertFalse(backdrop.isAnimating)
        XCTAssertTrue(backdrop.showsGradient)
        backdrop.permitsMotion = { true }
        backdrop.refreshMotion()
        XCTAssertTrue(backdrop.isAnimating)
        backdrop.apply(theme(drift: nil))
        XCTAssertFalse(backdrop.isAnimating)
        XCTAssertTrue(backdrop.showsGradient)
        backdrop.apply(theme(drift: .init()), frozenPhase: 0.25)
        XCTAssertFalse(backdrop.isAnimating)
        backdrop.apply(RemoteThemePalette(nil))
        XCTAssertFalse(backdrop.isAnimating)
        XCTAssertFalse(backdrop.showsGradient)
        backdrop.apply(theme(drift: .init()))
        backdrop.removeFromSuperview()
        XCTAssertFalse(backdrop.isAnimating)
    }

    func testInvalidDecorationDoesNotReplaceThePaletteOrStartAnAnimation() {
        let backdrop = MobileThemeBackdropView()
        backdrop.apply(theme(drift: .init(duration: 0)))
        XCTAssertTrue(backdrop.showsGradient)
        XCTAssertFalse(backdrop.isAnimating)
        backdrop.apply(theme(drift: .init(), count: 1000))
        XCTAssertFalse(backdrop.showsGradient)
        XCTAssertEqual(backdrop.layer.sublayers?.count, 1)
    }

    func testNavigationHandsOneBackdropLeaseBackOnPop() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let first = MobileThemeBackdropView(frame: window.bounds)
        let second = MobileThemeBackdropView(frame: window.bounds)
        for view in [first, second] {
            view.permitsMotion = { true }; view.sceneIsActive = { _ in true }
            window.addSubview(view); view.apply(theme(drift: .init()))
        }
        first.isPresentationActive = true
        XCTAssertTrue(first.isAnimating)
        second.isPresentationActive = true
        XCTAssertFalse(first.isAnimating)
        XCTAssertTrue(second.isAnimating)
        second.isPresentationActive = false
        XCTAssertTrue(first.isAnimating)
        XCTAssertFalse(second.isAnimating)
        first.removeFromSuperview()
        XCTAssertFalse(first.isAnimating)
    }

    /// Work quickens the drift through the layer's clock. Restating the animation with a new
    /// duration restarted it at phase zero, so the gradient snapped when a session began work.
    func testWorkloadQuickensTheDriftWithoutRestartingIt() throws {
        let defaults = UserDefaults.standard
        let keys = [MobileThemeMotionPreferences.reactionsKey, MobileThemeMotionPreferences.strengthKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: keys[0])
        defaults.set(200, forKey: keys[1])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let backdrop = MobileThemeBackdropView(frame: window.bounds)
        backdrop.permitsMotion = { true }; backdrop.sceneIsActive = { _ in true }
        window.addSubview(backdrop)
        defer { backdrop.removeFromSuperview() }
        backdrop.isPresentationActive = true
        backdrop.apply(theme(drift: .init(duration: 12)))
        let gradient = try XCTUnwrap(backdrop.layer.sublayers?.first as? CAGradientLayer)
        let running = try XCTUnwrap(gradient.animation(forKey: ThemeGradientAnimator.animationKey))
        let before = gradient.convertTime(CACurrentMediaTime(), from: nil)

        backdrop.workingCount = 3

        XCTAssertTrue(gradient.animation(forKey: ThemeGradientAnimator.animationKey) === running,
                      "the running keyframes continue rather than restarting at phase zero")
        XCTAssertEqual(gradient.convertTime(CACurrentMediaTime(), from: nil), before, accuracy: 0.05,
                       "the layer's clock continues from the same instant")
        XCTAssertEqual(Double(gradient.speed), 1.5, accuracy: 0.0001,
                       "full reaction would double a 12 s drift, but it stops at the 8 s floor")
        backdrop.workingCount = 0
        XCTAssertEqual(gradient.speed, 1)
        XCTAssertTrue(gradient.animation(forKey: ThemeGradientAnimator.animationKey) === running)
    }

    /// Reduce Transparency and Increase Contrast keep the authored gradient and drop what is
    /// drawn over it.
    func testAccessibilityGroundDropsParticlesAndKeepsTheGradient() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let backdrop = MobileThemeBackdropView(frame: window.bounds)
        backdrop.permitsMotion = { true }; backdrop.sceneIsActive = { _ in true }
        var plain = false
        backdrop.prefersPlainGround = { plain }
        window.addSubview(backdrop)
        defer { backdrop.removeFromSuperview() }
        backdrop.isPresentationActive = true
        backdrop.apply(RemoteThemePalette(RemoteThemeDTO(
            id: "plain-ground", name: "Plain ground", mode: .dark,
            colors: ["accent": "#00FF88", "ground": "#101010"],
            material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1,
                backdropGradient: .init(stops: [.init(color: "#101020", position: 0),
                                                .init(color: "#203040", position: 1)],
                                        angleDegrees: 135, drift: .init()),
                particles: .init(style: .snow, density: 1, speed: 1)))))
        func emitters() -> Int { backdrop.layer.sublayers?.filter { $0 is CAEmitterLayer }.count ?? 0 }
        XCTAssertEqual(emitters(), 1)

        plain = true
        NotificationCenter.default.post(name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        XCTAssertEqual(emitters(), 0)
        XCTAssertTrue(backdrop.showsGradient)
        XCTAssertTrue(backdrop.isAnimating, "transparency is not motion; the drift continues")

        plain = false
        NotificationCenter.default.post(name: UIAccessibility.darkerSystemColorsStatusDidChangeNotification, object: nil)
        XCTAssertEqual(emitters(), 1)
    }

    /// The motion switch may be written from any thread; only a change to a decoration value
    /// reaches the backdrop, and it arrives on the main actor.
    func testPreferenceWritesReachTheBackdropOnMainAndOnlyWhenTheyChange() async throws {
        let defaults = UserDefaults.standard
        let key = MobileThemeMotionPreferences.motionKey
        let previous = defaults.object(forKey: key)
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.set(true, forKey: key)
        try await Task.sleep(for: .milliseconds(50))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let backdrop = MobileThemeBackdropView(frame: window.bounds)
        backdrop.permitsMotion = { MobileThemeMotionPreferences.motionEnabled }
        backdrop.sceneIsActive = { _ in true }
        window.addSubview(backdrop)
        defer { backdrop.removeFromSuperview() }
        backdrop.isPresentationActive = true
        backdrop.apply(theme(drift: .init()))
        XCTAssertTrue(backdrop.isAnimating)

        let unrelated = expectation(forNotification: MobileThemeMotionPreferences.didChange, object: nil)
        unrelated.isInverted = true
        await Task.detached { UserDefaults.standard.set(UUID().uuidString, forKey: "unrelated-test-key") }.value
        await Task.detached { UserDefaults.standard.removeObject(forKey: "unrelated-test-key") }.value
        await fulfillment(of: [unrelated], timeout: 0.2)

        let changed = expectation(forNotification: MobileThemeMotionPreferences.didChange, object: nil) { _ in
            Thread.isMainThread
        }
        await Task.detached { UserDefaults.standard.set(false, forKey: key) }.value
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertFalse(backdrop.isAnimating)
    }

    /// The Workspace sheet over a pushed page: one backdrop in the sheet, and it is the one that
    /// moves. A second, outer backdrop competed for the window's lease and could animate behind
    /// the list while the list's own stood still.
    func testWorkspaceSheetOverAPushedStackMovesOnlyItsVisibleBackdrop() throws {
        let motionKey = MobileThemeMotionPreferences.motionKey
        let previous = UserDefaults.standard.object(forKey: motionKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: motionKey) }
            else { UserDefaults.standard.removeObject(forKey: motionKey) }
        }
        UserDefaults.standard.set(true, forKey: motionKey)
        guard !UIAccessibility.isReduceMotionEnabled, !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            throw XCTSkip("system motion is held on this device")
        }
        let theme = theme(drift: .init())
        let model = WorkspaceSheetFixture()
        let controller = UIHostingController(rootView: WorkspaceSheetHost(model: model, theme: theme))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func backdrops(in view: UIView) -> [MobileThemeBackdropView] {
            ((view as? MobileThemeBackdropView).map { [$0] } ?? []) + view.subviews.flatMap(backdrops(in:))
        }
        func settle(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }

        settle { backdrops(in: window).contains(where: \.isAnimating) }
        let root = try XCTUnwrap(backdrops(in: window).first(where: \.isAnimating))
        model.path = ["pushed"]
        settle { backdrops(in: window).contains { $0 !== root && $0.isAnimating } }
        let pushed = try XCTUnwrap(backdrops(in: window).first { $0 !== root && $0.isAnimating },
                                   "the pushed page owns the lease")
        XCTAssertFalse(root.isAnimating, "the covered page gives it up")

        model.showsSheet = true
        settle { controller.presentedViewController != nil }
        let sheet = try XCTUnwrap(controller.presentedViewController)
        settle { backdrops(in: sheet.view).contains(where: \.isAnimating) }
        let inSheet = backdrops(in: sheet.view)
        XCTAssertEqual(inSheet.count, 1, "the Workspace sheet has exactly one backdrop")
        XCTAssertEqual(inSheet.first?.isAnimating, true, "and it is the one that moves")
        XCTAssertTrue(sheet.view.window === window)
        XCTAssertEqual(backdrops(in: window).filter(\.isAnimating).count, 1,
                       "one decorative motion in the window")

        XCTAssertFalse(pushed.isAnimating, "the sheet covers the pushed page")

        model.showsSheet = false
        settle { controller.presentedViewController == nil && pushed.isAnimating }
        XCTAssertTrue(pushed.isAnimating, "dismissing hands the lease back")
    }

    func testExtensionBackdropSwitchWithholdsTheShaderRequest() throws {
        let key = MobileThemeMotionPreferences.extensionBackdropsKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let (surface, source) = MobileThemeAssets.evidenceSurface()
        let texture = RemoteThemeAsset(slot: MobileThemeMotionPreferences.surfaceTextureSlot,
            digest: String(repeating: "cd", count: 32), byteCount: 64, mediaType: "image/png",
            pixelWidth: 4, pixelHeight: 4)
        let picture = RemoteThemeAsset(slot: "backdrop", digest: String(repeating: "ef", count: 32),
            byteCount: 64, mediaType: "image/png", pixelWidth: 4, pixelHeight: 4)
        let theme = RemoteThemeDTO(id: "shader", name: "Shader", mode: .dark, colors: [:],
            material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1),
            assets: [source, texture, picture], surface: surface)
        XCTAssertNotNil(theme.surface)

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(MobileThemeMotionPreferences.extensionBackdropsEnabled, "on by default")
        XCTAssertEqual(MobileThemeMotionPreferences.assetRequest(for: theme), theme)

        UserDefaults.standard.set(false, forKey: key)
        let request = try XCTUnwrap(MobileThemeMotionPreferences.assetRequest(for: theme))
        XCTAssertNil(request.surface)
        XCTAssertEqual(request.assets?.map(\.slot), ["backdrop"], "neither the shader nor its texture is fetched")
        XCTAssertEqual(request.colors, theme.colors)
    }

    func testEveryParticleStyleHasBoundedCellsAndAStillUnderReducedMotion() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let backdrop = MobileThemeBackdropView(frame: window.bounds)
        backdrop.permitsMotion = { true }; backdrop.sceneIsActive = { _ in true }
        window.addSubview(backdrop); backdrop.isPresentationActive = true
        for style in RemoteThemeParticles.Style.allCases {
            let source = RemoteThemeDTO(id: "particles", name: "Particles", mode: .dark,
                colors: ["accent": "#00FF88", "ground": "#101010"],
                material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1,
                    particles: .init(style: style, density: 1, speed: 3)))
            backdrop.apply(RemoteThemePalette(source))
            let emitter = try XCTUnwrap(backdrop.layer.sublayers?.compactMap { $0 as? CAEmitterLayer }.first)
            let cells = try XCTUnwrap(emitter.emitterCells)
            XCTAssertEqual(cells.count, 1)
            XCTAssertNotNil(cells.first?.contents)
            XCTAssertLessThanOrEqual(cells.reduce(Float(0)) {
                $0 + $1.birthRate * ($1.lifetime + $1.lifetimeRange)
            }, 120.001)
            XCTAssertTrue(cells.allSatisfy { $0.lifetime + $0.lifetimeRange <= 24 })
            backdrop.permitsMotion = { false }; backdrop.refreshMotion()
            XCTAssertTrue(emitter.isHidden)
            XCTAssertEqual(emitter.speed, 0)
            XCTAssertEqual(backdrop.layer.sublayers?.last?.isHidden, false)
            backdrop.permitsMotion = { true }; backdrop.refreshMotion()
            XCTAssertFalse(emitter.isHidden)
        }
    }

    func testPhoneReactionsAreClampedAndOffByDefault() {
        let defaults = UserDefaults.standard
        let keys = [MobileThemeMotionPreferences.reactionsKey, MobileThemeMotionPreferences.strengthKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: keys[0])
        defaults.set(200, forKey: keys[1])
        XCTAssertEqual(MobileThemeMotionPreferences.reaction(workingCount: 3), 0)
        defaults.set(true, forKey: keys[0])
        XCTAssertEqual(MobileThemeMotionPreferences.reaction(workingCount: 3), 1)
        defaults.set(0, forKey: keys[1])
        XCTAssertEqual(MobileThemeMotionPreferences.reaction(workingCount: 3), 0)
    }

    private func theme(drift: ThemeGradientDrift?, count: Int = 2) -> RemoteThemePalette {
        RemoteThemePalette(RemoteThemeDTO(
            id: "backdrop-test", name: "Backdrop test", mode: .dark,
            colors: ["ground": "#101020", "label": "#FFFFFF"],
            material: .init(panelRadius: 10, controlRadius: 5, borderWidth: 1,
                backdropGradient: .init(stops: (0..<count).map {
                    .init(color: $0 == 0 ? "#101020" : "#203040", position: Double($0) / Double(count - 1))
                }, angleDegrees: 135, drift: drift))
        ))
    }
}

final class MobileFloatingSurfaceTests: XCTestCase {
    private struct ColorComponents: Equatable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    func testFloatingChromeUsesItsDedicatedRoleInsteadOfTheTranslucentPanel() throws {
        let palette = RemoteThemePalette(theme(colors: [
            "ground": "#101820",
            "panel": "#FFFFFF0D",
            "elevated": "#263746",
            "floating_surface": "#304A60",
        ]))

        XCTAssertEqual(
            try components(of: palette.uiFloatingSurface),
            try components(of: UIColor(remoteHex: "#304A60")!)
        )
    }

    func testTranslucentFloatingChromeIsFlattenedOverTheThemeGround() throws {
        let palette = RemoteThemePalette(theme(colors: [
            "ground": "#000000",
            "floating_surface": "#FFFFFF80",
        ]))
        let components = try components(of: palette.uiFloatingSurface)

        XCTAssertEqual(components.red, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(components.green, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(components.blue, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(components.alpha, 1, accuracy: 0.001)
    }

    func testAnOlderHostFallsBackToElevatedRatherThanPanel() throws {
        let palette = RemoteThemePalette(theme(colors: [
            "ground": "#101820",
            "panel": "#FFFFFF0D",
            "elevated": "#263746",
        ]))

        XCTAssertEqual(
            try components(of: palette.uiFloatingSurface),
            try components(of: UIColor(remoteHex: "#263746")!)
        )
    }

    private func theme(colors: [String: String]) -> RemoteThemeDTO {
        RemoteThemeDTO(
            id: "floating-surface-test",
            name: "Floating surface test",
            mode: .dark,
            colors: colors,
            material: RemoteThemeDTO.Material(
                panelRadius: 20,
                controlRadius: 10,
                borderWidth: 1
            )
        )
    }

    private func components(
        of color: UIColor
    ) throws -> ColorComponents {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            throw XCTSkip("The test colour did not resolve in sRGB")
        }
        return ColorComponents(red: red, green: green, blue: blue, alpha: alpha)
    }
}

final class MobileInputPlaceholderTests: XCTestCase {
    func testLegibleAuthoredSecondaryInkIsPreserved() {
        let palette = theme(secondary: "#B3A292", tertiary: "#303030")
        XCTAssertEqual(palette.uiInputPlaceholder, UIColor(remoteHex: "#B3A292"))
        XCTAssertNotEqual(palette.uiInputPlaceholder, palette.uiTertiaryLabel)
    }

    func testTranslucentSecondaryInkIsStrengthenedOverThePanel() throws {
        let palette = theme(secondary: "#FFFFFF33", tertiary: "#303030")
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(palette.uiInputPlaceholder.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertGreaterThan(alpha, 0.2)
        XCTAssertLessThan(alpha, 1)
        XCTAssertEqual(red, 1, accuracy: 0.001)
        XCTAssertEqual(green, 1, accuracy: 0.001)
        XCTAssertEqual(blue, 1, accuracy: 0.001)
    }

    func testOpaqueUnreadableSecondaryFallsBackToThemeLabel() {
        let palette = theme(secondary: "#303030", tertiary: "#303030")
        XCTAssertEqual(palette.uiInputPlaceholder, palette.uiLabel)
    }

    private func theme(secondary: String, tertiary: String) -> RemoteThemePalette {
        RemoteThemePalette(RemoteThemeDTO(
            id: "placeholder-test", name: "Placeholder test", mode: .dark,
            colors: [
                "ground": "#101010", "panel": "#202020", "label": "#FFFFFF",
                "secondary_label": secondary, "tertiary_label": tertiary,
            ],
            material: .init(panelRadius: 12, controlRadius: 8, borderWidth: 1)
        ))
    }
}

@MainActor
final class MobileThemedPopoverChromeTests: XCTestCase {
    func testThemeDoesNotReplaceUIKitManagedShadowPath() throws {
        let view = MobileThemedPopoverBackgroundView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 80)
        )
        view.arrowDirection = .down
        view.apply(.init(
            fill: .white,
            border: .black,
            borderWidth: 2,
            cornerRadius: 0
        ))
        view.layoutIfNeeded()

        let shadowBounds = try XCTUnwrap(view.layer.shadowPath).boundingBoxOfPath
        XCTAssertGreaterThan(
            shadowBounds.minX,
            view.bounds.minX,
            "the theme must not replace UIKit's inset shadow with its body outline"
        )
        XCTAssertLessThan(
            shadowBounds.maxY,
            view.bounds.maxY,
            "UIKit's shadow excludes the arrow instead of following the theme's full outline"
        )
    }

    func testThemeRadiusReachesTheOuterCornerAndArrowHasNoBodySeam() throws {
        let view = MobileThemedPopoverBackgroundView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 80)
        )
        view.arrowDirection = .down
        view.arrowOffset = 0
        view.apply(.init(
            fill: .black,
            border: .white,
            borderWidth: 2,
            cornerRadius: 3
        ))
        view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }

        XCTAssertGreaterThan(
            try rgba(in: image, at: CGPoint(x: 3, y: 1)).alpha,
            200,
            "a 3-point authored radius must not retain UIKit's large popover corner"
        )
        XCTAssertGreaterThan(
            try rgba(in: image, at: CGPoint(x: 10, y: 67)).red,
            200,
            "the ordinary bottom edge keeps the theme border"
        )
        XCTAssertLessThan(
            try rgba(in: image, at: CGPoint(x: 50, y: 67)).red,
            40,
            "the arrow repaints the body border at its base instead of leaving an internal rule"
        )
    }

    private func rgba(in image: UIImage, at point: CGPoint) throws -> RGBA {
        let cgImage = try XCTUnwrap(image.cgImage)
        let cropped = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: Int(point.x),
            y: Int(point.y),
            width: 1,
            height: 1
        )))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return RGBA(red: bytes[0], alpha: bytes[3])
    }

    private struct RGBA {
        let red: UInt8
        let alpha: UInt8
    }
}

@MainActor
final class MobileRootBackdropTests: XCTestCase {
    /// During an interactive pop, SwiftUI lays the destination out only above the still-focused
    /// keyboard. A background attached to that content stops at the same height, exposing the
    /// hosting view below. The root backdrop must keep painting independently of that short view.
    func testBackdropPaintsBelowKeyboardSizedNavigationContent() throws {
        let theme = RemoteThemePalette(.init(id: "root-ground", name: "Root ground", mode: .dark,
            colors: ["ground": "#1F1F1F"],
            material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1)))
        let root = MobileRootBackdrop {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 520)
        }.mobileTheme(theme)
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .black
        let window = hostedWindow(rootViewController: controller)
        defer { window.isHidden = true }

        let screenshot = UIGraphicsImageRenderer(
            bounds: window.bounds,
            format: onePixelPointFormat
        ).image { context in
            window.layer.render(in: context.cgContext)
        }
        let pixel = try rgba(in: screenshot, at: CGPoint(x: 20, y: 820))

        XCTAssertEqual(pixel.red, 31, accuracy: 1)
        XCTAssertEqual(pixel.green, 31, accuracy: 1)
        XCTAssertEqual(pixel.blue, 31, accuracy: 1)
        XCTAssertEqual(pixel.alpha, 255, accuracy: 1)
    }

    private var onePixelPointFormat: UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return format
    }

    private func hostedWindow(rootViewController: UIViewController) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
        return window
    }

    private func rgba(in image: UIImage, at point: CGPoint) throws -> RGBA {
        let cgImage = try XCTUnwrap(image.cgImage)
        let cropped = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: Int(point.x),
            y: Int(point.y),
            width: 1,
            height: 1
        )))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return RGBA(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes[3])
    }

    private struct RGBA {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }
}

/// The one property iOS lets an authored theme reach on the system keyboard.
///
/// There is no API for tinting keycaps, so `UIKeyboardAppearance` is the whole seam and the only
/// thing to get right is which side of the line a themed background lands on. These pin the
/// saturated cases, where a channel average and perceived luminance disagree most, and pin the
/// keyboard to the same crossover the accent's ink already uses.
final class MobileKeyboardAppearanceTests: XCTestCase {
    func testApplicationSurfaceModesResolveToExplicitKeyboardAppearances() {
        XCTAssertEqual(MobileKeyboardAppearance.matching(.light), .light)
        XCTAssertEqual(MobileKeyboardAppearance.matching(.dark), .dark)
    }

    func testADarkTerminalKeepsTheDarkKeyboard() {
        XCTAssertEqual(
            MobileKeyboardAppearance.over(UIColor(remoteHex: "#0A0C10")!),
            .dark
        )
    }

    func testAPaperTerminalGetsTheLightKeyboard() {
        XCTAssertEqual(
            MobileKeyboardAppearance.over(UIColor(remoteHex: "#FBF7EE")!),
            .light
        )
    }

    /// A saturated mid-tone, where a channel average and perceived luminance are furthest apart.
    /// Blue contributes least of the three to what the eye reads as brightness, so this stays a
    /// dark background however high its blue channel runs.
    func testASaturatedDeepBlueIsReadAsDark() {
        let background = UIColor(remoteHex: "#12306B")!
        XCTAssertEqual(MobileKeyboardAppearance.over(background), .dark)
        XCTAssertLessThan(
            background.remoteRelativeLuminance ?? 1,
            MobileKeyboardAppearance.lightThreshold
        )
    }

    /// A saturated yellow is the mirror image: bright to the eye, and it needs the light keyboard
    /// even though two of its three channels are at the top of their range.
    func testASaturatedYellowIsReadAsLight() {
        XCTAssertEqual(
            MobileKeyboardAppearance.over(UIColor(remoteHex: "#F2C744")!),
            .light
        )
    }

    /// The accent's ink and the keyboard's appearance answer the same question — "does this
    /// colour read as light?" — so they share one reading of luminance rather than each carrying
    /// a copy of the maths that can drift apart.
    func testTheAccentInkAndTheKeyboardCrossOverTogether() {
        for hex in ["#0A0C10", "#12306B", "#F2C744", "#FBF7EE", "#FFFFFF", "#000000"] {
            let palette = RemoteThemePalette(theme(accent: hex))
            let inkIsDark = palette.uiAccentForeground == UIColor.black
            let backgroundIsLight = MobileKeyboardAppearance.over(
                UIColor(remoteHex: hex)!
            ) == .light
            XCTAssertEqual(
                inkIsDark,
                backgroundIsLight,
                "\(hex) must be light for both the ink beside it and the keyboard under it"
            )
        }
    }

    /// A dark navigation bar may carry a pale control plate. The OpenAI knot sits on that plate,
    /// so its ink follows the plate rather than the page's secondary label.
    func testMonochromeControlMarkContrastsWithLightAndTranslucentPlates() throws {
        let palePlate = RemoteThemePalette(theme(colors: [
            "surface": "#071625",
            "control_resting": "#B9C1CF",
            "secondary_label": "#B9C1CF",
        ]))
        XCTAssertEqual(
            try XCTUnwrap(UIColor(palePlate.controlForeground).remoteRelativeLuminance),
            0,
            accuracy: 0.001
        )

        let darkWash = RemoteThemePalette(theme(colors: [
            "surface": "#071625",
            "control_resting": "#FFFFFF12",
        ]))
        XCTAssertEqual(
            try XCTUnwrap(UIColor(darkWash.controlForeground).remoteRelativeLuminance),
            1,
            accuracy: 0.001
        )
    }

    private func theme(colors: [String: String]) -> RemoteThemeDTO {
        RemoteThemeDTO(
            id: "control-mark-test",
            name: "Control mark test",
            mode: .dark,
            colors: colors,
            material: RemoteThemeDTO.Material(
                panelRadius: 20,
                controlRadius: 10,
                borderWidth: 1
            )
        )
    }

    private func theme(accent: String) -> RemoteThemeDTO {
        RemoteThemeDTO(
            id: "test",
            name: "Test",
            mode: .dark,
            colors: ["accent": accent],
            material: RemoteThemeDTO.Material(
                panelRadius: 20,
                controlRadius: 10,
                borderWidth: 1
            )
        )
    }
}

@MainActor
final class SessionDraftKeyboardAppearanceTests: XCTestCase {
    func testEditorPinsItsLightAppearanceBeforeTakingFocus() throws {
        let (window, textView) = try mountedEditor(theme: theme(mode: .light))
        defer { window.isHidden = true }

        XCTAssertEqual(textView.keyboardAppearance, .light)
        XCTAssertFalse(textView.isFirstResponder)
    }

    func testEditorPinsItsDarkAppearanceBeforeTakingFocus() throws {
        let (window, textView) = try mountedEditor(theme: theme(mode: .dark))
        defer { window.isHidden = true }

        XCTAssertEqual(textView.keyboardAppearance, .dark)
        XCTAssertFalse(textView.isFirstResponder)
    }

    private func mountedEditor(
        theme: RemoteThemePalette
    ) throws -> (UIWindow, IntrinsicTextView) {
        let controller = UIHostingController(rootView: Harness(theme: theme))
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
        return (window, try XCTUnwrap(descendant(of: IntrinsicTextView.self, in: window)))
    }

    private func descendant<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let root = root as? T { return root }
        return root.subviews.lazy.compactMap { self.descendant(of: type, in: $0) }.first
    }

    private func theme(mode: RemoteThemeMode) -> RemoteThemePalette {
        RemoteThemePalette(RemoteThemeDTO(
            id: "draft-keyboard-\(mode.rawValue)",
            name: "Draft keyboard",
            mode: mode,
            colors: ["ground": mode == .light ? "#FFFFFF" : "#101010"],
            material: RemoteThemeDTO.Material(
                panelRadius: 20,
                controlRadius: 10,
                borderWidth: 1
            )
        ))
    }

    private struct Harness: View {
        @State private var text = ""
        @State private var isFocused = false
        @State private var isOverflowing = false
        let theme: RemoteThemePalette

        var body: some View {
            SessionDraftPromptEditor(
                text: $text,
                isFocused: $isFocused,
                isOverflowing: $isOverflowing,
                isEnabled: true,
                theme: theme,
                offersFiles: { false },
                pasteFiles: { false },
                firstLineLeadingAccessoryWidth: 0,
                firstLineTrailingAccessoryWidth: 0,
                firstLineAccessoryHeight: 0,
                firstLineAccessoriesInline: true
            )
        }
    }
}

@MainActor
final class MobileMorphingTitleTests: XCTestCase {
    func testAMountedTitleMorphsWhenItsChatNameChanges() {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(title, text: "First chat", reducesMotion: false)
        window.layoutIfNeeded()
        XCTAssertFalse(title.isAnimatingTitleForTesting)

        configure(title, text: "Renamed chat", reducesMotion: false)
        window.layoutIfNeeded()

        XCTAssertEqual(title.stringValue, "Renamed chat")
        XCTAssertEqual(title.accessibilityLabel, "Renamed chat")
        XCTAssertTrue(title.isAnimatingTitleForTesting)
    }

    /// Reduce Motion keeps a rename visible but quiet: a brief crossfade in place, never a
    /// shape morph or a scramble. LabelMorph builds the morph in layout, so lay out first.
    func testReduceMotionCrossfadesAChangedChatName() {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(title, text: "First chat", reducesMotion: false)
        window.layoutIfNeeded()
        configure(title, text: "Renamed chat", reducesMotion: true)
        window.layoutIfNeeded()

        XCTAssertEqual(title.stringValue, "Renamed chat")
        assertCrossfades(title)
    }

    /// The phone's Theme motion switch holds a chat name to the same crossfade, even where a
    /// theme states a scramble.
    func testThemeMotionOffCrossfadesAChangedChatName() {
        let key = MobileThemeMotionPreferences.motionKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }
        title.theme = scrambleTheme("アイウエオ")

        configure(title, text: "First chat", reducesMotion: false)
        window.layoutIfNeeded()
        configure(title, text: "Renamed chat", reducesMotion: false)
        window.layoutIfNeeded()

        XCTAssertNil(title.scrambleAlphabetForTesting)
        assertCrossfades(title)
    }

    /// A theme's scramble decodes a rename from the theme's own alphabet, whitespace dropped.
    func testAThemesScrambleAlphabetDecodesARename() {
        let key = MobileThemeMotionPreferences.motionKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(true, forKey: key)
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }
        title.theme = scrambleTheme("ア イ\nウ")

        configure(title, text: "First chat", reducesMotion: false)
        window.layoutIfNeeded()
        configure(title, text: "Renamed chat", reducesMotion: false)
        window.layoutIfNeeded()

        XCTAssertEqual(title.scrambleAlphabetForTesting, ["ア", "イ", "ウ"])
        XCTAssertFalse(animations(in: title.layer, key: "morph.in.opacity", as: CABasicAnimation.self).isEmpty)
    }

    func testAConnectionStatusScrollsAsOneLineUnderTheSharedPulse() {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(
            title,
            text: "Opening chat…",
            reducesMotion: false,
            role: .connectionStatus
        )
        window.layoutIfNeeded()
        configure(
            title,
            text: "David's MacBook Pro",
            reducesMotion: false,
            role: .connectionStatus
        )
        window.layoutIfNeeded()

        XCTAssertEqual(title.stringValue, "David's MacBook Pro")
        XCTAssertTrue(title.isAnimatingLineScrollForTesting)
        XCTAssertTrue(title.isAnimatingTravelingFadeForTesting)
    }

    /// The reported transition is interrupted almost immediately: dashboard status gives way
    /// to "Opening chat…", then the live socket supplies the Mac name. The former five-pulse
    /// traveling wave left the final `Book Pro` bright while the first half flickered. One pulse
    /// beginning everywhere at once keeps even that interrupted handoff one visual line.
    func testAnInterruptedConnectionStatusUsesOneSynchronizedPulse() throws {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(
            title,
            text: "Connected · LAN",
            reducesMotion: false,
            role: .connectionStatus
        )
        window.layoutIfNeeded()
        configure(
            title,
            text: "Opening chat…",
            reducesMotion: false,
            role: .connectionStatus
        )
        configure(
            title,
            text: "David’s MacBook Pro",
            reducesMotion: false,
            role: .connectionStatus
        )
        window.layoutIfNeeded()

        let fades = animations(
            in: title.layer,
            key: "morph.fade.traveling",
            as: CAKeyframeAnimation.self
        )
        XCTAssertFalse(fades.isEmpty)
        let firstStart = try XCTUnwrap(fades.map(\.beginTime).min())
        let lastStart = try XCTUnwrap(fades.map(\.beginTime).max())
        XCTAssertEqual(lastStart - firstStart, 0, accuracy: 0.001)

        let values = try XCTUnwrap(fades.first?.values as? [NSNumber])
        XCTAssertEqual(values.count, 3, "a breath has one trough, not a flicker train")
        XCTAssertEqual(values[0].floatValue, 1, accuracy: 0.001)
        XCTAssertEqual(values[1].floatValue, 0.66, accuracy: 0.001)
        XCTAssertEqual(values[2].floatValue, 1, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(fades.first).duration,
            MobileDesign.Motion.connectionStatusMorphDuration,
            accuracy: 0.001
        )
    }

    func testAConnectionStatusScrollClearsTheCompleteCaptionLine() throws {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(
            title,
            text: "Opening chat…",
            reducesMotion: false,
            role: .connectionStatus,
            textStyle: .caption2,
            weight: .regular
        )
        window.layoutIfNeeded()
        configure(
            title,
            text: "David’s MacBook Pro",
            reducesMotion: false,
            role: .connectionStatus,
            textStyle: .caption2,
            weight: .regular
        )
        window.layoutIfNeeded()

        let incomingMoves = animations(
            in: title.layer,
            key: "morph.line.in.translation",
            as: CABasicAnimation.self
        )
        let move = try XCTUnwrap(incomingMoves.first)
        let offset = try XCTUnwrap(move.fromValue as? NSValue).cgSizeValue.height
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .caption2)
            .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.regular]])
        let font = UIFont(descriptor: descriptor, size: 0)
        XCTAssertGreaterThanOrEqual(
            abs(offset),
            font.lineHeight,
            "the incoming line started inside the old line instead of beyond it"
        )
    }

    func testReduceMotionLandsAConnectionStatusWithoutEitherAnimation() {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(
            title,
            text: "Opening chat…",
            reducesMotion: false,
            role: .connectionStatus
        )
        window.layoutIfNeeded()
        configure(
            title,
            text: "David's MacBook Pro",
            reducesMotion: true,
            role: .connectionStatus
        )

        XCTAssertFalse(title.isAnimatingLineScrollForTesting)
        XCTAssertFalse(title.isAnimatingTravelingFadeForTesting)
    }

    /// The dot moves because the centred phrase beside it changes width. The old-position copy
    /// fades away while the real dot is initially invisible at its new position, so two
    /// warning-coloured connection steps do not reveal that reflow as a teleport. The copy is
    /// the row's own subview at the row-local frame the dot was drawn in: a bar carrying the row
    /// somewhere — a push — carries the copy with it, where a copy parked in the window at the
    /// dot's *model* frame sat at the far end of the slide while the words slid under it.
    func testTheConnectionDotFadesAcrossLayoutWhenTheStatusChangesButItsColorDoesNot() throws {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        update(line, status: "Checking connections", color: .systemOrange)
        XCTAssertFalse(line.indicator.isAnimatingTransitionForTesting)
        let oldFrame = line.indicator.frame

        update(line, status: "Trying LAN", color: .systemOrange)
        window.layoutIfNeeded()

        let transition = try XCTUnwrap(line.indicator.transitionForTesting)
        let opacity = try XCTUnwrap(
            transition.animations?.compactMap { $0 as? CAKeyframeAnimation }
                .first { $0.keyPath == "opacity" }
        )
        let values = try XCTUnwrap(opacity.values as? [NSNumber])
        XCTAssertEqual(values.map(\.floatValue), [0, 0, 1])
        XCTAssertEqual(
            transition.duration,
            MobileDesign.Motion.connectionStatusMorphDuration,
            accuracy: 0.001
        )
        XCTAssertNotEqual(line.indicator.frame, oldFrame, "a shorter phrase leaves the dot where it was")

        let departing = try XCTUnwrap(line.departingIndicatorForTesting)
        XCTAssertTrue(departing.superview === line, "the departing copy left the row it belongs to")
        XCTAssertEqual(departing.frame, oldFrame)
        XCTAssertEqual(departing.backgroundColor, .systemOrange)
        let departure = try XCTUnwrap(
            departing.layer.animation(
                forKey: "threading.connection-status-indicator.departing"
            ) as? CABasicAnimation
        )
        XCTAssertEqual(departure.fromValue as? Float, 1)
        XCTAssertEqual(departure.toValue as? Float, 0)
        XCTAssertEqual(
            departure.duration,
            MobileDesign.Motion.connectionStatusMorphDuration
                * MobileDesign.Motion.connectionStatusDepartureShare,
            accuracy: 0.001
        )
    }

    func testReduceMotionLandsAConnectionDotChangeWithoutAFade() {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        update(line, status: "Checking connections", color: .systemOrange)
        update(line, status: "Connected", color: .systemGreen, reducesMotion: true)

        XCTAssertFalse(line.indicator.isAnimatingTransitionForTesting)
        XCTAssertFalse(line.label.isAnimatingLineScrollForTesting)
        XCTAssertNil(line.departingIndicatorForTesting)
        XCTAssertEqual(line.indicator.layer.backgroundColor, UIColor.systemGreen.cgColor)
    }

    /// SwiftUI and the UIKit conversation title may restate the same model several times while
    /// the transition is still playing. An idempotent update must not make the new dot pop in or
    /// discard the old-position copy early.
    func testRestatingAConnectionStatusPreservesItsInFlightTransition() throws {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        update(line, status: "Checking connections", color: .systemOrange)
        update(line, status: "Connected", color: .systemGreen)
        let departing = try XCTUnwrap(line.departingIndicatorForTesting)
        XCTAssertTrue(line.indicator.isAnimatingTransitionForTesting)

        update(line, status: "Connected", color: .systemGreen)

        XCTAssertTrue(line.indicator.isAnimatingTransitionForTesting)
        XCTAssertTrue(line.departingIndicatorForTesting === departing)
    }

    /// The working orb replaces the connection dot. If work begins during a connection change,
    /// both halves of the dot's fade must leave before the orb is shown.
    func testEnteringWorkCancelsBothConnectionDotHalves() throws {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        let mark = UIView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: MobileDesign.Size.navigationWorkingOrb),
            mark.heightAnchor.constraint(equalToConstant: MobileDesign.Size.navigationWorkingOrb),
        ])
        line.workingMark = mark
        update(line, status: "Checking connections", color: .systemOrange)
        update(line, status: "Connected", color: .systemGreen)
        XCTAssertNotNil(line.departingIndicatorForTesting)

        line.isWorking = true

        XCTAssertTrue(line.indicator.isHidden)
        XCTAssertNil(line.departingIndicatorForTesting)
        XCTAssertFalse(line.indicator.isAnimatingTransitionForTesting)
    }

    /// The recording this line exists for: "Opening chat…" gave way to "David's MacBook Pro"
    /// and the new phrase was drawn in two pieces, "David's MacBo" still rising while "ok Pro"
    /// already sat lit a line above it. The label had been sized to the old words, so the morph
    /// was built in the old width and the characters that had not fit were made fresh, without
    /// the animation, when the wider frame landed a pass later. The line gives the phrase a
    /// frame the words do not decide, so the morph it builds is the one that plays.
    func testThePhraseKeepsItsFrameThroughAChangeSoTheMorphItBuildsIsTheOneThatPlays() {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        update(line, status: "Opening chat…", color: .systemOrange)
        window.layoutIfNeeded()
        let frame = line.label.frame

        update(line, status: "David's MacBook Pro", color: .systemGreen)
        window.layoutIfNeeded()

        XCTAssertEqual(line.label.frame, frame)
        XCTAssertEqual(
            frame.width,
            line.bounds.width
                - MobileDesign.Size.navigationStatusIndicator
                - MobileDesign.Spacing.tight,
            accuracy: 0.5,
            "the phrase's frame is the row's width less the mark's slot, never the phrase's own"
        )
        XCTAssertTrue(line.label.isAnimatingLineScrollForTesting)
        XCTAssertEqual(line.label.stringValue, "David's MacBook Pro")
    }

    /// The mark stands `Spacing.tight` before the phrase's first character, and the pair is
    /// centred on the row — the geometry the SwiftUI row used to get from an `HStack`, now
    /// answered by the line itself so that the label can fill the row.
    func testTheMarkStandsBesideThePhrasesFirstCharacterAndThePairIsCentred() throws {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        update(line, status: "Connected · Tailscale", color: .systemGreen, reducesMotion: true)
        window.layoutIfNeeded()

        let ink = line.label.glyphInkFrames.map { line.convert($0, from: line.label) }
        let first = try XCTUnwrap(ink.min { $0.minX < $1.minX })
        let last = try XCTUnwrap(ink.max { $0.maxX < $1.maxX })
        XCTAssertEqual(
            line.indicator.frame.maxX + MobileDesign.Spacing.tight,
            first.minX,
            accuracy: 1
        )
        XCTAssertEqual((line.indicator.frame.minX + last.maxX) / 2, line.bounds.midX, accuracy: 1)
        XCTAssertEqual(line.indicator.frame.midY, line.bounds.midY, accuracy: 0.5)
    }

    /// A phrase too long for the row is drawn as its ellipsized head, and the mark stands
    /// beside that head — not beside where the whole phrase would have begun.
    func testATruncatedPhraseKeepsTheMarkBesideItsHead() throws {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        let phrase = String(repeating: "Connected over a very long route name ", count: 3)
        update(line, status: phrase, color: .systemGreen, reducesMotion: true)
        window.layoutIfNeeded()

        let ink = line.label.glyphInkFrames.map { line.convert($0, from: line.label) }
        let first = try XCTUnwrap(ink.min { $0.minX < $1.minX })
        let last = try XCTUnwrap(ink.max { $0.maxX < $1.maxX })
        XCTAssertLessThanOrEqual(last.maxX, line.bounds.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(line.indicator.frame.minX, -0.01)
        XCTAssertEqual(
            line.indicator.frame.maxX + MobileDesign.Spacing.tight,
            first.minX,
            accuracy: 1
        )
    }

    /// A change that lands while the bar is carrying the row — a push in flight — is committed,
    /// not performed: the title arrives already saying the settled state. The connection settles
    /// about 100 ms after a chat's screen appears, which is always inside its push.
    func testAStatusChangeWhileTheHostIsInFlightLandsWithoutAnimation() throws {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        update(line, status: "Opening chat…", color: .systemOrange)
        let host = try XCTUnwrap(line.superview)
        UIView.animate(withDuration: 1) { host.center.x += 120 }
        XCTAssertFalse(host.layer.animationKeys()?.isEmpty ?? true, "the fixture's host is not moving")

        update(line, status: "David's MacBook Pro", color: .systemGreen)

        XCTAssertFalse(line.label.isAnimatingLineScrollForTesting)
        XCTAssertFalse(line.indicator.isAnimatingTransitionForTesting)
        XCTAssertNil(line.departingIndicatorForTesting)
        XCTAssertEqual(line.label.stringValue, "David's MacBook Pro")
        XCTAssertEqual(line.indicator.layer.backgroundColor, UIColor.systemGreen.cgColor)
        host.layer.removeAllAnimations()
    }

    /// The working mark takes the dot's slot: the dot is hidden, the mark is centred where the
    /// dot stood, and the phrase moves over to make room for the wider mark.
    func testTheWorkingMarkStandsInTheDotsPlace() {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        let mark = UIView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: MobileDesign.Size.navigationWorkingOrb),
            mark.heightAnchor.constraint(equalToConstant: MobileDesign.Size.navigationWorkingOrb),
        ])
        line.workingMark = mark
        update(line, status: "David's MacBook Pro", color: .systemGreen, reducesMotion: true)
        window.layoutIfNeeded()
        let restingLabel = line.label.frame

        line.isWorking = true
        window.layoutIfNeeded()

        XCTAssertTrue(line.indicator.isHidden)
        XCTAssertFalse(mark.isHidden)
        let markFrame = mark.convert(mark.bounds, to: line)
        XCTAssertEqual(markFrame.width, MobileDesign.Size.navigationWorkingOrb, accuracy: 0.5)
        XCTAssertEqual(markFrame.midY, line.bounds.midY, accuracy: 0.5)
        XCTAssertEqual(
            line.label.frame.minX - restingLabel.minX,
            MobileDesign.Size.navigationWorkingOrb - MobileDesign.Size.navigationStatusIndicator,
            accuracy: 0.5
        )
        XCTAssertEqual(
            line.intrinsicContentSize.height,
            MobileDesign.Size.navigationWorkingOrb,
            accuracy: 0.5
        )

        line.isWorking = false
        window.layoutIfNeeded()
        XCTAssertFalse(line.indicator.isHidden)
        XCTAssertEqual(line.label.frame, restingLabel)
    }

    func testAConnectionProgressFadeDoesNotChangeItsWords() {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(
            title,
            text: "Trying LAN",
            reducesMotion: true,
            role: .connectionProgress
        )
        window.layoutIfNeeded()
        title.playFade()

        XCTAssertEqual(title.stringValue, "Trying LAN")
        XCTAssertTrue(title.isAnimatingTravelingFadeForTesting)
        XCTAssertFalse(title.isAnimatingLineScrollForTesting)

        title.stopFade()
        XCTAssertFalse(title.isAnimatingTravelingFadeForTesting)
    }

    func testNavigationStackCompressesALongChatNameWithoutCollapsingIt() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 280, height: 44))
        let title = MobileMorphingTitleLabel()
        configure(title, text: "Review the new remote access feature", reducesMotion: false)
        let status = UILabel()
        status.text = "Connected"
        let stack = UIStackView(arrangedSubviews: [title, status])
        stack.axis = .vertical
        stack.alignment = .center
        stack.frame = host.bounds
        host.addSubview(stack)

        host.layoutIfNeeded()

        XCTAssertEqual(title.frame.width, host.bounds.width, accuracy: 0.5)
        XCTAssertGreaterThan(title.frame.height, 0)
    }

    func testShapeMorphGlyphsUseUIKitCoordinateDirection() throws {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(title, text: "I", reducesMotion: false)
        window.layoutIfNeeded()
        configure(title, text: "P", reducesMotion: false)
        window.layoutIfNeeded()

        let path = try XCTUnwrap(shapeLayers(in: title.layer).compactMap(\.path).first)
        let box = path.boundingBoxOfPath
        var upperInk = 0
        var lowerInk = 0
        for row in 0..<40 {
            for column in 0..<40 {
                let point = CGPoint(
                    x: box.minX + (CGFloat(column) + 0.5) * box.width / 40,
                    y: box.minY + (CGFloat(row) + 0.5) * box.height / 40
                )
                guard path.contains(point, using: .evenOdd) else { continue }
                if point.y < box.midY {
                    upperInk += 1
                } else {
                    lowerInk += 1
                }
            }
        }

        XCTAssertGreaterThan(upperInk, lowerInk, "P's bowl belongs above its stem on UIKit")
    }

    private func assertCrossfades(_ title: MobileMorphingTitleLabel,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let fades = animations(in: title.layer, key: "morph.in", as: CABasicAnimation.self)
            + animations(in: title.layer, key: "morph.out", as: CABasicAnimation.self)
        XCTAssertFalse(fades.isEmpty, "the rename crossfades", file: file, line: line)
        XCTAssertTrue(fades.allSatisfy { $0.keyPath == "opacity" && $0.duration <= 0.18 + 0.0001 },
                      file: file, line: line)
        XCTAssertTrue(animations(in: title.layer, key: "morph.path", as: CABasicAnimation.self).isEmpty,
                      "no glyph shape morph", file: file, line: line)
    }

    private func scrambleTheme(_ characters: String) -> RemoteThemePalette {
        RemoteThemePalette(RemoteThemeDTO(
            id: "scramble", name: "Scramble", mode: .dark, colors: [:],
            material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1),
            titleMorph: .init(style: "scramble", characters: characters)
        ))
    }

    private func mountedTitle() -> (UIWindow, MobileMorphingTitleLabel) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        let title = MobileMorphingTitleLabel(frame: CGRect(x: 55, y: 80, width: 280, height: 24))
        controller.view.addSubview(title)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return (window, title)
    }

    /// The line at the width the bar hands a title, inside a host that stands in for the bar's
    /// title area — something a push can move.
    private func mountedStatusLine() -> (UIWindow, MobileConnectionStatusLineView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        let host = UIView(frame: CGRect(
            x: 77,
            y: 60,
            width: MobileDesign.Size.navigationTitleWidth,
            height: MobileDesign.Size.navigationTitleHeight
        ))
        let line = MobileConnectionStatusLineView(frame: CGRect(
            x: 0,
            y: 24,
            width: MobileDesign.Size.navigationTitleWidth,
            height: 14
        ))
        host.addSubview(line)
        controller.view.addSubview(host)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return (window, line)
    }

    private func update(
        _ line: MobileConnectionStatusLineView,
        status: String,
        color: UIColor,
        reducesMotion: Bool = false
    ) {
        line.update(
            status: status,
            color: color,
            textColor: .secondaryLabel,
            groundColor: .systemBackground,
            reducesMotion: reducesMotion
        )
    }

    private func configure(
        _ title: MobileMorphingTitleLabel,
        text: String,
        reducesMotion: Bool,
        role: MobileMorphingTextRole = .chatName,
        textStyle: UIFont.TextStyle = .headline,
        weight: UIFont.Weight = .semibold
    ) {
        title.configure(
            title: text,
            textStyle: textStyle,
            weight: weight,
            textColor: .label,
            groundColor: .systemBackground,
            alignment: .center,
            reducesMotion: reducesMotion,
            role: role
        )
    }

    private func animations<Animation: CAAnimation>(
        in layer: CALayer,
        key: String,
        as type: Animation.Type
    ) -> [Animation] {
        let own = (layer.animation(forKey: key) as? Animation).map { [$0] } ?? []
        return own + (layer.sublayers ?? []).flatMap {
            animations(in: $0, key: key, as: type)
        }
    }

    private func shapeLayers(in layer: CALayer) -> [CAShapeLayer] {
        (layer.sublayers ?? []).flatMap { child in
            (child as? CAShapeLayer).map { [$0] } ?? shapeLayers(in: child)
        }
    }
}

/// Whether an anchored popover has the room it asks for, which decides whether the draft's
/// choosers keep the keyboard under them or ask for its height.
@MainActor
final class MobileThemedPopoverRoomTests: XCTestCase {
    /// An iPhone 17 Pro with the keyboard up: the composer's action row stands at about 490
    /// points, under a navigation bar whose bottom is at about 116.
    private let anchorAboveTheKeyboard = CGRect(x: 16, y: 490, width: 160, height: 34)
    private let barBottom: CGFloat = 116
    private let screenBottom: CGFloat = 874 - 34

    func testAPickerThatFitsAboveItsAnchorNeedsNoRoom() {
        XCTAssertTrue(MobileThemedPopoverRoom.fits(
            contentHeight: 330,
            arrowEdge: .bottom,
            anchor: anchorAboveTheKeyboard,
            between: barBottom,
            and: screenBottom
        ))
    }

    /// A five-row page of the picker with its pager is 360 points; between a 116-point bar and
    /// an action row at 497 that leaves nine to spare once the arrow is counted, and none if
    /// UIKit's margin is charged a second time at the bar.
    func testOnlyTheArrowStandsBetweenTheBodyAndTheAnchor() {
        let bare = anchorAboveTheKeyboard.minY - barBottom
        XCTAssertFalse(
            MobileThemedPopoverRoom.fits(
                contentHeight: bare,
                arrowEdge: .bottom,
                anchor: anchorAboveTheKeyboard,
                between: barBottom,
                and: screenBottom
            ),
            "the content is not the whole popover: the arrow stands in the same room"
        )
        XCTAssertTrue(MobileThemedPopoverRoom.fits(
            contentHeight: bare - MobileThemedPopoverBackgroundView.arrowHeight(),
            arrowEdge: .bottom,
            anchor: anchorAboveTheKeyboard,
            between: barBottom,
            and: screenBottom
        ))
        XCTAssertTrue(MobileThemedPopoverRoom.fits(
            contentHeight: 360,
            arrowEdge: .bottom,
            anchor: CGRect(x: 16, y: 497, width: 160, height: 34),
            between: 116,
            and: screenBottom
        ))
    }

    /// An iPhone SE with the keyboard up leaves about 230 points between the bar and the row.
    func testAPickerTallerThanTheRoomAboveItsAnchorAsksForRoom() {
        let anchorOnASmallPhone = CGRect(x: 16, y: 300, width: 160, height: 34)
        XCTAssertFalse(MobileThemedPopoverRoom.fits(
            contentHeight: 330,
            arrowEdge: .bottom,
            anchor: anchorOnASmallPhone,
            between: 72,
            and: 667
        ))
    }

    func testAPopoverBelowItsAnchorMeasuresTheRoomBelow() {
        let anchorNearTheTop = CGRect(x: 16, y: 130, width: 160, height: 34)
        XCTAssertTrue(MobileThemedPopoverRoom.fits(
            contentHeight: 330,
            arrowEdge: .top,
            anchor: anchorNearTheTop,
            between: barBottom,
            and: screenBottom
        ))
        XCTAssertFalse(MobileThemedPopoverRoom.fits(
            contentHeight: 330,
            arrowEdge: .top,
            anchor: anchorAboveTheKeyboard,
            between: barBottom,
            and: 874 - 336
        ))
    }

    func testAPopoverBesideItsAnchorAlwaysHasRoom() {
        for edge in [Edge.leading, .trailing] {
            XCTAssertTrue(MobileThemedPopoverRoom.fits(
                contentHeight: 10_000,
                arrowEdge: edge,
                anchor: anchorAboveTheKeyboard,
                between: barBottom,
                and: screenBottom
            ))
        }
    }

    @MainActor
    func testTheContentTopIsTheNavigationBarsBottomWhenOneIsOnScreen() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let navigation = UINavigationController(rootViewController: UIViewController())
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        let bar = navigation.navigationBar
        let barBottom = bar.convert(bar.bounds, to: window).maxY

        XCTAssertEqual(MobileThemedPopoverRoom.contentTop(of: window), barBottom, accuracy: 0.5)
        XCTAssertGreaterThan(barBottom, window.safeAreaInsets.top)
        window.isHidden = true
    }

    @MainActor
    func testWithoutABarTheBoundsAreUIKitsSafeAreaPlusItsMargin() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIViewController()
        window.isHidden = false
        window.layoutIfNeeded()

        XCTAssertEqual(
            MobileThemedPopoverRoom.contentTop(of: window),
            window.safeAreaInsets.top + MobileThemedPopoverRoom.layoutMargin
        )
        XCTAssertEqual(
            MobileThemedPopoverRoom.contentBottom(of: window),
            874 - window.safeAreaInsets.bottom - MobileThemedPopoverRoom.layoutMargin
        )
        window.isHidden = true
    }
}

@MainActor
final class MobileThemeGlowTests: XCTestCase {
    func testUsageSheetShadowLeavesCapacityContentUnchanged() async throws {
        let link = try XCTUnwrap(RemoteConnectionLink(string: "https://demo.invalid/#shadow-test"))
        let model = RemoteUsageDashboardModel(link: link, isDemo: true)
        await model.load()
        let id = try XCTUnwrap(model.selectedLimitID)
        await model.loadLimit(seriesID: id, days: 30)
        let authored = try XCTUnwrap(RemoteAppModel.demoCatalogThemes.first { $0.id == "neo-brutalism" })
        func sheet(glow: RemoteThemeDTO.Material.Glow?) -> some View {
            let theme = RemoteThemePalette(RemoteThemeDTO(
                id: authored.id, name: authored.name, mode: authored.mode, colors: authored.colors,
                material: .init(panelRadius: 0, controlRadius: 0, borderWidth: 4, glow: glow)
            ))
            return Color.white.sheet(isPresented: .constant(true)) {
                RemoteUsageDashboardView(link: link, isDemo: true, model: model)
                    .mobileTheme(theme)
            }
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.dynamicTypeSize, .large)
        }
        let controller = UIHostingController(rootView: sheet(glow: nil))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let plain = try await stableCapture(window)
        XCTAssertNotNil(controller.presentedViewController)
        controller.rootView = sheet(glow: authored.material.glow)
        let shadowed = try await stableCapture(window)
        // Inside the first capacity card in this fixed-size shipping sheet, including its
        // provider heading and percentage. An outside shadow may not add any ink here.
        let capacity = CGRect(x: 36, y: 306, width: 320, height: 58)
        let expected = try pixels(plain, rect: capacity)
        XCTAssertGreaterThan(expected.filter { $0 < 100 }.count, 100,
                             "the comparison must contain capacity ink, not an empty sheet")
        XCTAssertEqual(expected, try pixels(shadowed, rect: capacity))
        for (name, image) in [("usage-shadow-plain", plain), ("usage-shadow-themed", shadowed)] {
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testPanelShadowDoesNotDuplicateItsContentsAndUpdatesWithTheme() async throws {
        let controller = UIHostingController(rootView: panel(glow: nil))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let plain = try await capture(window)
        for radius in [0.0, 10.0] {
            controller.rootView = panel(glow: .init(
                color: "#000000", radius: radius, opacity: 1, offsetX: 12, offsetY: -12
            ))
            let shadowed = try await capture(window)
            XCTAssertEqual(try pixels(plain, rect: face), try pixels(shadowed, rect: face),
                           "A panel's shadow must not redraw its text, controls or outline inside its face")
            XCTAssertNotEqual(try pixels(plain, rect: shadow), try pixels(shadowed, rect: shadow),
                              "The authored shadow must still be visible outside the panel")
        }
        controller.rootView = panel(glow: nil)
        let cleared = try await capture(window)
        XCTAssertEqual(try pixels(plain, rect: shadow), try pixels(cleared, rect: shadow))
    }

    private let face = CGRect(x: 42, y: 202, width: 196, height: 96)
    private let shadow = CGRect(x: 244, y: 220, width: 4, height: 60)

    private func stableCapture(_ window: UIWindow) async throws -> UIImage {
        var previous: Data?
        for _ in 0..<20 {
            let image = try await capture(window)
            let current = try pixels(image, rect: window.bounds)
            if current == previous { return image }
            previous = current
        }
        XCTFail("The shipping sheet did not finish presenting")
        return try await capture(window)
    }

    private func panel(glow: RemoteThemeDTO.Material.Glow?) -> some View {
        let theme = RemoteThemePalette(RemoteThemeDTO(
            id: "shadow-test", name: "Shadow test", mode: .light,
            colors: ["panel": "#FFFFFF", "label": "#000000"],
            material: .init(panelRadius: 0, controlRadius: 0, borderWidth: 2, glow: glow)
        ))
        return VStack {
            HStack {
                Text("Capacity").foregroundStyle(.black)
                Rectangle().fill(.red).frame(width: 20, height: 20)
            }
        }
        .frame(width: 200, height: 100)
        .background(theme.panel, in: Rectangle())
        .overlay { Rectangle().stroke(.black, lineWidth: 2) }
        .remoteThemeGlow(theme)
        .position(x: 140, y: 250)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .ignoresSafeArea()
    }

    private func capture(_ window: UIWindow) async throws -> UIImage {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(40))
            window.layoutIfNeeded()
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    private func pixels(_ image: UIImage, rect: CGRect) throws -> Data {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: rect))
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: crop.width, height: crop.height,
            bitsPerComponent: 8, bytesPerRow: crop.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return Data(bytes)
    }
}

@MainActor
final class ComposerChromeRenderTests: XCTestCase {
    func testSurfaceRefreshReplacesOnlyItsOwnOutline() {
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 52, height: 52))
        let childOutline = MobileThemeOutlineView()
        surface.addSubview(childOutline)
        for radius: CGFloat in [0, 10, 0] {
            surface.applyRemoteSurface(fill: .white, radius: radius, border: .black, borderWidth: 4)
            XCTAssertTrue(childOutline.superview === surface)
            XCTAssertEqual(surface.subviews.count, 2)
        }
        surface.applyRemoteSurface(fill: .white, radius: 0)
        XCTAssertEqual(surface.subviews, [childOutline])
    }

    func testSquareOutlineHasCompleteCornersAtEveryBorderWeight() throws {
        for width: CGFloat in [1, 2, 4] {
            let outline = MobileThemeOutlineView(frame: CGRect(x: 0, y: 0, width: 52, height: 52))
            outline.update(color: .black, radius: 0, width: width, glow: nil)
            let image = render(outline)
            for point in [CGPoint(x: 0, y: 0), CGPoint(x: 51, y: 0),
                          CGPoint(x: 0, y: 51), CGPoint(x: 51, y: 51)] {
                XCTAssertEqual(try pixel(image, point)[3], 255, "Missing corner at \(point), width \(width)")
            }
            XCTAssertEqual(try pixel(image, CGPoint(x: 26, y: 26))[3], 0)
        }
    }

    func testPartialRedrawKeepsOutlineOnViewBounds() throws {
        let outline = MobileThemeOutlineView(frame: CGRect(x: 0, y: 0, width: 52, height: 52))
        outline.update(color: .black, radius: 0, width: 4, glow: nil)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: outline.bounds, format: format).image { _ in
            outline.draw(CGRect(x: 10, y: 10, width: 20, height: 20))
        }
        XCTAssertEqual(try pixel(image, CGPoint(x: 10, y: 10))[3], 0)
        XCTAssertEqual(try pixel(image, CGPoint(x: 0, y: 0))[3], 255)
    }

    func testAttachmentRemoveMarkDoesNotRevealThumbnailThroughItsCross() throws {
        for radius: CGFloat in [0, 10] {
            let theme = RemoteThemePalette(RemoteThemeDTO(
                id: "attachment-test", name: "Attachment test", mode: .light,
                colors: ["ground": "#FFFFFF", "floating_surface": "#FFFFFF", "label": "#000000", "border": "#000000"],
                material: .init(panelRadius: Double(radius), controlRadius: Double(radius), borderWidth: 4)
            ))
            func capture(_ color: UIColor) throws -> UIImage {
                let strip = ComposerAttachmentStripView(frame: CGRect(x: 0, y: 0, width: 100, height: 66))
                let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 52, height: 52)).image { context in
                    color.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 52, height: 52))
                }
                var item = ComposerAttachmentItem(name: "Image", thumbnail: thumbnail, systemImage: "photo")
                item.state = .ready(uploadID: "test")
                strip.update(items: [item], theme: theme)
                strip.layoutIfNeeded()
                let remove = try XCTUnwrap(descendants(strip).first {
                    $0.accessibilityIdentifier == "composer.attachment.remove"
                } as? UIButton)
                // Render the actual configured symbol over the two thumbnail colours. Its
                // centre must be opaque even where the glyph used to cut through the disc.
                let mark = try XCTUnwrap(remove.image(for: .normal))
                let format = UIGraphicsImageRendererFormat()
                format.scale = 3
                return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format).image { context in
                    color.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
                    mark.draw(in: CGRect(x: 0, y: 0, width: 24, height: 24))
                }
            }
            let red = try capture(.red)
            let blue = try capture(.blue)
            for y in 30..<42 {
                for x in 30..<42 {
                    XCTAssertEqual(try pixel(red, CGPoint(x: x, y: y)), try pixel(blue, CGPoint(x: x, y: y)))
                }
            }
        }
    }

    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func render(_ view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
    }

    private func pixel(_ image: UIImage, _ point: CGPoint) throws -> [UInt8] {
        let cropped = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes
    }
}

/// A navigation stack with a pushed page and the session Workspace as a sheet over it — the
/// shape that put two backdrops in one sheet.
@MainActor
private final class WorkspaceSheetFixture: ObservableObject {
    @Published var path: [String] = []
    @Published var showsSheet = false
}

private struct WorkspaceSheetHost: View {
    @ObservedObject var model: WorkspaceSheetFixture
    let theme: RemoteThemePalette

    var body: some View {
        NavigationStack(path: $model.path) {
            Color.clear
                .mobileThemeBackdrop(theme)
                .navigationDestination(for: String.self) { _ in
                    Color.clear.mobileThemeBackdrop(theme)
                }
        }
        .sheet(isPresented: $model.showsSheet) {
            SessionWorkspaceView(
                session: RemoteSessionSummaryDTO(
                    id: "workspace-fixture", title: "Workspace", agentKind: "codex",
                    surface: .conversation, state: .idle, projectName: "Fixture"
                ),
                client: RemoteClient(link: DemoExperience.link),
                activity: MobileWorkspaceActivity(sessionID: "workspace-fixture"),
                loadsRemotely: false
            )
            .mobileTheme(theme)
        }
        .mobileTheme(theme)
    }
}

@MainActor
final class MobileThemeMascotTests: XCTestCase {
    private var digests: [String] = []

    override func tearDown() async throws {
        for digest in digests { MobileThemeAssets.shared.images.removeObject(forKey: digest as NSString) }
        digests = []
        try await super.tearDown()
    }

    func testPoseFollowsTheCatalogueMoodAndBorrowsLikeTheMac() {
        let idle = pose("mascot.idle")
        let working = pose("mascot.working")
        let celebrating = pose("mascot.celebrating")
        let mascot = MobileThemeMascotView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        mascot.apply(theme([idle, working, celebrating]))

        XCTAssertTrue(shown(mascot) === image(idle), "resting has no pose of its own and wears idle's")
        mascot.mood = "working"
        XCTAssertTrue(shown(mascot) === image(working))
        mascot.mood = "attention"
        XCTAssertTrue(shown(mascot) === image(working), "attention wears working's pose before idle's")
        mascot.mood = "working"
        mascot.mood = "idle"
        XCTAssertTrue(shown(mascot) === image(idle), "without motion a finished turn is not celebrated")
    }

    func testFigureStandsOnTheTrailingPillAndMirrorsForRightToLeft() throws {
        let wide = pose("mascot.idle", size: CGSize(width: 128, height: 64))
        let mascot = MobileThemeMascotView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        mascot.foot = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 94, trailing: 20)
        mascot.apply(theme([wide]))
        mascot.layoutIfNeeded()

        let side = MobileDesign.Size.mascot
        let standing = CGRect(x: 390 - 20 - side, y: 844 - 94 - side / 2, width: side, height: side / 2)
        XCTAssertEqual(mascot.figureForTesting.frame, standing, "fitted to the square, feet on the pill")
        XCTAssertFalse(mascot.isUserInteractionEnabled)
        XCTAssertNil(mascot.hitTest(CGPoint(x: standing.midX, y: standing.midY), with: nil))
        XCTAssertTrue(mascot.accessibilityElementsHidden)

        let rendered = UIGraphicsImageRenderer(bounds: mascot.bounds).image { mascot.layer.render(in: $0.cgContext) }
        XCTAssertEqual(try alpha(in: rendered, at: CGPoint(x: standing.midX, y: standing.midY)), 255)
        XCTAssertEqual(try alpha(in: rendered, at: CGPoint(x: 20, y: 20)), 0, "the rest of the ground is the backdrop's")

        mascot.semanticContentAttribute = .forceRightToLeft
        mascot.setNeedsLayout()
        mascot.layoutIfNeeded()
        XCTAssertEqual(mascot.figureForTesting.frame.minX, 20)
    }

    func testAThemeSwitchStandsOrClearsTheFigure() {
        let idle = pose("mascot.idle")
        let plain = RemoteThemePalette(nil)
        XCTAssertFalse(MobileThemeMascotView.stands(in: plain))
        XCTAssertTrue(MobileThemeMascotView.stands(in: theme([idle])))
        XCTAssertFalse(MobileThemeMascotView.stands(in: theme([pose("mascot.working")])),
            "the list reserves room only for a set the Mac would accept")

        let mascot = MobileThemeMascotView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        mascot.apply(theme([idle]))
        XCTAssertNotNil(mascot.figureForTesting.image)
        mascot.apply(plain)
        XCTAssertNil(mascot.figureForTesting.image)
    }

    // MARK: - Fixtures

    /// A pose picture in the shared cache, the way a finished download leaves it.
    private func pose(_ slot: String, size: CGSize = CGSize(width: 64, height: 64)) -> RemoteThemeAsset {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let picture = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let digest = (0..<4).map { _ in String(format: "%016llx", UInt64.random(in: .min ... .max)) }.joined()
        MobileThemeAssets.shared.images.setObject(picture, forKey: digest as NSString)
        digests.append(digest)
        return RemoteThemeAsset(slot: slot, digest: digest, byteCount: 1,
            pixelWidth: Int(size.width), pixelHeight: Int(size.height))
    }

    private func theme(_ assets: [RemoteThemeAsset]) -> RemoteThemePalette {
        RemoteThemePalette(RemoteThemeDTO(id: "mascot-\(assets.map(\.digest).joined())", name: "Mascot",
            mode: .dark, colors: [:], material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1),
            assets: assets))
    }

    private func image(_ asset: RemoteThemeAsset) -> UIImage? { MobileThemeAssets.shared.image(asset) }
    private func shown(_ mascot: MobileThemeMascotView) -> UIImage? { mascot.figureForTesting.image }

    private func alpha(in image: UIImage, at point: CGPoint) throws -> UInt8 {
        let cgImage = try XCTUnwrap(image.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let x = point.x * image.scale
        let y = point.y * image.scale
        context.draw(cgImage, in: CGRect(x: -x, y: y - CGFloat(cgImage.height) + 1,
            width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        return try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))[3]
    }
}
