import XCTest
@testable import Threading

/// The proposal sheet's outline: headings that mean something, and shared path segments folded
/// into branches under them.
///
/// The list this replaced was one bullet per absolute path. Six of them beginning
/// `/Users/david/repo/AnotherTerminal/` share their first thirty-four characters, so the part
/// that says *which* directory is going started wherever the eye finally got to.
@MainActor
final class StorageCleanupOutlineTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    // MARK: - Folding

    /// Paths that share a directory are one branch with its children under it, and the branch
    /// carries what it accounts for — a total is an answer too.
    func testSharedPathSegmentsBecomeOneBranchCarryingTheirTotal() {
        let outline = StorageCleanupOutline.make(
            from: [checkout([
                artifact("/repo/app/web/node_modules", bytes: 400),
                artifact("/repo/app/web/.next", bytes: 600),
                artifact("/repo/app/.build", bytes: 2_000)
            ])],
            at: now
        )

        // Largest first at both levels, which is why `.next` leads `node_modules` under `web`.
        let section = try? XCTUnwrap(outline.sections.first)
        XCTAssertEqual(section?.rows.map(\.label), [".build", "web", ".next", "node_modules"])
        XCTAssertEqual(section?.rows.map(\.depth), [0, 0, 1, 1])
        XCTAssertEqual(section?.rows.map(\.isDirectory), [true, false, true, true])
        XCTAssertEqual(
            section?.rows.first { !$0.isDirectory }?.byteCount,
            1_000,
            "the branch does not add up what is under it"
        )
        XCTAssertEqual(section?.directoryCount, 3, "a branch was counted as a directory")
    }

    /// A level that names one thing is an indent, not information: it folds into the label.
    func testASingleChildChainCollapsesOntoOneLine() {
        let outline = StorageCleanupOutline.make(
            from: [checkout([artifact("/repo/app/a/b/c/target", bytes: 10)])],
            at: now
        )

        XCTAssertEqual(outline.sections.first?.rows.map(\.label), ["a/b/c/target"])
        XCTAssertEqual(outline.sections.first?.rows.first?.depth, 0)
    }

    /// Largest first at every level, so the line worth reading is never under the ones that are
    /// not.
    func testEveryLevelIsOrderedBySize() {
        let outline = StorageCleanupOutline.make(
            from: [checkout([
                artifact("/repo/app/web/small", bytes: 1),
                artifact("/repo/app/web/large", bytes: 900),
                artifact("/repo/app/target", bytes: 500)
            ])],
            at: now
        )

        XCTAssertEqual(
            outline.sections.first?.rows.map(\.label),
            ["web", "large", "small", "target"]
        )
    }

    // MARK: - Notes

    /// What a temporary cache was built for is the only thing that tells two identical-looking
    /// caches apart, so a scratch row carries it.
    func testAScratchRowNamesTheWorkspaceItWasBuiltFor() {
        let project = Project(name: "app", folderURL: URL(fileURLWithPath: "/repo/app"))
        let groups = ReclaimableFindings.scratchGroups(
            [scratchArtifact("/private/tmp/dd", workspace: "/repo/app/App.xcodeproj", bytes: 10)],
            among: [project],
            workspaceExists: { _ in true }
        )

        let row = StorageCleanupOutline.make(from: groups, at: now).sections.first?.rows.first
        XCTAssertEqual(row?.note, ReclaimableFindings.Strings.builtFor("/repo/app/App.xcodeproj"))
    }

    /// An orphan's heading already says its workspace is gone. Repeating it on every row would
    /// spend the widest column in the sheet on the fact the heading opens with.
    func testAnOrphanRowCarriesNoNoteBecauseItsHeadingIsTheReason() {
        let groups = ReclaimableFindings.scratchGroups(
            [scratchArtifact("/private/tmp/dd", workspace: "/gone/App.xcodeproj", bytes: 10)],
            among: [],
            workspaceExists: { _ in false }
        )

        XCTAssertEqual(groups.first?.title, ReclaimableFindings.Strings.deletedWorkspaces)
        XCTAssertNil(StorageCleanupOutline.make(from: groups, at: now).sections.first?.rows.first?.note)
    }

    /// The one fact that makes an approval regrettable leads the note.
    func testADirectoryWrittenMomentsAgoIsMarkedInUse() {
        let outline = StorageCleanupOutline.make(
            from: [checkout([
                artifact("/repo/app/.build", bytes: 10, modifiedAt: now.addingTimeInterval(-30))
            ])],
            at: now
        )

        let note = outline.sections.first?.rows.first?.note
        XCTAssertNotNil(note)
        XCTAssertTrue(
            note?.contains(ReclaimableFindings.Strings.inUse("").prefix(6)) ?? false,
            "a directory being written to right now was not marked: \(note ?? "nil")"
        )
    }

    // MARK: - Reading

    /// Totals are the sections', and a section with nothing under it is not a section.
    func testTheOutlineTotalsWhatIsActuallyGoing() {
        let outline = StorageCleanupOutline.make(
            from: [
                checkout([artifact("/repo/app/.build", bytes: 2_000)]),
                checkout([], title: "empty")
            ],
            at: now
        )

        XCTAssertEqual(outline.sections.count, 1, "a heading with no rows was drawn")
        XCTAssertEqual(outline.byteCount, 2_000)
        XCTAssertEqual(outline.directoryCount, 1)
        XCTAssertTrue(outline.plainText().contains(".build"))
    }

    // MARK: - Helpers

    private func checkout(
        _ artifacts: [ReclaimableArtifact],
        title: String = "app · main"
    ) -> ReclaimableFindings.Group {
        ReclaimableFindings.Group(
            attribution: .checkout(
                Project(name: "app", folderURL: URL(fileURLWithPath: "/repo/app"))
            ),
            title: title,
            subtitle: "/repo/app",
            identity: "/repo/app",
            artifacts: artifacts
        )
    }

    private func artifact(
        _ path: String,
        bytes: Int64,
        modifiedAt: Date? = nil
    ) -> ReclaimableArtifact {
        ReclaimableArtifact(
            url: URL(fileURLWithPath: path),
            kind: .swiftPackage,
            byteCount: bytes,
            modifiedAt: modifiedAt ?? now.addingTimeInterval(-86_400),
            checkoutPath: "/repo/app"
        )
    }

    private func scratchArtifact(
        _ path: String,
        workspace: String,
        bytes: Int64
    ) -> ReclaimableArtifact {
        ReclaimableArtifact(
            url: URL(fileURLWithPath: path),
            kind: .xcodeDerivedData,
            byteCount: bytes,
            modifiedAt: now.addingTimeInterval(-86_400),
            checkoutPath: "/private/tmp",
            workspacePath: workspace
        )
    }
}
