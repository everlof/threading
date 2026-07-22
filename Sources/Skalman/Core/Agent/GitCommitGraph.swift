import Foundation

// MARK: - Model

/// One commit's place in the drawn history: the lane its node sits in, and the line segments
/// that cross its row.
///
/// A row is described in two halves because that is how it is drawn — every segment either
/// enters from the row above or leaves toward the row below, and both meet at the node's
/// centre line. Nothing here knows a pixel; the view multiplies lanes by a column width.
struct GitGraphRow: Equatable {

    /// A line crossing half a row, named by the lane it occupies at each end. `from == to` is
    /// a lane running straight through; anything else bends.
    struct Segment: Equatable {
        let from: Int
        let to: Int
    }

    /// The lane the commit's own node sits in.
    let lane: Int

    /// Lanes this row needs, which is one past the widest it touches.
    let laneCount: Int

    /// A merge draws its node differently: it is where two histories met, and that is the one
    /// thing a graph exists to show.
    let isMerge: Bool

    /// The upper half, from the row's top edge to its centre.
    let incoming: [Segment]

    /// The lower half, from the centre to the bottom edge.
    let outgoing: [Segment]
}

// MARK: - Layout

/// Assigns commits to lanes — the whole of what makes a history a graph.
///
/// The rule is the one `git log --graph` follows: a lane is a *slot waiting for a particular
/// commit*, opened when a commit names a parent and closed when that parent is reached. A
/// commit takes the lane that was waiting for it, its first parent inherits that lane, and
/// every further parent opens a new one — which is why a merge fans out downward and a branch
/// converges upward.
///
/// Parsed from `%P` rather than from `git log --graph`'s own ASCII art: that output is drawn
/// for a fixed-width terminal, and reading pixels back out of it to draw them again is a
/// lossy round trip through someone else's renderer.
///
/// A page ends mid-history, so lanes waiting for parents outside it simply run off the bottom.
/// That is honest — those commits exist, they are just not on this page.
enum GitCommitGraph {

    // MARK: - Public Methods

    static func rows(for commits: [GitCommitSummary]) -> [GitGraphRow] {
        /// Which commit each lane is waiting for; nil is a free slot.
        var lanes: [String?] = []
        var rows: [GitGraphRow] = []

        for commit in commits {
            let before = lanes
            let waiting = before.indices.filter { before[$0] == commit.hash }

            // A commit nothing is waiting for is a tip — the first row, or a branch head that
            // no commit on this page descends from.
            let node = waiting.first ?? claimFreeLane(in: &lanes)

            // Every occupied lane arrives at this row; the ones waiting for this commit
            // converge on its node instead of running past it.
            let incoming = before.indices
                .filter { before[$0] != nil }
                .map { Segment(from: $0, to: waiting.contains($0) ? node : $0) }

            for index in waiting { lanes[index] = nil }

            // The first parent inherits the node's lane, so a linear history stays one column.
            lanes[node] = commit.parents.first
            var parentLanes = commit.parents.isEmpty ? [] : [node]

            for parent in commit.parents.dropFirst() {
                // A parent something else already waits for keeps that lane; the merge just
                // draws an edge into it rather than opening a duplicate.
                if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    parentLanes.append(existing)
                } else {
                    let free = claimFreeLane(in: &lanes)
                    lanes[free] = parent
                    parentLanes.append(free)
                }
            }

            var outgoing: [Segment] = []
            for lane in lanes.indices where lanes[lane] != nil {
                let continues = lane < before.count
                    && before[lane] != nil
                    && !waiting.contains(lane)
                    && lane != node
                if continues { outgoing.append(Segment(from: lane, to: lane)) }
                if parentLanes.contains(lane) { outgoing.append(Segment(from: node, to: lane)) }
            }

            trimTrailingFreeLanes(&lanes)

            rows.append(GitGraphRow(
                lane: node,
                laneCount: laneCount(node: node, incoming: incoming, outgoing: outgoing),
                isMerge: commit.parents.count > 1,
                incoming: incoming,
                outgoing: outgoing
            ))
        }

        return rows
    }

    /// The widest row on the page, which is what every row's rail is sized to so the nodes of
    /// one column line up down the list.
    static func laneCount(of rows: [GitGraphRow]) -> Int {
        rows.map(\.laneCount).max() ?? 1
    }

    // MARK: - Private Methods

    private typealias Segment = GitGraphRow.Segment

    /// The leftmost free lane, appending a column when every one is busy. Leftmost on purpose:
    /// a graph that reuses closed lanes stays narrow, where one that always appends grows a
    /// column per branch ever seen.
    private static func claimFreeLane(in lanes: inout [String?]) -> Int {
        if let index = lanes.firstIndex(where: { $0 == nil }) { return index }
        lanes.append(nil)
        return lanes.count - 1
    }

    private static func trimTrailingFreeLanes(_ lanes: inout [String?]) {
        while lanes.last == .some(nil) { lanes.removeLast() }
    }

    private static func laneCount(node: Int, incoming: [Segment], outgoing: [Segment]) -> Int {
        let used = [node]
            + incoming.flatMap { [$0.from, $0.to] }
            + outgoing.flatMap { [$0.from, $0.to] }
        return (used.max() ?? 0) + 1
    }
}
