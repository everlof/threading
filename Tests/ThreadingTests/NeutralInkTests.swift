import AppKit
import XCTest
@testable import Threading

@MainActor
final class NeutralInkTests: XCTestCase {
    override func tearDown() {
        Design.Accessibility.increaseContrastOverrideForTesting = nil
        super.tearDown()
    }

    private func resolve(_ ground: NeutralInk.RGBA, increased: Bool = false) -> NeutralInk? {
        NeutralInk.resolve(on: ground, increasedContrast: increased,
                           readingRatio: LabelLegibility.Defaults.readingRatio,
                           glanceRatio: LabelLegibility.Defaults.glanceRatio,
                           strengthSteps: LabelLegibility.Defaults.strengthSteps)
    }

    private func assertSame(_ actual: Design.Ink, _ expected: Design.Ink,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let actualColors = [actual.base, actual.label, actual.secondary, actual.tertiary,
                            actual.quaternary, actual.surface, actual.surfaceHover, actual.border, actual.rule]
        let expectedColors = [expected.base, expected.label, expected.secondary, expected.tertiary,
                              expected.quaternary, expected.surface, expected.surfaceHover, expected.border, expected.rule]
        for (actualColor, expectedColor) in zip(actualColors, expectedColors) {
            XCTAssertTrue(actualColor.isEqual(expectedColor), file: file, line: line)
            let a = try XCTUnwrap(actualColor.usingColorSpace(.sRGB), file: file, line: line)
            let e = try XCTUnwrap(expectedColor.usingColorSpace(.sRGB), file: file, line: line)
            for (actualValue, expectedValue) in zip(
                [a.redComponent, a.greenComponent, a.blueComponent, a.alphaComponent],
                [e.redComponent, e.greenComponent, e.blueComponent, e.alphaComponent]
            ) {
                XCTAssertEqual(actualValue, expectedValue, accuracy: 1e-12, file: file, line: line)
            }
        }
    }

    func testMacAdapterMatchesOriginalPolicyOnResolvedAndDynamicGrounds() throws {
        let grounds: [NSColor] = [
            .white, .black, .controlBackgroundColor, .selectedContentBackgroundColor,
            NSColor(red: -0.2, green: 0.4, blue: 1.2, alpha: 0.6),
            NSColor(srgbRed: 0.16, green: 0.42, blue: 0.78, alpha: 1),
            NSColor(srgbRed: 0.8, green: 0.9, blue: 1, alpha: 1)
        ] + [0.87, 0.78, 0.52, 0.25, 0.34, 0.42, 0.03928, 0.03929].map {
            NSColor(srgbRed: $0, green: $0, blue: $0, alpha: 1)
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var failure: Error?
            appearance.performAsCurrentDrawingAppearance {
                do {
                    for increased in [false, true] {
                        Design.Accessibility.increaseContrastOverrideForTesting = increased
                        for ground in grounds {
                            for alpha in [CGFloat(0), 0.4, 1] {
                                let background = ground.withAlphaComponent(alpha)
                                try assertSame(Design.Text.on(background), originalInk(on: background))
                            }
                        }
                    }
                } catch { failure = error }
            }
            if let failure { throw failure }
        }
    }

    func testNormalizedColorGridKeepsTheOriginalFloorsAndCeilings() throws {
        for increased in [false, true] {
            Design.Accessibility.increaseContrastOverrideForTesting = increased
            for red in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
                for green in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
                    for blue in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
                        let ground = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
                        let ink = try XCTUnwrap(resolve(.init(red: red, green: green, blue: blue, alpha: 1),
                                                            increased: increased))
                        // The original alpha + (ceiling - alpha) * step / steps endpoint can
                        // round one representable step above the ceiling; keep that arithmetic.
                        XCTAssertGreaterThanOrEqual(ink.label.alpha.nextUp, ink.secondary.alpha)
                        XCTAssertGreaterThanOrEqual(ink.secondary.alpha.nextUp, ink.tertiary.alpha)
                        XCTAssertGreaterThanOrEqual(ink.tertiary.alpha.nextUp, ink.quaternary.alpha)
                        try assertSame(Design.Text.on(ground), originalInk(on: ground))
                    }
                }
            }
        }
    }

    func testPortableLeafRefusesUnsupportedComponentsAndRequiredPerceptualFallback() {
        for value in [CGFloat.nan, .infinity, -0.01, 1.01] {
            XCTAssertNil(resolve(.init(red: value, green: 0, blue: 0, alpha: 1)))
            XCTAssertNil(resolve(.init(red: 0, green: 0, blue: 0, alpha: value)))
        }
        XCTAssertNil(NeutralInk.resolve(on: .init(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
                                       increasedContrast: false, readingRatio: 22,
                                       glanceRatio: 22, strengthSteps: LabelLegibility.Defaults.strengthSteps))
    }

    func testNonconvertibleMacGroundKeepsItsExistingFallback() throws {
        let ground = NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))
        XCTAssertNil(ground.usingColorSpace(.sRGB))
        for increased in [false, true] {
            Design.Accessibility.increaseContrastOverrideForTesting = increased
            try assertSame(Design.Text.on(ground), originalInk(on: ground))
        }
    }

    // Exact pre-extraction policy: keep this independent of the portable leaf so a numerical
    // or fallback change must pass against the existing AppKit owner, not its own algorithm.
    private func originalInk(on background: NSColor) -> Design.Ink {
        let light = ThemeContrast.ratio(.white, background) >= ThemeContrast.ratio(.black, background)
        let base: NSColor = light ? .white : .black
        // The tiers are further apart on a dark ground than a light one: black fades to
        // nothing on paper long before white does on ink.
        let increased = Design.Accessibility.increasesContrast
        let reading = LabelLegibility.Defaults.readingRatio
        let glance = increased ? reading : LabelLegibility.Defaults.glanceRatio

        /// Each rung held over `background`, and never past the rung above it — so a ladder
        /// with no headroom left compresses from the bottom instead of inverting.
        func rung(_ alpha: CGFloat, at floor: CGFloat, under ceiling: NSColor?) -> NSColor {
            LabelLegibility.held(
                base.withAlphaComponent(alpha),
                at: floor,
                over: [background],
                ceiling: ceiling?.usingColorSpace(.sRGB)?.alphaComponent ?? 1
            )
        }

        let label = rung(increased ? 1 : (light ? 0.95 : 0.88), at: reading, under: nil)
        let secondary = rung(increased ? 0.82 : (light ? 0.70 : 0.62), at: reading, under: label)
        let tertiary = rung(increased ? 0.68 : (light ? 0.50 : 0.44), at: reading, under: secondary)
        return Design.Ink(
            base: base,
            label: label,
            secondary: secondary,
            tertiary: tertiary,
            quaternary: rung(
                increased ? 0.54 : (light ? 0.32 : 0.28),
                at: glance,
                under: tertiary
            )
        )
    }
}
