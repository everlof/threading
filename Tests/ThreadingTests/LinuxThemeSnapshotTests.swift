import AppKit
import XCTest
@testable import Threading

/// The Linux host consumes a checked snapshot of the production Threading style. Keep the
/// conversion here, where AppTheme's role derivation and OKLCH gamut mapping are authoritative.
@MainActor
final class LinuxThemeSnapshotTests: XCTestCase {
    private static let snapshotURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Platforms/Linux/Sources/WindowHarness/Resources/Theme/threading.json")

    func testLinuxSnapshotMatchesProductionThreadingTheme() throws {
        let generated = try Self.snapshot()
        if ProcessInfo.processInfo.environment["THREADING_WRITE_LINUX_THEME_SNAPSHOT"] == "1" {
            try FileManager.default.createDirectory(
                at: Self.snapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try generated.write(to: Self.snapshotURL)
        }
        let checked = try JSONDecoder().decode(
            [String: [String: [Double]]].self,
            from: Data(contentsOf: Self.snapshotURL))
        let expected = try JSONDecoder().decode(
            [String: [String: [Double]]].self, from: generated)
        XCTAssertEqual(Set(checked.keys), Set(expected.keys))
        for (mode, expectedRoles) in expected {
            let checkedRoles = try XCTUnwrap(checked[mode])
            XCTAssertEqual(Set(checkedRoles.keys), Set(expectedRoles.keys))
            for (role, expectedChannels) in expectedRoles {
                let channels = try XCTUnwrap(checkedRoles[role])
                XCTAssertEqual(channels.count, expectedChannels.count, "\(mode).\(role)")
                for (index, value) in channels.enumerated() {
                    XCTAssertEqual(value, expectedChannels[index], accuracy: 0.000001,
                                   "\(mode).\(role)[\(index)]")
                }
            }
        }
    }

    private static func snapshot() throws -> Data {
        let theme = AppThemeStyles.threading
        var variants: [String: [String: [Double]]] = [:]
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua),
                                       ("dark", NSAppearance.Name.darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var roles: [String: [Double]] = [:]
            let terminal = theme.terminalPalette(for: appearance)
            let terminalColors: [(String, NSColor)] = [
                ("foreground", terminal.foreground), ("boldForeground", terminal.boldForeground),
                ("background", terminal.background), ("cursor", terminal.cursor),
                ("selection", terminal.selection), ("black", terminal.black),
                ("red", terminal.red), ("green", terminal.green),
                ("yellow", terminal.yellow), ("blue", terminal.blue),
                ("magenta", terminal.magenta), ("cyan", terminal.cyan),
                ("white", terminal.white), ("brightBlack", terminal.brightBlack),
                ("brightRed", terminal.brightRed), ("brightGreen", terminal.brightGreen),
                ("brightYellow", terminal.brightYellow), ("brightBlue", terminal.brightBlue),
                ("brightMagenta", terminal.brightMagenta), ("brightCyan", terminal.brightCyan),
                ("brightWhite", terminal.brightWhite)
            ]
            appearance.performAsCurrentDrawingAppearance {
                for role in AppThemeRole.allCases {
                    roles[role.rawValue] = rgba(theme.resolved(role, appearance: appearance))
                }
                for (key, color) in terminalColors {
                    roles["terminal.\(key)"] = rgba(color)
                }
            }
            variants[name] = roles
        }
        var data = try JSONSerialization.data(
            withJSONObject: variants, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        return data
    }

    private static func rgba(_ color: NSColor) -> [Double] {
        let resolved = color.usingColorSpace(.sRGB)!
        return [resolved.redComponent, resolved.greenComponent,
                resolved.blueComponent, resolved.alphaComponent].map {
            (Double($0) * 1_000_000).rounded() / 1_000_000
        }
    }
}
