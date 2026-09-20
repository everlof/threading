import UIKit
import XCTest
@testable import ThreadingMobile

/// A streamed answer taller than the phone could leave the transcript blank.
///
/// The timeline's layout keeps measured row heights by diffable identifier and shifts the frames
/// after a changed row rather than re-solving the whole column. Every path that told it "this row
/// changed" used to do so by *forgetting* the row's height, which stands the row back up at
/// `estimatedRowHeight`. For the row being streamed into — reconfigured on every chunk, and
/// routinely thousands of points tall — that took the whole answer out of the content size
/// several times a second. A reader inside that row is then past the end of the content, and a
/// viewport past the end mounts no cell, so nothing is left on screen to report the real height
/// back: the blank is permanent until the person drags.
///
/// These cover the three seams that recovered it: measuring a mounted row in place, handing a
/// measurement to the row that replaces the streaming one, and the offset rules that decide
/// whether a growing row moves what the reader is looking at.
@MainActor
final class RemoteConversationLayoutTests: XCTestCase {
    private enum Fixture {
        static let estimate: CGFloat = 88
        static let width: CGFloat = 390
        static let height: CGFloat = 800
        static let spacing = MobileDesign.Spacing.large
    }

    private var hosts: [UICollectionView] = []
    private var sources: [Source] = []

    override func tearDown() async throws {
        hosts.removeAll()
        sources.removeAll()
        ScriptedHeightCell.heights.removeAll()
        try await super.tearDown()
    }

    // MARK: - A mounted row re-measures instead of collapsing

    func testReconfiguringTheStreamingRowKeepsItsMeasuredHeight() {
        let (collectionView, layout, _) = makeHost(identifiers: ["a", "b"], heights: [600, 2400])
        collectionView.layoutIfNeeded()
        let streaming = IndexPath(item: 1, section: 0)
        XCTAssertEqual(layout.layoutAttributesForItem(at: streaming)?.frame.height, 2400)
        let contentBefore = layout.collectionViewContentSize.height

        // One streaming chunk: the cell now measures taller, and the timeline asks the layout to
        // take that from the cell it just wrote to.
        ScriptedHeightCell.heights[1] = 2500
        layout.remeasureMountedItems(at: [streaming])

        XCTAssertEqual(
            layout.layoutAttributesForItem(at: streaming)?.frame.height,
            2500,
            "The row the reader is inside must never drop back to the estimate"
        )
        XCTAssertEqual(layout.collectionViewContentSize.height, contentBefore + 100, accuracy: 0.5)
    }

