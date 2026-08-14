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

    /// A finding in the scratch scope: no checkout, and a workspace its own manifest named. Built
    /// as a value rather than on disk, because nothing under test here reads the filesystem —
    /// whether the workspace still exists is a question the caller answers.
    private func scratchArtifact(
        _ path: String,
        builtFor workspace: String,
        bytes: Int64 = 2_000,
        modifiedAt: Date? = nil
    ) -> ReclaimableArtifact {
        ReclaimableArtifact(
            url: URL(fileURLWithPath: path),
            kind: .xcodeDerivedData,
            byteCount: bytes,
            modifiedAt: modifiedAt,
            checkoutPath: "/private/tmp",
            workspacePath: workspace
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

    // MARK: - The scratch scope

    /// The listing gained a second scope; the gate did not gain a second rule. A scratch path is
    /// proposable for exactly one reason — it is in the vetted list the tool built — and the
    /// tool builds that list from both scopes.
    func testAScratchPathInTheVettedListIsProposable() {
        let vetted = [
            artifact("/repo/node_modules"),
            scratchArtifact("/private/tmp/dd", builtFor: "/repo/App.xcodeproj")
        ]

        let resolution = StorageCleanupGate.resolve(
            "/private/tmp/dd\n/repo/node_modules",
            against: vetted
        )

        XCTAssertEqual(resolution.matched.map(\.url.path), ["/private/tmp/dd", "/repo/node_modules"])
        XCTAssertTrue(resolution.unknown.isEmpty)
    }

    /// The reach widened by exactly the findings, and by nothing else. A sibling of a vetted
    /// scratch directory is still an arbitrary path: `/private/tmp` holds other sessions' working
    /// copies, and the whole point of the manifest gate is that being *near* a finding proves
    /// nothing about a directory.
    func testAScratchPathOutsideTheVettedListIsStillRefused() {
        let vetted = [scratchArtifact("/private/tmp/dd", builtFor: "/repo/App.xcodeproj")]

        let resolution = StorageCleanupGate.resolve(
            "/private/tmp/dd2\n/private/tmp/claude-501/session/scratchpad/tree",
            against: vetted
        )

        XCTAssertTrue(resolution.matched.isEmpty)
        XCTAssertEqual(resolution.unknown, [
            "/private/tmp/dd2", "/private/tmp/claude-501/session/scratchpad/tree"
        ])
    }

    // MARK: - The scratch line

    /// A cache whose workspace is gone is marked, not merely described. It is the safest thing
    /// the listing offers — nothing can rebuild into it and nothing will read it again — and an
    /// agent assembling a proposal should be able to lead with these.
    @MainActor
    func testAnOrphanedScratchLineSaysItsWorkspaceIsGone() {
        let line = AgentToolCoordinator.describeScratch(
            scratchArtifact(
                "/private/tmp/verify-dd",
                builtFor: "/private/tmp/verify/App.xcodeproj",
                modifiedAt: Date(timeIntervalSinceNow: -60 * 60 * 24 * 20)
            ),
            workspaceExists: { _ in false }
        )

        XCTAssertTrue(line.hasPrefix("/private/tmp/verify-dd · "), line)
        XCTAssertTrue(line.contains("ORPHANED"), line)
        XCTAssertTrue(line.contains("/private/tmp/verify/App.xcodeproj, which no longer exists"), line)
        XCTAssertTrue(line.contains("Xcode derived data"), line)
        XCTAssertTrue(line.contains("rebuild: xcodebuild"), line)
        XCTAssertTrue(line.contains("last written"), line)
    }

    /// A live workspace is named and nothing more. Calling it an orphan would be a claim about
    /// somebody's real directory, and the difference is resolved when listing rather than when
    /// scanning, because a workspace can be deleted or restored in between.
    @MainActor
    func testALiveWorkspaceScratchLineNamesTheWorkspaceItWasBuiltFor() {
        let workspace = "/Users/someone/repo/App/App.xcodeproj"
        let line = AgentToolCoordinator.describeScratch(
            scratchArtifact("/private/tmp/dd", builtFor: workspace),
            workspaceExists: { $0 == workspace }
        )

        XCTAssertTrue(line.contains("built for \(workspace)"), line)
        XCTAssertFalse(line.contains("ORPHANED"), line)
        XCTAssertFalse(line.contains("no longer exists"), line)
    }

    /// The in-use tail is the project lines' rule applied to a scratch tree, where it matters
    /// more: `/private/tmp` is where another session builds, so a cache written moments ago is
    /// very likely being written by someone right now.
    @MainActor
    func testAFreshlyWrittenScratchLineIsMarkedInUse() {
        let now = Date()
        let line = AgentToolCoordinator.describeScratch(
            scratchArtifact(
                "/private/tmp/dd",
                builtFor: "/repo/App.xcodeproj",
                modifiedAt: now.addingTimeInterval(-30)
            ),
            at: now,
            workspaceExists: { _ in true }
        )

        XCTAssertTrue(line.contains("IN USE"), line)
        XCTAssertFalse(line.contains("last written"), line)
    }

    /// A scan that recorded no modification date states no age. A missing reading is not an age
    /// of zero, which would read as "written just now" and mark a months-old tree in use.
    @MainActor
    func testAScratchLineWithNoRecordedAgeSaysNothingAboutAge() {
        let line = AgentToolCoordinator.describeScratch(
            scratchArtifact("/private/tmp/dd", builtFor: "/repo/App.xcodeproj"),
            workspaceExists: { _ in true }
        )

        XCTAssertFalse(line.contains("IN USE"), line)
        XCTAssertFalse(line.contains("last written"), line)
        XCTAssertTrue(line.hasSuffix("rebuild: xcodebuild"), line)
    }
}
