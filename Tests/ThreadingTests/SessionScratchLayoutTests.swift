import XCTest
@testable import Threading

/// `SessionScratchLayout` is the recognizer a future delete gate will rest on, so what it
/// *refuses* is worth more than what it accepts. Every negative case here is a path that would
/// become a deletable directory if the match were loosened into a prefix or a regex.
final class SessionScratchLayoutTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    private let sessionUUID = "e11352e0-cb0f-4006-a210-cab6d4b00bc1"

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - Recognised

    func testReadsTheSessionIdentifierOutOfAWellFormedScratchDirectory() throws {
        let found = try XCTUnwrap(SessionScratchLayout.read(
            url("/private/tmp/claude-501/-Users-david-repo-AnotherTerminal/\(sessionUUID)"),
            roots: [root]
        ))

        XCTAssertEqual(found.sessionID, SessionID(uuidString: sessionUUID))
        XCTAssertEqual(found.namespace, "claude-501")
    }

    /// `/tmp` is a symlink to `/private/tmp`. Two spellings of one directory must not read as two
    /// places — the same equivalence `isDisposableScratch` relies on.
    func testAcceptsTheSymlinkedSpellingOfTheRoot() {
        XCTAssertNotNil(SessionScratchLayout.read(
            url("/tmp/claude-501/-Users-david-repo-AnotherTerminal/\(sessionUUID)"),
            roots: [root]
        ))
    }

    /// The slug is an encoding of a folder path that has changed shape before, so a session
    /// directory under an unfamiliar slug is still that session's directory.
    func testDoesNotValidateTheProjectSlug() {
        XCTAssertNotNil(SessionScratchLayout.read(
            url("/private/tmp/claude-501/-private-var-folders-p5-T-threading-panel-toggle-X/\(sessionUUID)"),
            roots: [root]
        ))
    }

    /// The regression this class was written to catch, and the reason `normalizedComponents`
    /// exists. `resolvingSymlinksInPath()` drops a leading `/private` only when the shorter path
    /// still resolves on disk, so the recognizer used to answer differently for two paths that
    /// differ *only* in whether they exist — and it passed its own well-formed case for the wrong
    /// reason, because that path named a real session directory.
    ///
    /// A scratch root is the most volatile place this code looks, so existence must not be part
    /// of the answer.
    func testAnswersTheSameForAPathThatExistsAndOneThatDoesNot() throws {
        let onDisk = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("claude-501/-Existing-Fixture/\(sessionUUID)", isDirectory: true)
        let roots = [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)]

        try FileManager.default.createDirectory(at: onDisk, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: onDisk.deletingLastPathComponent()) }

        let absent = onDisk
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("-Absent-Fixture/\(sessionUUID)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))

        XCTAssertEqual(
            SessionScratchLayout.read(onDisk, roots: roots)?.sessionID,
            SessionScratchLayout.read(absent, roots: roots)?.sessionID
        )
        XCTAssertNotNil(SessionScratchLayout.read(absent, roots: roots))
    }

    /// The same equivalence stated directly: both spellings of a root, against a path that is not
    /// on disk, so neither side can be rescued by the filesystem agreeing with it.
    func testBothSpellingsOfTheRootAgreeOnAPathThatDoesNotExist() {
        let viaPrivate = url("/private/tmp/claude-501/-Absent/\(sessionUUID)")
        let viaSymlink = url("/tmp/claude-501/-Absent/\(sessionUUID)")

        for root in [url("/private/tmp"), url("/tmp")] {
            XCTAssertNotNil(SessionScratchLayout.read(viaPrivate, roots: [root]), "root \(root.path)")
            XCTAssertNotNil(SessionScratchLayout.read(viaSymlink, roots: [root]), "root \(root.path)")
        }
    }

    // MARK: - Refused

    /// The directory *inside* a session's scratchpad is not the session's directory. Answering
    /// about it would put a delete gate one component away from the work in progress.
    func testRefusesAPathBelowTheSessionDirectory() {
        XCTAssertNil(SessionScratchLayout.read(
            url("/private/tmp/claude-501/-Users-david-repo-AnotherTerminal/\(sessionUUID)/scratchpad"),
            roots: [root]
        ))
    }

    func testRefusesTheProjectSlugDirectoryItself() {
        XCTAssertNil(SessionScratchLayout.read(
            url("/private/tmp/claude-501/-Users-david-repo-AnotherTerminal"),
            roots: [root]
        ))
    }

    func testRefusesALeafThatIsNotASessionIdentifier() {
        XCTAssertNil(SessionScratchLayout.read(
            url("/private/tmp/claude-501/-Users-david-repo-AnotherTerminal/not-a-uuid"),
            roots: [root]
        ))
    }

    /// `claude-` alone is a plausible name for somebody's own directory; the uid digits are what
    /// make it a namespace.
    func testRefusesTheNamespaceWithoutUidDigits() {
        XCTAssertNil(SessionScratchLayout.read(
            url("/private/tmp/claude-/-Users-david-repo-AnotherTerminal/\(sessionUUID)"),
            roots: [root]
        ))
    }

    func testRefusesANamespaceThatIsNotTheAgentOne() {
        XCTAssertNil(SessionScratchLayout.read(
            url("/private/tmp/codex-501/-Users-david-repo-AnotherTerminal/\(sessionUUID)"),
            roots: [root]
        ))
    }

    /// The whole claim is about the locations agents build in. A correctly shaped path somewhere
    /// else is somebody's data that happens to be named like a session.
    func testRefusesACorrectShapeOutsideAnyScratchRoot() {
        XCTAssertNil(SessionScratchLayout.read(
            url("/Users/david/claude-501/-Users-david-repo-AnotherTerminal/\(sessionUUID)"),
            roots: [root]
        ))
    }

    /// Traversal is refused rather than normalised into a match: the resolved path has more
    /// components than the layout allows, and no rule here collapses it back.
    func testRefusesATraversalThatWouldResolveIntoTheLayout() {
        XCTAssertNil(SessionScratchLayout.read(
            url("/private/tmp/claude-501/-Users-david/../-Users-david/\(sessionUUID)/.."),
            roots: [root]
        ))
    }

    func testRefusesEverythingWhenNoRootsAreGiven() {
        XCTAssertNil(SessionScratchLayout.read(
            url("/private/tmp/claude-501/-Users-david-repo-AnotherTerminal/\(sessionUUID)"),
            roots: []
        ))
    }
}
