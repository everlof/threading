import XCTest

@testable import Threading

/// Codex reaches Threading's MCP server with the session token in an `Authorization: Bearer`
/// header (read from the variable `bearer_token_env_var` names), so the token is never in the
/// `codex` process's arguments, which every user on the Mac can read. These tests pin the
/// server's half against a real listener.
final class MCPBearerEndpointTests: XCTestCase {

    private var directory: URL!
    private var sessionIDs: [SessionID] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mbe-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        let owned = sessionIDs
        MainActor.assumeIsolated {
            for sessionID in owned { MCPSessionRegistry.remove(sessionID: sessionID) }
        }
        sessionIDs.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testTheTokenIsReadFromThePathOrOnlyAtTheSharedEndpointFromABearerHeader() {
        XCTAssertEqual(MCPDefaults.sessionToken(path: "/mcp/abc", authorization: nil), "abc")
        XCTAssertEqual(MCPDefaults.sessionToken(path: "/mcp/abc", authorization: "Bearer other"), "abc",
                       "a path token is the address; the header does not override it")
        XCTAssertEqual(MCPDefaults.sessionToken(path: "/mcp", authorization: "Bearer abc"), "abc")
        XCTAssertEqual(MCPDefaults.sessionToken(path: "/mcp", authorization: "bearer  abc "), "abc")
        XCTAssertEqual(MCPDefaults.sessionToken(path: "/mcp/", authorization: "Bearer abc"), "abc")
        XCTAssertNil(MCPDefaults.sessionToken(path: "/mcp", authorization: nil))
        XCTAssertNil(MCPDefaults.sessionToken(path: "/mcp", authorization: "Basic abc"))
        XCTAssertNil(MCPDefaults.sessionToken(path: "/permission/x", authorization: "Bearer abc"))
        XCTAssertEqual(MCPSessionRegistry.bearerEndpointURL(from: "http://127.0.0.1:9/mcp/secret"),
                       "http://127.0.0.1:9/mcp")
    }

    @MainActor
    func testTheSharedEndpointAnswersABearerTokenAndRefusesWithoutOne() throws {
        let server = MCPServer(socketPath: directory.appendingPathComponent("mcp.sock").path)
        let started = expectation(description: "listener")
        server.start { started.fulfill() }
        wait(for: [started], timeout: 10)
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)

        let sessionID = SessionID()
        sessionIDs.append(sessionID)
        let token = MCPSessionRegistry.token(for: sessionID)
        let url = try XCTUnwrap(URL(string: "http://\(MCPDefaults.host):\(port)\(MCPDefaults.bearerEndpointPath)"))

        let withBearer = try post(url, bearer: token)
        XCTAssertEqual(withBearer.status, 200)
        XCTAssertTrue(withBearer.body.contains("\"result\""), withBearer.body)

        XCTAssertEqual(try post(url, bearer: nil).status, 404)
        XCTAssertEqual(try post(url, bearer: "not-a-session").status, 404)
    }

    // MARK: - Private

    private func post(_ url: URL, bearer: String?) throws -> (status: Int, body: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#.utf8)
        let done = expectation(description: "response")
        nonisolated(unsafe) var result: (Int, String) = (0, "")
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data ?? Data(), as: UTF8.self))
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return result
    }
}
