import XCTest
@testable import Threading

final class ClaudeAccountLocationsTests: XCTestCase {
    func testDiscoveryAndExactRoutingKeepAccountsDistinct() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-account-locations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let standard = home.appendingPathComponent(".claude", isDirectory: true)
        let work = home.appendingPathComponent(".claude-work", isDirectory: true)
        let empty = home.appendingPathComponent(".claude-empty", isDirectory: true)
        let science = home.appendingPathComponent(".claude-science", isDirectory: true)
        let customScience = home.appendingPathComponent(".claude-data", isDirectory: true)
        let registered = home.appendingPathComponent("registered-keyring", isDirectory: true)
        for directory in [standard, work, empty, science, customScience, registered] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for directory in [work, science, customScience] {
            try Data().write(to: directory.appendingPathComponent("settings.json"))
        }
        try Data().write(to: customScience.appendingPathComponent("install-id"))
        for marker in ["runtime", "orgs"] {
            try FileManager.default.createDirectory(at: customScience.appendingPathComponent(marker),
                                                    withIntermediateDirectories: true)
        }
        let trusted = ClaudeAccountLocation(handle: .named("team"), configPath: registered.path)

        XCTAssertEqual(ClaudeAccountLocations.discover(
            home: home, candidates: [work, empty, science, customScience], verified: [trusted]
        ), [
            .init(handle: .standard, configPath: standard.path),
            .init(handle: .named("claude-work"), configPath: work.path),
            trusted
        ])
        XCTAssertEqual(ClaudeAccountLocations.resolve(.standard, home: home)?.configPath,
                       standard.path)
        XCTAssertEqual(ClaudeAccountLocations.resolve(.named("claude-work"), home: home)?.configPath,
                       work.path)
        XCTAssertEqual(ClaudeAccountLocations.resolve(.named("team"), home: home,
                                                     verified: [trusted]), trusted)
        for name in ["claude-empty", "claude-science", "claude-data", "claude-../../other"] {
            XCTAssertNil(ClaudeAccountLocations.resolve(.named(name), home: home))
        }
        XCTAssertTrue(ClaudeAccountLocations.isScienceDataDirectory(science))
        XCTAssertTrue(ClaudeAccountLocations.isScienceDataDirectory(customScience))

        let conflicting = ClaudeAccountLocation(handle: .named("claude-work"),
                                                configPath: registered.path)
        XCTAssertNil(ClaudeAccountLocations.resolve(.named("claude-work"), home: home,
                                                   verified: [conflicting]))
        let renamed = ClaudeAccountLocation(handle: .named("claude-renamed"), configPath: work.path)
        XCTAssertEqual(ClaudeAccountLocations.discover(home: home, candidates: [work],
                                                       verified: [renamed]).map(\.handle),
                       [.standard, .named("claude-work")])
        XCTAssertEqual(ClaudeAccountLocations.resolve(.named("claude-work"), home: home,
                                                     verified: [renamed])?.configPath, work.path)
        XCTAssertEqual(ClaudeAccountLocations.resolve(.named("claude-renamed"), home: home,
                                                     verified: [renamed]), renamed)
        // A registry-only path has no marker-backed owner to break an alias conflict.
        XCTAssertTrue(ClaudeAccountLocations.discover(home: home, candidates: [], verified: [
            trusted, .init(handle: .named("another-team"), configPath: registered.path)
        ]).filter { $0.configPath == registered.path }.isEmpty)
    }

    func testRegisteredStandardCannotRedirectDefaultAndNamedPathCannotBeScience() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-verified-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let standard = home.appendingPathComponent(".claude", isDirectory: true)
        let other = home.appendingPathComponent("other", isDirectory: true)
        let science = home.appendingPathComponent(".claude-science", isDirectory: true)
        for directory in [standard, other, science] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        XCTAssertEqual(ClaudeAccountLocations.discover(home: home, candidates: [], verified: [
            .init(handle: .standard, configPath: other.path)
        ]), [.init(handle: .standard, configPath: standard.path)])
        XCTAssertNil(ClaudeAccountLocations.resolve(.named("team"), home: home, verified: [
            .init(handle: .named("team"), configPath: science.path)
        ]))
    }
}
