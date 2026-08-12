import XCTest
@testable import Threading

/// Reading one file out of a checkout, against a real repository.
///
/// This is the only path that turns a **string from the network** into a file read: the remote
/// server's `/repository/file` handler bounds the path with `RemoteInboundPolicy` — non-empty,
/// under a byte cap, no NUL — and nothing else. Every question about *which* file may be read is
/// answered here, so this is where those answers have to be pinned.
///
/// There are two independent defences and they catch different attacks. Git's own visible-file
/// list is an allowlist, which stops a path that simply points elsewhere. Resolving symlinks and
/// requiring the result to stay under the root is what stops a path that is *on* that list and
/// still escapes — `git ls-files -co` lists a symlink like any other file, so the allowlist waves
/// it straight through. Only the second check refuses it.
@MainActor
final class GitRepositoryFileAccessTests: XCTestCase {

    // MARK: - Fixture

    private var enclosure: URL!
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // The repository sits *inside* another directory so there is somewhere outside it to
        // point at that is not the developer's own filesystem.
        enclosure = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingRepoRead-\(UUID().uuidString)", isDirectory: true)
        root = enclosure.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try write("the secret outside the checkout", to: enclosure.appendingPathComponent("outside.txt"))

        try git("init", "--quiet")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "Test")
        try git("config", "commit.gpgsign", "false")

        try write("let tracked = true", to: root.appendingPathComponent("tracked.swift"))
        try write("ignored", to: root.appendingPathComponent("secret.key"))
        try write("*.key\n", to: root.appendingPathComponent(".gitignore"))
        try git("add", "tracked.swift", ".gitignore")
        try git("commit", "--quiet", "--message", "first")
    }

    override func tearDownWithError() throws {
        if let enclosure { try? FileManager.default.removeItem(at: enclosure) }
        enclosure = nil
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - What may be read

    func testATrackedFileReadsBack() throws {
        let file = try XCTUnwrap(read("tracked.swift").get())
        XCTAssertEqual(file.content, "let tracked = true")
        XCTAssertFalse(file.isBinary)
        XCTAssertFalse(file.isTruncated)
    }

    /// `ls-files -co --exclude-standard` lists untracked files too, so a file the user has just
    /// written is readable before it is added. That is deliberate — the review pane shows it.
    func testAnUntrackedButVisibleFileReadsBack() throws {
        try write("brand new", to: root.appendingPathComponent("fresh.txt"))
        let file = try XCTUnwrap(read("fresh.txt").get())
        XCTAssertEqual(file.content, "brand new")
    }

    /// The remote path is data, never a Git pathspec. This name would match every Swift file if
    /// handed to `ls-files` bare; the targeted allowlist query must find only the literal file.
    func testAPathspecShapedFilenameReadsLiterally() throws {
        let path = ":(glob)*.swift"
        try write("literal pathspec", to: root.appendingPathComponent(path))

        let file = try XCTUnwrap(read(path).get())
        XCTAssertEqual(file.path, path)
        XCTAssertEqual(file.content, "literal pathspec")
    }

    // MARK: - What may not

    /// Traversal, absolute paths, and a path that is merely wrong all fail the same way: they
    /// are not on git's list. No parsing of the path is involved, which is why this holds for
    /// spellings a path parser would have to enumerate.
    func testPathsOffGitsListAreRefused() throws {
        for path in [
            "../outside.txt",
            "../../outside.txt",
            "checkout/../../outside.txt",
            "/etc/passwd",
            "/etc/hosts",
            "./../outside.txt",
            ":(exclude)tracked.swift",
            "does-not-exist.txt",
            ""
        ] {
            XCTAssertThrowsError(
                try read(path).get(),
                "reading \(path) must be refused"
            )
        }
    }

    /// An ignored file is not on git's visible list, so the review pane cannot be used to read
    /// the secrets a `.gitignore` exists to keep out of it.
    func testAnIgnoredFileIsRefused() throws {
        XCTAssertThrowsError(try read("secret.key").get())
    }

    /// The case the allowlist alone does not catch, and the reason the containment check is
    /// there: a symlink *inside* the checkout, pointing outside it. `git ls-files -co` lists it
    /// like any other file, so it passes the list test — and resolving it must then put it out
    /// of bounds rather than reading what it points at.
    func testASymlinkEscapingTheCheckoutIsRefusedEvenThoughGitListsIt() throws {
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.txt"),
            withDestinationURL: enclosure.appendingPathComponent("outside.txt")
        )

        // Precondition: git really does offer this path, so the refusal below is the second
        // defence doing the work and not the first one.
        XCTAssertTrue(
            try visiblePaths().contains("escape.txt"),
            "git no longer lists the symlink; this test would pass for the wrong reason"
        )

        XCTAssertThrowsError(
            try read("escape.txt").get(),
            "a symlink out of the checkout was followed"
        )
    }

    /// The same escape one directory down, where the symlink is the *directory* rather than the
    /// file — `a/b.txt` where `a` points out of the checkout.
    func testASymlinkedDirectoryEscapingTheCheckoutIsRefused() throws {
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("away"),
            withDestinationURL: enclosure
        )
        XCTAssertThrowsError(try read("away/outside.txt").get())
    }

    // MARK: - Bounds

    /// The byte cap applies before decoding, so a large file cannot be turned into a large
    /// allocation by asking for it.
    func testAFileOverTheCapComesBackTruncated() throws {
        let cap = GitReviewDefaults.remoteRepositoryFileByteCap
        try write(String(repeating: "x", count: cap + 4096), to: root.appendingPathComponent("big.txt"))

        let file = try XCTUnwrap(read("big.txt").get())
        XCTAssertTrue(file.isTruncated)
        XCTAssertEqual(file.content?.utf8.count, cap)
    }

    /// A file with a NUL in its first bytes is reported as binary and carries no content, rather
    /// than being decoded into replacement characters.
    func testABinaryFileIsReportedRatherThanDecoded() throws {
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x1A, 0x0A])
            .write(to: root.appendingPathComponent("image.png"))

        let file = try XCTUnwrap(read("image.png").get())
        XCTAssertTrue(file.isBinary)
        XCTAssertNil(file.content)
    }

    // MARK: - Helpers

    private func read(_ path: String) -> Result<GitRepositoryFile, GitFailure> {
        let finished = expectation(description: "read \(path)")
        var outcome: Result<GitRepositoryFile, GitFailure>!
        GitReviewReader.repositoryFile(path: path, in: root) { result in
            outcome = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)
        return outcome
    }

    private func visiblePaths() throws -> [String] {
        try git("ls-files", "-co", "--exclude-standard")
            .split(separator: "\n")
            .map(String.init)
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git"] + arguments
        task.currentDirectoryURL = root
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
