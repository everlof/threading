import AppKit
import XCTest
@testable import Threading

/// Every palette this app ships states a bold text colour, and states one that works.
///
/// Three gates, because a heading has three ways to fail. It can be *legible and invisible*,
/// which is the defect the role was added for: Threading's body and bold were both `#F7EFE6`
/// and no contrast check anywhere would ever have noticed. It can be distinct and unreadable,
/// which is the failure a colour chosen for distinctness alone walks straight into. Or it can
/// be distinct, readable, and *already spoken for* — a heading drawn in the palette's own `red`
/// is an error message, in its `yellow` a warning, in its `cyan` or `green` any tool's coloured
/// output. Eight palettes shipped that way in the first pass, pixel-identical to a slot.
final class TerminalBoldTextSweepTests: XCTestCase {

    /// Every stock palette, named the way a failure message has to name it.
    private static func stockPalettes() -> [(name: String, palette: TerminalTheme)] {
        var palettes: [(String, TerminalTheme)] = TerminalTheme.builtInThemes.map {
            ("built-in \($0.name)", $0)
        }
        palettes.append(("System (light)", .systemLight))
        palettes.append(("System (dark)", .systemDark))

        for theme in AppThemeStyles.all {
            for kind in theme.availableVariants {
                guard let variant = theme.variant(kind) else { continue }
                palettes.append(("\(theme.name) (\(kind.rawValue))", variant.terminalPalette))
            }
        }
        return palettes.map { (name: $0.0, palette: $0.1) }
    }

    /// A sweep that walks nothing passes. The count is the catalogue's own size, so it moves
    /// when a theme is added and says so rather than quietly shrinking.
    func testTheSweepReachesEveryStockPalette() {
        let palettes = Self.stockPalettes()

        XCTAssertEqual(
            palettes.count,
            TerminalTheme.builtInThemes.count + 2
                + AppThemeStyles.all.reduce(0) { $0 + $1.availableVariants.count },
            "a stock palette is not being swept"
        )
        XCTAssertGreaterThanOrEqual(palettes.count, 37)
    }

    /// The distinctness gate. ΔE 15 is where two inks stop reading as one: `#F7EFE6` against
    /// `#FFFFFF` is 7.5 and was the bug, `#D9D1C8` against `#FFFFFF` is 16.7 and is the fix.
    func testEveryStockPalettesBoldTextIsTellableFromItsBodyText() {
        for (name, palette) in Self.stockPalettes() {
            let distance = ThemeContrast.perceptualDistance(
                palette.boldForeground,
                palette.foreground
            )
            XCTAssertGreaterThanOrEqual(
                distance, ThemeContrast.minimumBoldDistance,
                """
                \(name): bold \(palette.boldForeground.hexString) is only \
                \(String(format: "%.1f", distance)) from body \(palette.foreground.hexString); \
                a heading drawn in it would read as ordinary text.
                """
            )
        }
    }

    /// The legibility gate. Bold text is text, so it clears the floor every palette's text is
    /// held to, and it clears AA wherever the body already does. This is deliberately not
    /// "bold out-contrasts body": Terminal.app's own Grass draws body at 4.9:1 and bold at
    /// 3.1:1, because a heading may be louder in hue rather than in luminance.
    func testEveryStockPalettesBoldTextIsLegibleOnItsOwnGround() {
        for (name, palette) in Self.stockPalettes() {
            let bold = ThemeContrast.ratio(palette.boldForeground, palette.background)
            let body = ThemeContrast.ratio(palette.foreground, palette.background)

            XCTAssertGreaterThanOrEqual(
                bold, ThemeContrast.minimumRatio,
                """
                \(name): bold \(palette.boldForeground.hexString) is \
                \(String(format: "%.1f", bold)):1 on \(palette.background.hexString).
                """
            )
            if body >= 4.5, Self.publishedSchemeExceptions[palette.id.rawValue] == nil {
                XCTAssertGreaterThanOrEqual(
                    bold, 4.5,
                    """
                    \(name): body clears AA at \(String(format: "%.1f", body)):1 but bold is \
                    only \(String(format: "%.1f", bold)):1.
                    """
                )
            }
        }
    }

