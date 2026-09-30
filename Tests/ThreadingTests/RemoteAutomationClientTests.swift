import Foundation
import XCTest
@testable import Threading

final class RemoteAutomationClientTests: XCTestCase {
    private struct Runner: RemoteHostCommandRunning {
        let inspect: @Sendable (String, Data) throws -> Void
        func run(on destination: RemoteHostDestination, command: String, input: RemoteHostCommandInput,
                 extraOptions: [String], timeout: TimeInterval) throws -> RemoteHostCommandResult {
            guard case .data(let data) = input else { throw TriggerStore.StoreError.missing }
            try inspect(command, data)
            return .init(output: "{\"items\":[],\"next\":0}", termination: .exited(0))
        }
    }
    func testOwnerRequestQuotesPathsAndKeepsInstructionsInStdin() async throws {
        let endpoint = RemoteAutomationEndpoint(hostID: RemoteHostID(), executable: "/home/user's bin/controller",
            database: "/home/user/data;literal.db")
        let runner = Runner { command, data in
            XCTAssertEqual(command, "'/home/user'\\''s bin/controller' --database '/home/user/data;literal.db' owner-rpc")
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(request["command"] as? String, "automation-configure")
            XCTAssertFalse(command.contains("untrusted task"))
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("untrusted task"))
        }
        let result = try await RemoteAutomationClient().request(endpoint: endpoint,
            destination: .init(alias: "fixture", configFile: nil), command: "automation-configure",
            arguments: [.init(text: "untrusted task $(echo nope)")], runner: runner)
        XCTAssertTrue(result.contains("items"))
    }
    func testInvalidEndpointIsRefusedBeforeTransport() async {
        let endpoint = RemoteAutomationEndpoint(hostID: RemoteHostID(), executable: "relative/controller", database: "/data/db")
        let runner = Runner { _, _ in XCTFail("invalid endpoint reached SSH") }
        do {
            _ = try await RemoteAutomationClient().request(endpoint: endpoint,
                destination: .init(alias: "fixture", configFile: nil), command: "automations", arguments: [], runner: runner)
            XCTFail("relative executable was accepted")
        } catch { }
    }
}
