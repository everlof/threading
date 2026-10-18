import XCTest
@testable import Threading

/// The page `list_reclaimable_storage` answers with.
///
/// The unbounded version returned 501 lines and 95,647 characters on a machine whose disk was
/// full, which an agent's tool result could not hold — so the agent that had hit ENOSPC never read
/// it. These pin the bound, the order an agent should propose in, and that a cut is always said
/// out loud.
final class ReclaimableStorageListingTests: XCTestCase {

    // MARK: - Fixtures

    private let project = Project(
        name: "Threading",
        folderURL: URL(fileURLWithPath: "/Users/dev/repo/Threading")
    )

    private func artifact(_ path: String, bytes: Int64) -> ReclaimableArtifact {
        ReclaimableArtifact(
            url: URL(fileURLWithPath: path),
            kind: .swiftPackage,
            byteCount: bytes,
            modifiedAt: nil,
            checkoutPath: "/Users/dev/repo/Threading"
        )
    }

    private func checkoutGroup(_ artifacts: [ReclaimableArtifact]) -> ReclaimableFindings.Group {
        ReclaimableFindings.Group(
            attribution: .checkout(project),
            title: "Threading · master",
            subtitle: "~/repo/Threading",
            identity: "/Users/dev/repo/Threading",
            artifacts: artifacts
        )
    }

    private func orphanGroup(_ artifacts: [ReclaimableArtifact]) -> ReclaimableFindings.Group {
        ReclaimableFindings.Group(
            attribution: .scratchOrphan,
            title: "Left over from deleted workspaces",
            subtitle: "/private/tmp",
            identity: "orphaned",
            artifacts: artifacts
        )
    }

    /// Lines carry only the path, so assertions read the order directly.
    private func page(
        _ groups: [ReclaimableFindings.Group],
        _ options: ReclaimableStorageListing.Options = .init()
    ) -> String {
        ReclaimableStorageListing.page(groups: groups, measured: "", options: options) { artifact, _ in
            "ROW \(artifact.url.path)"
        }
    }

    private func rows(in text: String) -> [String] {
        text.split(separator: "\n")
            .filter { $0.hasPrefix("ROW ") }
            .map { String($0.dropFirst(4)) }
    }

    /// Five hundred and one findings, the shape that broke the old answer: one large, one orphaned,
    /// the rest small.
    private func manyFindings() -> [ReclaimableFindings.Group] {
        let small = (0..<499).map {
            artifact("/Users/dev/repo/Threading/pkg\($0)/__pycache__", bytes: Int64(1_000 + $0))
        }
        let large = artifact("/Users/dev/repo/Threading/.build", bytes: 30_000_000_000)
        return [checkoutGroup([large] + small), orphanGroup([
            artifact("/private/tmp/dd-gone", bytes: 5_000)
        ])]
    }

    // MARK: - The bound

    func testTheDefaultPageIsBoundedAndSaysWhatItLeftOut() {
        let text = page(manyFindings())

        XCTAssertEqual(rows(in: text).count, ReclaimableStorageListing.defaultLimit)
        XCTAssertTrue(text.contains("across 501 directories"), text)
        XCTAssertTrue(text.contains("461 more directories"), text)
        XCTAssertTrue(text.contains("offset 40"), text)
        XCTAssertLessThan(text.count, 10_000, "a default page must fit comfortably in one tool result")
    }

    func testTheLimitIsClampedToItsMaximum() {
        let options = ReclaimableStorageListing.Options(limit: 10_000)

        XCTAssertEqual(options.limit, ReclaimableStorageListing.maximumLimit)
        XCTAssertEqual(rows(in: page(manyFindings(), options)).count, ReclaimableStorageListing.maximumLimit)
        XCTAssertEqual(ReclaimableStorageListing.Options(limit: 0).limit, 1)
        XCTAssertEqual(ReclaimableStorageListing.Options(offset: -5).offset, 0)
    }

    func testOffsetPagesThroughEveryDirectoryExactlyOnce() {
        let groups = manyFindings()
        var seen: [String] = []
        var offset = 0

        while true {
            let text = page(groups, .init(limit: 150, offset: offset))
            let batch = rows(in: text)
            if batch.isEmpty { break }
            seen += batch
            offset += batch.count
        }

        XCTAssertEqual(seen.count, 501)
        XCTAssertEqual(Set(seen).count, 501)
    }

    func testAnOffsetPastTheEndSaysSoInsteadOfLookingEmpty() {
        let text = page(manyFindings(), .init(offset: 900))

        XCTAssertTrue(rows(in: text).isEmpty)
        XCTAssertTrue(text.contains("nothing past offset 900"), text)
    }

    // MARK: - The order

    /// An orphan is the one finding nothing can want back, so it leads even when it is the
    /// smallest thing on the page — the old answer buried them under project order.
    func testOrphansLeadThenLargestFirst() {
        let listed = rows(in: page(manyFindings()))

        XCTAssertEqual(listed.first, "/private/tmp/dd-gone")
        XCTAssertEqual(listed.dropFirst().first, "/Users/dev/repo/Threading/.build")
    }

    func testTheSummaryNamesEachLocationWithItsPath() {
        let text = page(manyFindings())

        XCTAssertTrue(text.contains("Where it is:"), text)
        XCTAssertTrue(text.contains("Threading · master · ~/repo/Threading · 500 directories"), text)
        XCTAssertTrue(text.contains("Left over from deleted workspaces · /private/tmp · 1 directory"), text)
    }

    // MARK: - Narrowing

    func testUnderListsOnlyThatLocation() {
        let text = page(manyFindings(), .init(under: "/private/tmp"))

        XCTAssertEqual(rows(in: text), ["/private/tmp/dd-gone"])
        XCTAssertTrue(text.hasPrefix("Under /private/tmp: "), text)
        XCTAssertFalse(text.contains("more directories"), text)
    }

    /// `/tmp` is a symlink to `/private/tmp`; the argument is resolved once so either spelling
    /// reaches the findings the scanner stored under the real path.
    func testUnderAcceptsTheTmpAlias() {
        XCTAssertEqual(rows(in: page(manyFindings(), .init(under: "/tmp"))), ["/private/tmp/dd-gone"])
    }

    func testUnderMatchesWholePathComponentsOnly() {
        let groups = [checkoutGroup([
            artifact("/Users/dev/repo/Threading/.build", bytes: 10),
            artifact("/Users/dev/repo/Threading-old/.build", bytes: 10)
        ])]

        XCTAssertEqual(
            rows(in: page(groups, .init(under: "/Users/dev/repo/Threading"))),
            ["/Users/dev/repo/Threading/.build"]
        )
    }

    func testUnderWithNothingBelowItSaysSo() {
        let text = page(manyFindings(), .init(under: "/Users/dev/elsewhere"))

        XCTAssertTrue(text.contains("Nothing reclaimable is listed under /Users/dev/elsewhere"), text)
    }
}
