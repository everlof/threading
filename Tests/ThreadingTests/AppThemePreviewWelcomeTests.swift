import AppKit
import XCTest
@testable import Threading

/// `preview_app_theme`'s new-session band: a variant that states a welcome is drawn beneath its
/// window as the composer would wear it — backdrop, mark, greeting, caption, veils and a prompt
/// box — with words rendered from a fixed moment, invented values and a fixed seed; and a theme
/// without one previews exactly as it did before the band existed.
///
/// The PNGs land in `THREADING_RENDER_OUT` (or the temporary renders folder) as
/// `theme-preview-welcome-*.png`.
@MainActor
final class AppThemePreviewWelcomeTests: XCTestCase {

    private enum Geometry {
        /// One window frame: 470 points at the preview's 1.5 scale.
        static let windowPixels = 705
        static let widthPixels = 1140
    }

    /// Run-unique, because the asset store is keyed by it.
    private let themeID = AppThemeID("custom-preview-welcome-\(UUID().uuidString.prefix(8).lowercased())")
    private var previousTheme: AppTheme!

    override func setUp() async throws {
        try await super.setUp()
        previousTheme = AppThemeLibrary.current
    }

    override func tearDown() async throws {
        AppThemeLibrary.apply(previousTheme)
        ThemeAssetStore.removeAll(for: themeID)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// Lines that read every invented value. At the sample's Tuesday morning only the first
    /// greeting is eligible — the night and Christmas lines are there to be passed over.
    private func wordedWelcome(
        mark: ThemeWelcome.Mark? = nil,
        markSize: Double? = 64,
        scrim: ThemeWelcome.Scrim? = ThemeWelcome.Scrim(hero: 0.55, prompt: 0.7),
        drift: Bool = false
    ) -> ThemeWelcome {
        let dark = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        let deep = AppThemeStyles.threading.resolved(.accent, appearance: dark)
        return ThemeWelcome(
            backdrop: ThemeBackdrop(
                gradient: ThemeBackdrop.Gradient(
                    stops: [
                        .init(color: Design.Surface.ground, position: 0),
                        .init(color: deep.withAlphaComponent(0.6), position: 1)
                    ],
                    angleDegrees: 165,
                    drift: drift ? ThemeGradientDrift(duration: 8, distance: 0.25) : nil
                ),
                particles: ThemeParticles(style: .snow, colors: [.role(.label)], density: 0.7)
            ),
            mark: mark,
            markSize: markSize,
            greeting: ThemeWelcome.Wording(
                lines: [
                    ThemeWelcome.Line(text: "Good {daypart}, {user}.", weight: 3),
                    ThemeWelcome.Line(
                        text: "Wake up, {user}…",
                        when: ThemeWelcome.Condition(dayparts: [.night]),
                        weight: 10
                    ),
                    ThemeWelcome.Line(
                        text: "Merry Christmas.",
                        when: ThemeWelcome.Condition(dates: [ThemeWelcome.DateSpan(
                            from: ThemeWelcome.MonthDay(month: 12, day: 24),
                            to: ThemeWelcome.MonthDay(month: 12, day: 26)
                        )]),
                        weight: 10
                    )
                ],
                style: ThemeWelcome.TextStyle(scale: 1.4, weight: .bold, ink: .role(.accent), typeface: .rounded)
            ),
            caption: ThemeWelcome.Wording(
                lines: [ThemeWelcome.Line(text: "{working} working, {waiting} waiting on {project}")],
                style: ThemeWelcome.TextStyle(ink: .role(.secondaryLabel), typeface: .monospaced)
            ),
            scrim: scrim
        )
    }

    private func theme(
        _ welcome: ThemeWelcome?,
        logo: Bool = false,
        mascot: Bool = false
    ) throws -> AppTheme {
        try ThemeWelcomeFixtures.theme(welcome, id: themeID, logo: logo, mascot: mascot)
    }

    // MARK: - The band

    func testAWelcomeAddsANewSessionBandBeneathEachWindowWithTheSampleWords() throws {
        let previous = AppThemePalette.current
        let rendering = try XCTUnwrap(AppThemePreviewService.rendering(
            try theme(wordedWelcome(mark: .app)),
            kinds: [.light, .dark]
        ))
        try write(rendering.image, "both")

        XCTAssertEqual(AppThemePalette.current.id, previous.id, "the palette is put back")
        XCTAssertEqual(rendering.welcomes.map(\.kind), [.light, .dark])
        let bandHeight = try XCTUnwrap(rendering.welcomes.first?.image.height)
        XCTAssertEqual(rendering.image.width, Geometry.widthPixels)
        XCTAssertEqual(rendering.image.height, (Geometry.windowPixels + bandHeight) * 2,
            "each appearance is its window, then its new-session band")

        for band in rendering.welcomes {
            let name = band.kind.rawValue
            XCTAssertEqual(band.image.width, Geometry.widthPixels, name)
            // The only line eligible at Tuesday 09:41, with the invented name and counts.
            XCTAssertEqual(band.greeting, "Good morning, Ada.", name)
            XCTAssertEqual(band.caption, "2 working, 1 waiting on threading", name)
            XCTAssertEqual(band.mark, .app, name)
            XCTAssertEqual(band.markSide, 64, name)
            XCTAssertTrue(band.isDressed, "\(name): the backdrop dresses the band")
            XCTAssertEqual(band.veils.map(\.opacity), [0.55, 0.7], "\(name): a veil behind each region")
        }

        // Nothing of the person's: not their name, whatever the Mac is signed in as.
        if let given = ComposerWelcome.givenName(from: NSFullUserName()), given != WelcomeNames.sample {
            XCTAssertFalse(rendering.welcomes.contains { $0.greeting.contains(given) })
        }

        // What the stack holds beneath each window is that appearance's band, pixel for pixel.
        for (index, band) in rendering.welcomes.enumerated() {
            let stacked = try XCTUnwrap(rendering.image.cropping(to: CGRect(
                x: 0,
                y: (Geometry.windowPixels + bandHeight) * index + Geometry.windowPixels,
                width: Geometry.widthPixels,
                height: bandHeight
            )))
            XCTAssertEqual(try bytes(stacked), try bytes(band.image), band.kind.rawValue)
        }
        // And the two appearances are two different bands.
        XCTAssertGreaterThan(try changedPixels(
            rendering.welcomes[0].image,
            rendering.welcomes[1].image,
            region: CGRect(x: 0, y: 0, width: Geometry.widthPixels, height: bandHeight)
        ), 10_000)
    }

    func testThePickIsTheSameEveryTimeAndInEveryAppearance() throws {
        // Five eligible lines of equal weight: a different seed or moment would move the pick.
        var welcome = wordedWelcome()
        welcome.greeting = ThemeWelcome.Wording(lines: (1...5).map {
            ThemeWelcome.Line(text: "Line \($0) for {user} on {weekday}")
        })
        let source = try theme(welcome)
        let first = try XCTUnwrap(AppThemePreviewService.rendering(source, kinds: [.light, .dark]))
        let second = try XCTUnwrap(AppThemePreviewService.rendering(source, kinds: [.light, .dark]))
        let greetings = (first.welcomes + second.welcomes).map(\.greeting)
        XCTAssertEqual(Set(greetings).count, 1, "\(greetings)")
        XCTAssertTrue(try XCTUnwrap(greetings.first).hasSuffix("for Ada on Tuesday"), "\(greetings)")
    }

    func testTheSampleMomentIsTheOneTheTextNames() {
        let calendar = AppThemePreviewService.WelcomeSample.calendar
        let moment = AppThemePreviewService.WelcomeSample.moment
        let parts = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: moment)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 3, 10, 9, 41])
        XCTAssertEqual(parts.weekday, 3, "a Tuesday")
        XCTAssertEqual(AppThemePreviewService.WelcomeSample.momentDescription, "Tuesday 10 March 2026, 09:41 UTC")
    }

    func testEachMarkTheThemeNamesStandsOverTheGreeting() throws {
        let expectations: [(ThemeWelcome.Mark?, ThemeWelcomeMarkView.Shown)] = [
            (nil, .app), (.app, .app), (.logo, .logo), (.mascot, .mascot), (.hidden, .hidden)
        ]
        for (stated, shown) in expectations {
            let source = try theme(wordedWelcome(mark: stated), logo: true, mascot: true)
            let band = try XCTUnwrap(AppThemePreviewService.welcomeBand(source, kind: .dark))
            XCTAssertEqual(band.mark, shown, "\(String(describing: stated))")
            try write(band.image, "mark-\(stated?.rawValue ?? "absent")")
        }
        // A mark the theme cannot draw is the app's, as in the composer.
        let bare = try XCTUnwrap(AppThemePreviewService.welcomeBand(
            try theme(wordedWelcome(mark: .logo)),
            kind: .light
        ))
        XCTAssertEqual(bare.mark, .app)
        // The theme's size, and the app's when it states none.
        let sized = try XCTUnwrap(AppThemePreviewService.welcomeBand(
            try theme(wordedWelcome(mark: .app, markSize: 120)),
            kind: .light
        ))
        XCTAssertEqual(sized.markSide, 120)
        let unsized = try XCTUnwrap(AppThemePreviewService.welcomeBand(
            try theme(wordedWelcome(mark: .app, markSize: nil)),
            kind: .light
        ))
        XCTAssertEqual(unsized.markSide, ComposerDefaults.heroMarkSide)
    }

    func testTheScrimsAreDrawnBehindTheHeroAndThePrompt() throws {
        let veiled = try XCTUnwrap(AppThemePreviewService.welcomeBand(
            try theme(wordedWelcome(mark: .app)),
            kind: .dark
        ))
        let bare = try XCTUnwrap(AppThemePreviewService.welcomeBand(
            try theme(wordedWelcome(mark: .app, scrim: nil)),
            kind: .dark
        ))
        XCTAssertEqual(veiled.veils.count, 2)
        XCTAssertTrue(bare.veils.isEmpty)
        XCTAssertEqual(veiled.image.height, bare.image.height)
        // The veils lie over the whole band's middle; the words and the box are the same.
        let region = CGRect(x: 0, y: 0, width: veiled.image.width, height: veiled.image.height)
        XCTAssertGreaterThan(try changedPixels(veiled.image, bare.image, region: region), 5_000)
        try write(bare.image, "no-scrim")
    }

    func testThreeFramesSampleTheWelcomesDrift() throws {
        let source = try theme(wordedWelcome(mark: .app, drift: true))
        let one = try XCTUnwrap(AppThemePreviewService.rendering(source, kinds: [.dark]))
        let three = try XCTUnwrap(AppThemePreviewService.rendering(source, kinds: [.dark], frameCount: 3))
        let band = try XCTUnwrap(one.welcomes.first).image
        XCTAssertEqual(three.image.height, (Geometry.windowPixels + band.height) * 3)
        XCTAssertEqual(three.welcomes.count, 1, "one report per appearance")

        // The three bands follow the three windows, and the drift moves between them.
        let firstBandTop = Geometry.windowPixels * 3
        let first = try XCTUnwrap(three.image.cropping(to: CGRect(
            x: 0, y: firstBandTop, width: band.width, height: band.height
        )))
        let second = try XCTUnwrap(three.image.cropping(to: CGRect(
            x: 0, y: firstBandTop + band.height, width: band.width, height: band.height
        )))
        XCTAssertEqual(try pixels(first, region: CGRect(x: 0, y: 0, width: band.width, height: band.height)),
            try pixels(band, region: CGRect(x: 0, y: 0, width: band.width, height: band.height)),
            "the first sample is the single frame's")
        XCTAssertGreaterThan(try changedPixels(first, second, region: CGRect(
            x: 0, y: 0, width: band.width, height: band.height
        )), 1_000)
        try write(three.image, "drift")
    }

    // MARK: - No welcome

    /// Today's preview, byte for byte: a theme stating no welcome — or an empty one — draws only
    /// the window, at the window's geometry, and the window above a welcome's band is that same
    /// window to the last byte.
    func testAThemeWithoutAWelcomeKeepsTodaysPreviewByteForByte() throws {
        let plain = try XCTUnwrap(AppThemePreviewService.rendering(try theme(nil), kinds: [.light, .dark]))
        XCTAssertTrue(plain.welcomes.isEmpty)
        XCTAssertEqual(plain.image.width, Geometry.widthPixels)
        XCTAssertEqual(plain.image.height, Geometry.windowPixels * 2)
        let rendered = try XCTUnwrap(AppThemePreviewService.render(try theme(nil), kinds: [.light, .dark]))
        XCTAssertEqual(try bytes(rendered), try bytes(plain.image))

        let empty = try XCTUnwrap(AppThemePreviewService.rendering(try theme(ThemeWelcome()), kinds: [.light, .dark]))
        XCTAssertTrue(empty.welcomes.isEmpty)
        XCTAssertEqual(try bytes(empty.image), try bytes(plain.image), "an empty welcome is no welcome")

        for (index, kind) in [AppTheme.VariantKind.light, .dark].enumerated() {
            let window = try XCTUnwrap(AppThemePreviewService.render(try theme(nil), kinds: [kind]))
            let dressed = try XCTUnwrap(AppThemePreviewService.render(
                try theme(wordedWelcome(mark: .app)),
                kinds: [kind]
            ))
            XCTAssertGreaterThan(dressed.height, window.height)
            let top = try XCTUnwrap(dressed.cropping(to: CGRect(
                x: 0, y: 0, width: window.width, height: window.height
            )))
            XCTAssertEqual(try bytes(top), try bytes(window), "\(kind): the window is untouched")
            let stacked = try XCTUnwrap(plain.image.cropping(to: CGRect(
                x: 0, y: window.height * index, width: window.width, height: window.height
            )))
            XCTAssertEqual(try bytes(stacked), try bytes(window), "\(kind): stacking is unchanged")
        }
    }

    // MARK: - The tool

    func testTheToolsTextNamesTheWordsTheBandDraws() async throws {
        AppThemeLibrary.apply(try theme(wordedWelcome(mark: .logo)))
        let result = await previewOfTheActiveTheme()
        XCTAssertFalse(result.isError, result.text)
        for fragment in [
            "new-session composer (⌘N)",
            "Tuesday 10 March 2026, 09:41 UTC",
            "dark greets \"Good morning, Ada.\" over the caption \"2 working, 1 waiting on threading\"",
            // No logo picture: the band draws the fallback, and the text says so.
            "mark app"
        ] {
            XCTAssertTrue(result.text.contains(fragment), "\(fragment): \(result.text)")
        }

        AppThemeLibrary.apply(try theme(nil))
        let plain = await previewOfTheActiveTheme()
        XCTAssertFalse(plain.isError, plain.text)
        XCTAssertFalse(plain.text.contains("new-session"), plain.text)
    }

    // MARK: - Helpers

    /// The tool as an agent calls it, on the active theme's dark appearance.
    private func previewOfTheActiveTheme() async -> MCPToolResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<MCPToolResult, Never>) in
            AppThemePreviewService.preview(
                PreviewAppThemeArguments(themeID: nil, appearance: "dark")
            ) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private enum WelcomeNames {
        static let sample = AppThemePreviewService.WelcomeSample.user
    }

    private func write(_ image: CGImage, _ name: String) throws {
        let directory = ThemeWelcomeFixtures.renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(AppThemePreviewService.pngData(image))
            .write(to: directory.appendingPathComponent("theme-preview-welcome-\(name).png"))
    }

    /// Every pixel, drawn into one fixed RGBA layout so two images compare by value.
    private func bytes(_ image: CGImage) throws -> [UInt8] {
        try pixels(image, region: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    private func pixels(_ image: CGImage, region: CGRect) throws -> [UInt8] {
        let crop = try XCTUnwrap(image.cropping(to: region))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: crop.width,
            height: crop.height,
            bitsPerComponent: 8,
            bytesPerRow: crop.width * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let pointer = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        return Array(UnsafeBufferPointer(start: pointer, count: crop.width * crop.height * 4))
    }

    private func changedPixels(_ before: CGImage, _ after: CGImage, region: CGRect) throws -> Int {
        let a = try pixels(before, region: region), b = try pixels(after, region: region)
        return stride(from: 0, to: min(a.count, b.count), by: 4).filter { index in
            (0..<4).contains { a[index + $0] != b[index + $0] }
        }.count
    }
}
