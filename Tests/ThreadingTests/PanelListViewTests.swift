import XCTest
@testable import Threading

/// The shared panel-list vocabulary: the geometry both panes repeat is stated once, so it is
/// asserted once — content ink on the `Spacing.inset` column, rows spanning the width minus the
/// stated insets, headings without counts.
@MainActor
final class PanelListViewTests: XCTestCase {

    private enum Fixture {
        static let width: CGFloat = 300
        static let height: CGFloat = 400
        static let rowHeight: CGFloat = 22
    }

    /// A detached fixture with a frame constrains nothing, so the host states its size the way
    /// a pane does — anchors, not frames.
    private func makeHostedList() -> (host: NSView, list: PanelListView) {
        let list = PanelListView(rowSpacing: Design.Spacing.hairline)
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(list)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: Fixture.width),
            host.heightAnchor.constraint(equalToConstant: Fixture.height),
            list.topAnchor.constraint(equalTo: host.topAnchor),
            list.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        return (host, list)
    }

    func testARowSpansTheWidthMinusTheStatedInsets() throws {
        let (host, list) = makeHostedList()

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: Fixture.rowHeight).isActive = true
        list.addRow(row)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.frame.width, Fixture.width - 2 * Design.Spacing.inset)
        XCTAssertEqual(row.frame.origin.x, Design.Spacing.inset)
    }

    /// The heading's ink sits on the same column as the rows — the misaligned edges this
    /// component exists to end — and carries no count.
    func testAHeadingSitsOnTheContentColumnAndSaysOnlyItsName() throws {
        let (host, list) = makeHostedList()

        list.addSection("Processes")
        host.layoutSubtreeIfNeeded()

        let label = try XCTUnwrap(list.rows.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(label.stringValue, "Processes")

        // Constraints place a label by its *alignment rect* — the frame sits a couple of
        // points outside it — so the column is asserted where Auto Layout put it.
        XCTAssertEqual(
            label.alignmentRect(forFrame: label.frame).origin.x,
            Design.Spacing.inset
        )
    }

    /// The first heading opens the list flush; a later one takes a breath above it. The spacer
    /// is geometry rather than content, which is why the first section adds one arranged view
    /// and the second adds two.
    func testOnlyALaterSectionTakesASpacer() {
        let (_, list) = makeHostedList()

        list.addSection("Processes")
        XCTAssertEqual(list.rows.count, 1)

        list.addSection("Ports")
        XCTAssertEqual(list.rows.count, 3)
    }

    func testClearEmptiesTheList() {
        let (_, list) = makeHostedList()

        list.addSection("Processes")
        list.addNote("Nothing listening.")
        XCTAssertFalse(list.rows.isEmpty)

        list.clear()
        XCTAssertTrue(list.rows.isEmpty)
    }

    func testANoteWraps() throws {
        let (_, list) = makeHostedList()

        list.addNote("Nothing listening.")

        let label = try XCTUnwrap(list.rows.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(label.stringValue, "Nothing listening.")
        XCTAssertEqual(label.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(label.maximumNumberOfLines, 0)
    }
}
