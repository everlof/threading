import Foundation
import XCTest
@testable import Threading

/// The whole-disk conversation scan: grouping by cwd and worktree root, dedup against tracked
/// transcripts, the missing-folder ledger, and the 48-hour pre-check boundary.
final class GlobalSessionScanTests: XCTestCase {

    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("threading-global-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    private func session(
        _ id: String,
        kind: AgentKind = .claude,
        daysAgo: Double = 0
    ) -> ImportableSession {
        ImportableSession(
            agentSessionID: TranscriptID(id),
            kind: kind,
            accountHandle: .standard,
            title: "Conversation \(id)",
            lastActiveAt: Date(timeIntervalSinceNow: -daysAgo * 24 * 60 * 60)
        )
    }

    // MARK: - Grouping

    func testGroupsByResolvedRootAndSortsNewestFirst() {
        let result = GlobalSessionScan.grouped(
            [
                (session("a", daysAgo: 3), "/repo/sub"),
                (session("b", daysAgo: 1), "/repo"),
                (session("c", daysAgo: 2), "/elsewhere")
            ],
            knownTranscriptIDs: [],
            rootResolver: { cwd in cwd.hasPrefix("/repo") ? "/repo" : nil },
            folderExists: { _ in true }
        )

        XCTAssertEqual(result.groups.map(\.folder), ["/repo", "/elsewhere"])
        XCTAssertEqual(
            result.groups[0].conversations.map { $0.agentSessionID.rawValue },
            ["b", "a"],
            "Newest first within a group; the subdirectory chat groups to the root"
        )
        XCTAssertEqual(result.missingFolderConversations, 0)
    }

    func testCwdWithoutARepositoryGroupsToItself() {
        let result = GlobalSessionScan.grouped(
            [(session("a"), "/plain/folder")],
            knownTranscriptIDs: [],
            rootResolver: { _ in nil },
            folderExists: { _ in true }
        )
        XCTAssertEqual(result.groups.map(\.folder), ["/plain/folder"])
    }

    func testTrackedTranscriptsAndDuplicatesAreDropped() {
        let result = GlobalSessionScan.grouped(
            [
                (session("known"), "/repo"),
                (session("new"), "/repo"),
                (session("new"), "/repo")   // the same conversation found twice
            ],
            knownTranscriptIDs: [TranscriptID("known")],
            rootResolver: { _ in nil },
            folderExists: { _ in true }
        )
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(
            result.groups[0].conversations.map { $0.agentSessionID.rawValue },
            ["new"]
        )
    }

    func testAFolderThatNoLongerExistsIsCountedNotSilentlyDropped() {
        let result = GlobalSessionScan.grouped(
            [
                (session("gone"), "/vanished"),
                (session("here"), "/still/here")
            ],
            knownTranscriptIDs: [],
            rootResolver: { _ in nil },
            folderExists: { $0 != "/vanished" }
        )
        XCTAssertEqual(result.groups.map(\.folder), ["/still/here"])
        XCTAssertEqual(result.missingFolderConversations, 1)
    }

    // MARK: - Worktree identity

    /// A chat in a nested worktree must group to *that* worktree, not the enclosing repo —
    /// proven against a real `git worktree` layout, the `SessionImportBelongingTests` approach.
    func testANestedWorktreeGroupsToItsOwnCheckout() throws {
        let repo = workspace.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "."], in: repo)
        try git(
            ["-c", "user.email=t@t", "-c", "user.name=t",
             "commit", "-q", "--allow-empty", "-m", "root"],
            in: repo
        )
        try git(["worktree", "add", "-q", "--detach", "nested"], in: repo)

        let nested = repo.appendingPathComponent("nested")

        var roots: [String: String?] = [:]
        func resolve(_ cwd: String) -> String? {
            if let cached = roots[cwd] { return cached }
            let root = GitInfo.repositoryRoot(for: cwd).map {
                SessionImporter.normalized($0.path)
            }
            roots[cwd] = root
            return root
        }

        let result = GlobalSessionScan.grouped(
            [
                (session("outer"), repo.path),
                (session("inner"), nested.path)
            ],
            knownTranscriptIDs: [],
            rootResolver: resolve,
            folderExists: { _ in true }
        )

        XCTAssertEqual(result.groups.count, 2, "The worktree is its own checkout")
        let folders = Set(result.groups.map {
            URL(fileURLWithPath: $0.folder).lastPathComponent
        })
        XCTAssertEqual(folders, ["repo", "nested"])
    }

    // MARK: - Pre-check

    func testThePrecheckBoundarySitsAtFortyEightHours() {
        let now = Date()
        let justInside = ImportableSession(
            agentSessionID: TranscriptID("in"),
            kind: .claude,
            accountHandle: .standard,
            title: "in",
            lastActiveAt: now.addingTimeInterval(-GlobalSessionScan.precheckWindow + 60)
        )
        let justOutside = ImportableSession(
            agentSessionID: TranscriptID("out"),
            kind: .claude,
            accountHandle: .standard,
            title: "out",
            lastActiveAt: now.addingTimeInterval(-GlobalSessionScan.precheckWindow - 60)
        )
        XCTAssertTrue(GlobalSessionScan.isPrechecked(justInside, now: now))
        XCTAssertFalse(GlobalSessionScan.isPrechecked(justOutside, now: now))
    }

    // MARK: - Helpers

    /// The `SessionImportBelongingTests` helper: the developer's own git config could inherit
    /// hooks, templates or a signing key, none of which a fixture is about.
    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment

        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "git \(arguments.joined(separator: " ")) failed while building the fixture"
        )
    }
}
