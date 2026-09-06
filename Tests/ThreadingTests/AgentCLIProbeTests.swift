import Foundation
import XCTest
@testable import Threading

/// The pure half of the CLI probe: what `command -v` output counts as an installed executable.
final class AgentCLIProbeTests: XCTestCase {

    func testAnAbsoluteExecutablePathIsAccepted() {
        XCTAssertEqual(
            AgentCLIProbe.path(fromShellOutput: "/usr/local/bin/claude\n", isExecutable: { _ in true }),
            "/usr/local/bin/claude"
        )
    }

    func testEmptyOutputMeansNotInstalled() {
        XCTAssertNil(AgentCLIProbe.path(fromShellOutput: "", isExecutable: { _ in true }))
        XCTAssertNil(AgentCLIProbe.path(fromShellOutput: "  \n", isExecutable: { _ in true }))
    }

    func testAShellComplaintIsNotAPath() {
        XCTAssertNil(AgentCLIProbe.path(
            fromShellOutput: "claude: command not found",
            isExecutable: { _ in true }
        ))
    }

    func testAnAliasDefinitionIsNotAPath() {
        XCTAssertNil(AgentCLIProbe.path(
            fromShellOutput: "alias claude='CLAUDE_CONFIG_DIR=~/.claude-work claude'",
            isExecutable: { _ in true }
        ))
    }

    func testMultiLineOutputIsRejected() {
        XCTAssertNil(AgentCLIProbe.path(
            fromShellOutput: "/usr/local/bin/claude\ngarbage",
            isExecutable: { _ in true }
        ))
    }

    func testANonExecutableAnswerIsRejected() {
        XCTAssertNil(AgentCLIProbe.path(
            fromShellOutput: "/usr/local/bin/claude",
            isExecutable: { _ in false }
        ))
    }

    func testTheExecutableCheckReceivesTheTrimmedPath() {
        var asked: [String] = []
        _ = AgentCLIProbe.path(fromShellOutput: " /opt/bin/codex \n", isExecutable: {
            asked.append($0)
            return true
        })
        XCTAssertEqual(asked, ["/opt/bin/codex"])
    }

    func testLoginPATHIgnoresProfileOutputBeforeItsMarker() {
        let output = """
        PATH=/wrong/profile/banner
        welcome back
        \(AgentCLIProbe.environmentMarker)
        USER=fixture
        PATH=/fixture/bin:/usr/bin:/bin

        """

        XCTAssertEqual(
            AgentCLIProbe.path(fromLoginEnvironmentOutput: output),
            "/fixture/bin:/usr/bin:/bin"
        )
    }

    func testLoginPATHRequiresThePostProfileMarkerAndANonemptyValue() {
        XCTAssertNil(AgentCLIProbe.path(fromLoginEnvironmentOutput: "PATH=/unframed/bin\n"))
        XCTAssertNil(AgentCLIProbe.path(
            fromLoginEnvironmentOutput: "\(AgentCLIProbe.environmentMarker)\nPATH=\n"
        ))
    }
}