    /// The six hues a program can ask for by name, in both weights.
    ///
    /// The neutral slots are left out on purpose. Bold equal to `brightWhite` is the oldest
    /// pairing a terminal has, and a heading in the palette's own white or black is still
    /// unmistakably a heading — nothing prints "white" to mean something.
    private static let chromaticSlots: [ThemeColorKey] = [
        .red, .green, .yellow, .blue, .magenta, .cyan,
        .brightRed, .brightGreen, .brightYellow,
        .brightBlue, .brightMagenta, .brightCyan
    ]

    /// The ownership gate: a heading is not one of the palette's coloured slots.
    ///
    /// This is the same measure as the body gate pointed at the other half of the palette, and
    /// it fails for the same reason. Christmas drew its heading in `#C1121F`, which *is* its
    /// `red`; Dracula's was its `yellow`; Cyberpunk's its `green`. Nothing about that is
    /// illegible or indistinct — it is unattributable, which is worse, because the reader has
    /// no way to tell the agent's heading from the error the compiler just printed.
    /// Terminal.app's own hue-shifted profiles never do it: Grass's amber bold `#FFB03B` is not
    /// its yellow, and Novel's `#802A19` is not its red.
    func testNoStockPalettesBoldTextIsOneOfItsOwnColouredSlots() {
        for (name, palette) in Self.stockPalettes() {
            for slot in Self.chromaticSlots {
                let distance = ThemeContrast.perceptualDistance(
                    palette.boldForeground,
                    palette[keyPath: slot.keyPath]
                )
                XCTAssertGreaterThanOrEqual(
                    distance, ThemeContrast.minimumBoldDistance,
                    """
                    \(name): bold \(palette.boldForeground.hexString) is \
                    \(String(format: "%.1f", distance)) from its own \(slot.rawValue) \
                    \(palette[keyPath: slot.keyPath].hexString); a heading drawn in it would \
                    read as output a program coloured.
                    """
                )
            }
        }
    }

    /// The one place a palette is let past a gate, keyed by id and stated with its reason.
    ///
    /// Only for schemes whose colours are somebody else's published set — re-authoring one of
    /// those is a different act from authoring ours, and a scheme people recognise is worth
    /// more than the last tenth of a contrast point. An entry names the gate it is exempt from
    /// and why no tone in the scheme clears it, and `testEveryStatedExceptionIsStillNeeded`
    /// deletes it the moment that stops being true.
    private static let publishedSchemeExceptions: [String: String] = [
        "app-nord-terminal": """
        Nord's published terminal mapping spends every colour but nord10 and nord12. nord10 is \
        3.1:1 on nord0, and every remaining tone bright enough for AA is either an ANSI slot or \
        a Snow Storm neighbour the body cannot be told from. nord12 is 4.4:1 — above the floor \
        every palette's text is held to, under AA — and is the only Nord colour that reads as a \
        heading rather than as a second body.
        """
    ]

    /// An exception that has stopped being load-bearing is a lie about the palette. Each one
    /// must still fail the gate it names, and must still clear the floor underneath it.
    func testEveryStatedExceptionIsStillNeeded() {
        var unseen = Set(Self.publishedSchemeExceptions.keys)

        for (name, palette) in Self.stockPalettes() {
            guard Self.publishedSchemeExceptions[palette.id.rawValue] != nil else { continue }
            unseen.remove(palette.id.rawValue)

            let bold = ThemeContrast.ratio(palette.boldForeground, palette.background)
            let body = ThemeContrast.ratio(palette.foreground, palette.background)
            XCTAssertTrue(
                body >= 4.5 && bold < 4.5,
                "\(name): the AA exception is no longer needed; delete it"
            )
            XCTAssertGreaterThanOrEqual(
                bold, ThemeContrast.minimumRatio,
                "\(name): an exception does not reach below the floor"
            )
        }

        XCTAssertTrue(unseen.isEmpty, "these palettes are no longer in the catalogue: \(unseen)")
    }

