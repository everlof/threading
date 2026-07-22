import AppKit
import XCTest
@testable import Skalman

/// The theme tools as an agent meets them: the JSON it sends, and the schema it reads.
///
/// Both halves fail quietly when they are wrong — a mistyped argument name decodes to nil and
/// the tool reports a missing value, while a colour missing from the schema is simply never
/// sent — so neither shows up as a crash or a failing build.
final class ThemeToolTests: XCTestCase {

    // MARK: - Decoding

    private func call(_ json: String) throws -> MCPToolCall {
        try JSONDecoder()
            .decode(MCPToolCallParameters.self, from: Data(json.utf8))
            .call
    }

    func testSetThemeDecodesItsArguments() throws {
        let call = try call("""
            {"name": "set_theme", "arguments": {"theme": "Ocean", "scope": "project"}}
            """)

        guard case .setTheme(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        XCTAssertEqual(arguments.theme, "Ocean")
        XCTAssertEqual(arguments.scope, "project")
    }

    /// Both arguments are optional: no theme means "clear this scope", and no scope means the
    /// calling session. A tool an agent can call correctly with `{}` is one it will.
    func testSetThemeDecodesWithNoArgumentsAtAll() throws {
        let call = try call("""
            {"name": "set_theme"}
            """)

        guard case .setTheme(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        XCTAssertNil(arguments.theme)
        XCTAssertNil(arguments.scope)
    }

    func testCreateThemeDecodesAPartialPalette() throws {
        let call = try call("""
            {
              "name": "create_theme",
              "arguments": {
                "name": "Dusk",
                "base": "Ocean",
                "colors": {"background": "#101018", "bright_magenta": "#FF77FF"},
                "apply": "session"
              }
            }
            """)

        guard case .createTheme(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        XCTAssertEqual(arguments.name, "Dusk")
        XCTAssertEqual(arguments.base, "Ocean")
        XCTAssertEqual(arguments.apply, "session")
        XCTAssertEqual(arguments.colors?["background"], "#101018")
        XCTAssertEqual(arguments.colors?["bright_magenta"], "#FF77FF")
    }

    func testListThemesTakesNoArguments() throws {
        guard case .listThemes = try call("""
            {"name": "list_themes", "arguments": {}}
            """) else {
            return XCTFail("list_themes did not decode")
        }
    }

    // MARK: - Schema

    private func schema(for name: String) throws -> [String: Any] {
        let definition = try XCTUnwrap(
            MCPTools.definitions.first { $0.name == name },
            "\(name) is not in the tool definitions"
        )
        let data = try JSONEncoder().encode(definition)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    func testEveryThemeToolIsDefined() {
        for name in MCPTools.themeTools {
            XCTAssertTrue(
                MCPTools.definitions.contains { $0.name == name },
                "\(name) is advertised but has no schema"
            )
        }
    }

    func testThemeToolsAreInTheCatalogue() {
        let grouped = Set(MCPToolCatalog.groups.flatMap { $0.tools.map(\.name) })
        for name in MCPTools.themeTools {
            XCTAssertTrue(grouped.contains(name), "\(name) belongs to no settings group")
        }
    }

    /// The palette is generated from `ThemeColorKey`, so a colour added to the model cannot be
    /// left out of the schema an agent reads.
    func testCreateThemeSchemaDescribesEveryColour() throws {
        let schema = try schema(for: MCPTools.createTheme)
        let input = try XCTUnwrap(schema["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(input["properties"] as? [String: Any])
        let colors = try XCTUnwrap(properties["colors"] as? [String: Any])

        XCTAssertEqual(colors["type"] as? String, "object")

        let palette = try XCTUnwrap(colors["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(palette.keys),
            Set(ThemeColorKey.allCases.map(\.wireName))
        )
    }

    /// A scalar property is unchanged by the object case existing — no stray `properties` key
    /// in a schema that has no members.
    func testScalarPropertiesCarryNoNestedProperties() throws {
        let schema = try schema(for: MCPTools.setTheme)
        let input = try XCTUnwrap(schema["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(input["properties"] as? [String: Any])
        let theme = try XCTUnwrap(properties["theme"] as? [String: Any])

        XCTAssertEqual(theme["type"] as? String, "string")
        XCTAssertNil(theme["properties"])
    }

    /// Every scope the tool documents has to be one `ThemeScope` accepts, or the tool describes
    /// a value it then rejects.
    func testDocumentedScopesAreRealScopes() {
        for raw in ["session", "project", "global"] {
            XCTAssertNotNil(ThemeScope(rawValue: raw))
        }
        XCTAssertNil(ThemeScope(rawValue: "none"), "none is an apply target, not a scope")
    }
}
