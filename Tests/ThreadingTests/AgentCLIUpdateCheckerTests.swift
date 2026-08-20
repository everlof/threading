import Foundation
import XCTest
@testable import Threading

final class AgentCLIUpdateCheckerTests: XCTestCase {

    // MARK: - Catalog

    func testEveryAgentKindContributesExactlyOneUpdateDefinition() {
        let definitions = AgentCLIUpdateCatalog.all

        XCTAssertEqual(definitions.count, AgentKind.allCases.count)
        XCTAssertEqual(Set(definitions.map(\.id)).count, definitions.count)
        XCTAssertEqual(
            definitions.map(\.executable),
            AgentKind.allCases.map(\.executableName)
        )
        XCTAssertTrue(definitions.allSatisfy { $0.source.url.scheme == "https" })
    }

    func testCatalogUsesProviderOwnedUpdateCommands() {
        XCTAssertEqual(
            AgentCLIUpdateCatalog.all.map(\.updateCommand),
            [
                "claude update",
                "codex update",
                "grok update",
                "opencode upgrade",
                "cursor-agent update"
            ]
        )
    }

    // MARK: - Version parsing and ordering

    func testVersionsAreExtractedFromEverySupportedOutputShape() {
        XCTAssertEqual(AgentCLIVersion("2.1.237 (Claude Code)")?.display, "2.1.237")
        XCTAssertEqual(AgentCLIVersion("codex-cli 0.148.0")?.display, "0.148.0")
        XCTAssertEqual(AgentCLIVersion("grok version 1.0.5")?.display, "1.0.5")
        XCTAssertEqual(AgentCLIVersion("opencode 1.18.19")?.display, "1.18.19")
        XCTAssertEqual(
            AgentCLIVersion("2026.08.11-e8db854")?.display,
            "2026.08.11-e8db854"
        )
    }

    func testSemanticOrderingPadsComponentsAndHonoursPrereleases() throws {
        let release = try XCTUnwrap(AgentCLIVersion("2.1.0"))
        let short = try XCTUnwrap(AgentCLIVersion("2.1"))
        let prerelease = try XCTUnwrap(AgentCLIVersion("2.1.0-beta.2"))
        let laterPrerelease = try XCTUnwrap(AgentCLIVersion("2.1.0-beta.10"))

        XCTAssertEqual(release, short)
        XCTAssertLessThan(prerelease, laterPrerelease)
        XCTAssertLessThan(laterPrerelease, release)
    }

    func testCursorOrdersTheDateAndDoesNotGuessBetweenCommitHashes() throws {
        let installed = try XCTUnwrap(AgentCLIVersion("2026.08.10-aaaaaaa"))
        let latest = try XCTUnwrap(AgentCLIVersion("2026.08.11-bbbbbbb"))
        XCTAssertTrue(installed.isOlder(than: latest, comparison: .datedBuild))

        let sameDate = try XCTUnwrap(AgentCLIVersion("2026.08.11-ccccccc"))
        XCTAssertFalse(sameDate.isOlder(than: latest, comparison: .datedBuild))
    }

    func testBareNumbersAndArbitraryTextAreNotVersions() {
        XCTAssertNil(AgentCLIVersion("version 42"))
        XCTAssertNil(AgentCLIVersion("newest"))
    }

    // MARK: - Source decoding

    func testNPMSourceReadsOnlyAValidBoundedVersion() throws {
        let source = AgentCLIReleaseSource.npm(packageName: "@openai/codex")
        XCTAssertEqual(
            try source.latestVersion(in: Data(#"{"version":"0.148.0"}"#.utf8)),
            "0.148.0"
        )
        XCTAssertThrowsError(try source.latestVersion(in: Data(#"{"name":"codex"}"#.utf8)))
        XCTAssertThrowsError(try source.latestVersion(in: Data(#"{"version":"latest"}"#.utf8)))
    }

    func testCursorSourceReadsTheFinalInstallerDirectoryNotATemporaryOne() throws {
        let script = """
        TEMP_EXTRACT_DIR="$HOME/.local/share/cursor-agent/versions/.tmp-2026.08.10-old"
        FINAL_DIR="$HOME/.local/share/cursor-agent/versions/2026.08.11-e8db854"
        """
        XCTAssertEqual(
            try AgentCLIReleaseSource.cursorInstaller.latestVersion(in: Data(script.utf8)),
            "2026.08.11-e8db854"
        )
    }

    // MARK: - Complete check

    func testCheckReportsInstalledMissingOutdatedAndUnreadableToolsInCatalogOrder() async {
        let definitions = [
            definition(id: "old", package: "old"),
            definition(id: "current", package: "current"),
            definition(id: "missing", package: "missing"),
            definition(id: "broken", package: "broken")
        ]
        let localVersions = ["old": "1.0.0", "current": "2.0.0", "broken": "unknown"]
        let latestVersions = ["old": "1.1.0", "current": "2.0.0"]

        let checker = AgentCLIUpdateChecker(
            definitions: definitions,
            localReader: { definition in .success(localVersions[definition.id]) },
            transport: { request in
                let package = request.url?.deletingLastPathComponent().lastPathComponent ?? ""
                let version = latestVersions[package] ?? "0.0.0"
                return AgentCLIUpdateHTTPResponse(
                    data: Data(#"{"version":"\#(version)"}"#.utf8),
                    statusCode: 200
                )
            }
        )

        let report = await checker.check()

        XCTAssertEqual(report.installed.map(\.id), ["old", "current"])
        XCTAssertEqual(report.updates.map(\.id), ["old"])
        XCTAssertEqual(report.updates.first?.installedVersion, "1.0.0")
        XCTAssertEqual(report.updates.first?.latestVersion, "1.1.0")
        XCTAssertEqual(report.checkedSourceCount, 2)
        XCTAssertEqual(report.missingCount, 1)
        XCTAssertEqual(
            report.failures,
            [AgentCLIUpdateFailure(
                toolID: "broken",
                stage: .installedVersion,
                reason: .unreadableVersionOutput
            )]
        )
    }

    func testSourceFailuresKeepTheInstalledReadingAndNeverInventAnUpdate() async {
        let checker = AgentCLIUpdateChecker(
            definitions: [definition(id: "codex", package: "codex")],
            localReader: { _ in .success("0.148.0") },
            transport: { _ in
                AgentCLIUpdateHTTPResponse(data: Data(), statusCode: 503)
            }
        )

        let report = await checker.check()

        XCTAssertEqual(report.installed.map(\.version), ["0.148.0"])
        XCTAssertTrue(report.updates.isEmpty)
        XCTAssertEqual(report.checkedSourceCount, 0)
        XCTAssertEqual(
            report.failures.first,
            AgentCLIUpdateFailure(
                toolID: "codex",
                stage: .releaseSource,
                reason: .httpStatus(503)
            )
        )
    }

    private func definition(id: String, package: String) -> AgentCLIUpdateDefinition {
        AgentCLIUpdateDefinition(
            id: id,
            displayName: id.capitalized,
            executable: id,
            versionArguments: ["--version"],
            source: .npm(packageName: package),
            comparison: .semantic,
            updateCommand: "\(id) update"
        )
    }
}
