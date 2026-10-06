@testable import ThreadingMobile
import SwiftUI
import ThreadingRemoteKit
import UIKit
import XCTest

/// The theme's welcome on the phone's new-chat screen: the pick on the phone's own clock and
/// seed, the minute that renders a clock line only while the screen is visible, the welcome's
/// own ground under the accessibility gates, the reconnect cache's budget, and the draft drawn
/// with a welcome in light and dark.
@MainActor
final class MobileDraftWelcomeTests: XCTestCase {
    private typealias Line = ThemeWelcomeGrammar.Line

    // MARK: - Fixtures

    /// Monday 5 October 2026, 19:05:30 UTC — an evening.
    private static let evening: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 19, minute: 5, second: 30))!
    }()

    private final class Clock {
        var now: Date
        var scheduled: [(date: Date, fire: @MainActor () -> Void)] = []
        var cancelled = 0
        var seed: UInt64

        init(now: Date, seed: UInt64) {
            self.now = now
            self.seed = seed
        }

        /// SplitMix64, so a pick is the same pick on every run.
        func next() -> UInt64 {
            seed &+= 0x9E37_79B9_7F4A_7C15
            var value = seed
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    private func environment(_ clock: Clock) -> MobileDraftWelcomeEnvironment {
        MobileDraftWelcomeEnvironment(
            now: { clock.now },
            calendar: {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC")!
                return calendar
            },
            locale: { Locale(identifier: "en_GB") },
            random: { clock.next() },
            schedule: { date, fire in
                clock.scheduled.append((date, fire))
                return { clock.cancelled += 1 }
            }
        )
    }

    private static func welcome(greeting: [Line], includesAppLines: Bool = false, caption: [Line]? = nil) -> RemoteThemeWelcome {
        RemoteThemeWelcome(
            greeting: .init(lines: greeting, includesAppLines: includesAppLines),
            caption: caption.map { .init(lines: $0) }
        )
    }

    private static let inputs = MobileDraftWelcome.Inputs(project: "AnotherTerminal", user: "Ada", working: 2, waiting: 1)

    // MARK: - Pick

    func testThePickIsTheGrammarsOnThePhonesClockAndSeed() throws {
        let welcome = Self.welcome(
            greeting: [
                Line(text: "Good {daypart}, {user}.", when: .init(dayparts: [.evening])),
                Line(text: "Morning only", when: .init(dayparts: [.morning])),
                Line(text: "Back to {project}", weight: 5)
            ],
            caption: [Line(text: "{working} working, {waiting} waiting")]
        )
        for seed: UInt64 in [1, 7, 2026] {
            let clock = Clock(now: Self.evening, seed: seed)
            let model = MobileDraftWelcomeModel(environment: environment(clock))
            model.arrive(welcome, inputs: Self.inputs)

            // The same seed through the shared grammar is the same pick.
            let mirror = Clock(now: Self.evening, seed: seed)
            var generator = MobileDraftWelcomeEnvironment.Generator(draw: { mirror.next() })
            let expected = MobileDraftWelcome.pick(welcome, at: model.context(Self.inputs), using: &generator)
            XCTAssertEqual(model.pick, expected, "seed \(seed)")
            XCTAssertNotEqual(model.pick?.greeting?.text, "Morning only", "a morning line is not eligible at 19:05")
            XCTAssertTrue(["Good \(MobileDraftWelcome.daypartName(.evening)), Ada.", "Back to AnotherTerminal"]
                .contains(try XCTUnwrap(model.greeting(Self.inputs))))
            XCTAssertEqual(model.caption(Self.inputs), "2 working, 1 waiting",
                           "the counts are the phone's catalogue")
        }
    }

    func testAGuestsPhoneHasNoNameSoItsUserLinesAreIneligible() {
        let clock = Clock(now: Self.evening, seed: 3)
        let model = MobileDraftWelcomeModel(environment: environment(clock))
        var guest = Self.inputs
        guest.user = nil
        model.arrive(Self.welcome(greeting: [Line(text: "Wake up, {user}.")]), inputs: guest)
        XCTAssertNil(model.pick?.greeting)
        XCTAssertNil(model.greeting(guest), "the phone shows no greeting rather than a hole")
    }

    /// Facts live in the Mac's extension registry and are not projected to the phone, so a
    /// `{fact:KEY}` line is never eligible here; the pool's other lines still are.
    func testAFactLineIsNeverShownOnThePhone() {
        let clock = Clock(now: Self.evening, seed: 5)
        let model = MobileDraftWelcomeModel(environment: environment(clock))
        model.arrive(Self.welcome(
            greeting: [Line(text: "CI is {fact:ci.status}.", weight: 10)],
            caption: [Line(text: "{fact:weather.summary@2} outside")]
        ), inputs: Self.inputs)
        XCTAssertNil(model.pick?.greeting)
        XCTAssertNil(model.pick?.caption)
        XCTAssertNil(model.greeting(Self.inputs))
        XCTAssertNil(model.caption(Self.inputs))
        XCTAssertTrue(model.context(Self.inputs).facts.isEmpty, "the phone states no facts")

        let mixed = MobileDraftWelcomeModel(environment: environment(Clock(now: Self.evening, seed: 5)))
        mixed.arrive(Self.welcome(greeting: [
            Line(text: "CI is {fact:ci.status}.", weight: 10),
            Line(text: "Plain words.")
        ]), inputs: Self.inputs)
        XCTAssertEqual(mixed.greeting(Self.inputs), "Plain words.")
    }

    func testTheAppsShareOfAGreetingIsThePhonesOwnScreenWithNoGreeting() {
        let welcome = Self.welcome(greeting: [Line(text: "Theme line")], includesAppLines: true)
        var appShare = 0
        for seed in 0..<400 {
            let model = MobileDraftWelcomeModel(environment: environment(Clock(now: Self.evening, seed: UInt64(seed))))
            model.arrive(welcome, inputs: Self.inputs)
            if model.greeting(Self.inputs) == nil { appShare += 1 }
        }
        XCTAssertEqual(Double(appShare) / 400, 0.5, accuracy: 0.08,
                       "one theme line of weight 1 beside the app's one share")
    }

    func testAThemeChangeThatKeepsThePoolsKeepsThePick() throws {
        let clock = Clock(now: Self.evening, seed: 5)
        let model = MobileDraftWelcomeModel(environment: environment(clock))
        let lines = (0..<10).map { Line(text: "Line \($0)") }
        model.arrive(Self.welcome(greeting: lines), inputs: Self.inputs)
        let first = try XCTUnwrap(model.pick)
        for _ in 0..<10 {
            model.arrive(RemoteThemeWelcome(mark: .app, greeting: .init(lines: lines)), inputs: Self.inputs)
            XCTAssertEqual(model.pick, first, "a mark change does not re-pick the words")
        }
        model.arrive(Self.welcome(greeting: [Line(text: "Another pool")]), inputs: Self.inputs)
        XCTAssertEqual(model.pick?.greeting?.text, "Another pool")
        model.arrive(nil, inputs: Self.inputs)
        XCTAssertNil(model.pick, "no welcome is the phone's own screen")
    }

    // MARK: - Minute

    func testTheMinuteRendersAClockLineOnlyWhileTheScreenIsVisible() throws {
        let clock = Clock(now: Self.evening, seed: 9)
        let model = MobileDraftWelcomeModel(environment: environment(clock))
        model.arrive(Self.welcome(greeting: [Line(text: "It is {time}")]), inputs: Self.inputs)
        XCTAssertEqual(model.greeting(Self.inputs), "It is 19:05")
        XCTAssertTrue(clock.scheduled.isEmpty, "nothing runs before the screen is visible")
        XCTAssertFalse(model.isTicking)

        model.setVisible(true)
        let tick = try XCTUnwrap(clock.scheduled.last)
        XCTAssertEqual(tick.date.timeIntervalSince(Self.evening), 30, accuracy: 0.001,
                       "the next render is on the minute, not a minute from now")
        clock.now = tick.date
        tick.fire()
        XCTAssertEqual(model.greeting(Self.inputs), "It is 19:06")
        XCTAssertEqual(clock.scheduled.count, 2, "a fired minute schedules the next while visible")

        model.setVisible(false)
        XCTAssertFalse(model.isTicking)
        XCTAssertEqual(clock.cancelled, 1, "leaving the screen cancels the pending minute")
        clock.now = clock.now.addingTimeInterval(600)
        XCTAssertEqual(model.greeting(Self.inputs), "It is 19:06", "a hidden screen is not re-rendered")
        model.setVisible(true)
        XCTAssertEqual(model.greeting(Self.inputs), "It is 19:16", "returning reads the clock at once")
        XCTAssertTrue(model.isTicking)
    }

    func testALineThatDoesNotReadTheClockSchedulesNothing() {
        let clock = Clock(now: Self.evening, seed: 9)
        let model = MobileDraftWelcomeModel(environment: environment(clock))
        model.arrive(Self.welcome(greeting: [Line(text: "Hello, {user} in {project}")]), inputs: Self.inputs)
        model.setVisible(true)
        XCTAssertTrue(clock.scheduled.isEmpty)
        XCTAssertFalse(model.isTicking)
        model.arrive(Self.welcome(greeting: [Line(text: "{days_until:12-24} sleeps")]), inputs: Self.inputs)
        XCTAssertTrue(model.isTicking, "a new pool that reads the calendar starts the minute")
        model.arrive(nil, inputs: Self.inputs)
        XCTAssertFalse(model.isTicking)
    }

    // MARK: - Ground

    func testTheWelcomesOwnGroundAndReduceTransparencyDropsItsPicture() throws {
        let digest = String(repeating: "e", count: 64)
        let assets = MobileThemeAssets.shared
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.magenta.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        assets.images.setObject(picture, forKey: digest as NSString)
        defer { assets.images.removeObject(forKey: digest as NSString) }
        let theme = RemoteThemePalette(RemoteThemeDTO(
            id: "welcome-ground", name: "Welcome ground", mode: .dark,
            colors: ["ground": "#050805", "accent": "#00FF41"],
            material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1),
            assets: [RemoteThemeAsset(slot: "welcome", digest: digest, byteCount: 512,
                                      pixelWidth: 8, pixelHeight: 8, opacity: 0.6)],
            welcome: RemoteThemeWelcome(backdrop: .init(
                gradient: .init(stops: [.init(color: "#001100", position: 0), .init(color: "#003300", position: 1)],
                                angleDegrees: 180),
                particles: .init(style: .embers, density: 1, speed: 1)
            ))
        ))
        XCTAssertEqual(MobileThemeBackdropDecoration.forNewChat(theme), .welcome)
        XCTAssertEqual(MobileThemeBackdropDecoration.forNewChat(RemoteThemePalette(nil)), .material)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let backdrop = MobileThemeBackdropView(frame: window.bounds)
        backdrop.permitsMotion = { true }; backdrop.sceneIsActive = { _ in true }
        var plain = false
        backdrop.prefersPlainGround = { plain }
        window.addSubview(backdrop)
        defer { backdrop.removeFromSuperview() }
        backdrop.isPresentationActive = true

        backdrop.apply(theme)
        XCTAssertFalse(backdrop.showsPicture, "every other screen stands on the material, which has none")
        XCTAssertFalse(backdrop.showsGradient)

        backdrop.decoration = .welcome
        XCTAssertTrue(backdrop.showsPicture)
        XCTAssertTrue(backdrop.showsParticles)
        XCTAssertTrue(backdrop.showsGradient)

        plain = true
        NotificationCenter.default.post(name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        XCTAssertFalse(backdrop.showsPicture, "Reduce Transparency drops the welcome's picture")
        XCTAssertFalse(backdrop.showsParticles)
        XCTAssertTrue(backdrop.showsGradient, "and keeps its authored gradient")

        plain = false
        NotificationCenter.default.post(name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        XCTAssertTrue(backdrop.showsPicture)
    }

    // MARK: - Cache

    func testAWelcomeBearingThemeFitsTheArchiveAndOlderWelcomesYieldFirst() throws {
        let suite = "MobileDraftWelcomeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // The largest welcome the wire admits: its whole text budget in three-byte glyphs.
        let lines = (0..<64).map { Line(text: String(repeating: "ア", count: 150) + "\($0)") }
        func theme(_ index: Int) -> RemoteThemeDTO {
            RemoteThemeDTO(
                id: "theme-\(index)", name: "Theme \(index)", mode: .dark,
                colors: ["ground": "#101010", "label": "#F0F0F0"],
                material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1),
                welcome: RemoteThemeWelcome(
                    greeting: .init(lines: lines), caption: .init(lines: lines), user: "Ada"
                )
            )
        }
        let store = MobileThemeCacheStore(defaults: defaults)
        for index in 0..<8 {
            XCTAssertTrue(store.remember(theme(index), for: "host:mac-\(index)"),
                          "a welcome never stops a palette being remembered")
            XCTAssertEqual(store.theme(for: "host:mac-\(index)"), theme(index),
                           "the Mac just heard from keeps its welcome")
        }
        let reloaded = MobileThemeCacheStore(defaults: defaults)
        XCTAssertEqual(reloaded.theme(for: "host:mac-7"), theme(7))
        let oldest = try XCTUnwrap(reloaded.theme(for: "host:mac-0"))
        XCTAssertNil(oldest.welcome, "an older Mac's welcome yields first")
        XCTAssertEqual(oldest.colors, theme(0).colors, "its palette stays")
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(defaults.data(forKey: MobileThemeCacheStore.archiveKey)).count,
            MobileThemeCacheStore.maximumArchiveBytes
        )

        let written = defaults.data(forKey: MobileThemeCacheStore.archiveKey)
        XCTAssertTrue(reloaded.remember(theme(7), for: "host:mac-7"))
        XCTAssertEqual(defaults.data(forKey: MobileThemeCacheStore.archiveKey), written,
                       "the same theme arriving again writes nothing")
    }

    // MARK: - Render

    func testTheDraftDrawsAWelcomeInLightAndDark() throws {
        for mode in [RemoteThemeMode.dark, .light] {
            let ink = mode == .dark ? "#FF00FF" : "#B0008C"
            let plain = try render(theme(mode: mode, welcome: nil))
            let welcomed = try render(theme(mode: mode, welcome: RemoteThemeWelcome(
                mark: .app,
                markSize: 56,
                greeting: .init(lines: [Line(text: "Wake up, {user}.")],
                                style: .init(scale: 1.6, weight: .heavy, ink: ink)),
                caption: .init(lines: [Line(text: "Follow the white rabbit.")]),
                scrim: .init(hero: 0.5, prompt: 0.6),
                backdrop: .init(gradient: .init(
                    stops: mode == .dark
                        ? [.init(color: "#001A00", position: 0), .init(color: "#000000", position: 1)]
                        : [.init(color: "#FFF6E0", position: 0), .init(color: "#F0E8FF", position: 1)],
                    angleDegrees: 180
                )),
                user: "Ada"
            )))
            attach(plain, named: "draft-\(mode.rawValue)-no-welcome")
            attach(welcomed, named: "draft-\(mode.rawValue)-welcome")
            let target = try XCTUnwrap(UIColor(remoteHex: ink))
            XCTAssertGreaterThan(count(target, in: welcomed), 60,
                                 "the greeting is set in the theme's ink (\(mode.rawValue))")
            XCTAssertLessThan(count(target, in: plain), 5,
                              "without a welcome the draft is the phone's own (\(mode.rawValue))")
        }
    }

    private func theme(mode: RemoteThemeMode, welcome: RemoteThemeWelcome?) -> RemoteThemeDTO {
        let dark = mode == .dark
        return RemoteThemeDTO(
            id: "welcome-\(mode.rawValue)", name: "Welcome", mode: mode,
            colors: [
                "ground": dark ? "#050805" : "#FAF7F0",
                "surface": dark ? "#0A100A" : "#FFFFFF",
                "panel": dark ? "#0E160E" : "#F2EEE4",
                "label": dark ? "#D8FFD8" : "#1A1A1A",
                "secondary_label": dark ? "#8FB88F" : "#555555",
                "tertiary_label": dark ? "#5C7A5C" : "#888888",
                "accent": dark ? "#00FF41" : "#22AA66",
                "border": dark ? "#1F331F" : "#DDD6C8"
            ],
            material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1),
            welcome: welcome
        )
    }

    private func render(_ theme: RemoteThemeDTO) throws -> UIImage {
        let suite = "MobileDraftWelcomeTests.render.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let continuity = MobileSessionContinuityStore(defaults: defaults)
        let model = RemoteAppModel(continuity: continuity)
        model.startDemo()
        let screen = NavigationStack {
            SessionDraftView(draft: MobileSessionDraft())
        }
        .environmentObject(model)
        .environmentObject(continuity)
        .environmentObject(MobileTerminalKeyboardStore())
        .environmentObject(RemoteNotificationManager())
        .mobileTheme(RemoteThemePalette(theme))
        let controller = UIHostingController(rootView: screen)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        window.layoutIfNeeded()
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// Pixels within a small distance of `color`: how a render's finding becomes an assertion.
    private func count(_ color: UIColor, in image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let target = [red, green, blue].map { Int($0 * 255) }
        var matches = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let distance = abs(Int(pixels[index]) - target[0]) + abs(Int(pixels[index + 1]) - target[1])
                + abs(Int(pixels[index + 2]) - target[2])
            if distance < 24 { matches += 1 }
        }
        return matches
    }

    private func attach(_ image: UIImage, named name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
