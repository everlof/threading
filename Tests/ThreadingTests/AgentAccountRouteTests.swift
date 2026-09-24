import XCTest
@testable import Threading

final class AgentAccountRouteTests: XCTestCase {
    func testStandardCodexAccountClearsInheritedHome() {
        let route = AgentAccountRoute.prefix(for: .codex, handle: .standard,
            configPath: "/tmp/ignored")
        XCTAssertEqual(route.source, "'env' '-u' 'CODEX_HOME'")
    }

    func testNamedCodexAccountUsesQuotedPath() {
        let route = AgentAccountRoute.prefix(for: .codex, handle: .named("work"),
            configPath: "/tmp/work's Codex")
        XCTAssertEqual(route.source, "'env' 'CODEX_HOME=/tmp/work'\\''s Codex'")
    }
}
