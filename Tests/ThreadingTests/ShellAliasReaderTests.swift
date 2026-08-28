import XCTest
@testable import Threading

final class ShellAliasReaderTests: XCTestCase {

    func testACommentCannotTurnAnUnrelatedAliasIntoAnAccountName() {
        XCTAssertNil(ShellAliasReader.parseAlias(
            "alias gs='git status' # to switch: CLAUDE_CONFIG_DIR=~/.claude-dblock claude"
        ))
    }

    func testARealAccountAliasStillWinsBeforeItsComment() throws {
        let alias = try XCTUnwrap(ShellAliasReader.parseAlias(
            "alias cdb='CLAUDE_CONFIG_DIR=~/.claude-dblock claude' # was ~/.claude-old"
        ))

        XCTAssertEqual(alias.name, "cdb")
        XCTAssertEqual(
            alias.configPath,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude-dblock")
                .path
        )
    }

    func testAQuotedHashRemainsPartOfTheConfigPath() throws {
        let alias = try XCTUnwrap(ShellAliasReader.parseAlias(
            "alias codexhash='CODEX_HOME=\"$HOME/.codex#work\" codex' # account shortcut"
        ))

        XCTAssertEqual(alias.name, "codexhash")
        XCTAssertEqual(
            alias.configPath,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex#work")
                .path
        )
    }
}
