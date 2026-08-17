import AppKit
import SwiftTerm
import XCTest
@testable import Threading

/// The bold-text role, from the stored palette down to the pixels SwiftTerm resolves.
///
/// The defect this exists for was invisible to every assertion in the suite: an agent writes its
/// headings as SGR 1 in the terminal's *default* foreground, so on a palette whose foreground is
/// already its brightest tone a heading and a paragraph came out as the same colour and only the
/// face differed. Nothing was wrong with the theme, the model or the renderer on their own.
final class TerminalBoldTextTests: XCTestCase {

    // MARK: - Fixtures

    /// A palette whose bold text is deliberately nothing like its body text, so a colour that
    /// arrives from the wrong branch is unmistakable.
    private var distinctPalette: TerminalTheme {
        var theme = TerminalTheme.basic
        theme.foreground = NSColor(hex: "#C7C7C7")!
        theme.boldForeground = NSColor(hex: "#FF00AA")!
        theme.background = NSColor(hex: "#000000")!
        theme.red = NSColor(hex: "#C91B00")!
        theme.brightRed = NSColor(hex: "#FF6D67")!
        return theme
    }

    private func json(of theme: TerminalTheme) throws -> [String: Any] {
        let data = try JSONEncoder().encode(theme)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decoded(_ document: [String: Any]) throws -> TerminalTheme {
        let data = try JSONSerialization.data(withJSONObject: document)
        return try JSONDecoder().decode(TerminalTheme.self, from: data)
    }

    // MARK: - Storage

    /// The migration rule. A palette saved before the role existed drew bold text in its
    /// foreground, because that is all SwiftTerm could do with it, so an absent key has to keep
    /// meaning exactly that rather than reaching for a stock value the user never chose.
    func testAPaletteStoredBeforeTheRoleExistedDrawsBoldInItsForeground() throws {
        var document = try json(of: TerminalTheme.pro)
        document.removeValue(forKey: "boldForeground")

        let theme = try decoded(document)

        XCTAssertEqual(theme.boldForeground.hexString, theme.foreground.hexString)
        XCTAssertEqual(theme.foreground.hexString, TerminalTheme.pro.foreground.hexString)
    }

    func testAStoredBoldColourIsRead() throws {
        var document = try json(of: TerminalTheme.pro)
        document["boldForeground"] = "#FF00AA"

        XCTAssertEqual(try decoded(document).boldForeground.hexString, "#FF00AA")
    }

    func testTheRoleSurvivesAnEncodeDecodeRoundTrip() throws {
        let original = distinctPalette

        let restored = try decoded(try json(of: original))

        XCTAssertEqual(restored.boldForeground.hexString, original.boldForeground.hexString)
        XCTAssertEqual(restored.foreground.hexString, original.foreground.hexString)
        XCTAssertNotEqual(restored.boldForeground.hexString, restored.foreground.hexString)
    }

    /// A key that is present and wrong has *said* something, so it takes the same role-shaped
    /// fallback as every other colour rather than being read as silence.
    func testAnUnparseableBoldColourFallsBackToTheStockPalettesOwnBold() throws {
        var document = try json(of: TerminalTheme.pro)
        document["boldForeground"] = "not a colour"

        let theme = try decoded(document)

        XCTAssertEqual(
            theme.boldForeground.hexString,
            TerminalTheme.basic.boldForeground.hexString,
            "the fallback took some other role's colour"
        )
        XCTAssertNotEqual(theme.boldForeground.hexString, theme.foreground.hexString)
    }

    /// Encoding is unconditional: a palette that omitted the key on write would be
    /// indistinguishable from one written before the role existed.
    func testTheRoleIsAlwaysWritten() throws {
        XCTAssertNotNil(try json(of: TerminalTheme.basic)["boldForeground"])
    }

    // MARK: - Naming

    func testTheRoleIsOneOfThePalettesMainColours() {
        XCTAssertTrue(ThemeColorKey.main.contains(.boldForeground))
        XCTAssertEqual(
            ThemeColorKey.main,
            [.foreground, .boldForeground, .background, .cursor, .selection],
            "the editor draws the main colours in this order"
        )
        XCTAssertEqual(ThemeColorKey.allCases.count, 21)
    }

    /// The raw value is camel case and the wire is snake case, and nothing derives one from the
    /// other except the `bright` prefix — so this pair has to be stated and has to round-trip.
    func testTheWireNameIsSnakeCaseAndRoundTrips() {
        XCTAssertEqual(ThemeColorKey.boldForeground.wireName, "bold_foreground")
        XCTAssertEqual(ThemeColorKey.named("bold_foreground"), .boldForeground)
        XCTAssertEqual(ThemeColorKey.named("BOLD_FOREGROUND"), .boldForeground)
        XCTAssertNil(ThemeColorKey.named("boldForeground"))
    }

    func testTheRoleHasALabelAndAKeyPath() {
        XCTAssertEqual(ThemeColorKey.boldForeground.displayName, L10n.string("Bold Text"))
        XCTAssertFalse(ThemeColorKey.boldForeground.displayName.isEmpty)

        var theme = TerminalTheme.basic
        theme[.boldForeground] = NSColor(hex: "#123456")!
        XCTAssertEqual(theme.boldForeground.hexString, "#123456")
    }

    // MARK: - Rendering Through the Fork

    /// The whole point, measured where it actually happens: what colour does SwiftTerm hand the
    /// text system for each of the four cases a transcript contains?
    @MainActor
    func testTheForkDrawsEachKindOfRunInItsOwnColour() throws {
        let theme = distinctPalette
        let view = terminalView(with: theme)

        // "plain " is 6 cells, "bold" 4, " " 1, "red" 3, " " 1, then "boldred".
        view.getTerminal().feed(
            text: "plain \u{1B}[1mbold\u{1B}[0m \u{1B}[31mred\u{1B}[0m \u{1B}[1;31mboldred\u{1B}[0m"
        )

        assertColour(of: view, atColumn: 0, is: theme.foreground, "plain text")
        assertColour(of: view, atColumn: 7, is: theme.boldForeground, "bold default-coloured text")
        assertColour(of: view, atColumn: 12, is: theme.red, "ANSI red")
        assertColour(
            of: view, atColumn: 17, is: theme.brightRed,
            "bold ANSI red keeps its bright shift"
        )
    }

    /// A palette that states no separate bold colour must render exactly as it did before the
    /// role existed, which is the guarantee every stored theme depends on.
    @MainActor
    func testBoldDrawsInTheForegroundWhenThePaletteStatesNoOtherColour() throws {
        var theme = distinctPalette
        theme.boldForeground = theme.foreground
        let view = terminalView(with: theme)

        view.getTerminal().feed(text: "plain \u{1B}[1mbold\u{1B}[0m")

        assertColour(of: view, atColumn: 0, is: theme.foreground, "plain text")
        assertColour(of: view, atColumn: 7, is: theme.foreground, "bold text")
    }

    /// The attribute cache holds one resolved answer per style, so a palette swapped under a
    /// live view has to clear it. Without this the theme changed everywhere except in the cells
    /// that had already been drawn bold.
    @MainActor
    func testChangingTheBoldColourUnderALiveViewMovesTheAlreadyResolvedText() throws {
        let theme = distinctPalette
        let view = terminalView(with: theme)
        view.getTerminal().feed(text: "plain \u{1B}[1mbold\u{1B}[0m")
        assertColour(of: view, atColumn: 7, is: theme.boldForeground, "bold text before the swap")

        view.nativeBoldForegroundColor = NSColor(hex: "#00C2FF")!

        assertColour(
            of: view, atColumn: 7, is: NSColor(hex: "#00C2FF")!,
            "the cached bold attribute outlived the palette that made it"
        )
        assertColour(of: view, atColumn: 0, is: theme.foreground, "plain text is untouched")
    }

    /// Nil is the seam's "no opinion", and it has to be reachable again after a colour was set:
    /// a session moving to a palette that states nothing must not keep the last one's heading.
    @MainActor
    func testClearingTheBoldColourReturnsBoldToTheForeground() throws {
        let theme = distinctPalette
        let view = terminalView(with: theme)
        view.getTerminal().feed(text: "plain \u{1B}[1mbold\u{1B}[0m")

        view.nativeBoldForegroundColor = nil

        assertColour(of: view, atColumn: 7, is: theme.foreground, "bold text")
    }

    // MARK: - The Tools

    /// `create_theme`'s palette is generated from `ThemeColorKey`, so the *presence* of the key
    /// is already covered. What is not is its description: falling through to the default would
    /// tell an agent this is an ANSI index, which is the one thing it is not.
    func testTheCreateThemeSchemaDescribesBoldTextAsItsOwnRole() throws {
        let definition = try XCTUnwrap(
            MCPTools.definitions.first { $0.name == MCPTools.createTheme }
        )
        let encoded = try JSONEncoder().encode(definition)
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let input = try XCTUnwrap(schema["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(input["properties"] as? [String: Any])
        let colors = try XCTUnwrap(properties["colors"] as? [String: Any])
        let palette = try XCTUnwrap(colors["properties"] as? [String: Any])

        let bold = try XCTUnwrap(palette["bold_foreground"] as? [String: Any])
        let description = try XCTUnwrap(bold["description"] as? String)

        XCTAssertTrue(
            description.contains("SGR 1"),
            "the schema does not say which text this colour is for: \(description)"
        )
        XCTAssertTrue(description.contains("Terminal.app"), description)
        XCTAssertFalse(
            description.hasPrefix("ANSI"),
            "bold text fell through to the ANSI description"
        )
    }

    /// The app-theme document reports a palette through the same enum, so an agent reading a
    /// theme back sees the role it can write.
    @MainActor
    func testTheAppThemeDocumentReportsTheRole() throws {
        let coordinator = AgentToolCoordinator(
            displayPaneController: DisplayPaneController(),
            visibleSessionID: { nil },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )

        let result = coordinator.getAppTheme(
            AppThemeReferenceArguments(themeID: AppThemeStyles.threading.id.rawValue)
        )

        XCTAssertFalse(result.isError, result.text)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any]
        )
        let variants = try XCTUnwrap(document["variants"] as? [String: Any])
        let variant = try XCTUnwrap(variants.values.first as? [String: Any])
        let terminal = try XCTUnwrap(variant["terminal_colors"] as? [String: Any])

        XCTAssertEqual(terminal["bold_foreground"] as? String, "#FFFFFF")
        XCTAssertNil(terminal["boldForeground"])
    }

    // MARK: - Helpers

    @MainActor
    private func terminalView(with theme: TerminalTheme) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 120))
        view.installColors(theme.asSwiftTermColors())
        view.nativeForegroundColor = theme.foreground
        view.nativeBoldForegroundColor = theme.boldForeground
        view.nativeBackgroundColor = theme.background
        return view
    }

    @MainActor
    private func assertColour(
        of view: TerminalView,
        atColumn column: Int,
        is expected: NSColor,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let row = view.getTerminal().getLine(row: 0), column < row.count else {
            return XCTFail("row 0 has no column \(column)", file: file, line: line)
        }
        let drawn = view.resolvedForegroundColor(for: row[column].attribute)
        XCTAssertEqual(
            drawn.hexString, expected.hexString,
            "\(what) drew in \(drawn.hexString)",
            file: file, line: line
        )
    }
}