    /// The palettes whose body text stepped back so a heading could have the extreme, and where
    /// it landed. Stated rather than derived, because the point of the list is that it is short
    /// and that adding to it is a decision somebody took.
    private static let steppedBodies: [String: String] = [
        "basic": "#C7C7C7",
        "system-light": "#333333",
        "system-dark": "#C7C7C7",
        "app-beos-r5-terminal": "#C8C8C8",
        "app-irix-indigo-magic-terminal": "#BDBDBD",
        "app-pure-terminal-light": "#333333",
        "app-pure-terminal-dark": "#B3B3B3",
        "app-cappuccino-terminal-dark": "#CFC0B0",
        "app-threading-terminal": "#D9D1C8",
        "app-neo-brutalism-terminal": "#333333",
        "app-newsprint-terminal": "#333333",
        "app-openstep-42-terminal": "#333333",
        "app-platinum-9-terminal": "#333333",
        "app-aqua-cheetah-terminal": "#333333",
        "app-aqua-tiger-terminal": "#333333",
        "app-swiss-minimalist-terminal": "#333333"
    ]

    /// A body that moved is still AAA on its own ground. Every one of these was above 7:1
    /// before it moved, and stepping back one tone is not allowed to spend that.
    func testEveryBodyThatSteppedBackIsStillTheColourItSteppedTo() {
        var unseen = Set(Self.steppedBodies.keys)

        for (name, palette) in Self.stockPalettes() {
            guard let expected = Self.steppedBodies[palette.id.rawValue] else { continue }
            unseen.remove(palette.id.rawValue)

            XCTAssertEqual(palette.foreground.hexString, expected, "\(name): body text moved")
            let body = ThemeContrast.ratio(palette.foreground, palette.background)
            XCTAssertGreaterThanOrEqual(
                body, 7,
                "\(name): body text is only \(String(format: "%.1f", body)):1 on its ground"
            )
        }

        XCTAssertTrue(unseen.isEmpty, "these palettes are no longer in the catalogue: \(unseen)")
    }

    /// The one relationship the body step must not create. Every light palette that stepped its
    /// body back landed strictly between its own `black` and its own `brightBlack`, because a
    /// body equal to `brightBlack` would make text a program *dims* to index 8 identical to
    /// text it did not, which is this same defect pointed at a different pair.
    func testNoPalettesBodyTextCollidesWithTheColourProgramsDimTo() {
        for (name, palette) in Self.stockPalettes() {
            XCTAssertGreaterThanOrEqual(
                ThemeContrast.perceptualDistance(palette.foreground, palette.brightBlack), 5,
                """
                \(name): body \(palette.foreground.hexString) is the palette's own bright black, \
                so dimmed text would be indistinguishable from ordinary text.
                """
            )
        }
    }

    /// The ΔE helper itself, against the numbers the authoring rule was calibrated with. A gate
    /// is only as good as the measure under it.
    func testThePerceptualDistanceMeasureMatchesItsCalibration() {
        func distance(_ first: String, _ second: String) -> CGFloat {
            ThemeContrast.perceptualDistance(NSColor(hex: first)!, NSColor(hex: second)!)
        }

        XCTAssertEqual(distance("#F7EFE6", "#FFFFFF"), 7.5, accuracy: 0.4)
        XCTAssertEqual(distance("#D9D1C8", "#FFFFFF"), 16.7, accuracy: 0.4)
        XCTAssertEqual(distance("#333333", "#000000"), 21.2, accuracy: 0.4)
        XCTAssertEqual(distance("#1A1A1A", "#000000"), 9.3, accuracy: 0.4)
        XCTAssertEqual(distance("#FFFFFF", "#FFFFFF"), 0, accuracy: 0.001)
    }
}
