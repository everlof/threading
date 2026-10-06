import AppKit
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// Shared fixtures for the composer's welcome: a theme built by hand around a `ThemeWelcome`
/// (never through the tools), stored pictures for its logo, mascot and backdrop, a seeded
/// generator, a fixed moment, and a clock whose ticks a test fires itself.
@MainActor
enum ThemeWelcomeFixtures {

    /// Run-unique, because the asset store is keyed by it and a sibling class may run alongside.
    static let themeID = AppThemeID("custom-welcome-tests-\(UUID().uuidString.prefix(8).lowercased())")

    // MARK: - Themes

    /// The stock adaptive theme with `welcome` stated on both variants, and — when asked — a
    /// sidebar brand logo and mascot whose pictures are in the store.
    static func theme(
        _ welcome: ThemeWelcome?,
        id: AppThemeID = themeID,
        logo: Bool = false,
        mascot: Bool = false
    ) throws -> AppTheme {
        let base = AppThemeStyles.threading
        var variants: [AppTheme.VariantKind: AppTheme.Variant] = [:]
        for kind in base.availableVariants {
            var variant = try XCTUnwrap(base.variant(kind)).replacingWelcome(welcome)
            if logo || mascot {
                var style = variant.sidebar ?? SidebarStyle()
                if logo {
                    let name = try XCTUnwrap(ThemeAssetStore.store(
                        imageData: try logoPNG(),
                        for: id,
                        slot: .logo,
                        variant: kind
                    ))
                    style.brand = SidebarStyle.Brand(logo: .asset(name))
                }
                if mascot {
                    let name = try XCTUnwrap(ThemeAssetStore.storeMascotPose(
                        imageData: try mascotPNG(),
                        for: id,
                        mood: .idle,
                        variant: kind
                    ))
                    style.mascot = ThemeMascot(poses: [.idle: .init(asset: name, motion: .bob)])
                }
                variant = variant.replacingSidebar(style)
            }
            variants[kind] = variant
        }
        return AppTheme(
            id: id,
            name: "Welcome Fixture",
            mode: base.mode,
            summary: nil,
            variants: variants
        )
    }

    /// A welcome with a stated line per slot and nothing else.
    static func words(
        greeting: [ThemeWelcome.Line]? = nil,
        caption: [ThemeWelcome.Line]? = nil,
        includesAppLines: Bool = false
    ) -> ThemeWelcome {
        ThemeWelcome(
            greeting: greeting.map {
                ThemeWelcome.Wording(lines: $0, includesAppLines: includesAppLines)
            },
            caption: caption.map { ThemeWelcome.Wording(lines: $0) }
        )
    }

    /// The whole vocabulary at once: a wash in the variant's own roles with a picture and snow,
    /// the theme's mark at 64 points, a styled greeting and caption that read the clock, and
    /// both veils.
    static func dressedWelcome(mark: ThemeWelcome.Mark?, picture: String? = nil) -> ThemeWelcome {
        let base = AppThemeStyles.threading
        let dark = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        let deep = base.resolved(.accent, appearance: dark)
        return ThemeWelcome(
            backdrop: ThemeBackdrop(
                gradient: ThemeBackdrop.Gradient(
                    stops: [
                        .init(color: Design.Surface.ground, position: 0),
                        .init(color: deep.withAlphaComponent(0.55), position: 1)
                    ],
                    angleDegrees: 165
                ),
                image: picture.map { ThemeBackdrop.ImageLayer(asset: $0, mode: .fill, opacity: 0.4) },
                particles: ThemeParticles(style: .snow, colors: [.role(.label)], density: 0.7)
            ),
            mark: mark,
            markSize: 64,
            greeting: ThemeWelcome.Wording(
                lines: [ThemeWelcome.Line(
                    text: "Good {daypart}, {user}.",
                    when: ThemeWelcome.Condition(dayparts: [.evening])
                )],
                style: ThemeWelcome.TextStyle(
                    scale: 1.4,
                    weight: .bold,
                    ink: .role(.accent),
                    typeface: .rounded
                )
            ),
            caption: ThemeWelcome.Wording(
                lines: [ThemeWelcome.Line(text: "{time} · {working} working, {waiting} waiting")],
                style: ThemeWelcome.TextStyle(ink: .role(.secondaryLabel), typeface: .monospaced)
            ),
            scrim: ThemeWelcome.Scrim(hero: 0.55, prompt: 0.7)
        )
    }

    // MARK: - Pictures

