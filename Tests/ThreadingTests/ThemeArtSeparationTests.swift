import AppKit
import XCTest
@testable import Threading

/// The edge measure, the rim identity art is given, and the lines the authoring tools append —
/// driven by the case that motivated all three: a brown, dark-outlined cartoon drawn for a cream
/// light appearance and copied unchanged onto a near-black dark one.
@MainActor
final class ThemeArtSeparationTests: XCTestCase {

    private enum Palette {
        static let cream = NSColor(srgbRed: 0xF7 / 255, green: 0xF0 / 255, blue: 0xE3 / 255, alpha: 1)
        static let night = NSColor(srgbRed: 0x1C / 255, green: 0x16 / 255, blue: 0x11 / 255, alpha: 1)
        static let body = NSColor(srgbRed: 0x7A / 255, green: 0x4A / 255, blue: 0x21 / 255, alpha: 1)
        static let outline = NSColor(srgbRed: 0x3E / 255, green: 0x22 / 255, blue: 0x0E / 255, alpha: 1)
        static let rim = NSColor(srgbRed: 1, green: 0.96, blue: 0.89, alpha: 1)
    }

    private enum Fixture {
        static let side = 200
        /// The disk's radius and its outline's width, as shares of the side.
        static let radiusRatio: CGFloat = 0.4
        static let outlineRatio: CGFloat = 0.05
        /// Summed sRGB channel difference a raster round trip may cost.
        static let colourTolerance: CGFloat = 0.06
    }

    // MARK: - The Measure

    func testADarkOutlinedPictureSeparatesOnCreamButNotOnNight() throws {
        let cartoon = try XCTUnwrap(Self.cartoon())
        let onCream = try XCTUnwrap(ThemeArtSeparation.measure(cartoon, grounds: [rgb(Palette.cream)]))
        let onNight = try XCTUnwrap(ThemeArtSeparation.measure(cartoon, grounds: [rgb(Palette.night)]))

        XCTAssertTrue(onCream.separates, "a dark outline on cream: \(onCream.share)")
        XCTAssertFalse(onNight.separates, "a dark outline on near-black: \(onNight.share)")
    }

    func testEveryGroundThePictureCanLandOnMustBeCleared() throws {
        let cartoon = try XCTUnwrap(Self.cartoon())
        let both = try XCTUnwrap(
            ThemeArtSeparation.measure(cartoon, grounds: [rgb(Palette.cream), rgb(Palette.night)])
        )
        XCTAssertFalse(both.separates, "a gradient running into the dark stop still loses the edge")
    }

    func testAPictureWithNothingOpaqueHasNoMeasure() throws {
        let blank = try XCTUnwrap(Self.image(side: Fixture.side) { _ in })
        XCTAssertNil(ThemeArtSeparation.measure(blank, grounds: [rgb(Palette.cream)]))
    }

    // MARK: - The Rim

    func testTheRimSurroundsTheSilhouetteInItsInk() throws {
        let cartoon = try XCTUnwrap(Self.cartoon())
        let rimmed = try XCTUnwrap(ThemeArtSeparation.rimmed(cartoon, ink: Palette.rim.cgColor))
        let rim = Int((CGFloat(Fixture.side) * ThemeArtSeparation.rimWidthRatio).rounded(.up))
        XCTAssertEqual(rimmed.width, Fixture.side + rim * 2, "the canvas grows by the rim on both sides")

        let centre = Fixture.side / 2 + rim
        let radius = Int(CGFloat(Fixture.side) * Fixture.radiusRatio)
        let pixels = try XCTUnwrap(Self.pixels(rimmed))
        // On the horizontal centre line, which reads the same whichever way rows are stored.
        let inRim = pixels.colour(x: centre + radius + rim / 2, y: centre)
        XCTAssertLessThan(difference(inRim, Palette.rim), Fixture.colourTolerance, "the rim is the ink")
        XCTAssertLessThan(
            difference(pixels.colour(x: centre, y: centre), Palette.body),
            Fixture.colourTolerance,
            "the picture is drawn over its rim, unchanged"
        )
        XCTAssertEqual(pixels.alpha(x: 0, y: centre), 0, "beyond the rim stays transparent")
    }

