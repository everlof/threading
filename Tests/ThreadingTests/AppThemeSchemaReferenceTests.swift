import Foundation
import ThreadingRemoteKit
import XCTest
@testable import Threading

final class AppThemeSchemaReferenceTests: XCTestCase {
    /// The listing is built *from* `appVariantSchema`, so comparing the two could not fail. The
    /// independent answer is what the argument decoder actually reads: every stored property of
    /// `AppThemeVariantArguments`, in its wire spelling.
    func testListedSchemasStaySmallAndExposeEveryBlock() throws {
        let decoded = Set(Mirror(reflecting: AppThemeVariantArguments()).children.compactMap { child in
            child.label.map(Self.wireName)
        })
        XCTAssertTrue(decoded.isSuperset(of: ["roles", "material", "terminal_colors", "sidebar",
            "chrome", "title_morph"]), "the reflection must see the decoder's properties: \(decoded)")
        XCTAssertEqual(Set(MCPTools.appVariantSchema.keys), decoded,
            "every block the decoder reads is documented, and nothing documented is ignored")
        for tool in [MCPBuiltInTool.createAppTheme, .updateAppTheme] {
            let definition = try XCTUnwrap(MCPTools.definition(for: tool))
            let data = try JSONEncoder().encode(definition.inputSchema)
            XCTAssertLessThan(data.count, 6_000, "Fetch field documentation by section instead of expanding both variants.")
            let variants = try XCTUnwrap(definition.inputSchema.properties["variants"]?.properties)
            XCTAssertFalse(variants.isEmpty)
            for variant in variants.values {
                XCTAssertEqual(Set(variant.properties?.keys.map { $0 } ?? []), decoded)
            }
        }
    }

    func testEveryFieldHasDocumentationAndAReferenceRow() throws {
        let entries = MCPTools.appThemeSchemaEntries
        let data = try JSONEncoder().encode(entries)
        // This bounded export feeds scripts/generate_theme_reference.py when the vocabulary
        // changes. Ordinary tests only read the checked-in reference.
        if let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"], !output.isEmpty {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("theme-schema.json"))
        }
        let reference = try Self.reference()
        for (path, entry) in entries {
            XCTAssertFalse(entry.description.isEmpty, path)
            let description = entry.description.split(whereSeparator: \.isWhitespace)
                .joined(separator: " ").replacingOccurrences(of: "|", with: "\\|")
            XCTAssertTrue(reference.contains("| `\(path)` | \(description) |"),
                "Missing or stale reference row: \(path)")
            XCTAssertFalse(MCPTools.appThemeDocumentation(section: path).isError, path)
        }
        XCTAssertTrue(MCPTools.appThemeDocumentation(section: "unknown.field").isError)
    }

    /// A field removed from the schema must take its row with it, or the page documents a
    /// field the tools no longer accept.
    func testTheReferenceHasNoRowForAFieldTheSchemaLacks() throws {
        let rows = try Self.reference().split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("| `"), let end = line.dropFirst(3).firstIndex(of: "`") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 3)..<end])
        }
        XCTAssertFalse(rows.isEmpty, "the reference table could not be read")
        XCTAssertEqual(rows.count, Set(rows).count, "each field has one row")
        XCTAssertEqual(Set(rows).subtracting(MCPTools.appThemeSchemaEntries.keys), [],
            "rows for fields the schema no longer has")
    }

    /// Range prose is generated from the constants the validators check.
    func testRangeProseFollowsTheLimitConstants() throws {
        let entries = MCPTools.appThemeSchemaEntries
        func description(_ path: String) throws -> String { try XCTUnwrap(entries[path]?.description, path) }
        XCTAssertTrue(try description("material.backdrop.gradient.drift.duration")
            .contains(ThemeLimitText.span(ThemeGradientDrift.durationRange)))
        XCTAssertTrue(try description("material.backdrop.gradient.drift.distance")
            .contains(ThemeLimitText.span(ThemeGradientDrift.distanceRange)))
        XCTAssertTrue(try description("title_morph.characters")
            .contains("1–\(ThemeTitleMorphLimits.maximumScrambleCharacters) "))
        XCTAssertTrue(try description("sprites.name").contains("1–\(ThemeSpriteLimits.maximumNameLength) "))
        XCTAssertTrue(try description("material.panel_radius")
            .contains(ThemeLimitText.span(AppThemeMaterialLimits.panelRadiusRange)))
        XCTAssertFalse(try description("sidebar.image").contains("yours to keep"),
            "image legibility is sampled and reported now")
    }

    private static func wireName(_ property: String) -> String {
        property.reduce(into: "") { name, character in
            if character.isUppercase { name += "_" + character.lowercased() } else { name.append(character) }
        }
    }

    private static func reference() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("docs/architecture/theme-reference.md"),
                          encoding: .utf8)
    }
}
