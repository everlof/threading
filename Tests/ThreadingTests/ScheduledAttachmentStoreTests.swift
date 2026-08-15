import AppKit
import XCTest

@testable import Threading

/// The pictures a scheduled send carries, and the custody that makes carrying them possible.
///
/// Scheduling an image was refused outright to begin with, and the reason was sound as far as it
/// went: a pasted screenshot is written into the temporary directory, so a path recorded on
/// Friday can name nothing by Monday. Every case here is about the answer to that — a copy taken
/// at the moment of scheduling — and about the three ways the copy must not outlive its reason:
/// a refused record, a removed row, and a crash between the two writes.
///
/// Every case drives stores rooted in a scratch directory. The bundle is hosted in the app, so a
/// store that resolved Application Support would have each run deleting the developer's own
/// scheduled pictures.
@MainActor
final class ScheduledAttachmentStoreTests: XCTestCase {

    // MARK: - Fixture

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scheduled-images-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        super.tearDown()
    }

    private func makeStore() -> ScheduledAttachmentStore {
        ScheduledAttachmentStore(directory: directory)
    }

    private var root: URL {
        directory.appendingPathComponent(
            ScheduledAttachmentDefaults.directoryName,
            isDirectory: true
        )
    }

    /// A file where a pasted screenshot lands, under the name one is actually given — the prefix
    /// is what tells the attachments pane to show it as "Pasted image" rather than as a UUID.
    @discardableResult
    private func makeImage(named name: String, bytes: Int = 64) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(repeating: 0x7f, count: bytes).write(to: url)
        return url
    }

    private func message(
        id: ScheduledMessageID,
        attachments: [ScheduledAttachment],
        to sessionID: SessionID = SessionID()
    ) -> ScheduledMessage {
        ScheduledMessage(
            id: id,
            dueAt: Date(timeIntervalSince1970: 1_775_000_000),
            target: .session(sessionID),
            text: "Look at this",
            attachments: attachments
        )
    }

    // MARK: - Taking Custody

    func testTakingCustodyCopiesThePicturesAndKeepsTheirNames() throws {
        let store = makeStore()
        let id = ScheduledMessageID()
        let first = makeImage(named: "threading-attachment-\(UUID().uuidString).png")
        let second = makeImage(named: "Diagram.png")

        let taken = try XCTUnwrap(store.take([first.path, second.path], for: id))
        XCTAssertEqual(taken.map(\.name), [first.lastPathComponent, "Diagram.png"])
        XCTAssertEqual(taken.map(\.slot), [0, 1])

        let urls = store.urls(for: message(id: id, attachments: taken))
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls.map(\.lastPathComponent), taken.map(\.name))
        for url in urls {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }

        // The originals are untouched: the composer still holds them until it is cleared, and an
        // immediate send would still be reading them.
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    /// Two files can both be called `Screenshot.png`, and renaming one of them would break the
    /// two things downstream that read the name.
    func testTwoPicturesWithTheSameNameBothSurvive() throws {
        let store = makeStore()
        let id = ScheduledMessageID()
        let first = makeImage(named: "Screenshot.png", bytes: 16)
        let second = makeImage(named: "Screenshot.png", bytes: 32)

        let taken = try XCTUnwrap(store.take([first.path, second.path], for: id))
        let urls = store.urls(for: message(id: id, attachments: taken))

        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Screenshot.png", "Screenshot.png"])
        XCTAssertNotEqual(urls[0].path, urls[1].path)
        XCTAssertEqual(try Data(contentsOf: urls[0]).count, 16)
        XCTAssertEqual(try Data(contentsOf: urls[1]).count, 32)
    }

    func testNothingToTakeIsNotARefusal() {
        XCTAssertEqual(makeStore().take([], for: ScheduledMessageID()), [])
    }

    /// A send that quietly lost one of three pictures is worse than one that was refused: the
    /// composer still holds all three when this is asked, so a refusal it can state is the only
    /// answer that leaves the user able to act.
    func testAMissingFileRefusesTheWholeSetAndLeavesNothingBehind() {
        let store = makeStore()
        let id = ScheduledMessageID()
        let real = makeImage(named: "Real.png")

        XCTAssertNil(store.take([real.path, "/nope/gone.png"], for: id))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.directory(for: id).path),
            "the copy taken before the refusal was left on disk"
        )
    }

    func testTooManyPicturesAreRefused() {
        let store = makeStore()
        let paths = (0...ScheduledAttachmentDefaults.maximumPerMessage).map {
            makeImage(named: "Image\($0).png").path
        }
        XCTAssertNil(store.take(paths, for: ScheduledMessageID()))
    }

    /// A per-image cap is not an aggregate cap. Twelve merely large pictures is the case the
    /// per-image answer never sees.
    func testTooManyBytesTogetherAreRefusedAndLeaveNothingBehind() {
        let store = makeStore()
        let id = ScheduledMessageID()
        let size = ScheduledAttachmentDefaults.maximumTotalBytes / 2 + 1
        let paths = [
            makeImage(named: "Big1.png", bytes: size).path,
            makeImage(named: "Big2.png", bytes: size).path
        ]

        XCTAssertNil(store.take(paths, for: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: id).path))
    }

    // MARK: - Reading

    /// The name comes off disk, so it is a name someone could have hand-edited. It has to resolve
    /// inside this message's own slot or to nothing at all.
    func testAHandEditedNameCannotReachOutOfTheMessagesOwnDirectory() throws {
        let store = makeStore()
        let id = ScheduledMessageID()
        let taken = try XCTUnwrap(store.take([makeImage(named: "Real.png").path], for: id))

        let tampered = message(
            id: id,
            attachments: [ScheduledAttachment(slot: taken[0].slot, name: "../../../../etc/hosts")]
        )
        XCTAssertEqual(store.urls(for: tampered), [])
    }

    func testAPictureTheFilesystemLostIsSkippedRatherThanNamed() throws {
        let store = makeStore()
        let id = ScheduledMessageID()
        let taken = try XCTUnwrap(store.take(
            [makeImage(named: "One.png").path, makeImage(named: "Two.png").path],
            for: id
        ))

        let kept = message(id: id, attachments: taken)
        try FileManager.default.removeItem(at: store.urls(for: kept)[0])

        XCTAssertEqual(store.urls(for: kept).map(\.lastPathComponent), ["Two.png"])
    }

    // MARK: - Giving It Back

    /// Edit and Send now take a waiting record apart again. What comes back has to be exactly
    /// what a freshly pasted image is, because the composer it lands in will hold the path, send
    /// it, and take custody again if it is scheduled a second time.
    func testDetachingHandsThePicturesBackAndEmptiesTheDirectory() throws {
        let store = makeStore()
        let id = ScheduledMessageID()
        let taken = try XCTUnwrap(store.take([makeImage(named: "Handback.png").path], for: id))
        let waiting = message(id: id, attachments: taken)

        let handed = store.detach(waiting)

        XCTAssertEqual(handed.count, 1)
        XCTAssertEqual(URL(fileURLWithPath: handed[0]).lastPathComponent, "Handback.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: handed[0]))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.directory(for: id).path),
            "the record gave its pictures back and then kept them too"
        )
        XCTAssertFalse(
            handed[0].hasPrefix(root.path),
            "a composer was handed a path into a directory the next removal deletes"
        )
    }

    // MARK: - Lifecycle

    func testReleasingDropsEverythingOneMessageWasCarrying() throws {
        let store = makeStore()
        let id = ScheduledMessageID()
        _ = try XCTUnwrap(store.take([makeImage(named: "Gone.png").path], for: id))

        store.release(id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: id).path))
    }

    /// The record and its pictures are two writes, so a quit between them strands a directory
    /// nothing names.
    ///
    /// The sweep is performed by a *second* store over the same root, which is what a later
    /// launch is: the run that took custody is gone, so nothing is in flight any more.
    func testTheSweepDropsDirectoriesNoRecordNames() throws {
        let kept = ScheduledMessageID()
        let stranded = ScheduledMessageID()
        let firstRun = makeStore()
        _ = try XCTUnwrap(firstRun.take([makeImage(named: "Kept.png").path], for: kept))
        _ = try XCTUnwrap(firstRun.take([makeImage(named: "Stranded.png").path], for: stranded))

        let laterRun = makeStore()
        laterRun.retainOnly([kept])

        XCTAssertTrue(FileManager.default.fileExists(atPath: laterRun.directory(for: kept).path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: laterRun.directory(for: stranded).path)
        )
    }

    /// **The sweep must not fire into the gap between the two writes.**
    ///
    /// Custody is taken first and the record written second, so for a moment the bytes exist and
    /// nothing names them — exactly what `retainOnly` removes. `ScheduledMessageStore.shared` is
    /// constructed lazily, so the first schedule of a run can be what triggers its `load`, and
    /// the sweep then lands inside that gap: the record reached disk naming files deleted a
    /// microsecond earlier. The end-to-end composer test is what caught it; this is the unit
    /// that holds it.
    func testTheSweepSparesAPictureStillWaitingForItsRecord() throws {
        let store = makeStore()
        let id = ScheduledMessageID()
        let taken = try XCTUnwrap(store.take([makeImage(named: "Mid.png").path], for: id))

        store.retainOnly([])

        XCTAssertEqual(store.urls(for: message(id: id, attachments: taken)).count, 1)
    }

    // MARK: - Against The Record Store

    /// The words and the bytes are one record split across two places. Every way out of the
    /// message store has to take the pictures with it, which is why the release lives on the
    /// store's own mutations rather than on the surfaces that ask for them.
    func testRemovingAScheduledMessageDropsThePicturesItWasCarrying() throws {
        let store = ScheduledMessageStore(directory: directory, center: NotificationCenter())
        let id = ScheduledMessageID()
        let taken = try XCTUnwrap(store.attachments.take(
            [makeImage(named: "Attached.png").path],
            for: id
        ))
        let waiting = message(id: id, attachments: taken)
        XCTAssertNoThrow(try store.add(waiting, now: Date(timeIntervalSince1970: 1_774_000_000)).get())

        XCTAssertEqual(store[id]?.attachments, taken)
        XCTAssertEqual(store.attachments.urls(for: waiting).count, 1)

        store.remove(id)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.attachments.directory(for: id).path)
        )
    }

    func testAttachmentsSurviveTheFileTheStoreWrites() throws {
        let center = NotificationCenter()
        let first = ScheduledMessageStore(directory: directory, center: center)
        let id = ScheduledMessageID()
        let taken = try XCTUnwrap(first.attachments.take(
            [makeImage(named: "Persisted.png").path],
            for: id
        ))
        XCTAssertNoThrow(try first.add(
            message(id: id, attachments: taken),
            now: Date(timeIntervalSince1970: 1_774_000_000)
        ).get())

        let reopened = ScheduledMessageStore(directory: directory, center: center)
        let recovered = try XCTUnwrap(reopened[id])
        XCTAssertEqual(recovered.attachments, taken)
        XCTAssertEqual(
            reopened.attachments.urls(for: recovered).map(\.lastPathComponent),
            ["Persisted.png"]
        )
    }

    /// A picture and nothing else is a real message to schedule — the composer's own send accepts
    /// one, and the store used to call it empty and refuse it.
    func testAPictureWithNoWordsIsStillSomethingToSchedule() throws {
        let store = ScheduledMessageStore(directory: directory, center: NotificationCenter())
        let id = ScheduledMessageID()
        let taken = try XCTUnwrap(store.attachments.take(
            [makeImage(named: "Wordless.png").path],
            for: id
        ))
        let wordless = ScheduledMessage(
            id: id,
            dueAt: Date(timeIntervalSince1970: 1_775_000_000),
            target: .session(SessionID()),
            text: "",
            attachments: taken
        )

        XCTAssertFalse(wordless.isEmpty)
        XCTAssertEqual(wordless.summary, L10n.string("1 image"))
        XCTAssertNoThrow(
            try store.add(wordless, now: Date(timeIntervalSince1970: 1_774_000_000)).get()
        )
    }
}
