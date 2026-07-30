import XCTest
@testable import Threading

/// The gate that decides what an agent's cleanup proposal is allowed to name.
///
/// It is the security boundary of the storage feature — everything past it is a real `rm -rf` on
/// somebody's directory, with only a modal sheet in between — and until it was pulled out of the
/// tool handler nothing tested it, because reaching it needed a window, a project store and a
/// sheet. These pin the answers that make it a gate rather than a lookup.
final class StorageCleanupGateTests: XCTestCase {

    // MARK: - Fixtures

    private func artifact(_ path: String, bytes: Int64 = 1_000) -> ReclaimableArtifact {
        ReclaimableArtifact(
            url: URL(fileURLWithPath: path),
            kind: .node,
            byteCount: bytes,
            modifiedAt: nil,
            checkoutPath: "/repo"
        )
    }

    // MARK: - The gate

    func testOnlyVettedPathsAreMatched() {
        let vetted = [artifact("/repo/node_modules"), artifact("/repo/web/node_modules")]

        let resolution = StorageCleanupGate.resolve(
            "/repo/node_modules\n/etc/passwd\n/repo/web/node_modules",
            against: vetted
        )

        XCTAssertEqual(resolution.matched.map(\.url.path), [
            "/repo/node_modules", "/repo/web/node_modules"
        ])
        XCTAssertEqual(resolution.unknown, ["/etc/passwd"])
    }

    /// A path that merely *resolves* to a vetted directory is refused rather than normalised
    /// into a match. Every rule that makes two different strings mean one directory is a rule
    /// that can be run backwards, and the cost of refusing is one corrected call.
    func testPathsThatOnlyResolveToAFindingAreRefused() {
        let vetted = [artifact("/repo/node_modules")]

        for variant in [
            "/repo/node_modules/",
            "/repo/web/../node_modules",
            "/repo//node_modules",
            "~/repo/node_modules",
            "/REPO/node_modules"
        ] {
            let resolution = StorageCleanupGate.resolve(variant, against: vetted)
            XCTAssertTrue(
                resolution.matched.isEmpty,
                "\(variant) was matched to a finding it is not string-equal to"
            )
            XCTAssertEqual(resolution.unknown, [variant])
        }
    }

    /// Nothing named at all is a different failure from naming only unknown paths: one is a
    /// malformed call, the other a listing that has gone stale, and the agent needs to tell them
    /// apart to know whether to re-read.
    func testAnEmptyRequestIsItsOwnAnswer() {
        XCTAssertTrue(StorageCleanupGate.resolve(nil, against: []).isEmptyRequest)
        XCTAssertTrue(StorageCleanupGate.resolve("", against: []).isEmptyRequest)
        XCTAssertTrue(StorageCleanupGate.resolve("  \n \n ", against: []).isEmptyRequest)

        let unknownOnly = StorageCleanupGate.resolve("/etc/passwd", against: [])
        XCTAssertFalse(unknownOnly.isEmptyRequest)
        XCTAssertEqual(unknownOnly.unknown, ["/etc/passwd"])
    }

    /// Two projects can list the same artifact — the same folder added twice, or one checkout
    /// nested inside another. This used to build its lookup with `Dictionary(uniqueKeysWithValues:)`,
    /// which **traps** on a duplicate key: an ordinary configuration took the app down from a
    /// tool call.
    func testDuplicateFindingsDoNotTrap() {
        let duplicated = [
            artifact("/repo/node_modules", bytes: 10),
            artifact("/repo/node_modules", bytes: 20)
        ]

        let resolution = StorageCleanupGate.resolve("/repo/node_modules", against: duplicated)

        XCTAssertEqual(resolution.matched.count, 1, "one path resolved to two deletions")
        XCTAssertEqual(resolution.matched.first?.byteCount, 10, "the first finding should win")
    }

    /// A path named twice is put to the user once — an approval sheet listing the same directory
    /// twice reads as two directories.
    func testARepeatedPathCollapses() {
        let resolution = StorageCleanupGate.resolve(
            "/repo/node_modules\n/repo/node_modules",
            against: [artifact("/repo/node_modules")]
        )

        XCTAssertEqual(resolution.matched.count, 1)
        XCTAssertTrue(resolution.unknown.isEmpty)
    }

    /// Whitespace and blank lines are the shape of a list an agent writes; they are not part of
    /// the path.
    func testSurroundingWhitespaceIsNotPartOfThePath() {
        let resolution = StorageCleanupGate.resolve(
            "\n  /repo/node_modules  \n\n",
            against: [artifact("/repo/node_modules")]
        )

        XCTAssertEqual(resolution.matched.map(\.url.path), ["/repo/node_modules"])
    }
}
