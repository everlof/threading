import AppKit
import ThreadingRemoteKit
import Vision
import XCTest
@testable import Threading

/// The pairing code is the one piece of drawn artwork in the app that a *machine* has to read.
///
/// Every other component is checked by looking at a render and asserting on geometry. This one
/// has a second, harder contract underneath the styling: a phone camera pointed at it must
/// recover the exact URL. So the tests decode what was drawn rather than assert on the
/// constants that drew it — styling the modules into dots, tinting the ink, or trimming the
/// quiet zone are all changes that pass a geometry assertion and break a scan.
///
/// Vision is the oracle. It is not the same decoder `DataScannerViewController` uses on iPhone,
/// but it is the same family and it is the only one available offline here; a code Vision
/// cannot find is not a code worth shipping.
@MainActor
final class PairingCodeImageTests: XCTestCase {

    /// A real pairing payload: a median four-word Cloudflare quick-tunnel host written the way
    /// `RemoteConnectionLink.scannablePayload` writes it, and a base32 owner token. 37 modules
    /// at correction level M.
    private static let payload =
        "HTTPS://MEAT-IMPLIES-TRACKING-NEWFOUNDLAND.TRYCLOUDFLARE.COM"
            + "/#MZXW6YTBOI7EU3TFOQQGE43FMN"

    private enum Render {
        static let modules = 37
        static let quietModules = 4

