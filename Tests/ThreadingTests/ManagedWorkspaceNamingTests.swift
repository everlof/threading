import XCTest
@testable import Threading

/// The name of a managed checkout is the one string an agent reads all session: it is the
/// working directory, so it is also the status line, the prompt, and every path it prints.
final class ManagedWorkspaceNamingTests: XCTestCase {

    private let sessionID = SessionID(
        UUID(uuidString: "63BAA514-DA0F-4789-9756-221DC0DF3D89")!
    )

    func testNamesTheCheckoutAfterTheTaskAndKeepsTheUUIDsFirstGroup() {
        XCTAssertEqual(
            ManagedWorkspaceNaming.directoryName(
                for: sessionID,
                title: "Deliver a running child's output as it arrives"
            ),
            "deliver-a-running-childs-63baa514"
        )
    }

    /// The reason the words are capped at all. A name that grew past the identifier it replaced
    /// would push the parts of a status line that are actually about the agent off the end.
    func testIsNeverLongerThanTheUUIDItReplaces() {
        let titles = [
            "Deliver a running child's output as it arrives",
            "Stand up the hosted control plane's infrastructure and notifications",
            "Put the attachments fold's seam out when the hand lets go",
            "Städa förrådet före släppet"
        ]

        for title in titles {
            let name = ManagedWorkspaceNaming.directoryName(for: sessionID, title: title)
            XCTAssertLessThanOrEqual(
                name.count,
                sessionID.uuidString.count,
                "\(title) named a longer directory than its own UUID"
            )
        }
    }

    func testCutsAtAWordBoundaryRatherThanMidWord() {
        XCTAssertEqual(
            ManagedWorkspaceNaming.slug(from: "Reticulating splines exhaustively"),
            "reticulating-splines"
        )
    }

    /// A single word longer than the whole allowance is the one case that may be cut inside a
    /// word: the alternative is a name made only of a UUID.
    func testTruncatesAFirstWordThatIsLongerThanTheWholeAllowance() {
        let slug = ManagedWorkspaceNaming.slug(from: "Internationalizationalization now")

        XCTAssertEqual(slug.count, ManagedWorkspaceNamingDefaults.slugLimit)
        XCTAssertTrue("internationalizationalization".hasPrefix(slug))
    }

    func testKeepsDigitsBecauseAnIssueNumberIsMostOfWhatSaysWhichTaskThisIs() {
        XCTAssertEqual(
            ManagedWorkspaceNaming.slug(from: "Fix issue 4711"),
            "fix-issue-4711"
        )
    }

    /// Transliterated before it is filtered. Filtering first would leave nothing of a title
    /// written outside ASCII, and those titles would silently be the only ones still on a UUID.
    func testTransliteratesATitleWrittenOutsideASCII() {
        XCTAssertEqual(
            ManagedWorkspaceNaming.slug(from: "Städa förrådet före släppet"),
            "stada-forradet-fore"
        )

        let japanese = ManagedWorkspaceNaming.slug(from: "日本語のテスト")
        XCTAssertFalse(japanese.isEmpty)
        XCTAssertTrue(
            japanese.allSatisfy { character in
                character == "-" || (character.isASCII && (character.isLetter || character.isNumber))
            },
            "a transliterated title must still produce a plain ASCII directory name: \(japanese)"
        )
    }

    func testFallsBackToTheUUIDWhenTheTitleIsNotWordsAtAll() {
        let identifier = sessionID.uuidString.lowercased()

        XCTAssertEqual(
            ManagedWorkspaceNaming.directoryName(for: sessionID, title: nil),
            identifier
        )
        XCTAssertEqual(
            ManagedWorkspaceNaming.directoryName(for: sessionID, title: "   "),
            identifier
        )
        XCTAssertEqual(
            ManagedWorkspaceNaming.directoryName(for: sessionID, title: "🎉 …!"),
            identifier
        )
    }

    /// Nine of these can sit side by side under one directory, and two of them can have been
    /// started from the same sentence.
    func testTwoSessionsStartedFromOneSentenceStillGetDifferentDirectories() {
        let title = "Rename the worktree"
        let first = ManagedWorkspaceNaming.directoryName(for: SessionID(), title: title)
        let second = ManagedWorkspaceNaming.directoryName(for: SessionID(), title: title)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix("rename-the-worktree-"))
        XCTAssertTrue(second.hasPrefix("rename-the-worktree-"))
    }

    /// A directory name is not a sentence: anything a shell, a path or Git would have to be
    /// careful with is gone before it reaches the filesystem.
    func testContainsNothingAPathHasToBeCarefulWith() {
        let name = ManagedWorkspaceNaming.directoryName(
            for: sessionID,
            title: "Fix ../../etc/hosts & \"quoting\" in $PATH; now"
        )

        XCTAssertEqual(
            name.filter { !($0.isASCII && ($0.isLetter || $0.isNumber)) && $0 != "-" },
            ""
        )
        XCTAssertFalse(name.hasPrefix("-"))
        XCTAssertFalse(name.contains(".."))
    }
}
