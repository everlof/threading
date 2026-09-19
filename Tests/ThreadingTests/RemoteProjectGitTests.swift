import AppKit
import XCTest
@testable import Threading

/// A project that runs on a remote host keeps the Mac folder it was created from, and that folder
/// is often a real checkout on a real branch. Every git surface must leave it alone for a remote
/// session: its changes, branch and turns are this Mac's, not the agent's. Each test therefore uses
/// a genuine repository here, so a surface that still read it would have something to find.
@MainActor
final class RemoteProjectGitTests: HostedStoreTestCase {

    private let host = ProjectExecutionHost(destination: "pi", remoteDirectory: "/home/me/app")
    private var checkouts: [URL] = []

    override func tearDownWithError() throws {
        for checkout in checkouts { try? FileManager.default.removeItem(at: checkout) }
        try super.tearDownWithError()
    }

    /// A real repository on `local-branch`, with an uncommitted change a surface still reading it
    /// would report. One per project: adding a folder twice returns the same project.
    private func makeCheckout() throws -> URL {
        let checkout = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-git-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        checkouts.append(checkout)
        try git(in: checkout, "init", "-q", "-b", "local-branch")
        try git(in: checkout, "config", "user.email", "t@t")
        try git(in: checkout, "config", "user.name", "t")
        try Data("one\n".utf8).write(to: checkout.appendingPathComponent("a.txt"))
        try git(in: checkout, "add", ".")
        try git(in: checkout, "commit", "-qm", "local")
        try Data("one\ntwo\n".utf8).write(to: checkout.appendingPathComponent("a.txt"))
        return checkout
    }

    private func git(in checkout: URL, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = checkout
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")): \(message)")
    }

    private func session(remote: Bool, in checkout: URL) throws -> AgentSession {
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: checkout))
        if remote {
            XCTAssertEqual(ProjectStore.shared.setExecutionHost(host, forProjectID: project.id), .applied)
        }
        return try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .claude))
    }

    /// A remote turn records no checkpoint: snapshotting this Mac's folder would attribute this
    /// Mac's edits to the agent, with refs written into a repository the agent never touched.
    func testARemoteTurnRecordsNoCheckpointInTheMacFolder() throws {
        let remote = try session(remote: true, in: try makeCheckout())
        let answered = expectation(description: "prepareTurn answered")
        GitTurnBaselineStore.shared.prepareTurn(sessionID: remote.id) { checkpoint in
            XCTAssertNil(checkpoint)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        XCTAssertTrue(GitTurnBaselineStore.shared.checkpoints(forSessionID: remote.id).isEmpty)
    }

    /// The review pane reads nothing here for a remote project, and says where the checkout is — for
    /// the modes a remote review does not offer yet, plainly.
    func testTheReviewPaneRefusesTheMacFolderAndNamesTheHost() throws {
        let checkout = try makeCheckout()
        let remote = try session(remote: true, in: checkout)
        // Staged, not Uncommitted: Uncommitted asks the host over ssh, and "pi" is no host.
        let controller = GitReviewViewController(sessionID: remote.id, folderPath: checkout.path, mode: .staged)
        XCTAssertNil(controller.repositoryRoot, "the pane would read, watch and stage the Mac folder")
        controller.refresh(force: true)
        XCTAssertTrue(controller.placeholderLabel.stringValue.contains(host.destination),
                      controller.placeholderLabel.stringValue)
        XCTAssertFalse(controller.placeholderLabel.isHidden)

        let localCheckout = try makeCheckout()
        let local = try session(remote: false, in: localCheckout)
        let localController = GitReviewViewController(sessionID: local.id, folderPath: localCheckout.path, mode: .uncommitted)
        XCTAssertNotNil(localController.repositoryRoot, "a local project lost its review")
    }

    /// A remote session shows no branch rather than this Mac's, and does not follow a HEAD moving
    /// here.
    func testARemoteSessionNeverTakesTheMacFoldersBranch() throws {
        let checkout = try makeCheckout()
        let remote = try session(remote: true, in: checkout)
        ProjectStore.shared.refreshBranch(forSessionID: remote.id)
        XCTAssertNil(ProjectStore.shared.session(withID: remote.id)?.branch)

        // HEAD moves with plumbing rather than `checkout`: this is about the branch a surface would
        // read, and nothing about the index or working tree needs to change for it to move.
        try git(in: checkout, "branch", "moved-here")
        try git(in: checkout, "symbolic-ref", "HEAD", "refs/heads/moved-here")
        ProjectStore.shared.refreshBranches(forCheckoutAt: checkout.path)
        XCTAssertNil(ProjectStore.shared.session(withID: remote.id)?.branch,
                     "a HEAD moving on this Mac relabelled a session running elsewhere")

        let localCheckout = try makeCheckout()
        let local = try session(remote: false, in: localCheckout)
        ProjectStore.shared.refreshBranch(forSessionID: local.id)
        XCTAssertEqual(ProjectStore.shared.session(withID: local.id)?.branch, "local-branch")
    }
}