    func testRemeasuringARowMovesEveryRowAfterItAndNothingBefore() {
        let (collectionView, layout, _) = makeHost(
            identifiers: ["a", "b", "c"],
            heights: [200, 300, 250]
        )
        collectionView.layoutIfNeeded()
        let firstOrigin = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!.frame.minY
        let lastOrigin = layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))!.frame.minY

        ScriptedHeightCell.heights[1] = 500
        layout.remeasureMountedItems(at: [IndexPath(item: 1, section: 0)])

        XCTAssertEqual(
            layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame.minY,
            firstOrigin
        )
        XCTAssertEqual(
            layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))!.frame.minY,
            lastOrigin + 200,
            accuracy: 0.5
        )
    }

    func testRemeasuringIgnoresARowTheLayoutNoLongerHas() {
        // A reconfigure and a snapshot can race: the index path the timeline collected may already
        // be past the end of the rebuilt column. That is a row to skip, not geometry to corrupt.
        let (collectionView, layout, _) = makeHost(identifiers: ["a", "b"], heights: [200, 300])
        collectionView.layoutIfNeeded()
        let contentBefore = layout.collectionViewContentSize.height

        layout.remeasureMountedItems(at: [IndexPath(item: 7, section: 0)])

        XCTAssertEqual(layout.collectionViewContentSize.height, contentBefore, accuracy: 0.5)
        XCTAssertEqual(
            layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame.height,
            300
        )
    }

    // MARK: - The streaming hand-off

    func testTheRowReplacingTheStreamingRowStartsFromItsMeasuredHeight() {
        let source = Source(identifiers: ["a", "streaming"])
        let (collectionView, layout, _) = makeHost(source: source, heights: [200, 2400])
        collectionView.layoutIfNeeded()
        XCTAssertEqual(
            layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame.height,
            2400
        )

        // Streaming ends: the answer becomes an ordinary row, which is a different identity.
        layout.adoptHeight(of: AnyHashable("streaming"), for: AnyHashable("final"))
        source.identifiers[1] = "final"
        rebuild(layout)

        XCTAssertEqual(
            layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame.height,
            2400,
            "The finished answer must not take its own height out of the content"
        )
    }

    /// The companion to the test above: without the hand-off the rebuild is what the reader fell
    /// through. It is recorded rather than described so the seam cannot quietly stop mattering.
    func testWithoutTheHandOffTheReplacementRowFallsBackToTheEstimate() {
        let source = Source(identifiers: ["a", "streaming"])
        let (collectionView, layout, _) = makeHost(source: source, heights: [200, 2400])
        collectionView.layoutIfNeeded()

        source.identifiers[1] = "final"
        rebuild(layout)

        XCTAssertEqual(
            layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame.height,
            Fixture.estimate
        )
    }

    func testAdoptingAHeightNeverOverwritesOneTheRowAlreadyHas() {
        let (collectionView, layout, _) = makeHost(
            identifiers: ["a", "streaming"],
            heights: [900, 2400]
        )
        collectionView.layoutIfNeeded()

        layout.adoptHeight(of: AnyHashable("streaming"), for: AnyHashable("a"))
        rebuild(layout)

        XCTAssertEqual(
            layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame.height,
            900
        )
    }

    // MARK: - Who moves when a row grows

    func testGrowingTheRowTheViewportIsInsideLeavesTheOffsetAlone() {
        let (collectionView, layout, _) = makeHost(
            identifiers: ["a", "b"],
            heights: [400, 3000]
        )
        collectionView.layoutIfNeeded()
        // Reading the middle of the long answer: its top is above the viewport, its text grows
        // below the visible lines.
        collectionView.contentOffset = CGPoint(x: 0, y: 1200)

        let adjustment = offsetAdjustment(in: layout, item: 1, newHeight: 3200)

        XCTAssertEqual(adjustment, 0, "Appended text below the fold must not scroll the reader")
    }

    func testGrowingARowEntirelyAboveTheViewportFollowsItWithTheOffset() {
        let (collectionView, layout, _) = makeHost(
            identifiers: ["a", "b"],
            heights: [400, 3000]
        )
        collectionView.layoutIfNeeded()
        collectionView.contentOffset = CGPoint(x: 0, y: 1200)

        let adjustment = offsetAdjustment(in: layout, item: 0, newHeight: 600)

        XCTAssertEqual(adjustment, 200, accuracy: 0.5)
    }

    // MARK: - The viewport never rests past the end

    func testABatchUpdateClampsAProposedOffsetPastTheEndOfTheContent() {
        let (collectionView, layout, _) = makeHost(identifiers: ["a"], heights: [1200])
        collectionView.layoutIfNeeded()
        let maximum = layout.collectionViewContentSize.height - Fixture.height

        let clamped = layout.targetContentOffset(
            forProposedContentOffset: CGPoint(x: 0, y: 9000)
        )

        XCTAssertEqual(clamped.y, maximum, accuracy: 0.5)
    }

    func testABatchUpdateLeavesAnOffsetInsideTheContentUntouched() {
        let (collectionView, layout, _) = makeHost(identifiers: ["a"], heights: [4000])
        collectionView.layoutIfNeeded()

        let clamped = layout.targetContentOffset(
            forProposedContentOffset: CGPoint(x: 0, y: 1500)
        )

        XCTAssertEqual(clamped.y, 1500, accuracy: 0.5)
    }

    // MARK: - Fixture

    /// Runs the rebuild the collection view would run, with no self-sizing pass after it, so a
    /// test can see the geometry a row starts from rather than the one a mounted cell reports.
    private func rebuild(_ layout: RemoteConversationLayout) {
        layout.invalidateLayout()
        layout.prepare()
    }

    private func offsetAdjustment(
        in layout: RemoteConversationLayout,
        item: Int,
        newHeight: CGFloat
    ) -> CGFloat {
        let indexPath = IndexPath(item: item, section: 0)
        let original = layout.layoutAttributesForItem(at: indexPath)!.copy()
            as! UICollectionViewLayoutAttributes
        let preferred = original.copy() as! UICollectionViewLayoutAttributes
        preferred.size.height = newHeight
        let context = layout.invalidationContext(
            forPreferredLayoutAttributes: preferred,
            withOriginalAttributes: original
        )
        return context.contentOffsetAdjustment.y
    }

    private func makeHost(
        identifiers: [String],
        heights: [CGFloat]
    ) -> (UICollectionView, RemoteConversationLayout, Source) {
        makeHost(source: Source(identifiers: identifiers), heights: heights)
    }

    private func makeHost(
        source: Source,
        heights: [CGFloat]
    ) -> (UICollectionView, RemoteConversationLayout, Source) {
        for (index, height) in heights.enumerated() {
            ScriptedHeightCell.heights[index] = height
        }
        let layout = RemoteConversationLayout(estimatedRowHeight: Fixture.estimate)
        layout.itemIdentifier = { [weak source] indexPath in
            source?.identifiers.indices.contains(indexPath.item) == true
                ? AnyHashable(source!.identifiers[indexPath.item])
                : nil
        }
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: Fixture.width, height: Fixture.height),
            collectionViewLayout: layout
        )
        collectionView.register(
            ScriptedHeightCell.self,
            forCellWithReuseIdentifier: ScriptedHeightCell.reuseIdentifier
        )
        collectionView.dataSource = source
        hosts.append(collectionView)
        sources.append(source)
        return (collectionView, layout, source)
    }
}

/// A row whose measured height is scripted, so a fixture can reproduce the one shape that made
/// the timeline fail: an answer several times taller than the screen, growing a chunk at a time.
@MainActor
private final class ScriptedHeightCell: UICollectionViewCell {
    static let reuseIdentifier = "ScriptedHeightCell"
    static var heights: [Int: CGFloat] = [:]

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let preferred = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
        preferred.size.height = Self.heights[layoutAttributes.indexPath.item]
            ?? layoutAttributes.size.height
        return preferred
    }
}

@MainActor
private final class Source: NSObject, UICollectionViewDataSource {
    var identifiers: [String]

    init(identifiers: [String]) {
        self.identifiers = identifiers
        super.init()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        identifiers.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        collectionView.dequeueReusableCell(
            withReuseIdentifier: ScriptedHeightCell.reuseIdentifier,
            for: indexPath
        )
    }
}