// MARK: - Importing a Terminal.app Profile

/// Importing writes to the theme library, so this half inherits the hosted-store base class.
final class TerminalBoldTextImportTests: HostedStoreTestCase {

    private func profile(
        named name: String,
        includingBold bold: Bool
    ) throws -> URL {
        var plist: [String: Any] = [
            "name": name,
            "TextColor": try archived(NSColor(hex: "#4FD946")!),
            "BackgroundColor": try archived(NSColor(hex: "#000000")!)
        ]
        if bold {
            plist["TextBoldColor"] = try archived(NSColor(hex: "#FFFFFF")!)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).terminal")
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url)
        return url
    }

    /// Terminal.app stores each colour as an archived `NSColor`, which is what the importer
    /// unarchives; a plain hex string here would test a format the app never meets.
    private func archived(_ color: NSColor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false)
    }

    @MainActor
    func testAProfilesBoldTextColourIsImported() throws {
        let url = try profile(named: "Bold Import Probe", includingBold: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let theme = try ThemeManager.shared.importAppleTerminalTheme(from: url)
        defer { _ = ThemeManager.shared.deleteTheme(theme) }

        XCTAssertEqual(theme.boldForeground.hexString, "#FFFFFF")
        // A colour that has been through `NSKeyedArchiver` and back can land a single unit off
        // in a component, so the text colour is checked as a colour rather than as a string.
        XCTAssertLessThan(
            ThemeContrast.perceptualDistance(theme.foreground, NSColor(hex: "#4FD946")!), 1,
            "the profile's text colour did not survive the import: \(theme.foreground.hexString)"
        )
    }

    /// Terminal.app's own Basic, Man Page and Solid Colors profiles state no bold colour, and
    /// what they draw is the text colour.
    @MainActor
    func testAProfileWithNoBoldTextColourImportsBoldAsItsText() throws {
        let url = try profile(named: "Plain Import Probe", includingBold: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let theme = try ThemeManager.shared.importAppleTerminalTheme(from: url)
        defer { _ = ThemeManager.shared.deleteTheme(theme) }

        XCTAssertEqual(theme.boldForeground.hexString, theme.foreground.hexString)
    }
}
