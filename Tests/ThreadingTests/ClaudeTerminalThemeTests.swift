import AppKit
import XCTest
@testable import Threading

/// Claude's TUI drawing in the terminal palette rather than in colours of its own.
///
/// Claude's ordinary themes paint 24-bit colours over the palette, so a theme's paired terminal
/// reached only the ground and plain text. A terminal launch states one of Claude's two ANSI
/// themes in its per-session settings file — the variant matching the palette that session draws
/// with — while the setting is on, and nothing at all while it is off.
@MainActor
final class ClaudeTerminalThemeTests: HostedStoreTestCase {

    private var previousSetting = true

    override func setUp() async throws {
        try await super.setUp()
        previousSetting = AppSettings.shared.agentsUseTerminalPalette
        addTeardownBlock { @MainActor [previousSetting] in
            AppSettings.shared.agentsUseTerminalPalette = previousSetting
        }
    }

    // MARK: - Choice

    func testThePalettesGroundChoosesTheVariant() {
        XCTAssertEqual(ClaudeTerminalTheme.ansi(for: .systemDark), ClaudeTerminalTheme.darkANSI)
        XCTAssertEqual(ClaudeTerminalTheme.ansi(for: .systemLight), ClaudeTerminalTheme.lightANSI)
        for palette in TerminalTheme.builtInThemes {
            XCTAssertEqual(
                ClaudeTerminalTheme.ansi(for: palette),
                palette.colorFGBG == TerminalTheme.systemDark.colorFGBG
                    ? ClaudeTerminalTheme.darkANSI
                    : ClaudeTerminalTheme.lightANSI,
                "\(palette.name) asks for the same paper or ink COLORFGBG reports"
            )
        }
    }

    func testOnlyTheSettingDecidesWhetherALaunchStatesOne() {
        let session = AgentSession(kind: .claude, title: "c")

        AppSettings.shared.agentsUseTerminalPalette = true
        XCTAssertEqual(
            AgentLauncher.terminalTheme(for: session),
            ClaudeTerminalTheme.ansi(for: ThemeAssignments.theme(for: session.id)),
            "the session's own resolved palette, not the app's"
        )

        AppSettings.shared.agentsUseTerminalPalette = false
        XCTAssertNil(AgentLauncher.terminalTheme(for: session), "off leaves the account's theme")
    }

    func testItIsOnUntilSomeoneTurnsItOff() {
        let absence = AppSettingDefinitions.agentsUseTerminalPalette.absence
        XCTAssertEqual(absence.erased, .registered(true.storedAppSettingValue))
        XCTAssertEqual(absence.value, true)
    }

    // MARK: - Settings File

    func testTheSettingsFileCarriesTheThemeUnderClaudesKey() throws {
        let sessionID = SessionID()
        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: sessionID,
            brokersPermissions: false,
            reportsLifecycle: false,
            theme: ClaudeTerminalTheme.lightANSI
        ), "a theme alone is reason enough to write the file")
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(settings["theme"] as? String, "light-ansi")
        XCTAssertNil(settings["hooks"], "no listener was asked for, so no hooks may appear")
    }

    func testATerminalLaunchHandsClaudeTheFile() throws {
        AppSettings.shared.agentsUseTerminalPalette = true
        let session = AgentSession(kind: .claude, title: "c")
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        let command = try XCTUnwrap(try AgentLauncher.plan(for: session, in: project).arguments.last)
        let path = try XCTUnwrap(settingsPath(in: command), command)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            settings["theme"] as? String,
            ClaudeTerminalTheme.ansi(for: ThemeAssignments.theme(for: session.id))
        )
    }

    // MARK: - Private Methods

    /// The path after `--settings` in a shell command, each word single-quoted or bare.
    private func settingsPath(in command: String) -> String? {
        let pattern = #"'?--settings'? (?:'([^']+)'|(\S+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: command,
                  range: NSRange(command.startIndex..., in: command)
              ) else { return nil }
        for group in 1...2 {
            if let range = Range(match.range(at: group), in: command) {
                return String(command[range])
            }
        }
        return nil
    }
}
