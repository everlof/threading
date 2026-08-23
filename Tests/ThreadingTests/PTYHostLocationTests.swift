import Foundation
import ThreadingPTYHostKit
import XCTest
@testable import Threading

/// Where the daemon's rendezvous lives, and the redirect that keeps a test out of the developer's
/// own Application Support.
final class PTYHostLocationTests: XCTestCase {

    func testAHostedTestResolvesTheDirectoryUnderItsOwnScratchRoot() throws {
        XCTAssertTrue(
            StateManager.isHostedTest,
            "this suite only means anything inside a hosted test bundle"
        )

        XCTAssertEqual(PTYHostLocation.supportRoot, StateManager.hostedTestDirectory())
        XCTAssertEqual(
            PTYHostLocation.directory,
            StateManager.hostedTestDirectory()
                .appendingPathComponent(PTYHostDefaults.directoryName, isDirectory: true)
        )
        // The one that matters. A test bundle runs inside the shipping app, so without the
        // redirect a test that started a daemon would bind the socket the developer's running app
        // is listening on — and the two would then be fighting over the same PTY children.
        XCTAssertFalse(
            PTYHostLocation.socketPath.hasPrefix(AppDataLocations.supportDirectory.path),
            "a hosted test must never address the real Application Support rendezvous"
        )
    }

    func testTheRendezvousIsASiblingOfTheBridgeAndNotARoomMate() {
        XCTAssertEqual(PTYHostDefaults.directoryName, "pty")
        XCTAssertEqual(PTYHostDefaults.socketFileName, "ptyd.sock")
        XCTAssertEqual(
            PTYHostLocation.socketPath,
            PTYHostLocation.directory.appendingPathComponent("ptyd.sock").path
        )
        XCTAssertNotEqual(
            PTYHostLocation.directory.lastPathComponent,
            MCPBridgeDefaults.directoryName,
            "the daemon gets its own directory; it must not be able to write the MCP tokens"
        )
        XCTAssertEqual(
            PTYHostLocation.stateDirectory,
            PTYHostLocation.directory,
            "sessions.jsonl and the daemon's journal live beside the socket, never in Logs/"
        )
    }

    func testPreparingTheDirectoryTightensItToOwnerOnly() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("PTYHostLocationTests-\(UUID().uuidString)/pty", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: directory.deletingLastPathComponent())
        }

        // Pre-create it with the default mask, which is the case the re-apply exists for: a
        // directory left behind by a build that did not tighten it must not stay world-readable.
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        XCTAssertTrue(PTYHostLocation.prepareDirectory(directory))

        let permissions = try XCTUnwrap(
            fileManager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(
            permissions.intValue & 0o777,
            PTYHostDefaults.directoryPermissions,
            "the directory's permissions are the authorization boundary, not the socket's"
        )
    }

    func testPreparingTheRealDirectoryUnderAHostedTestIsAlsoOwnerOnly() throws {
        XCTAssertTrue(PTYHostLocation.prepareDirectory())
        let permissions = try XCTUnwrap(
            FileManager.default
                .attributesOfItem(atPath: PTYHostLocation.directory.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
    }

    func testAnOverlongPathIsNotAddressableAndTheRealOneIs() {
        XCTAssertEqual(
            PTYHostDefaults.maximumSocketPathBytes,
            MCPBridgeDefaults.maximumSocketPathBytes,
            "the 103-byte bound is a property of sockaddr_un, not of either feature"
        )

        let overlong = "/" + String(repeating: "x", count: PTYHostDefaults.maximumSocketPathBytes)
        XCTAssertNil(PTYHostLocation.addressableSocketPath(overlong))

        let exact = "/" + String(
            repeating: "x",
            count: PTYHostDefaults.maximumSocketPathBytes - 1
        )
        XCTAssertEqual(PTYHostLocation.addressableSocketPath(exact), exact)
        XCTAssertNotNil(
            PTYHostLocation.addressableSocketPath(),
            "pty/ptyd.sock is shorter than bridge/mcp.sock, so anything that fits today fits"
        )
    }

    func testTheHelperIsACandidateInTheBundlesHelpersDirectory() {
        let helper = PTYHostLocation.helperURL(in: .main)
        XCTAssertEqual(helper.lastPathComponent, "threading-ptyd")
        XCTAssertEqual(helper.deletingLastPathComponent().lastPathComponent, "Helpers")
        XCTAssertEqual(
            helper.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            "Contents"
        )
    }

    func testTheWriteBoundIsAWholeNumberOfWireFrames() {
        XCTAssertEqual(
            PTYHostDefaults.maximumQueuedWriteBytes,
            4 * PTYHostFramingDefaults.maximumPayloadBytes
        )
        XCTAssertGreaterThan(PTYHostDefaults.helloTimeout, PTYHostDefaults.connectTimeout)
    }
}
