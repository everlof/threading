import AppKit
import XCTest
@testable import Threading

/// The perceptual authoring boundary. Theme files choose lightness, chroma, and hue here; sRGB
/// remains the storage and display encoding used by theme documents and AppKit.
final class OKLCHColorTests: XCTestCase {

    func testOKLCHAuthoringRoundTripsPerceptualCoordinates() {
        let authored = OKLCH(
            lightness: 0.64,
            chroma: 0.08,
            hueDegrees: 55,
            alpha: 0.35
        )

        let measured = NSColor.oklch(authored).oklch

        XCTAssertEqual(measured.lightness, authored.lightness, accuracy: 0.000_1)
        XCTAssertEqual(measured.chroma, authored.chroma, accuracy: 0.000_1)
        XCTAssertEqual(measured.hueDegrees, authored.hueDegrees, accuracy: 0.05)
        XCTAssertEqual(measured.alpha, authored.alpha, accuracy: 0.001)
    }

    func testOutOfGamutOKLCHKeepsLightnessAndHueWhileReducingChroma() {
        let authored = OKLCH(lightness: 0.72, chroma: 0.5, hueDegrees: 145)
        let measured = NSColor.oklch(authored).oklch

        XCTAssertEqual(measured.lightness, authored.lightness, accuracy: 0.000_1)
        XCTAssertEqual(measured.hueDegrees, authored.hueDegrees, accuracy: 0.05)
        XCTAssertLessThan(measured.chroma, authored.chroma)
    }

    func testNegativeHueMeasuresAsItsEquivalentPositiveAngle() {
        let measured = NSColor.oklch(
            OKLCH(lightness: 0.6, chroma: 0.08, hueDegrees: -30)
        ).oklch

        XCTAssertEqual(measured.hueDegrees, 330, accuracy: 0.001)
    }

}