    func testIdentityArtIsRimmedOnlyWhereItDisappearsAndOnlyOnce() throws {
        let source = try XCTUnwrap(Self.cartoon())
        let picture = NSImage(cgImage: source, size: NSSize(width: 100, height: 100))

        let full = Fixture.side
        let onCream = ThemeArtSeparation.legible(
            picture, grounds: [Palette.cream], ink: Palette.outline, maximumPixels: full
        )
        XCTAssertTrue(onCream === picture, "a picture that stands apart is drawn as authored")

        let onNight = ThemeArtSeparation.legible(
            picture, grounds: [Palette.night], ink: Palette.rim, maximumPixels: full
        )
        XCTAssertFalse(onNight === picture, "a picture that sinks into its ground is rimmed")
        XCTAssertTrue(
            ThemeArtSeparation.legible(picture, grounds: [Palette.night], ink: Palette.rim, maximumPixels: full)
                === onNight,
            "the rim is made once and served from the cache"
        )
        // The picture keeps its own point size; the rim sits outside it.
        let rim = CGFloat(Int((CGFloat(Fixture.side) * ThemeArtSeparation.rimWidthRatio).rounded(.up)))
        XCTAssertEqual(onNight.size.width, 100 * (CGFloat(Fixture.side) + rim * 2) / CGFloat(Fixture.side), accuracy: 0.01)
    }

    /// The rim costs the square of the side it is drawn at, so it is drawn at the most the place
    /// can show — while the picture keeps the point size it was given.
    func testTheRimIsDrawnNoLargerThanItsPlaceCanShow() throws {
        let picture = NSImage(cgImage: try XCTUnwrap(Self.cartoon()), size: NSSize(width: 100, height: 100))
        let limit = 50
        let rimmed = ThemeArtSeparation.legible(
            picture, grounds: [Palette.night], ink: Palette.rim, maximumPixels: limit
        )
        let rim = Int((CGFloat(limit) * ThemeArtSeparation.rimWidthRatio).rounded(.up))
        XCTAssertEqual(ThemeArtSeparation.pixelSize(of: rimmed).width, CGFloat(limit + rim * 2))
        XCTAssertEqual(rimmed.size.width, 100 * CGFloat(limit + rim * 2) / CGFloat(limit), accuracy: 0.01)
    }

    // MARK: - The Advisory

    func testACopiedLightPoseOnANightSidebarIsReportedAsACopy() throws {
        let data = try XCTUnwrap(Self.png(try XCTUnwrap(Self.cartoon())))
        let lines = ThemeArtAdvisory.lines(for: sample(
            path: "dark.sidebar.mascot.poses.idle",
            role: .mascot(mood: "idle"),
            ground: Palette.night,
            data: data,
            counterpart: data
        ))

        let line = try XCTUnwrap(lines.first, "the pose sinks into the column")
        XCTAssertTrue(line.hasPrefix("dark.sidebar.mascot.poses.idle:"), line)
        XCTAssertTrue(line.contains("lighter outline or rim"), line)
        XCTAssertTrue(line.contains("same picture as the light appearance's"), line)
    }

    func testTheSamePoseOnCreamEarnsNoLine() throws {
        let data = try XCTUnwrap(Self.png(try XCTUnwrap(Self.cartoon())))
        XCTAssertEqual(ThemeArtAdvisory.lines(for: sample(
            path: "light.sidebar.mascot.poses.idle",
            role: .mascot(mood: "idle"),
            ground: Palette.cream,
            data: data,
            counterpart: data
        )), [])
    }

    func testADockLogoTooSmallToFillItsPlateIsNamedWithTheSizeItNeeds() throws {
        let small = 100
        let data = try XCTUnwrap(Self.png(try XCTUnwrap(Self.cartoon(side: small))))
        let minimum = Int(GeneratedAppIcon.Layout.minimumSharpMarkPixels)
        XCTAssertGreaterThan(minimum, small, "the fixture must be under the floor it tests")

        let lines = ThemeArtAdvisory.lines(for: sample(
            path: "light.sidebar.logo_in_dock",
            role: .dockLogo(minimumPixels: minimum),
            ground: Palette.cream,
            data: data
        ))
        XCTAssertEqual(lines.count, 1, "the size is the only finding on cream: \(lines)")
        XCTAssertTrue(lines.first?.contains("\(small) px") == true, "\(lines)")
        XCTAssertTrue(lines.first?.contains("\(minimum) px") == true, "\(lines)")
        XCTAssertTrue(lines.first?.contains("512 × 512") == true, "\(lines)")
    }