        /// Small enough to be a hard test and still above anything the UI does: the card gives
        /// the code 212pt. A style change that costs real robustness fails here before it
        /// reaches a phone.
        static let scannableSide: CGFloat = 120

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    override func setUp() {
        super.setUp()
        // Pinned rather than inherited: two of these tests read pixels, and which theme the
        // previous test class happened to leave behind decides what colour they are.
        AppThemePalette.set(.system)
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - The Matrix

    func testStripsCoreImagesOwnBorderFromTheMatrix() throws {
        let matrix = try XCTUnwrap(
            PairingCodeMatrix.make(Self.payload, correctionLevel: "M"),
            "the pairing URL did not encode"
        )

        XCTAssertEqual(
            matrix.size, Render.modules,
            "a version change here moves every measurement in these tests"
        )

        // Core Image pads the symbol with one light module on each side. If that border is
        // still attached, the corner is light and the finder pattern is off by one — which
        // draws a code that looks right and scans as a different symbol.
        XCTAssertTrue(matrix[0, 0], "the top-left finder pattern does not start at (0, 0)")
        XCTAssertTrue(matrix[matrix.size - 1, 0], "the top-right finder pattern is misplaced")
        XCTAssertTrue(matrix[0, matrix.size - 1], "the bottom-left finder pattern is misplaced")

        // The gap ring inside every finder pattern, which is what makes it a finder pattern.
        XCTAssertFalse(matrix[1, 1], "the top-left finder pattern has no light ring")
        XCTAssertTrue(matrix.isLocator(6, 6), "the finder pattern is not 7 modules wide")
        XCTAssertFalse(matrix.isLocator(7, 7), "the finder pattern claims more than 7 modules")
    }

    // MARK: - Scannability

    func testDecodesBackToTheExactPairingURL() throws {
        let image = try XCTUnwrap(PairingCodeImage.make(for: Self.payload))
        XCTAssertEqual(
            decode(image), Self.payload,
            "the drawn code does not read back as the URL it was drawn from"
        )
    }

    func testStaysReadableUnderEveryStockAppTheme() throws {
        for theme in AppThemeLibrary.stock {
            AppThemePalette.set(theme)
            let appearance = try XCTUnwrap(theme.mode.appearance ?? NSAppearance(named: .darkAqua))

            var decoded: String?
            appearance.performAsCurrentDrawingAppearance {
                decoded = PairingCodeImage.make(for: Self.payload).flatMap { decode($0) }
            }

            XCTAssertEqual(
                decoded, Self.payload,
                "\(theme.name) tints the code into something Vision cannot read"
            )
        }
    }

    /// The quiet zone is what this component was written for, so it is asserted directly.
    ///
    /// Core Image supplies one clear module; ISO/IEC 18004 asks for four. The failure it causes
    /// is not a code that cannot be decoded from a screenshot — it is a code a phone hunts for,
    /// which no offline decode test would ever catch. Measuring the drawn margin does.
    func testKeepsFourClearModulesOnEverySide() throws {
        let side = PairingCodeImage.preferredSide
        let image = try XCTUnwrap(PairingCodeImage.make(for: Self.payload, side: side))
        let raster = try XCTUnwrap(bitmap(of: image, scale: 2))

        let box = try XCTUnwrap(inkBounds(in: raster), "nothing was drawn")
        let pitch = Double(raster.pixelsWide) / Double(Render.modules + Render.quietModules * 2)
        let required = pitch * Double(Render.quietModules)

        // A rounded module is inscribed in its cell, so the ink starts slightly inside the
        // first dark module — the measured margin is never smaller than four modules, and the
        // tolerance is only there to keep an antialiased edge pixel from failing it.
        let tolerance = pitch * 0.1
        for (edge, margin) in [
            ("left", Double(box.minX)),
            ("top", Double(box.minY)),
            ("right", Double(raster.pixelsWide) - Double(box.maxX)),
            ("bottom", Double(raster.pixelsHigh) - Double(box.maxY))
        ] {
            XCTAssertGreaterThanOrEqual(
                margin, required - tolerance,
                "the \(edge) quiet zone is \(margin / pitch) modules, not \(Render.quietModules)"
            )
        }
    }

    /// Small, because a code that only survives at the size the card happens to give it has no
    /// margin left for a camera, an angle, or a screenshot someone pinches into.
    func testSurvivesBeingDrawnSmall() throws {
        let image = try XCTUnwrap(
            PairingCodeImage.make(for: Self.payload, side: Render.scannableSide)
        )
        XCTAssertEqual(
            decode(image), Self.payload,
            "the code stops reading at \(Render.scannableSide)pt"
        )
    }

    /// A theme can tint the plate and the ink; it must not be able to tint them together.
    ///
    /// Measured on the pixels rather than on the colours that produced them, so it also covers
    /// the blending that turns those colours into what is actually drawn.
    func testHoldsItsContrastFloorUnderEveryStockAppTheme() throws {
        for theme in AppThemeLibrary.stock {
            AppThemePalette.set(theme)
            let appearance = try XCTUnwrap(theme.mode.appearance ?? NSAppearance(named: .darkAqua))

            var ratio: CGFloat?
            appearance.performAsCurrentDrawingAppearance {
                guard let image = PairingCodeImage.make(for: Self.payload),
                      let raster = bitmap(of: image, scale: 2)
                else { return }
                // The centre of the top-left finder pattern is solid ink; a point inside the
                // quiet zone is solid plate. Both are large enough to sample without landing
                // on an antialiased edge.
                let pitch = CGFloat(raster.pixelsWide)
                    / CGFloat(Render.modules + Render.quietModules * 2)
                let eye = Int(pitch * (CGFloat(Render.quietModules) + 3.5))
                let quiet = Int(pitch * CGFloat(Render.quietModules) / 2)
                guard let ink = raster.colorAt(x: eye, y: eye),
                      let plate = raster.colorAt(x: quiet, y: eye)
                else { return }
                ratio = ThemeContrast.ratio(ink, plate)
            }

            // ISO asks for 4:1. The component holds 7:1 so that a screen, a camera and a
            // compression pass in between still leave the spec's margin intact.
            XCTAssertGreaterThanOrEqual(
                try XCTUnwrap(ratio), 7,
                "\(theme.name) draws the modules too close to the plate they sit on"
            )
        }
    }

    // MARK: - The Payload

    /// QR's alphanumeric mode buys 5.5 bits a character against byte mode's 8, and its charset
    /// has no lower case. The pairing token is base32 for exactly that reason, so the property
    /// is asserted rather than left to the comment that explains it.
    func testPairingTokenFitsQRsAlphanumericCharset() {
        let alphanumeric = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")

        for _ in 0..<32 {
            let token = RemoteAccessCoordinator.pairingToken()
            // 16 bytes at 5 bits a character, rounded up.
            XCTAssertEqual(token.count, 26, "the pairing token is no longer 128 bits of base32")
            XCTAssertTrue(
                token.allSatisfy { alphanumeric.contains($0) },
                "\(token) contains a character QR must encode in byte mode"
            )
        }
    }

    /// The measurement the payload's shape exists for.
    ///
    /// Two changes only pay off together — upper-casing the origin, and a token that is not
    /// mixed-case — so a test that pinned only one of them would pass while the win was gone.
    /// This compares the real thing against the shape it replaced.
    func testTheScannablePayloadEncodesSmallerThanThePlainURL() throws {
        // A median `trycloudflare.com` host: four dictionary words and the TLD.
        let host = "meat-implies-tracking-newfoundland.trycloudflare.com"
        let origin = try XCTUnwrap(URL(string: "https://\(host)/"))
        let link = try XCTUnwrap(
            RemoteConnectionLink(baseURL: origin, token: RemoteAccessCoordinator.pairingToken())
        )

        let scanned = try XCTUnwrap(
            PairingCodeMatrix.make(link.scannablePayload, correctionLevel: "M")
        )
        // The shape this replaced: lower-case origin, 32-byte base64url token.
        let previous = try XCTUnwrap(PairingCodeMatrix.make(
            "https://\(host)/#\(RemoteAccessCoordinator.randomToken())",
            correctionLevel: "M"
        ))

        XCTAssertLessThan(
            scanned.size, previous.size,
            "the pairing payload no longer encodes more tightly than a plain URL"
        )
        XCTAssertLessThanOrEqual(
            scanned.size, 37,
            "a median host should reach version 5; it needs \(scanned.size) modules"
        )

        // Smaller has to still mean scannable, and the same credential.
        let image = try XCTUnwrap(PairingCodeImage.make(for: link.scannablePayload))
        XCTAssertEqual(decode(image), link.scannablePayload)
        XCTAssertEqual(
            RemoteConnectionLink(string: link.scannablePayload), link,
            "the scanned payload is not the link it was built from"
        )
    }

    // MARK: - Failure

    func testReturnsNothingRatherThanAnEmptyPlateWhenNothingCanBeEncoded() {
        // Core Image encodes an empty message as a valid symbol, so the guard that matters is
        // the one on a payload too long for any version: 3000 bytes exceeds the format.
        let oversized = String(repeating: "x", count: 3000)
        XCTAssertNil(
            PairingCodeImage.make(for: oversized),
            "an unencodable payload drew a plate with no code on it"
        )
    }

    // MARK: - Rendering

    /// Writes the code under System plus two deliberately different app themes.
    ///
    /// Cyberpunk and Newsprint are the pair that break it in opposite directions: a saturated
    /// accent over a dark card, and a light card the near-white plate has to stay distinct
    /// from. Swiss Minimalist is here for its silhouette — its zero panel radius should give a
    /// square plate, which is the check that the plate follows the theme rather than a number.
    func testRendersUnderSystemAndTwoContrastingThemes() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let themes: [AppTheme] = [
            .system,
            AppThemeStyles.cyberpunk,
            AppThemeStyles.newsprint,
            AppThemeStyles.swissMinimalist
        ]

        for theme in themes {
            AppThemePalette.set(theme)
            let appearance = try XCTUnwrap(theme.mode.appearance ?? NSAppearance(named: .darkAqua))

            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                guard let image = PairingCodeImage.make(for: Self.payload),
                      let raster = bitmap(of: image, scale: 2)
                else { return }
                data = raster.representation(using: .png, properties: [:])
            }

            let url = directory.appendingPathComponent("pairing-code-\(theme.id.rawValue).png")
            try XCTUnwrap(data, "\(theme.name) rendered nothing").write(to: url)
        }
    }

