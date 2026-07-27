import XCTest
@testable import SwiftTerm
@testable import Skalman

private func hexColor(_ value: String) -> NSColor {
    NSColor(hex: value) ?? .black
}

/// The harmoniser rewrites colours a *program* chose, which is the reason its guarantees are
/// worth pinning rather than eyeballing: getting one of these wrong does not look like a bug in
/// Skalman, it looks like the agent CLI rendering badly.
///
/// The three that matter are lightness preservation (the program's own text stays as legible as
/// it drew it), monotonic hue (distinct backgrounds stay distinct and in order), and a bounded
/// ceiling (there is actually a limit, rather than a scaling that merely postpones the slab).
final class TerminalBackgroundHarmonyTests: XCTestCase {

    private var anchors: [CGFloat] { TerminalBackgroundHarmony.anchorHues(of: theme) }

    /// Christmas night — the palette the reported case was seen in.
    private let theme = TerminalTheme(
        id: TerminalThemeID("test-christmas-night"),
        name: "Test",
        foreground: hexColor("#EAF4EC"),
        background: hexColor("#082019"),
        cursor: hexColor("#EAF4EC"),
        selection: hexColor("#14432F"),
        black: hexColor("#113328"),
        red: hexColor("#E5484D"),
        green: hexColor("#2FBF71"),
        yellow: hexColor("#E3B23C"),
        blue: hexColor("#5AA9E6"),
        magenta: hexColor("#C77DBA"),
        cyan: hexColor("#4FD1C5"),
        white: hexColor("#B7C7BC"),
        brightBlack: hexColor("#2A5343"),
        brightRed: hexColor("#FF6B70"),
        brightGreen: hexColor("#6FE39C"),
        brightYellow: hexColor("#F5D06A"),
        brightBlue: hexColor("#8CC7F5"),
        brightMagenta: hexColor("#E0A3D6"),
        brightCyan: hexColor("#86E7DE"),
        brightWhite: hexColor("#F2FBF4")
    )

    // MARK: - The guarantee that protects the program's own text

    /// Lightness is the coordinate this transform must never touch: the program paired its
    /// foreground with this background, and moving the background's lightness silently changes
    /// a contrast ratio nobody here is in a position to re-derive.
    func testLightnessIsPreservedExactly() {
        let subjects = [
            "#0E3203", "#470802", "#FF00AA", "#FFD400",
            "#2A0B4A", "#3A4A5A", "#16233A", "#FFFFFF", "#000000"
        ]

        for value in subjects {
            let incoming = hexColor(value)
            let outgoing = TerminalBackgroundHarmony.harmonize(incoming, anchors: anchors)
            XCTAssertEqual(
                outgoing.oklab.lightness,
                incoming.oklab.lightness,
                accuracy: 0.0005,
                "\(value) moved in lightness"
            )
        }
    }

    // MARK: - The guarantee that keeps unrelated output readable

    /// A program painting several categories as background blocks must get several *distinct*
    /// categories back, in the same order. Attraction is a contraction toward the palette's
    /// hues, so it compresses the circle without ever folding it — which snapping to a small
    /// set of anchors would not.
    func testHueOrderAndDistinctnessSurvive() {
        let sweep = stride(from: CGFloat(0), to: 360, by: 15).map { degrees -> CGFloat in
            let incoming = NSColor.oklab(
                Oklab(lightness: 0.5, chroma: 0.12, hue: degrees * .pi / 180)
            )
            let outgoing = TerminalBackgroundHarmony.harmonize(incoming, anchors: anchors)
            let hue = outgoing.oklab.hue * 180 / .pi
            return hue < 0 ? hue + 360 : hue
        }

        for index in 1..<sweep.count {
            var step = sweep[index] - sweep[index - 1]
            if step < -180 { step += 360 }
            if step > 180 { step -= 360 }
            XCTAssertGreaterThan(
                step, 0,
                "hues \(index - 1) and \(index) folded together or swapped order"
            )
        }
    }

    // MARK: - The guarantee that there is actually a limit

