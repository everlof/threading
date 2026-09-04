#if DEBUG
import Foundation
import ThreadingRemoteKit

/// A privacy-reviewed PTY snapshot emitted by an installed provider TUI.
///
/// Marketing evidence replays these bytes into SwiftTerm. It never launches a provider, reads a
/// developer's provider history, or sends a prompt while screenshots are being captured. Keeping
/// the recording in a resource also makes changing the story independent of the view code.
struct MobileMarketingTerminalFixture: Decodable, Equatable {
    enum Provider: String, CaseIterable {
        case claude
        case codex

        fileprivate var resourceName: String { "marketing-\(rawValue)-tui" }
    }

    /// The terminal background a recording was made against.
    ///
    /// A TUI picks its palette from what the terminal reports, so a light app theme replays the
    /// recording made against a light terminal: Codex's own light diff backgrounds and Claude's
    /// light ANSI theme, rather than the dark recording's truecolour blocks drawn on paper.
    enum TerminalMode: String, CaseIterable {
        case dark
        case light

        static func matching(_ theme: RemoteThemeDTO) -> TerminalMode {
            theme.mode == .light ? .light : .dark
        }

        fileprivate var resourceSuffix: String { self == .dark ? "" : "-\(rawValue)" }
    }

    enum FixtureError: Error, Equatable {
        case resourceMissing(String)
        case terminalModeMismatch(expected: String, actual: String)
        case malformed
        case unsupportedSchema(Int)
        case providerMismatch(expected: String, actual: String)
        case invalidGrid
        case invalidPayload
        case privatePath
    }

    let schemaVersion: Int
    let kind: String
    let provider: String
    let providerVersion: String
    let columns: Int
    let rows: Int
    let provenance: String
    /// Absent on a recording from before light-mode fixtures existed; such a file is dark.
    let terminalMode: String?
    private let payloadBase64: String

    var payload: Data { Data(base64Encoded: payloadBase64) ?? Data() }

    /// The provider recording behind one row in the marketing dashboard.
    ///
    /// Static screenshot fixtures name the provider in their launch id. The recorded walkthrough
    /// starts at the dashboard and reaches the same recordings by tapping a real session row, so
    /// the session id is the durable join between those two entry paths.
    static func provider(marketingSessionID: String) -> Provider? {
        switch marketingSessionID {
        case "marketing-claude-session": .claude
        case "marketing-codex-session": .codex
        default: nil
        }
    }

    static func load(
        _ provider: Provider,
        mode: TerminalMode = .dark,
        bundle: Bundle = .main
    ) throws -> Self {
        let resourceName = provider.resourceName + mode.resourceSuffix
        let url = bundle.url(
            forResource: resourceName,
            withExtension: "json",
            subdirectory: "TerminalFixtures"
        ) ?? bundle.url(forResource: resourceName, withExtension: "json")
        guard let url else { throw FixtureError.resourceMissing(resourceName) }
        let fixture = try decode(Data(contentsOf: url), expectedProvider: provider)
        if let recorded = fixture.terminalMode, recorded != mode.rawValue {
            throw FixtureError.terminalModeMismatch(expected: mode.rawValue, actual: recorded)
        }
        return fixture
    }

    static func decode(_ data: Data, expectedProvider: Provider) throws -> Self {
        guard let fixture = try? JSONDecoder().decode(Self.self, from: data) else {
            throw FixtureError.malformed
        }
        guard fixture.schemaVersion == 1 else {
            throw FixtureError.unsupportedSchema(fixture.schemaVersion)
        }
        guard fixture.kind == "threading-mobile-terminal-pty-fixture" else {
            throw FixtureError.malformed
        }
        guard fixture.provider == expectedProvider.rawValue else {
            throw FixtureError.providerMismatch(
                expected: expectedProvider.rawValue,
                actual: fixture.provider
            )
        }
        guard (20...240).contains(fixture.columns), (8...120).contains(fixture.rows) else {
            throw FixtureError.invalidGrid
        }
        guard !fixture.payload.isEmpty, fixture.payload.contains(0x1B) else {
            throw FixtureError.invalidPayload
        }
        // A fixture is allowed to name its synthetic `/tmp` workspace, but never a developer's
        // home directory. This catches the common recorder mistake before bytes reach a bundle.
        let privatePathMarkers = [Data("/Users/".utf8), Data("/home/".utf8)]
        guard !privatePathMarkers.contains(where: fixture.payload.contains) else {
            throw FixtureError.privatePath
        }
        return fixture
    }
}
#endif