    // MARK: - Helpers

    private func decode(_ image: NSImage) -> String? {
        guard let raster = bitmap(of: image, scale: 4), let cgImage = raster.cgImage else {
            return nil
        }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.payloadStringValue }.first
    }

    private func bitmap(of image: NSImage, scale: CGFloat) -> NSBitmapImageRep? {
        let pixels = Int(image.size.width * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The bounding box of the ink, in pixels, measured against the plate the code is drawn on
    /// rather than against a fixed threshold — the plate is themed and the ink is not always
    /// black.
    private func inkBounds(in raster: NSBitmapImageRep) -> CGRect? {
        // Sampled mid-edge, not at a corner: the plate's corners are rounded, so a corner
        // pixel is transparent — and reading the plate as transparent black makes every
        // threshold below it collapse to nothing.
        guard let plate = raster.colorAt(x: raster.pixelsWide / 2, y: 2)?
            .usingColorSpace(.sRGB) else { return nil }
        let plateLuminance = plate.brightnessComponent

        var minX = raster.pixelsWide, minY = raster.pixelsHigh
        var maxX = 0, maxY = 0
        for y in 0..<raster.pixelsHigh {
            for x in 0..<raster.pixelsWide {
                guard let pixel = raster.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      // Outside the plate's rounded corners there is nothing at all, and
                      // transparent reads darker than any ink.
                      pixel.alphaComponent > 0.5,
                      // Half way to the plate is well clear of an antialiased dot edge and
                      // well clear of the hairline border, which is a theme role, not ink.
                      pixel.brightnessComponent < plateLuminance * 0.5
                else { continue }
                minX = min(minX, x); maxX = max(maxX, x + 1)
                minY = min(minY, y); maxY = max(maxY, y + 1)
            }
        }
        guard maxX > minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