    func testChromaIsBoundedByTheCeiling() {
        let ceiling = TerminalBackgroundHarmony.Recipe.chromaKnee
            + TerminalBackgroundHarmony.Recipe.chromaHeadroom

        // Deliberately past anything sRGB can show, so the bound is tested rather than the gamut.
        for chroma in stride(from: CGFloat(0.05), through: 0.5, by: 0.05) {
            XCTAssertLessThanOrEqual(TerminalBackgroundHarmony.compressed(chroma), ceiling)
        }
    }

    /// Strictly increasing, so a program's own ordering of "louder" survives the squeeze.
    func testChromaCompressionIsMonotonic() {
        var previous = TerminalBackgroundHarmony.compressed(0)
        for chroma in stride(from: CGFloat(0.005), through: 0.5, by: 0.005) {
            let current = TerminalBackgroundHarmony.compressed(chroma)
            XCTAssertGreaterThan(current, previous, "compression flattened at \(chroma)")
            previous = current
        }
    }

    // MARK: - The guarantee that restraint is left alone

    /// Below the knee nothing moves at all: a program that already chose a quiet background is
    /// not second-guessed, which is most of what a terminal actually emits.
    func testColoursBelowTheKneeKeepTheirChroma() {
        let knee = TerminalBackgroundHarmony.Recipe.chromaKnee
        for chroma in stride(from: CGFloat(0), through: knee, by: 0.005) {
            XCTAssertEqual(TerminalBackgroundHarmony.compressed(chroma), chroma, accuracy: 1e-9)
        }
    }

    /// A near-neutral background has no meaningful hue — `atan2` of two rounding errors — so it
    /// is returned untouched rather than rotated toward whichever anchor the noise pointed at.
    func testNearNeutralColoursAreReturnedUnchanged() {
        for value in ["#1C1C1C", "#808080", "#FFFFFF", "#000000"] {
            let incoming = hexColor(value)
            let outgoing = TerminalBackgroundHarmony.harmonize(incoming, anchors: anchors)
            XCTAssertEqual(outgoing.hexString, incoming.hexString, "\(value) was rewritten")
        }
    }

    // MARK: - Anchors

    /// The anchor list is the palette's *chromatic* entries only. A greyscale theme states none,
    /// and must therefore leave every hue exactly where the program put it.
    func testGreyscalePaletteLeavesHuesAlone() {
        var grey = theme
        for keyPath in [
            \TerminalTheme.red, \.green, \.yellow, \.blue, \.magenta, \.cyan,
            \.brightRed, \.brightGreen, \.brightYellow, \.brightBlue, \.brightMagenta, \.brightCyan
        ] {
            grey[keyPath: keyPath] = NSColor(white: 0.5, alpha: 1)
        }

        XCTAssertTrue(TerminalBackgroundHarmony.anchorHues(of: grey).isEmpty)

        let incoming = hexColor("#0E3203")
        let outgoing = TerminalBackgroundHarmony.harmonize(
            incoming,
            anchors: TerminalBackgroundHarmony.anchorHues(of: grey)
        )
        XCTAssertEqual(
            outgoing.oklab.hue, incoming.oklab.hue, accuracy: 0.001,
            "with no anchors the hue must not move"
        )
    }

    /// A quiet colour comes back **byte-identical**, and the terminal's own background most of
    /// all.
    ///
    /// This is not a purity concern. A program filling a region with the palette's background —
    /// `tput setab` with the theme's own colour, or a TUI erasing a panel — has to render as the
    /// surrounding ground or the block shows a seam. Before hue attraction was ramped, chroma
    /// was correctly left alone below the knee while the hue rotated anyway, and `#082019` came
    /// back `#06201C`.
    func testQuietColoursAreTheIdentity() {
        for value in [
            "#082019",  // the terminal background itself
            "#113328",  // a panel-weight tint, exactly at the knee
            "#0C2A20",  // below the knee
            "#2A5343",  // the palette's own bright black — vivid enough to clear the knee,
            "#E5484D"   // and its red, which is very much over it
        ] {
            let incoming = hexColor(value)
            let outgoing = TerminalBackgroundHarmony.harmonize(
                incoming,
                anchors: anchors,
                stated: TerminalBackgroundHarmony.statedColours(of: theme)
            )
            XCTAssertEqual(
                outgoing.hexString, incoming.hexString,
                "\(value) was rewritten — a block painted in it would seam against the ground"
            )
        }
    }

