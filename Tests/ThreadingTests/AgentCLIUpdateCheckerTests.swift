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

    func testCatalogUsesProviderOwnedTypedUpdateArguments() {
        XCTAssertEqual(
            AgentCLIUpdateCatalog.all.map(\.updateArguments),
            [
                ["update"],
                ["update"],
                ["update"],
                ["upgrade"],
                ["update"]
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
            localReader: { definition in
                guard let version = localVersions[definition.id] else { return .success(nil) }
                return .success(Self.resolved(definition, version: version))
            },
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
            localReader: { definition in
                .success(Self.resolved(definition, version: "0.148.0"))
            },
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

    func testTheCheckerCoversTheWholeCatalogRatherThanSilentlyTruncatingIt() async {
        let checker = AgentCLIUpdateChecker(
            definitions: AgentCLIUpdateCatalog.all,
            localReader: { definition in
                .success(Self.resolved(definition, version: "1.0.0"))
            },
            transport: { request in
                let body = request.url?.host == "cursor.com"
                    ? #"FINAL_DIR="$HOME/.local/share/cursor-agent/versions/2026.08.11-e8db854""#
                    : #"{"version":"1.0.0"}"#
                return AgentCLIUpdateHTTPResponse(data: Data(body.utf8), statusCode: 200)
            }
        )

        let report = await checker.check()

        XCTAssertEqual(report.installed.count, AgentKind.allCases.count)
        XCTAssertEqual(report.checkedSourceCount, AgentKind.allCases.count)
        XCTAssertTrue(report.failures.isEmpty)
    }

    // MARK: - Installed version resolution

    func testPATHResolutionKeepsTheStableExecutablePathAndRejectsRelativeEntries() {
        var checked: [String] = []
        let path = AgentCLIProbe.locate(
            "cursor-agent",
            on: "relative:/first/bin:/second/bin"
        ) { candidate in
            checked.append(candidate)
            return candidate == "/second/bin/cursor-agent"
        }

        XCTAssertEqual(path, "/second/bin/cursor-agent")
        XCTAssertEqual(checked, [
            "/first/bin/cursor-agent",
            "/second/bin/cursor-agent"
        ])
    }

    func testLocalResolverCarriesTheLoginPATHIntoAnEnvShebang() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCLILocalResolver-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let interpreter = bin.appendingPathComponent("fixture-interpreter")
        try FileManager.default.createSymbolicLink(
            at: interpreter,
            withDestinationURL: URL(fileURLWithPath: "/bin/sh")
        )

        let executable = bin.appendingPathComponent("fixture-agent")
        try Data("""
        #!/usr/bin/env fixture-interpreter
        /usr/bin/printf 'fixture-agent 7.8.9\\n'
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let loginShell = root.appendingPathComponent("fixture-login-shell")
        let fixturePATH = "\(bin.path):/usr/bin:/bin"
        try Data("""
        #!/bin/sh
        PATH=\(ShellCommand(word: fixturePATH).source)
        export PATH
        if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
            exec /bin/sh -c "$3"
        fi
        exit 64
        """.utf8).write(to: loginShell)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: loginShell.path
        )

        let definition = AgentCLIUpdateDefinition(
            id: "fixture",
            displayName: "Fixture",
            executable: "fixture-agent",
            versionArguments: ["--version"],
            source: .npm(packageName: "fixture"),
            comparison: .semantic,
            updateArguments: ["update"]
        )

        XCTAssertEqual(
            AgentCLILocalResolver(shell: loginShell.path).resolve(definition),
            .success(ResolvedAgentCLI(
                executablePath: executable.path,
                effectivePATH: fixturePATH,
                version: "7.8.9"
            ))
        )
    }

    func testCursorSourceAllowsADeclaredAssignmentButNotProseAboutOne() {
        let declared = """
        readonly FINAL_DIR="$HOME/.local/share/cursor-agent/versions/2026.08.11-e8db854"
        """
        XCTAssertEqual(
            try? AgentCLIReleaseSource.cursorInstaller.latestVersion(in: Data(declared.utf8)),
            "2026.08.11-e8db854"
        )
        XCTAssertThrowsError(
            try AgentCLIReleaseSource.cursorInstaller.latestVersion(
                in: Data("# FINAL_DIR= is set further down, around 1.2.3\n".utf8)
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
            updateArguments: ["update"]
        )
    }

    private static func resolved(
        _ definition: AgentCLIUpdateDefinition,
        version: String
    ) -> ResolvedAgentCLI {
        ResolvedAgentCLI(
            executablePath: "/tools/\(definition.executable)",
            effectivePATH: "/tools:/usr/bin:/bin",
            version: version
        )
    }
}
