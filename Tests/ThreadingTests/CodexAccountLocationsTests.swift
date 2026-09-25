import XCTest
@testable import Threading

final class CodexAccountLocationsTests: XCTestCase {
    func testDiscoveryAndExactRoutingKeepAccountsDistinct() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-account-locations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let standard = home.appendingPathComponent(".codex", isDirectory: true)
        let work = home.appendingPathComponent(".codex-work", isDirectory: true)
        let unverified = home.appendingPathComponent(".codex-empty", isDirectory: true)
        let registered = home.appendingPathComponent("registered-keyring", isDirectory: true)
        for directory in [standard, work, unverified, registered] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for directory in [standard, work] {
            try Data().write(to: directory.appendingPathComponent("auth.json"))
        }
        let trusted = CodexAccountLocation(handle: .named("team"), configPath: registered.path)

        let found = CodexAccountLocations.discover(
            home: home, candidates: [work, unverified], verified: [trusted])
        XCTAssertEqual(found, [
            .init(handle: .standard, configPath: standard.path),
            .init(handle: .named("codex-work"), configPath: work.path),
            trusted
        ])
        XCTAssertEqual(CodexAccountLocations.resolve(.standard, home: home)?.configPath,
                       standard.path)
        XCTAssertEqual(CodexAccountLocations.resolve(.named("codex-work"), home: home)?.configPath,
                       work.path)
        XCTAssertEqual(CodexAccountLocations.resolve(.named("team"), home: home,
                                                    verified: [trusted]), trusted)
        XCTAssertNil(CodexAccountLocations.resolve(.named("codex-empty"), home: home))
        XCTAssertNil(CodexAccountLocations.resolve(.named("codex-../../elsewhere"), home: home))

        // A second home claiming one handle must not be chosen by list order.
        let conflicting = CodexAccountLocation(handle: .named("codex-work"),
                                               configPath: registered.path)
        XCTAssertNil(CodexAccountLocations.resolve(.named("codex-work"), home: home,
                                                  verified: [conflicting]))
        XCTAssertFalse(CodexAccountLocations.discover(
            home: home, candidates: [work], verified: [conflicting]
        ).contains { $0.handle == .named("codex-work") })
        XCTAssertFalse(CodexAccountLocations.discover(
            home: home, candidates: [work], verified: [
                .init(handle: .named("alias"), configPath: work.path)
            ]
        ).contains { $0.configPath == work.path })
        XCTAssertNil(CodexAccountLocations.resolve(.named("codex-work"), home: home, verified: [
            .init(handle: .named("alias"), configPath: work.path)
        ]))
    }

    func testRegisteredStandardKeyringLocationUsesOnlyDefaultHome() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-keyring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let standard = home.appendingPathComponent(".codex", isDirectory: true)
        let other = home.appendingPathComponent("other", isDirectory: true)
        for directory in [standard, other] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let trusted = CodexAccountLocation(handle: .standard, configPath: standard.path)
        XCTAssertEqual(CodexAccountLocations.discover(home: home, candidates: [], verified: [trusted]),
                       [trusted])
        XCTAssertTrue(CodexAccountLocations.discover(home: home, candidates: [], verified: [
            .init(handle: .standard, configPath: other.path)
        ]).isEmpty)
    }
}
