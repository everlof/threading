import AppKit
import XCTest
@testable import Threading

/// Two pictures in this list can be held against each other, by menu or by drag.
///
/// The rules these pin down are the ones that have to agree across three surfaces — the row's
/// **Compare with** submenu, a row dragged onto another row, and a picture dragged in from
/// outside — because a menu that offers a pair the drop refuses is the same defect stated twice.
@MainActor
final class SessionAttachmentComparisonTests: XCTestCase {

    private var root: URL!
    private var scopeBeforeTest = false
    private var pasteboards: [NSPasteboard] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-compare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scopeBeforeTest = AppSettings.shared.includesAttachmentsOutsideProject
    }

    override func tearDownWithError() throws {
        AppSettings.shared.includesAttachmentsOutsideProject = scopeBeforeTest
        pasteboards.forEach { $0.releaseGlobally() }
        pasteboards.removeAll()
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Which way round

    /// The clock decides the direction, not the gesture. Dragging A onto B and B onto A ask the
    /// same question, and a comparison whose arrow flips with the pointer's starting row would
    /// claim this morning's screenshot replaced this afternoon's.
    func testTheOlderPictureIsAlwaysTheOldSideWhicheverWayItIsAsked() throws {
        let older = attachment(named: "before.png", at: Date(timeIntervalSince1970: 1_000))
        let newer = attachment(named: "after.png", at: Date(timeIntervalSince1970: 2_000))

        let forward = AttachmentComparison.ordered(older, newer)
        XCTAssertEqual(forward.old.name, "before.png")
        XCTAssertEqual(forward.new.name, "after.png")

        let backward = AttachmentComparison.ordered(newer, older)
        XCTAssertEqual(
            backward.old.name, "before.png",
            "the pair read backwards depending on which row the drag started from"
        )
        XCTAssertEqual(backward.new.name, "after.png")
    }

    /// **The case the clock cannot settle, and it is the common one.** Both of the store's doors
    /// stamp one time for a whole batch, so two pictures from a single terminal scan — or from one
    /// `display_compare_files` — carry the same instant. Left to the clock alone the gesture
    /// decided after all, which is the flip this rule exists to prevent.
    func testPicturesRecordedInOneBatchStillOrderTheSameWayRoundBothWays() throws {
        let urls = try (0..<2).map { try writePNG(named: "batch-\($0).png") }
        let pane = try laidOutPane(showing: urls, asOneBatch: true)
        let listed = attachments(of: pane)
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(
            listed[0].referencedAt, listed[1].referencedAt,
            "the fixture no longer reproduces a batch's shared timestamp"
        )

        let forward = AttachmentComparison.ordered(listed[0], listed[1], in: listed)
        let backward = AttachmentComparison.ordered(listed[1], listed[0], in: listed)
        XCTAssertEqual(
            forward.old.id, backward.old.id,
            "a tied pair read backwards depending on which row the drag started from"
        )
        XCTAssertEqual(forward.new.id, backward.new.id)
        // Tied or not, the list's own order decides: a lower row is the newer picture.
        XCTAssertEqual(forward.old.id, listed[1].id)
    }

    /// The same tie through the gesture rather than through the rule, which is where it would
    /// actually be seen: two drags of one pair must open one comparison, not two mirrored ones.
    func testDraggingATiedPairEitherWayOpensTheSameComparison() throws {
        let urls = try (0..<2).map { try writePNG(named: "batch-\($0).png") }
        let pane = try laidOutPane(showing: urls, asOneBatch: true)
        let listed = attachments(of: pane)

        var pairs: [(old: String, new: String)] = []
        pane.onCompare = { old, new in pairs.append((old.id, new.id)) }

        XCTAssertTrue(drop(pasteboard(carrying: listed[0].url), onRow: 1, of: pane))
        XCTAssertTrue(drop(pasteboard(carrying: listed[1].url), onRow: 0, of: pane))

        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(
            pairs.first?.old, pairs.last?.old,
            "the same pair opened two comparisons pointing opposite ways"
        )
        XCTAssertEqual(pairs.first?.new, pairs.last?.new)
    }

    /// A PDF classifies as binary in `CompareViewController`, so every comparison offered for one
    /// would open a tab saying it cannot draw one. The offer is not made rather than made dead.
    func testAPDFIsNeverASideOfAComparison() throws {
        let picture = attachment(named: "shot.png", at: Date())
        let document = attachment(named: "report.pdf", kind: .pdf, at: Date())

        XCTAssertTrue(AttachmentComparison.canCompare(picture))
        XCTAssertFalse(AttachmentComparison.canCompare(document))
        XCTAssertTrue(
            AttachmentComparison.candidates(for: document, in: [picture, document]).isEmpty,
            "a PDF row was offered something to compare itself with"
        )
        XCTAssertEqual(
            AttachmentComparison.candidates(for: picture, in: [picture, document]).map(\.name),
            [],
            "a PDF was offered as the other side of an image comparison"
        )
    }

    func testAFileIsNeverOfferedAgainstItself() throws {
        let first = attachment(named: "one.png", at: Date())
        let second = attachment(named: "two.png", at: Date())

        XCTAssertEqual(
            AttachmentComparison.candidates(for: first, in: [first, second]).map(\.name),
            ["two.png"]
        )
    }

    // MARK: - The row's menu

    /// The footer menu's own actions, said for the row that was actually pointed at, plus the
    /// one thing no control under a single preview can offer: another row's name.
    func testTheRowMenuCarriesThePanesOwnActionsAndNamesTheOtherPictures() throws {
        let urls = try (0..<2).map { try writePNG(named: "picture-\($0).png") }
        let pane = try laidOutPane(showing: urls)
        let listed = try XCTUnwrap(attachments(of: pane).first)

        let entries = pane.contextMenuEntries(for: listed)
        let titles = entries.compactMap(\.item).map(\.title)
        XCTAssertTrue(titles.contains("Open"), "no Open: \(titles)")
        XCTAssertTrue(titles.contains("Reveal in Finder"), "no Finder: \(titles)")
        XCTAssertTrue(titles.contains("Copy Path"), "no Copy Path: \(titles)")
        XCTAssertTrue(titles.contains("Copy Image"), "an image row did not offer its picture")

        let compare = try XCTUnwrap(
            entries.compactMap(\.item).first { $0.title == "Compare with" },
            "the row menu offered no comparison: \(titles)"
        )
        XCTAssertEqual(
            (compare.submenu ?? []).compactMap(\.item).map(\.title),
            ["picture-0.png"],
            "the submenu named the wrong pictures — the clicked row is not one of them"
        )
    }

    /// A session holding one picture has nothing to hold it against, and a parent item opening an
    /// empty submenu is a dead row in a menu somebody opened for something else.
    func testALonePictureIsOfferedNoComparisonAtAll() throws {
        let pane = try laidOutPane(showing: [try writePNG(named: "only.png")])
        let listed = try XCTUnwrap(attachments(of: pane).first)

        let titles = pane.contextMenuEntries(for: listed).compactMap(\.item).map(\.title)
        XCTAssertFalse(
            titles.contains("Compare with"),
            "a session with one picture was offered a comparison: \(titles)"
        )
    }

    /// A PDF row keeps every action that means something for a file and loses only the picture:
    /// `Copy File` in place of `Copy Image`, and no comparison.
    func testAPDFRowKeepsTheFileActionsAndLosesThePictureOnes() throws {
        let pane = try laidOutPane(showing: [try writePNG(named: "shot.png"), try writePDF()])
        let document = try XCTUnwrap(
            attachments(of: pane).first { $0.kind == .pdf },
            "the fixture PDF was not listed"
        )

        let titles = pane.contextMenuEntries(for: document).compactMap(\.item).map(\.title)
        XCTAssertTrue(titles.contains("Open"))
        XCTAssertTrue(titles.contains("Copy File"), "a PDF row offered no way to copy it: \(titles)")
        XCTAssertFalse(titles.contains("Copy Image"), "a PDF row offered to copy a picture")
        XCTAssertFalse(titles.contains("Compare with"), "a PDF row offered a comparison")
    }

    // MARK: - Dropping one row on another

    func testDroppingOneRowOnAnotherComparesThePairOldestFirst() throws {
        let pane = try laidOutPane(showing: [
            try writePNG(named: "first.png"),
            try writePNG(named: "second.png")
        ])
        let listed = attachments(of: pane)
        XCTAssertEqual(listed.count, 2)

        var compared: (old: SessionAttachment, new: SessionAttachment)?
        pane.onCompare = { old, new in compared = (old, new) }

        // Newest first, so row 0 is the file recorded last. Dragging it onto row 1 asks about
        // the pair; the answer must still put the older one on the left.
        let dragged = try XCTUnwrap(listed.first)
        let target = try XCTUnwrap(listed.last)
        let dropped = drop(pasteboard(carrying: dragged.url), onRow: 1, of: pane)

        XCTAssertTrue(dropped, "the drop was refused")
        let pair = try XCTUnwrap(compared, "nothing was compared")
        XCTAssertEqual(pair.old.id, target.id)
        XCTAssertEqual(pair.new.id, dragged.id)
    }

    /// The one gesture that has to be refused, asked of the file rather than of the row index —
    /// the same picture dragged in from Finder is the same picture, whichever way it arrived.
    func testARowRefusesItsOwnFile() throws {
        let pane = try laidOutPane(showing: [
            try writePNG(named: "first.png"),
            try writePNG(named: "second.png")
        ])
        let listed = attachments(of: pane)
        let target = try XCTUnwrap(listed.first)

        XCTAssertFalse(
            pane.canDrop(pasteboard(carrying: target.url), on: target),
            "a picture was offered against itself"
        )
        XCTAssertTrue(
            pane.canDrop(pasteboard(carrying: try XCTUnwrap(listed.last).url), on: target),
            "a row refused the other row"
        )
    }

    /// A PDF row is not a drop target, for the same reason it is not a name in the submenu.
    func testAPDFRowTakesNoDrop() throws {
        let pane = try laidOutPane(showing: [try writePNG(named: "shot.png"), try writePDF()])
        let document = try XCTUnwrap(attachments(of: pane).first { $0.kind == .pdf })
        let picture = try XCTUnwrap(attachments(of: pane).first { $0.kind == .image })

        XCTAssertFalse(pane.canDrop(pasteboard(carrying: picture.url), on: document))
    }

    /// Anything that is not a picture this list would admit is refused before the row lights up:
    /// a drop the pane offered and then dropped on the floor is worse than one it never offered.
    func testAFileThatIsNotAPictureIsRefused() throws {
        let pane = try laidOutPane(showing: [try writePNG(named: "shot.png")])
        let target = try XCTUnwrap(attachments(of: pane).first)

        let notes = root.appendingPathComponent("notes.txt")
        try "not a picture".write(to: notes, atomically: true, encoding: .utf8)

        XCTAssertFalse(pane.canDrop(pasteboard(carrying: notes), on: target))
    }

    /// **Files win over pixels, and the offer has to be made in that order.** Dragging out of Mail
    /// or Notes puts a file *and* a bitmap preview of it on the pasteboard; the drop reads the file
    /// and never looks at the bitmap, so answering from the bitmap lit the row up for a `.txt`.
    func testAFileDraggedWithAPicturePreviewOfItIsStillRefused() throws {
        let pane = try laidOutPane(showing: [try writePNG(named: "shot.png")])
        let target = try XCTUnwrap(attachments(of: pane).first)

        let notes = root.appendingPathComponent("notes.txt")
        try "not a picture".write(to: notes, atomically: true, encoding: .utf8)

        let board = makePasteboard()
        board.clearContents()
        board.writeObjects([notes as NSURL])
        board.setData(try pngData(), forType: .png)

        XCTAssertFalse(
            pane.canDrop(board, on: target),
            "a text file riding beside a picture preview was offered as a comparison"
        )
        XCTAssertFalse(drop(board, onRow: 0, of: pane), "and the drop went through anyway")
    }

    /// A drag holding several pictures is asked about all of them, not only the first: leading with
    /// the row's own file must not throw away the perfectly good other side behind it.
    func testAMultiPictureDragLeadingWithTheRowsOwnFileStillCompares() throws {
        let pane = try laidOutPane(showing: [
            try writePNG(named: "first.png"),
            try writePNG(named: "second.png")
        ])
        let listed = attachments(of: pane)
        let target = try XCTUnwrap(listed.first)
        let other = try XCTUnwrap(listed.last)

        let board = makePasteboard()
        board.clearContents()
        board.writeObjects([target.url as NSURL, other.url as NSURL])

        var compared: (old: SessionAttachment, new: SessionAttachment)?
        pane.onCompare = { old, new in compared = (old, new) }

        XCTAssertTrue(pane.canDrop(board, on: target))
        XCTAssertTrue(drop(board, onRow: 0, of: pane), "the drop was refused")
        let pair = try XCTUnwrap(compared, "nothing was compared")
        XCTAssertEqual(Set([pair.old.id, pair.new.id]), Set([target.id, other.id]))
    }

    // MARK: - Dropping a picture in from outside

    /// A picture from anywhere else is **filed first**, and that is not incidental: a Compare tab
    /// is persisted by path, and a screenshot dragged out of Preview lives in a directory macOS
    /// will reap. Filing it also puts it in the list it was dropped on, marked as the user's.
    func testAPictureDroppedFromOutsideIsFiledAndThenCompared() throws {
        let pane = try laidOutPane(showing: [try writePNG(named: "made.png")])
        let target = try XCTUnwrap(attachments(of: pane).first)

        // Outside the project, which is where the interesting case lives — a file on the Desktop,
        // a screenshot in a temporary directory.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropped-\(UUID().uuidString).png")
        try pngData().write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        var compared: (old: SessionAttachment, new: SessionAttachment)?
        pane.onCompare = { old, new in compared = (old, new) }

        XCTAssertTrue(
            drop(pasteboard(carrying: outside), onRow: 0, of: pane),
            "a picture dragged in from outside was refused"
        )

        let pair = try XCTUnwrap(compared, "nothing was compared")
        XCTAssertEqual(pair.old.id, target.id, "the file already in the list is the older side")
        XCTAssertEqual(pair.new.sourcePath, outside.path)
        XCTAssertEqual(
            pair.new.origin, .user,
            "a picture the user dropped was filed as though the agent had surfaced it"
        )
        XCTAssertTrue(
            attachments(of: pane).contains { $0.id == pair.new.id },
            "the dropped picture was compared but never joined the list it was dropped on"
        )
        // Custody, not a reference into a directory that will be reaped: the row's own file has
        // to outlive the drag that named it.
        XCTAssertNotEqual(pair.new.url.path, outside.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pair.new.url.path))
    }

    /// Custody freezes bytes at the moment it takes them, so a picture regenerated at the same
    /// path since would otherwise be compared as it was that morning.
    func testDroppingAnOutsidePictureAgainRefreshesTheCopyItWasFiledAs() throws {
        let pane = try laidOutPane(showing: [
            try writePNG(named: "made.png"),
            try writePNG(named: "other.png")
        ])
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("regenerated-\(UUID().uuidString).png")
        try pngData(pixel: 8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        var compared: SessionAttachment?
        pane.onCompare = { _, new in compared = new }
        XCTAssertTrue(drop(pasteboard(carrying: outside), onRow: 0, of: pane))
        let filed = try XCTUnwrap(compared)
        XCTAssertNotEqual(filed.url.path, outside.path, "the file was referenced, not taken in")

        // The same path, different bytes — a chart the agent regenerated, a screenshot retaken.
        let regenerated = try pngData(pixel: 24)
        try regenerated.write(to: outside)

        compared = nil
        XCTAssertTrue(drop(pasteboard(carrying: outside), onRow: 1, of: pane))
        let again = try XCTUnwrap(compared, "the second drop compared nothing")
        XCTAssertEqual(again.sourcePath, outside.path)
        XCTAssertEqual(
            try Data(contentsOf: again.url), regenerated,
            "the comparison was drawn against the bytes custody took the first time"
        )
    }

    /// A picture with no file of its own — dragged straight out of another app — is written to the
    /// temporary directory so it can be filed. Once its bytes are in custody that original is
    /// nobody's, and the composer's reason for keeping one (a CLI is about to be handed the path)
    /// does not apply here.
    func testAPictureDraggedWithNoFileLeavesNoTemporaryOriginalBehind() throws {
        let pane = try laidOutPane(showing: [try writePNG(named: "made.png")])

        let board = makePasteboard()
        board.clearContents()
        board.setData(try pngData(), forType: .png)

        var compared: SessionAttachment?
        pane.onCompare = { _, new in compared = new }
        XCTAssertTrue(drop(board, onRow: 0, of: pane), "a pasted picture was refused")

        let filed = try XCTUnwrap(compared)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: filed.url.path),
            "the picture was compared but its bytes are not in custody"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: filed.sourcePath),
            "the minted temporary original was left behind at \(filed.sourcePath)"
        )
    }

    // MARK: - Where the drop lands

    /// AppKit proposes a row and an insertion; this list has no order to insert into, so a pointer
    /// between rows — or below the last one — is aimed at the nearest row rather than refused.
    func testAPointerBelowTheLastRowIsAimedAtIt() throws {
        let pane = try laidOutPane(showing: [
            try writePNG(named: "first.png"),
            try writePNG(named: "second.png")
        ])
        let listed = attachments(of: pane)
        let table = try table(of: pane)
        let info = DraggingInfoStub(pasteboard: pasteboard(carrying: listed[0].url))

        // Two rows, so `2` is the strip under the last one — the row index AppKit proposes for a
        // pointer past the end, with `.above` for the gap it is in.
        let operation = pane.tableView(
            table, validateDrop: info, proposedRow: 2, proposedDropOperation: .above
        )
        XCTAssertFalse(operation.isEmpty, "the empty stretch under the list refused the drag")
        XCTAssertEqual(table.numberOfRows, 2)

        var compared: (old: SessionAttachment, new: SessionAttachment)?
        pane.onCompare = { old, new in compared = (old, new) }
        XCTAssertTrue(pane.tableView(table, acceptDrop: info, row: 1, dropOperation: .on))
        let pair = try XCTUnwrap(compared)
        XCTAssertEqual(Set([pair.old.id, pair.new.id]), Set([listed[0].id, listed[1].id]))
    }

    /// **The list is live under the pointer.** A terminal scan's debounce is a main-queue timer and
    /// event tracking is a common run-loop mode, so an attachment can be recorded between the last
    /// `draggingUpdated` and the release — inserting at the top and sliding every row down one. The
    /// release then lands on a different file than the one that lit up, and taking the validation
    /// on trust would open exactly the dead-end PDF comparison the rule forbids.
    func testARowThatChangedUnderTheDragIsNotComparedOnTrust() throws {
        // Recorded picture-first so the list — newest first — puts the PDF directly *above* it:
        // one arrival then slides the PDF down onto the row the drag was aimed at.
        let pane = try laidOutPane(showing: [try writePNG(named: "shot.png"), try writePDF()])
        let table = try table(of: pane)
        XCTAssertEqual(attachments(of: pane).map(\.kind), [.pdf, .image], "fixture order changed")

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("dragged-\(UUID().uuidString).png")
        try pngData().write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        // Row 1 is the picture, and the drag is allowed to land on it.
        let info = DraggingInfoStub(pasteboard: pasteboard(carrying: outside))
        XCTAssertFalse(
            pane.tableView(
                table, validateDrop: info, proposedRow: 1, proposedDropOperation: .on
            ).isEmpty
        )

        // …and then the session surfaces another picture while the pointer is still down. Row 1
        // is the PDF now.
        let arrived = try writePNG(named: "arrived.png")
        XCTAssertNotNil(
            SessionAttachmentStore.shared.record(
                url: arrived, sessionID: pane.sessionID, projectRoot: root
            )
        )
        XCTAssertEqual(attachments(of: pane)[1].kind, .pdf, "the fixture did not shift the rows")

        var compared = false
        pane.onCompare = { _, _ in compared = true }
        XCTAssertFalse(
            pane.tableView(table, acceptDrop: info, row: 1, dropOperation: .on),
            "the drop was accepted against a row that had changed under it"
        )
        XCTAssertFalse(compared, "a PDF was opened as one side of an image comparison")
    }

    /// An empty list is not a target, and neither is a row index nothing stands at.
    func testAnEmptyListTakesNoDrop() throws {
        let pane = try laidOutPane(showing: [])
        let file = try writePNG(named: "loose.png")
        let table = try table(of: pane)

        XCTAssertEqual(
            pane.tableView(
                table,
                validateDrop: DraggingInfoStub(pasteboard: pasteboard(carrying: file)),
                proposedRow: 0,
                proposedDropOperation: .above
            ),
            [],
            "a list with no rows offered a comparison"
        )
    }

    // MARK: - What the row says while a drag is over it

    /// A highlight only answers *here*, which is the part nobody has to be told. The row says what
    /// dropping would do, and takes its four lines of detail back the moment the drag leaves.
    func testTheRowSaysWhatDroppingOnItWouldDo() throws {
        // In a folder, so the row's path and its name are different strings and "the caption took
        // the path's place" is a claim this test can actually make.
        let pane = try laidOutPane(showing: [
            try writePNG(named: "first.png"),
            try writePNG(named: "shots/second.png")
        ])
        let row = try XCTUnwrap(
            table(of: pane).view(atColumn: 0, row: 0, makeIfNecessary: true)
                as? SessionAttachmentRowView,
            "the list built no row"
        )
        // Newest first, so the top row is the file recorded last.
        let listed = try XCTUnwrap(attachments(of: pane).first)

        XCTAssertFalse(visibleLabels(in: row).contains("Drop to compare"))
        let atRest = visibleLabels(in: row)
        XCTAssertTrue(
            atRest.contains(listed.name), "the row is not describing its file: \(atRest)"
        )

        row.isDropTarget = true
        let underDrag = visibleLabels(in: row)
        XCTAssertTrue(underDrag.contains("Drop to compare"), "the row said nothing: \(underDrag)")
        // **The row stays the row.** Which picture is under the pointer is the whole question the
        // affordance answers, so the name it is asking about may not leave with the path.
        XCTAssertTrue(
            underDrag.contains(listed.name),
            "the row stopped naming the picture the drop would compare: \(underDrag)"
        )
        XCTAssertFalse(
            underDrag.contains(listed.relativePath),
            "the caption did not take the place of the one line nobody reads mid-drag: \(underDrag)"
        )

        row.isDropTarget = false
        XCTAssertEqual(
            visibleLabels(in: row), atRest,
            "the row did not take its own detail back when the drag left"
        )
    }

    /// The same caption, raised by the drag itself rather than by the test — the wiring between
    /// `validateDrop`, the held row index and the row views, which setting `isDropTarget` by hand
    /// steps straight over.
    func testTheDragItselfRaisesTheCaptionAndOnlyOnTheRowUnderIt() throws {
        let pane = try laidOutPane(showing: [
            try writePNG(named: "first.png"),
            try writePNG(named: "second.png")
        ])
        let table = try table(of: pane)
        let listed = attachments(of: pane)
        let info = DraggingInfoStub(pasteboard: pasteboard(carrying: listed[0].url))

        XCTAssertFalse(
            pane.tableView(
                table, validateDrop: info, proposedRow: 1, proposedDropOperation: .on
            ).isEmpty
        )
        XCTAssertEqual(markedRows(of: pane), [1], "the drag lit the wrong rows")

        // Over the row the drag came from: refused, and nothing may stay lit behind it.
        XCTAssertTrue(
            pane.tableView(
                table, validateDrop: info, proposedRow: 0, proposedDropOperation: .on
            ).isEmpty
        )
        XCTAssertEqual(markedRows(of: pane), [], "a refused row kept the previous mark")

        // And the drag leaving the list at all, which no delegate method is told about.
        XCTAssertFalse(
            pane.tableView(
                table, validateDrop: info, proposedRow: 1, proposedDropOperation: .on
            ).isEmpty
        )
        XCTAssertEqual(markedRows(of: pane), [1])
        table.onDraggingExited?()
        XCTAssertEqual(markedRows(of: pane), [], "the mark was left lit after the drag left")
    }

    /// Which rows are currently saying they would take the drop, read off the views themselves —
    /// both of them, because the wash and the sentence are drawn by different views and a row
    /// carrying one without the other is the defect, not a detail.
    private func markedRows(of pane: SessionAttachmentsViewController) -> [Int] {
        guard let table = try? table(of: pane) else { return [] }
        return (0..<table.numberOfRows).filter { row in
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? SessionAttachmentRowView
            let rowView = table.rowView(atRow: row, makeIfNecessary: true) as? ThemedTableRowView
            XCTAssertEqual(
                cell?.isDropTarget, rowView?.isDropTarget,
                "row \(row) drew the wash and the sentence out of step"
            )
            return cell?.isDropTarget == true
        }
    }

    // MARK: - What it looks like

    /// **The wash and the selection are the same shape, and this is measured on drawn pixels.**
    ///
    /// Reported as the affordance looking odd — "not full width but still full height" — and it
    /// was both, in turn: drawn from the cell it stood as tall as the selection above it and
    /// visibly narrower, and drawn from the row at our own hairline inset it ran the full width of
    /// a list whose System selection does not. Neither is expressible as a constant anyone can
    /// review, because the number that has to be matched is AppKit's and is not published: an
    /// inset-style table pads its selection plate 10 points in from the row. So the assertion is
    /// the comparison itself, taken off the two plates as they are actually painted.
    func testTheDropWashTakesTheSelectionsOwnShape() throws {
        let pane = try laidOutPane(showing: [
            try writePNG(named: "first.png", color: .systemTeal),
            try writePNG(named: "second.png", color: .systemOrange)
        ])
        let table = try table(of: pane)
        let listed = attachments(of: pane)

        // Row 0 selected by the pane already; row 1 lit by a drag held over it.
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        _ = pane.tableView(
            table,
            validateDrop: DraggingInfoStub(pasteboard: pasteboard(carrying: listed[0].url)),
            proposedRow: 1,
            proposedDropOperation: .on
        )

        let selection = try paintedSpan(ofRow: 0, in: table)
        let wash = try paintedSpan(ofRow: 1, in: table)
        XCTAssertEqual(
            wash.start, selection.start, accuracy: 0.5,
            "the drop wash starts \(wash.start) where the selection starts \(selection.start)"
        )
        XCTAssertEqual(
            wash.end, selection.end, accuracy: 0.5,
            "the drop wash ends \(wash.end) where the selection ends \(selection.end)"
        )
        XCTAssertLessThan(
            selection.start, table.bounds.width / 4,
            "the fixture stopped drawing a selection at all"
        )
    }

    /// **The words in a row can be read, selected or not — measured on drawn pixels.**
    ///
    /// This is the assertion the screenshot became. A row's timestamp and origin mark are set in
    /// `Design.Text.quaternary`, and in dark System that tier was white at 10%: the chronology
    /// this pane exists to show drew at **1.34:1** over the panel, and at **1.20:1** once the row
    /// was selected — so clicking a row made its own metadata harder to read, not easier.
    ///
    /// Read off the raster rather than off the colours, because the two halves failed for
    /// different reasons and only pixels catch both at once: the tier itself was never measured
    /// against a ground (`LabelLegibility`), and the cell was never told the row had painted an
    /// accent under it (`ThemedTableRowView.contentInk`). Asserting on `textColor` would have
    /// passed on the second one right up until the row was drawn.
    func testARowsQuietestWordsReadOnTheirOwnRowSelectedOrNot() throws {
        let pane = try laidOutPane(showing: [
            try writePNG(named: "timeline.png", color: .systemTeal),
            try writePNG(named: "contact.png", color: .systemOrange)
        ])
        let table = try table(of: pane)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            // Row 0 is selected and row 1 is not, so one render answers both halves.
            var measured: [CGFloat] = []
            NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
                pane.view.appearance = NSAppearance(named: appearanceName)
                pane.view.wantsLayer = true
                pane.view.layer?.backgroundColor = Design.Surface.background.cgColor
                AppThemeRefresh.repaint(pane.view)
                pane.view.layoutSubtreeIfNeeded()
                measured = (0...1).compactMap {
                    try? timestampContrast(ofRow: $0, in: table, drawnBy: pane.view)
                }
            }

            XCTAssertEqual(measured.count, 2, "\(name): the list drew no rows to measure")
            for (row, ratio) in measured.enumerated() {
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    LabelLegibility.Defaults.glanceRatio - 0.15,
                    "\(name): the \(row == 0 ? "selected" : "unselected") row's timestamp "
                        + "drew at \(String(format: "%.2f", ratio)):1"
                )
            }
        }
    }

    /// The contrast between a row's **timestamp** and the ground it was drawn on, taken off the
    /// raster.
    ///
    /// The label is *located* rather than guessed at: its frame is converted into the pane's
    /// coordinates and the scan runs inside it, with the ground read from a column just outside
    /// its leading edge at the same height. A first version of this swept a band and a quarter of
    /// the width instead, and reported 1.43:1 on a row whose timestamp is plainly legible in the
    /// rendered PNG beside it — it had found the row's own bottom edge. A measurement that can
    /// miss its subject is not evidence.
    ///
    /// The value returned is the *strongest* pixel in the label, because a glyph's stem is
    /// antialiased down toward the ground at its edges and only its core carries the colour that
    /// was actually asked for.
    private func timestampContrast(
        ofRow row: Int,
        in table: NSTableView,
        drawnBy host: NSView
    ) throws -> CGFloat {
        let cell = try XCTUnwrap(
            table.view(atColumn: 0, row: row, makeIfNecessary: true) as? SessionAttachmentRowView,
            "the list built no row \(row)"
        )
        let clock = try XCTUnwrap(
            descendants(of: cell)
                .compactMap { $0 as? NSTextField }
                .filter { !$0.isHidden && $0.stringValue.contains(":") }
                .max { $0.frame.minX < $1.frame.minX },
            "row \(row) is not showing a time at all"
        )
        let frame = cell.convert(clock.bounds, from: clock)

        // Drawn through the **pane**, not the bare list. `ThemedTableView` is transparent by
        // design — every table in this app sits on a surface the theme already painted — so a
        // raster taken from the table has nothing behind an unselected row, and the ground read
        // beside a word came back fully clear. `ThemeContrast.ratio` ignores alpha, so clear
        // measures as black, and the assertion then compared dark text against imaginary black
        // paper. The pane has the opaque surface under it, which is what a person is looking at.
        host.layoutSubtreeIfNeeded()
        host.display()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        // The rep is backing-scaled, so a point coordinate has to be taken through the same scale
        // the raster was made at rather than used as a pixel index.
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let inHost = host.convert(frame, from: cell)
        // `NSBitmapImageRep` indexes from the top-left. A view controller's view is not flipped,
        // so its own coordinates run the other way, and reading them as pixel indices samples the
        // mirror image of the row — empty pane, which measures as a flat 1.00:1 and reads as a
        // catastrophic failure rather than as a fixture pointed at the wrong place.
        func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
            let down = host.isFlipped ? y : host.bounds.height - y
            return rep.colorAt(x: Int(x * scale), y: Int(down * scale))?.usingColorSpace(.sRGB)
        }

        let ground = try XCTUnwrap(
            pixel(inHost.minX - Design.Spacing.small, inHost.midY),
            "nothing was drawn beside row \(row)'s time"
        )
        XCTAssertGreaterThan(
            ground.alphaComponent, 0.99,
            "row \(row)'s time was measured against a transparent ground"
        )

        var strongest: CGFloat = 1
        for y in stride(from: inHost.minY, to: inHost.maxY, by: 1 / scale) {
            for x in stride(from: inHost.minX, to: inHost.maxX, by: 1 / scale) {
                guard let ink = pixel(x, y) else { continue }
                strongest = max(strongest, ThemeContrast.ratio(ink, ground))
            }
        }
        return strongest
    }

    /// The horizontal run a row actually paints, in the table's own points.
    ///
    /// Read off a cached bitmap rather than from a frame, because what is being checked is what
    /// AppKit *drew* — the whole point of the mismatch this pins down is that one of the two
    /// plates was never ours to compute.
    private func paintedSpan(
        ofRow row: Int,
        in table: NSTableView
    ) throws -> (start: CGFloat, end: CGFloat) {
        table.display()
        let rep = try XCTUnwrap(table.bitmapImageRepForCachingDisplay(in: table.bounds))
        table.cacheDisplay(in: table.bounds, to: rep)

        let scale = table.bounds.width / CGFloat(rep.pixelsWide)
        // The row's middle, where a plate is at its full width. Nearer the top edge the two
        // plates' corners are still curving in at different radii, which reads as a one-point
        // disagreement that is not one. The row's own content cannot be mistaken for the plate
        // from either side: the thumbnail starts well inside the left edge and the origin mark
        // stops well inside the right.
        let rect = table.rect(ofRow: row)
        let y = Int(rect.midY / scale)
        var first = -1
        var last = -1
        for x in 0..<rep.pixelsWide {
            guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                  colour.alphaComponent > 0.02 else { continue }
            if first < 0 { first = x }
            last = x
        }
        guard first >= 0 else {
            XCTFail("row \(row) painted nothing at all")
            return (0, 0)
        }
        return (CGFloat(first) * scale, CGFloat(last + 1) * scale)
    }

    /// The list with a drag held over one of its rows, drawn through the real views in both
    /// appearances.
    ///
    /// Rendered rather than asserted because the question this state raises is not "is the caption
    /// there" — that is the test above — but whether a row that has swapped its content for one
    /// line still reads as *that row* rather than as a hole the list opened up. Only a picture
    /// answers that, which is this repository's rule for reviewing appearance.
    func testRendersTheDropAffordance() throws {
        // Real colours, because the row's thumbnail is half of what this picture is checking:
        // whether the row under the drag is still recognisably itself.
        let pane = try laidOutPane(showing: [
            try writePNG(named: "chart-before.png", color: .systemTeal),
            try writePNG(named: "chart-after.png", color: .systemOrange),
            try writePNG(named: "screenshot.png", color: .systemPurple)
        ])
        let table = try table(of: pane)
        let listed = attachments(of: pane)
        let info = DraggingInfoStub(pasteboard: pasteboard(carrying: listed[0].url))

        let directory = renderDirectory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            var data: Data?
            let render = {
                let view = pane.view
                view.appearance = NSAppearance(named: appearanceName)
                // The pane draws no ground of its own — it sits on the panel's. Without one the
                // dark render is the theme's near-white ink on white paper, which reads as a
                // contrast failure that only the harness had.
                view.wantsLayer = true
                view.layer?.backgroundColor = Design.Surface.background.cgColor
                AppThemeRefresh.repaint(view)
                view.layoutSubtreeIfNeeded()
                _ = pane.tableView(
                    table, validateDrop: info, proposedRow: 1, proposedDropOperation: .on
                )
                view.layoutSubtreeIfNeeded()

                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }
            NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance(render)

            let image = try XCTUnwrap(data, "the pane rendered nothing in \(name)")
            try image.write(
                to: directory.appendingPathComponent("attachments-drop-target-\(name).png")
            )
        }
        print("Rendered the drop affordance to \(directory.path)")
    }

    /// **The chronology at rest, selected row and all — the picture this pane is reviewed by.**
    ///
    /// The pane's whole reason for existing is that the files are in time order, and the two
    /// things that say so are the trailing time and the origin mark under it. Both are set in the
    /// quietest label tier, and in dark System that tier was white at 10%: the words were drawn,
    /// occupied their space, passed every assertion about their content, and could not be read —
    /// 1.34:1 on the panel and 1.20:1 on the selected row.
    ///
    /// No assertion anyone would have written catches that, which is why it is rendered. The
    /// selected row is in the picture deliberately: it was the worse of the two, and it is the one
    /// state a screenshot of a working pane will almost always be in.
    func testRendersTheChronology() throws {
        let pane = try laidOutPane(showing: [
            try writePNG(named: "timeline.png", color: .systemTeal),
            try writePNG(named: "shots/contact.png", color: .systemOrange),
            try writePNG(named: "screenshot.png", color: .systemPurple)
        ], origins: [.agent, .user, .agent], width: 548)
        let table = try table(of: pane)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let directory = renderDirectory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            var data: Data?
            NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
                let view = pane.view
                view.appearance = NSAppearance(named: appearanceName)
                // The pane draws no ground of its own — it sits on the panel's.
                view.wantsLayer = true
                view.layer?.backgroundColor = Design.Surface.background.cgColor
                AppThemeRefresh.repaint(view)
                view.layoutSubtreeIfNeeded()

                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }

            let image = try XCTUnwrap(data, "the pane rendered nothing in \(name)")
            try image.write(
                to: directory.appendingPathComponent("attachments-chronology-\(name).png")
            )
        }
        print("Rendered the attachments chronology to \(directory.path)")
    }

    /// The count and origin filter are one sentence. Centring their frames does not align their
    /// text because caption and control fonts have different line metrics; they share a baseline.
    func testTheAttachmentCountSharesTheFiltersTextBaseline() throws {
        let pane = try laidOutPane(
            showing: [
                try writePNG(named: "agent.png"),
                try writePNG(named: "user.png")
            ],
            origins: [.agent, .user]
        )
        let filter = try XCTUnwrap(
            descendants(of: pane.view).compactMap { $0 as? ThemedSegmentedControl }.first
        )
        let count = try XCTUnwrap(
            descendants(of: pane.view)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue.hasPrefix("ATTACHMENTS") }
        )

        XCTAssertFalse(filter.isHidden, "the mixed-origin fixture did not show the filter")
        XCTAssertEqual(
            count.frame.maxY - count.firstBaselineOffsetFromTop,
            filter.frame.maxY - filter.firstBaselineOffsetFromTop,
            accuracy: 0.5,
            "count=\(count.frame) filter=\(filter.frame) rowFlipped=\(count.superview?.isFlipped == true)"
        )
    }

    /// A one-origin session offers no filter. Removing it also removes its taller control line;
    /// the caption becomes the header's whole height instead of leaving an empty control band.
    func testTheCountOwnsTheHeaderHeightWhenTheFilterIsHidden() throws {
        let pane = try laidOutPane(showing: [try writePNG(named: "agent.png")])
        let filter = try XCTUnwrap(
            descendants(of: pane.view).compactMap { $0 as? ThemedSegmentedControl }.first
        )
        let count = try XCTUnwrap(
            descendants(of: pane.view)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue.hasPrefix("ATTACHMENTS") }
        )
        let row = try XCTUnwrap(count.superview)

        XCTAssertTrue(filter.isHidden)
        XCTAssertEqual(row.bounds.height, count.intrinsicContentSize.height, accuracy: 0.5)
        XCTAssertEqual(count.frame.height, row.bounds.height, accuracy: 0.5)
    }

    /// At the width of the supplied product pane all three filter choices fit in full. The run
    /// may truncate in a deliberately narrow pane, but a retained compressed first pass must not
    /// survive after the header grows to its shipping width.
    func testTheFilterTitlesFitAtProductPaneWidth() throws {
        let pane = try laidOutPane(
            showing: [try writePNG(named: "agent.png"), try writePNG(named: "user.png")],
            origins: [.agent, .user],
            width: 548
        )
        let filter = try XCTUnwrap(
            descendants(of: pane.view).compactMap { $0 as? ThemedSegmentedControl }.first
        )
        let titles = descendants(of: filter)
            .compactMap { $0 as? NSTextField }
            .filter { ["All", "Agent", "You"].contains($0.stringValue) }

        XCTAssertEqual(titles.count, 3)
        for title in titles {
            let visibleWidth = title.frame.intersection(title.superview?.bounds ?? .zero).width
            XCTAssertGreaterThanOrEqual(
                visibleWidth,
                title.intrinsicContentSize.width,
                "\(title.stringValue) visible=\(visibleWidth) frame=\(title.frame) "
                    + "intrinsic=\(title.intrinsicContentSize) "
                    + "segment=\(title.superview?.superview?.frame ?? .zero) filter=\(filter.frame)"
            )
        }
    }

    private var renderDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
    }

    // MARK: - Fixtures

    /// `asOneBatch` records every file in a single call, which is how the store stamps them all
    /// with one `referencedAt` — the tie the ordering rule has to survive.
    private func laidOutPane(
        showing urls: [URL],
        asOneBatch: Bool = false,
        origins: [SessionAttachment.Origin]? = nil,
        width: CGFloat = 360
    ) throws -> SessionAttachmentsViewController {
        let sessionID = SessionID()
        if let origins {
            XCTAssertFalse(asOneBatch, "a fixture cannot be one scanned batch and declared")
            XCTAssertEqual(origins.count, urls.count, "every fixture attachment needs an origin")
            for (url, origin) in zip(urls, origins) {
                XCTAssertNotNil(
                    SessionAttachmentStore.shared.record(
                        declared: url,
                        sessionID: sessionID,
                        projectRoot: root,
                        origin: origin
                    ),
                    "a fixture attachment was refused: \(url.lastPathComponent)"
                )
            }
        } else if asOneBatch {
            XCTAssertEqual(
                SessionAttachmentStore.shared.record(
                    urls: urls, sessionID: sessionID, projectRoot: root
                ).count,
                urls.count,
                "a fixture attachment was refused"
            )
        } else {
            for url in urls {
                XCTAssertNotNil(
                    SessionAttachmentStore.shared.record(
                        url: url, sessionID: sessionID, projectRoot: root
                    ),
                    "a fixture attachment was refused: \(url.lastPathComponent)"
                )
            }
        }

        let controller = SessionAttachmentsViewController(sessionID: sessionID)
        // The fixture's own folder stands in for the session's project: registering a real one
        // would write a row into the developer's own sidebar, since this bundle is hosted in the
        // app and `ProjectStore` has no scratch mode.
        controller.projectRootProvider = { [root] in root }
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        controller.view.autoresizingMask = []
        controller.view.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func attachments(of pane: SessionAttachmentsViewController) -> [SessionAttachment] {
        SessionAttachmentStore.shared.attachments(for: pane.sessionID)
    }

    private func table(of pane: SessionAttachmentsViewController) throws -> ThemedTableView {
        try XCTUnwrap(
            descendants(of: pane.view).compactMap { $0 as? ThemedTableView }.first,
            "the pane grew no list"
        )
    }

    /// The drop as the table would perform it — validated first, exactly as AppKit does, so a
    /// test cannot accept something the pointer would never have been allowed to release over.
    private func drop(
        _ pasteboard: NSPasteboard,
        onRow row: Int,
        of pane: SessionAttachmentsViewController
    ) -> Bool {
        guard let table = try? self.table(of: pane) else {
            XCTFail("the pane grew no list to drop on")
            return false
        }
        let info = DraggingInfoStub(pasteboard: pasteboard)
        let operation = pane.tableView(
            table, validateDrop: info, proposedRow: row, proposedDropOperation: .on
        )
        guard !operation.isEmpty else { return false }
        return pane.tableView(table, acceptDrop: info, row: row, dropOperation: .on)
    }

    private func pasteboard(carrying url: URL) -> NSPasteboard {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        return pasteboard
    }

    /// A named pasteboard of its own per drag, released in `tearDown`: a uniquely named one that
    /// is merely dropped stays in the pasteboard server for the rest of the login session.
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(rawValue: "compare-\(UUID())"))
        pasteboards.append(pasteboard)
        return pasteboard
    }

    private func visibleLabels(in view: NSView) -> [String] {
        ([view] + descendants(of: view))
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden }
            .map(\.stringValue)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// A recorded-looking value for the rules that are about the record rather than about a file.
    private func attachment(
        named name: String,
        kind: SessionAttachment.Kind = .image,
        at date: Date
    ) -> SessionAttachment {
        SessionAttachment(
            sessionID: SessionID(),
            root: root,
            url: root.appendingPathComponent(name),
            relativePath: name,
            sourcePath: root.appendingPathComponent(name).path,
            kind: kind,
            origin: .agent,
            referencedAt: date
        )
    }

    /// `name` may carry a folder, for the tests that need a row whose path is not its name.
    @discardableResult
    private func writePNG(named name: String, color: NSColor? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try pngData(color: color).write(to: url)
        return url
    }

    /// `pixel` only varies the bytes, for the tests that need one picture to have become another;
    /// `color` fills it, for the rendered story, where an empty well would be checking nothing.
    /// Drawn through a graphics context rather than `setColor(atX:y:)`, which leaves the bitmap
    /// transparent and logs a colorspace complaint per pixel while doing it.
    private func pngData(pixel: Int = 12, color: NSColor? = nil) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixel,
            pixelsHigh: pixel,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        if let color {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            color.setFill()
            NSRect(x: 0, y: 0, width: pixel, height: pixel).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func writePDF() throws -> URL {
        let url = root.appendingPathComponent("report.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 40, height: 40)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        return url
    }
}

@MainActor
final class AttachmentMomentTests: XCTestCase {

    /// A timestamp keeps the detail that still helps at its age: recent days retain their time,
    /// then the weekday and finally the day fall away instead of every non-today row collapsing
    /// straight to one date-only format.
    func testResolutionFallsAwayAsAnAttachmentAges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let locale = Locale(identifier: "en_US_POSIX")
        let reference = try date(
            year: 2026,
            month: 8,
            day: 17,
            hour: 15,
            minute: 45,
            calendar: calendar
        )

        XCTAssertEqual(
            AttachmentMoment.description(
                of: try date(
                    year: 2026,
                    month: 8,
                    day: 17,
                    hour: 9,
                    minute: 5,
                    calendar: calendar
                ),
                relativeTo: reference,
                calendar: calendar,
                locale: locale
            ),
            "9:05\u{202F}AM"
        )
        XCTAssertEqual(
            AttachmentMoment.description(
                of: try date(
                    year: 2026,
                    month: 8,
                    day: 14,
                    hour: 9,
                    minute: 5,
                    calendar: calendar
                ),
                relativeTo: reference,
                calendar: calendar,
                locale: locale
            ),
            "Fri 9:05\u{202F}AM"
        )
        XCTAssertEqual(
            AttachmentMoment.description(
                of: try date(
                    year: 2026,
                    month: 7,
                    day: 18,
                    hour: 9,
                    minute: 5,
                    calendar: calendar
                ),
                relativeTo: reference,
                calendar: calendar,
                locale: locale
            ),
            "Jul 18"
        )
        XCTAssertEqual(
            AttachmentMoment.description(
                of: try date(
                    year: 2025,
                    month: 2,
                    day: 17,
                    hour: 9,
                    minute: 5,
                    calendar: calendar
                ),
                relativeTo: reference,
                calendar: calendar,
                locale: locale
            ),
            "Feb 2025"
        )
    }

    /// Calendar days, rather than elapsed 24-hour blocks, decide whether a row is "today".
    /// A file from just before midnight is yesterday once the local date rolls over.
    func testTheRecentTierUsesCalendarDayBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Stockholm"))
        let locale = Locale(identifier: "sv_SE")
        let reference = try date(
            year: 2026,
            month: 3,
            day: 29,
            hour: 0,
            minute: 5,
            calendar: calendar
        )
        let yesterday = try date(
            year: 2026,
            month: 3,
            day: 28,
            hour: 23,
            minute: 55,
            calendar: calendar
        )

        let value = AttachmentMoment.description(
            of: yesterday,
            relativeTo: reference,
            calendar: calendar,
            locale: locale
        )
        XCTAssertTrue(value.contains("lör"), "the weekday was missing from yesterday: \(value)")
        XCTAssertTrue(value.contains("23:55"), "yesterday lost its useful time: \(value)")
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    calendar: calendar,
                    timeZone: calendar.timeZone,
                    year: year,
                    month: month,
                    day: day,
                    hour: hour,
                    minute: minute
                )
            )
        )
    }
}

// MARK: - Dragging Info

/// The little AppKit hands a drop destination, with nothing in it but the pasteboard.
///
/// Written out rather than mocked away because the two methods under test are the ones AppKit
/// itself calls, and a test that reached past them to the helpers underneath would not notice the
/// day the retargeting or the operation mask stopped being asked for.
private final class DraggingInfoStub: NSObject, NSDraggingInfo {

    let draggingPasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.draggingPasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic] }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var draggingFormation: NSDraggingFormation = .default
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}

    // `override` because AppKit declares this one on `NSObject` itself, not only on the protocol.
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
        nil
    }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
