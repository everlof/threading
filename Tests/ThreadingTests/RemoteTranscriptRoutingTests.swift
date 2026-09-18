import Foundation
import ThreadingDomain
import XCTest
@testable import Threading

/// Which file a session's transcript readers get, and which writers refuse it. A remote session is
/// read from its mirror and never from this Mac's Claude directory — where a file of the same name
/// would be a different conversation — and nothing that repairs, migrates or moves a transcript may
/// write over a mirror.
@MainActor
final class RemoteTranscriptRoutingTests: HostedStoreTestCase {

    private let host = ProjectExecutionHost(destination: "pi", remoteDirectory: "/home/me/app")

    private func project(remote: Bool) throws -> Project {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: folder))
        if remote {
            XCTAssertEqual(ProjectStore.shared.setExecutionHost(host, forProjectID: project.id), .applied)
        }
        return try XCTUnwrap(ProjectStore.shared.project(withID: project.id))
    }

    func testARemoteSessionReadsItsMirrorAndALocalOneItsOwnFile() throws {
        let remoteProject = try project(remote: true)
        let localProject = try project(remote: false)
        let remote = try XCTUnwrap(ProjectStore.shared.addSession(to: remoteProject.id, kind: .claude))
        let local = try XCTUnwrap(ProjectStore.shared.addSession(to: localProject.id, kind: .claude))
        let account = try XCTUnwrap(AgentAccountDiscovery.account(for: .claude, handle: remote.accountHandle))
        let id = TranscriptID("0f4c7a55-1111-4222-8333-944455556666")

        guard case .file(let remoteURL)? = SessionTranscript.readRequest(
            sessionID: id, for: remote, in: remoteProject, account: account
        ) else { return XCTFail("no request for the remote session") }
        XCTAssertTrue(RemoteTranscriptMirror.shared.contains(remoteURL), remoteURL.path)
        XCTAssertEqual(remoteURL, RemoteTranscriptMirror.shared.localURL(destination: host.sshDestination, transcriptID: id))
        XCTAssertFalse(remoteURL.path.contains("/.claude"), "a mirror inside a Claude directory is counted as a conversation")

        guard case .file(let localURL)? = SessionTranscript.readRequest(
            sessionID: id, for: local, in: localProject, account: account
        ) else { return XCTFail("no request for the local session") }
        XCTAssertFalse(RemoteTranscriptMirror.shared.contains(localURL))
        XCTAssertTrue(localURL.path.hasPrefix(account.configPath), localURL.path)
    }

    /// Repair rewrites the file it is handed. A mirror is a copy of a file on the host: repairing it
    /// changes nothing the agent reads, and the next refresh would put the host's bytes back.
    func testLaunchRepairRefusesAMirror() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("repair-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        let repaired = scratch.appendingPathComponent("repaired.jsonl")
        try Data("{}\n".utf8).write(to: repaired)
        let mirror = RemoteTranscriptMirror.shared.localURL(destination: host.sshDestination, transcriptID: TranscriptID("abc"))

        let workspace = LaunchRecoveryWorkspace(root: scratch.appendingPathComponent("recovery", isDirectory: true))
        XCTAssertThrowsError(try workspace.accept(repaired: repaired, replacing: mirror, for: SessionID())) { error in
            XCTAssertEqual(error as? LaunchRecoveryWorkspace.Failure, .remoteTranscript)
        }
    }

    /// A remote conversation uses the host's own login, so there is no account on this Mac to move it
    /// to; and its checkout is a folder there, so there is no checkout here to move it into.
    func testMigrationAndCheckoutMovesRefuseARemoteSession() throws {
        let remoteProject = try project(remote: true)
        let session = try XCTUnwrap(ProjectStore.shared.addSession(to: remoteProject.id, kind: .claude))
        XCTAssertFalse(SessionMigration.canMigrate(session, in: remoteProject))
        if let other = AgentAccountDiscovery.accounts(for: .claude).first(where: { $0.handle != session.accountHandle }) {
            guard case .failure(let error) = SessionMigration.move(sessionID: session.id, to: other) else {
                return XCTFail("a remote conversation moved between this Mac's accounts")
            }
            XCTAssertEqual(error.code, .remoteHost)
        }

        let coordinator = SessionCheckoutCoordinator(projects: ProjectStore.shared)
        XCTAssertEqual(coordinator.validate(checkoutPath: "/tmp", forSessionID: session.id), .failure(.remoteHost))
    }
}