    /// Ramping rather than gating: two colours either side of the knee must not render visibly
    /// differently, or a gradient crossing it shows a band.
    func testTheAttractionRampIntroducesNoVisibleStep() {
        var previous: NSColor?
        var worst: CGFloat = 0

        for chroma in stride(from: CGFloat(0.02), through: 0.14, by: 0.002) {
            let incoming = NSColor.oklab(
                Oklab(lightness: 0.28, chroma: chroma, hue: 139 * .pi / 180)
            )
            let outgoing = TerminalBackgroundHarmony.harmonize(incoming, anchors: anchors)
            if let previous,
               let a = previous.usingColorSpace(.sRGB),
               let b = outgoing.usingColorSpace(.sRGB) {
                worst = max(worst, 255 * max(
                    abs(a.redComponent - b.redComponent),
                    abs(a.greenComponent - b.greenComponent),
                    abs(a.blueComponent - b.blueComponent)
                ))
            }
            previous = outgoing
        }

        XCTAssertLessThan(worst, 4, "the transform steps visibly somewhere across the knee")
    }

    // MARK: - The SwiftTerm seam

    /// The transform reaches backgrounds and **only** backgrounds.
    ///
    /// The order here is the test: SwiftTerm's `trueColors` cache is keyed by the colour alone,
    /// with no room for the role, so a single shared cache would answer a later foreground with
    /// whatever the transform did to the identical background. Asking for the background first
    /// is what makes that failure show up rather than hide.
    func testTransformReachesBackgroundsAndNeverForegrounds() {
        let view = EmojiFixedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let raw = Attribute.Color.trueColor(red: 0x47, green: 0x08, blue: 0x02)
        view.trueColorBackgroundTransform = { _ in .systemPink }

        let background = view.mapColor(color: raw, isFg: false, isBold: false)
        let foreground = view.mapColor(color: raw, isFg: true, isBold: false)

        XCTAssertEqual(background.hexString, NSColor.systemPink.hexString,
                       "the background was not transformed")
        XCTAssertEqual(foreground.hexString, hexColor("#470802").hexString,
                       "the transform leaked onto a foreground through the colour cache")
    }

    /// Clearing the hook restores the program's own bytes, and does not strand the cache.
    func testRemovingTheTransformRestoresTheRawColour() {
        let view = EmojiFixedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let raw = Attribute.Color.trueColor(red: 0x47, green: 0x08, blue: 0x02)

        view.trueColorBackgroundTransform = { _ in .systemPink }
        XCTAssertEqual(view.mapColor(color: raw, isFg: false, isBold: false).hexString,
                       NSColor.systemPink.hexString)

        view.trueColorBackgroundTransform = nil
        XCTAssertEqual(view.mapColor(color: raw, isFg: false, isBold: false).hexString,
                       hexColor("#470802").hexString,
                       "a stale harmonised colour survived the hook being removed")
    }

    /// The reported case, end to end: both washes come down into the palette's register while
    /// staying on their own side of the circle, so the diff is still obviously a diff.
    func testReportedDiffWashesLandInThePalettesRegister() {
        let ceiling = TerminalBackgroundHarmony.Recipe.chromaKnee
            + TerminalBackgroundHarmony.Recipe.chromaHeadroom

        let added = TerminalBackgroundHarmony.harmonize(hexColor("#0E3203"), anchors: anchors)
        let removed = TerminalBackgroundHarmony.harmonize(hexColor("#470802"), anchors: anchors)

        XCTAssertLessThanOrEqual(added.oklab.chroma, ceiling)
        XCTAssertLessThanOrEqual(removed.oklab.chroma, ceiling)

        func degrees(_ colour: NSColor) -> CGFloat {
            let hue = colour.oklab.hue * 180 / .pi
            return hue < 0 ? hue + 360 : hue
        }

        // Still a green and still a red, and still far enough apart to read at a glance.
        var separation = abs(degrees(added) - degrees(removed))
        if separation > 180 { separation = 360 - separation }
        XCTAssertGreaterThan(separation, 90, "added and removed stopped being distinguishable")
    }
}
