import XCTest
@testable import Threading

final class RemoteHostBridgeProbeTests: XCTestCase {
    func testProbeRunsTheEmbeddedBridgeWithTheShippingEnvironmentContract() throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/threading-mcp-bridge")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
        let result = try runProbe(executable: helper.path)
        XCTAssertTrue(RemoteHostBridgeProbe.accepts(result), result.output)
    }

    func testAnOldBridgeThatDemandsATokenArgumentIsRefused() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("#!/bin/sh\necho 'usage: bridge --token token' >&2\nexit 64\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let result = try runProbe(executable: file.path)
        XCTAssertFalse(RemoteHostBridgeProbe.accepts(result))
        XCTAssertEqual(result.termination, .exited(64))
    }

    func testAnEmptyOrInvalidHandshakeIsNotCompatibilityProof() {
        for output in ["", "usage: bridge", #"{"jsonrpc":"2.0","id":1,"error":{"code":-1}}"#] {
            XCTAssertFalse(RemoteHostBridgeProbe.accepts(.init(output: output, termination: .exited(0))))
        }
    }

    private func runProbe(executable: String) throws -> RemoteHostCommandResult {
        let child = Process()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", RemoteHostBridgeProbe.script(executable: executable)]
        child.standardOutput = output
        child.standardError = output
        // Do not inherit a real session token into the compatibility test.
        child.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": "/tmp"]
        try child.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        return .init(output: String(decoding: bytes, as: UTF8.self), termination: .exited(child.terminationStatus))
    }
}
