import Foundation
import XCTest
@testable import Threading

/// A remote checkout's uncommitted changes, read by the exact command a host runs — here run by a
/// real shell against real repositories, so the quoting, the untracked synthesis and every refusal
/// are exercised rather than described.
final class RemoteGitReviewTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/threading-remote-review-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func git(_ arguments: String..., in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    private func run(_ directory: String, path: String = "/usr/bin:/bin") throws -> RemoteGitReviewOutcome {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", RemoteGitReviewReader.command(remoteDirectory: directory)]
        shell.environment = ["PATH": path, "HOME": root.path]
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        return RemoteGitReviewReader.parse(data)
    }

    private func repository(named name: String, committed: Bool = true) throws -> URL {
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "work", in: repo)
        try git("config", "user.email", "t@t", in: repo)
        try git("config", "user.name", "t", in: repo)
        if committed {
            try Data("one\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
            try git("add", ".", in: repo)
            try git("commit", "-qm", "base", in: repo)
        }
        return repo
    }

    /// Tracked changes and untracked files both arrive, the untracked ones without the index ever
    /// being written, and a file over the per-file cap is left out rather than truncated.
    func testTrackedAndUntrackedChangesArriveAndAnOversizedFileIsLeftOut() throws {
        let repo = try repository(named: "it's a $(checkout)")
        try Data("one\ntwo\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        try Data("fresh\n".utf8).write(to: repo.appendingPathComponent("new file.txt"))
        try Data(repeating: UInt8(ascii: "x"), count: RemoteGitReviewDefaults.untrackedFileBytes + 1)
            .write(to: repo.appendingPathComponent("huge.txt"))
        let indexBefore = try Data(contentsOf: repo.appendingPathComponent(".git/index"))

        guard case .diffs(let branch, let files, let truncated) = try run(repo.path) else {
            return XCTFail("no diff came back")
        }
        XCTAssertEqual(branch, "work")
        XCTAssertFalse(truncated)
        let paths = Set(files.map(\.path))
        XCTAssertTrue(paths.contains("tracked.txt"), "\(paths)")
        XCTAssertTrue(paths.contains("new file.txt"), "an untracked file did not arrive: \(paths)")
        XCTAssertFalse(paths.contains("huge.txt"), "a file over the cap was read")
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent(".git/index")), indexBefore,
                       "a read wrote the index")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/index.lock").path))
    }

    /// A repository with no commit yet compares against the empty tree rather than failing on HEAD.
    func testARepositoryWithNoCommitYetShowsItsFiles() throws {
        let repo = try repository(named: "empty", committed: false)
        try Data("first\n".utf8).write(to: repo.appendingPathComponent("first.txt"))
        guard case .diffs(_, let files, _) = try run(repo.path) else { return XCTFail("no diff came back") }
        XCTAssertEqual(files.map(\.path), ["first.txt"])
    }

    /// Each reason a checkout cannot be reviewed is its own answer, not an error.
    func testEachRefusalIsNamed() throws {
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertEqual(try run(plain.path), .notRepository)
        XCTAssertEqual(try run(root.appendingPathComponent("absent").path), .missingDirectory)
        XCTAssertEqual(try run(plain.path, path: "/nonexistent"), .noGit)
        XCTAssertEqual(RemoteGitReviewReader.parse(Data("garbage\n".utf8)),
                       .failed("The host's answer about its checkout could not be read."))
    }

    func testACleanCheckoutHasNothingToShow() throws {
        let repo = try repository(named: "clean")
        guard case .diffs(_, let files, _) = try run(repo.path) else { return XCTFail("no diff came back") }
        XCTAssertTrue(files.isEmpty)
    }
}