    func testABrandLogoOnItsBandSaysTheHostRimsIt() throws {
        let data = try XCTUnwrap(Self.png(try XCTUnwrap(Self.cartoon())))
        let lines = ThemeArtAdvisory.lines(for: sample(
            path: "dark.sidebar.logo",
            role: .brandLogo(onBand: true),
            ground: Palette.outline,
            data: data
        ))
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.contains("brand band"), line)
        XCTAssertTrue(line.contains("rim in the band's ink"), line)
    }

    /// The slots a theme states become samples against the grounds they land on, without a
    /// file being read on the main actor.
    func testTheSamplesFollowTheSlotsTheThemeStates() throws {
        let base = try XCTUnwrap(AppThemeStyles.all.first { $0.availableVariants == [.dark] })
        let variant = try XCTUnwrap(base.variant(.dark)).replacingSidebar(SidebarStyle(
            brand: SidebarStyle.Brand(logo: .asset("dark-logo.png"), dockIcon: true),
            mascot: ThemeMascot(poses: [
                .idle: .init(asset: "dark-mascot-idle.png"),
                .working: .init(asset: "dark-mascot-working.png")
            ])
        ))
        let theme = AppTheme(
            id: AppThemeID("custom-art-advisory-\(UUID().uuidString.lowercased())"),
            name: "Art Advisory",
            mode: .dark,
            summary: "",
            variants: [.dark: variant]
        )

        let samples = ThemeArtAdvisory.samples(for: theme)
        XCTAssertEqual(samples.map(\.path), [
            "dark.sidebar.logo",
            "dark.sidebar.logo_in_dock",
            "dark.sidebar.mascot.poses.idle",
            "dark.sidebar.mascot.poses.working"
        ])
        XCTAssertEqual(samples.first?.role, .brandLogo(onBand: false))
        XCTAssertEqual(
            samples.first { $0.path.hasSuffix("logo_in_dock") }?.grounds,
            [ThemeArtSeparation.rgb(theme.resolved(.ground, appearance: try XCTUnwrap(AppTheme.VariantKind.dark.appearance)))],
            "the Dock tile's plate is the theme's ground"
        )
    }

    // MARK: - Private Methods

    private func rgb(_ colour: NSColor) -> ThemeLuminance.RGB {
        ThemeArtSeparation.rgb(colour)
    }

    private func sample(
        path: String,
        role: ThemeArtAdvisory.Sample.Role,
        ground: NSColor,
        data: Data,
        counterpart: Data? = nil
    ) -> ThemeArtAdvisory.Sample {
        ThemeArtAdvisory.Sample(
            path: path,
            role: role,
            grounds: [rgb(ground)],
            source: ThemeArtAdvisory.ImageSource(url: nil, data: data),
            counterpart: counterpart.map { ThemeArtAdvisory.ImageSource(url: nil, data: $0) },
            counterpartName: path.hasPrefix("dark") ? "light" : "dark"
        )
    }

    private func difference(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let a = first.usingColorSpace(.sRGB) ?? first
        let b = second.usingColorSpace(.sRGB) ?? second
        return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }

    /// A brown disk with a dark outline on transparency: the reviewed theme's mascot, reduced.
    private static func cartoon(side: Int = Fixture.side) -> CGImage? {
        image(side: side) { context in
            let centre = CGFloat(side) / 2
            let radius = CGFloat(side) * Fixture.radiusRatio
            let outline = CGFloat(side) * Fixture.outlineRatio
            context.setFillColor(Palette.outline.cgColor)
            context.fillEllipse(in: CGRect(x: centre - radius, y: centre - radius, width: radius * 2, height: radius * 2))
            let inner = radius - outline
            context.setFillColor(Palette.body.cgColor)
            context.fillEllipse(in: CGRect(x: centre - inner, y: centre - inner, width: inner * 2, height: inner * 2))
        }
    }

    private static func image(side: Int, draw: (CGContext) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        draw(context)
        return context.makeImage()
    }

    private static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private struct Pixels {
        let bytes: [UInt8]
        let width: Int

        func alpha(x: Int, y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }

        func colour(x: Int, y: Int) -> NSColor {
            let offset = (y * width + x) * 4
            let alpha = max(CGFloat(bytes[offset + 3]), 1)
            return NSColor(
                srgbRed: CGFloat(bytes[offset]) / alpha,
                green: CGFloat(bytes[offset + 1]) / alpha,
                blue: CGFloat(bytes[offset + 2]) / alpha,
                alpha: alpha / 255
            )
        }
    }

    private static func pixels(_ image: CGImage) -> Pixels? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let buffer = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let count = image.width * image.height * 4
        let bytes = Array(UnsafeBufferPointer(start: buffer.assumingMemoryBound(to: UInt8.self), count: count))
        return Pixels(bytes: bytes, width: image.width)
    }
}
