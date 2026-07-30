import XCTest
@testable import Threading

/// Lane assignment — the whole of what makes a list of commits a graph, and pure, so every
/// shape that used to need a repository to see is a fixture here.
final class GitCommitGraphTests: XCTestCase {

    // MARK: - Helpers

    private func commit(_ hash: String, parents: [String] = [], refs: [String] = []) -> GitCommitSummary {
        GitCommitSummary(
            hash: hash,
            shortHash: String(hash.prefix(7)),
            subject: "subject \(hash)",
            author: "A",
            date: Date(timeIntervalSince1970: 0),
            added: 0,
            removed: 0,
            parents: parents,
            refs: refs
        )
    }

    // MARK: - Linear History

    func testLinearHistoryStaysInOneLane() {
        let rows = GitCommitGraph.rows(for: [
            commit("a", parents: ["b"]),
            commit("b", parents: ["c"]),
            commit("c", parents: [])
        ])

        XCTAssertEqual(rows.map(\.lane), [0, 0, 0])
        XCTAssertEqual(rows.map(\.laneCount), [1, 1, 1])
        XCTAssertFalse(rows.contains { $0.isMerge })
    }

    func testFirstRowHasNothingAbove() {
        let rows = GitCommitGraph.rows(for: [commit("a", parents: ["b"])])
        XCTAssertTrue(rows[0].incoming.isEmpty, "nothing enters the newest commit")
        XCTAssertEqual(rows[0].outgoing, [.init(from: 0, to: 0)])
    }

    func testRootCommitEndsItsLane() {
        let rows = GitCommitGraph.rows(for: [commit("a", parents: ["b"]), commit("b")])
        XCTAssertTrue(rows[1].outgoing.isEmpty, "a root commit has nowhere to continue to")
        XCTAssertEqual(rows[1].incoming, [.init(from: 0, to: 0)])
    }

    // MARK: - Merges

    func testMergeOpensASecondLaneAndClosesIt() {
        // a is a merge of b (first parent) and c; both reach d.
        let rows = GitCommitGraph.rows(for: [
            commit("a", parents: ["b", "c"]),
            commit("b", parents: ["d"]),
            commit("c", parents: ["d"]),
            commit("d", parents: [])
        ])

        XCTAssertTrue(rows[0].isMerge)
        XCTAssertEqual(rows[0].lane, 0)
        // The merge fans out: first parent keeps the lane, the second opens one.
        XCTAssertEqual(rows[0].outgoing, [.init(from: 0, to: 0), .init(from: 0, to: 1)])
        XCTAssertEqual(rows[0].laneCount, 2)

        // The side branch runs past b in its own lane.
        XCTAssertEqual(rows[1].lane, 0)
        XCTAssertEqual(rows[1].incoming, [.init(from: 0, to: 0), .init(from: 1, to: 1)])

        XCTAssertEqual(rows[2].lane, 1, "c is picked up by the lane opened for it")

        // Both lanes converge on d, which is what a converging line means.
        XCTAssertEqual(rows[3].lane, 0)
        XCTAssertEqual(rows[3].incoming, [.init(from: 0, to: 0), .init(from: 1, to: 0)])
        XCTAssertTrue(rows[3].outgoing.isEmpty)
    }

    func testMergeIntoAnAlreadyWaitingLaneDoesNotDuplicateIt() {
        // Both a and b name c as a parent; the merge draws an edge into the existing lane
        // rather than opening a second one for the same commit.
        let rows = GitCommitGraph.rows(for: [
            commit("a", parents: ["b", "c"]),
            commit("b", parents: ["c"]),
            commit("c", parents: [])
        ])

        XCTAssertEqual(rows.map(\.laneCount), [2, 2, 2])
        XCTAssertEqual(rows[2].lane, 0)
        XCTAssertEqual(rows[2].incoming, [.init(from: 0, to: 0), .init(from: 1, to: 0)])
    }

    // MARK: - Detached Tips

    func testCommitNothingWaitsForClaimsAFreeLane() {
        // A page can contain a commit no listed commit descends from — a second branch tip.
        let rows = GitCommitGraph.rows(for: [
            commit("a", parents: ["b"]),
            commit("x", parents: ["b"]),
            commit("b", parents: [])
        ])

        XCTAssertEqual(rows[1].lane, 1, "the tip takes the free lane beside the first")
        XCTAssertEqual(rows[2].incoming, [.init(from: 0, to: 0), .init(from: 1, to: 0)])
    }

    func testClosedLanesAreReused() {
        // Lane 1 closes at c and is free again for the later branch, so the graph stays narrow.
        let rows = GitCommitGraph.rows(for: [
            commit("a", parents: ["b", "c"]),
            commit("c", parents: ["b"]),
            commit("b", parents: ["d", "e"]),
            commit("e", parents: ["d"]),
            commit("d", parents: [])
        ])

        XCTAssertEqual(GitCommitGraph.laneCount(of: rows), 2, "never wider than two lanes at once")
    }

    // MARK: - Page Boundaries

    func testLanesRunOffTheBottomOfAPage() {
        // The parents of the last row are on the next page; their lanes still leave the row.
        let rows = GitCommitGraph.rows(for: [commit("a", parents: ["b", "c"])])
        XCTAssertEqual(rows[0].outgoing.count, 2)
    }

    func testEmptyHistoryHasOneLane() {
        XCTAssertEqual(GitCommitGraph.laneCount(of: GitCommitGraph.rows(for: [])), 1)
    }
}