    static func logoPNG() throws -> Data {
        try png(width: 64, height: 64) { rect in
            NSColor(srgbRed: 0.85, green: 0.25, blue: 0.3, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 14, yRadius: 14).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 20, dy: 20)).fill()
        }
    }

    static func mascotPNG() throws -> Data {
        try png(width: 48, height: 64) { rect in
            NSColor(srgbRed: 0.95, green: 0.7, blue: 0.2, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: 0, width: 40, height: 44)).fill()
            NSBezierPath(ovalIn: NSRect(x: 10, y: 34, width: 28, height: 28)).fill()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 16, y: 46, width: 5, height: 5)).fill()
            NSBezierPath(ovalIn: NSRect(x: 27, y: 46, width: 5, height: 5)).fill()
            _ = rect
        }
    }

    /// Diagonal stripes, so the backdrop picture is visibly a picture.
    static func wallpaperPNG() throws -> Data {
        try png(width: 480, height: 320) { rect in
            NSColor(srgbRed: 0.2, green: 0.45, blue: 0.85, alpha: 1).setFill()
            rect.fill()
            NSColor(srgbRed: 0.95, green: 0.85, blue: 0.3, alpha: 1).setFill()
            for index in 0..<8 {
                let path = NSBezierPath()
                let offset = CGFloat(index) * 80 - 120
                path.move(to: NSPoint(x: offset, y: 0))
                path.line(to: NSPoint(x: offset + 40, y: 0))
                path.line(to: NSPoint(x: offset + 240, y: rect.height))
                path.line(to: NSPoint(x: offset + 200, y: rect.height))
                path.close()
                path.fill()
            }
        }
    }

    private static func png(
        width: CGFloat,
        height: CGFloat,
        draw: @escaping (NSRect) -> Void
    ) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            draw(rect)
            return true
        }
        return try XCTUnwrap(
            NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
                .representation(using: .png, properties: [:])
        )
    }

    // MARK: - Moment

    nonisolated static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    /// Monday 5 October 2026, 19:42:30 UTC — an evening.
    nonisolated static var evening: Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 5, hour: 19, minute: 42, second: 30
        )) ?? Date()
    }

    static func context(
        at date: Date = evening,
        project: String? = nil,
        user: String? = "Ada"
    ) -> ThemeWelcome.Context {
        ThemeWelcome.Context(
            date: date,
            calendar: calendar,
            locale: Locale(identifier: "en_GB"),
            project: project,
            user: user,
            working: 2,
            waiting: 1,
            daypartName: ComposerWelcome.daypartName
        )
    }

    // MARK: - Environment

    /// A clock the test moves and fires by hand, and the seeded randomness beside it.
    final class Clock {
        typealias Scheduled = (date: Date, tick: ComposerWelcomeTick, fire: @MainActor () -> Void)

        var now: Date
        private(set) var scheduled: [Scheduled] = []
        private(set) var draws = 0
        private var generator: WelcomeSeededGenerator

        init(now: Date = ThemeWelcomeFixtures.evening, seed: UInt64 = 7) {
            self.now = now
            generator = WelcomeSeededGenerator(state: seed)
        }

        /// The ticks not yet cancelled.
        @MainActor
        var pending: [Scheduled] {
            scheduled.filter { !$0.tick.isCancelled }
        }

        func draw() -> UInt64 {
            draws += 1
            return generator.next()
        }

        /// Moves to the pending tick's moment and fires it, as the run loop would.
        @MainActor
        func fireNext() {
            guard let next = pending.first else { return }
            now = next.date
            next.tick.invalidate()
            next.fire()
        }

        /// Captured strongly: a composer outliving its test may still be asked for the time.
        /// `fact` stands in for the registry; `nextTurn`, when stated, receives each deferred
        /// fact render instead of the main queue, so a test runs it when it chooses.
        @MainActor
        func environment(
            user: String? = "Ada",
            counts: (working: Int, waiting: Int) = (2, 1),
            fact: @escaping @MainActor (ExtensionFactKey, ProjectID?) -> ExtensionFact? = { _, _ in nil },
            nextTurn: (@MainActor (_ work: @escaping @MainActor @Sendable () -> Void) -> Void)? = nil
        ) -> ComposerWelcomeEnvironment {
            var environment = ComposerWelcomeEnvironment(
                now: { self.now },
                calendar: { ThemeWelcomeFixtures.calendar },
                locale: { Locale(identifier: "en_GB") },
                userName: { user },
                sessionCounts: { counts },
                random: { self.draw() },
                schedule: { date, fire in
                    let tick = ComposerWelcomeTick {}
                    self.scheduled.append((date, tick, fire))
                    return tick
                }
            )
            environment.fact = fact
            if let nextTurn { environment.nextTurn = nextTurn }
            return environment
        }
    }

    // MARK: - Renders

    static var renderDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
    }
}

/// SplitMix64 — a test names its seed and the pick is a fact rather than a flake.
struct WelcomeSeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
