import XCTest
@testable import Threading

/// Asking once, however many agents propose the same directories.
///
/// The bug these are written against is the one the user reported: the disk is one disk, so every
/// session hits ENOSPC in the same minute, reads the same listing, and proposes the same 20 GB —
/// and the app put each of those to the user as its own sheet, then refused the later ones with
/// "none of these paths are in the current listing" because the first sheet had already deleted
/// them.
@MainActor
final class StorageCleanupLedgerTests: XCTestCase {

    private var ledger: StorageCleanupLedger!

    /// Every batch this test's presenter was handed, in order.
    private var presented: [[String]] = []

    override func setUp() {
        super.setUp()
        ledger = StorageCleanupLedger()
        presented = []
    }

    // MARK: - One sheet

    /// Two sessions proposing the same directories are one question.
    func testASecondProposalNamingTheSamePathsOpensNoSecondSheet() {
        let artifact = self.artifact("/repo/app/.build", bytes: 2_000)
        var answers: [StorageCleanupLedger.Answer] = []
        var respond: Reply?

        // The first proposal's sheet stays on screen: this is the burst, not two answers apart.
        submit([artifact], present: { _, reply in respond = reply }) { answers.append($0) }
        submit([artifact], present: { _, reply in respond = reply }) { answers.append($0) }

        XCTAssertEqual(presented.count, 1, "the second proposal opened a sheet of its own")
        XCTAssertTrue(answers.isEmpty, "a proposal answered before the user did")

        respond?(.approved([.init(path: artifact.url.path, byteCount: artifact.byteCount)]))

        XCTAssertEqual(answers.count, 2, "the proposal waiting on that sheet was never answered")
        XCTAssertEqual(answers.map(\.removed.count), [1, 1])
        XCTAssertEqual(presented.count, 1)
    }

    /// Overlapping but not identical proposals ask only about what is genuinely new.
    func testOnlyTheUnaskedPathsReachTheSecondSheet() {
        let first = artifact("/repo/app/.build", bytes: 2_000)
        let second = artifact("/repo/app/web/node_modules", bytes: 3_000)
        let third = artifact("/repo/other/target", bytes: 4_000)
        var replies: [Reply] = []

        submit([first, second], present: { _, reply in replies.append(reply) }) { _ in }
        submit([second, third], present: { _, reply in replies.append(reply) }) { _ in }

        XCTAssertEqual(presented.first, [first.url.path, second.url.path])
        XCTAssertEqual(presented.count, 1, "the second sheet went up before the first was answered")

        replies[0](.declined)

        XCTAssertEqual(
            presented.last,
            [third.url.path],
            "the path already on screen was put to the user twice"
        )
    }

    // MARK: - Remembering

    /// An approval answers the proposals that arrive after it, rather than being refused as a
    /// stale quote — the path is no longer in the findings precisely *because* it was removed.
    func testAnApprovedPathAnswersALaterProposalWithoutAsking() {
        let artifact = self.artifact("/repo/app/.build", bytes: 2_000)
        submit([artifact]) { _ in }
        reply(.approved([.init(path: artifact.url.path, byteCount: 2_000)]))

        var answer: StorageCleanupLedger.Answer?
        // Gone from disk, so the gate reports it as unknown from here on.
        ledger.submit(
            StorageCleanupGate.Resolution(
                matched: [],
                unknown: [artifact.url.path],
                isEmptyRequest: false
            ),
            reason: nil,
            asker: nil,
            present: presenter(),
            completion: { answer = $0 }
        )

        XCTAssertEqual(presented.count, 1, "an already-removed path was put to the user again")
        XCTAssertEqual(answer?.askedTheUser, false)
        XCTAssertEqual(answer?.alreadyRemoved.map(\.path), [artifact.url.path])
        XCTAssertEqual(answer?.alreadyRemovedBytes, 2_000)
        XCTAssertEqual(answer?.unknown, [])
    }

    /// A decline is the answer for the rest of the run. Asking again ten minutes later because a
    /// different session read the same listing is the spam this exists to stop.
    func testADeclinedPathIsRefusedWithoutAskingAgain() {
        let artifact = self.artifact("/repo/app/.build", bytes: 2_000)
        submit([artifact]) { _ in }
        reply(.declined)

        var answer: StorageCleanupLedger.Answer?
        submit([artifact]) { answer = $0 }

        XCTAssertEqual(presented.count, 1, "a declined path was put to the user again")
        XCTAssertEqual(answer?.askedTheUser, false)
        XCTAssertEqual(answer?.declinedEarlier, [artifact.url.path])
    }

    /// A directory that was removed and has been rebuilt is a new question about new bytes.
    func testARebuiltDirectoryIsAskedAboutAgain() {
        let artifact = self.artifact("/repo/app/.build", bytes: 2_000)
        submit([artifact]) { _ in }
        reply(.approved([.init(path: artifact.url.path, byteCount: 2_000)]))

        // Back in the findings: the scan sees it on disk again.
        submit([self.artifact("/repo/app/.build", bytes: 9_000)]) { _ in }

        XCTAssertEqual(presented.count, 2, "a rebuilt directory was answered with the old decision")
    }

    /// The gate refusing at the moment of deletion is not a decision by the user, so it must not
    /// silence the next proposal.
    func testAPathTheGateRefusedCanBeProposedAgain() {
        let artifact = self.artifact("/repo/app/.build", bytes: 2_000)
        var answer: StorageCleanupLedger.Answer?
        submit([artifact]) { answer = $0 }
        reply(.approved([]))

        XCTAssertEqual(answer?.refused, [artifact.url.path])

        submit([artifact]) { _ in }
        XCTAssertEqual(presented.count, 2)
    }

    /// Nothing decided means nothing remembered: a sheet that could not be put up leaves the
    /// question open and says why.
    func testASheetThatCouldNotBePutUpDecidesNothing() {
        let artifact = self.artifact("/repo/app/.build", bytes: 2_000)
        var answer: StorageCleanupLedger.Answer?
        submit([artifact]) { answer = $0 }
        reply(.unavailable("There is no window to ask the user in."))

        XCTAssertEqual(answer?.couldNotAsk, [artifact.url.path])
        XCTAssertEqual(answer?.couldNotAskReason, "There is no window to ask the user in.")
        XCTAssertEqual(answer?.askedTheUser, false)

        submit([artifact]) { _ in }
        XCTAssertEqual(presented.count, 2, "a question nobody answered was treated as answered")
    }

    // MARK: - Queueing

    /// A proposal naming something genuinely new waits its turn rather than stacking a sheet on
    /// the one already up.
    func testAFreshProposalWaitsForTheSheetInFront() {
        let first = artifact("/repo/app/.build", bytes: 2_000)
        let second = artifact("/repo/other/target", bytes: 4_000)
        var replies: [Reply] = []

        submit([first], present: { _, reply in replies.append(reply) }) { _ in }
        submit([second], present: { _, reply in replies.append(reply) }) { _ in }

        XCTAssertEqual(presented.count, 1)
        replies[0](.declined)
        XCTAssertEqual(presented.count, 2)
        XCTAssertEqual(presented.last, [second.url.path])
    }

    /// The reported case, end to end: the disk fills, three sessions read the same listing within
    /// seconds of each other, and the user answers once.
    func testThreeSessionsProposingTheSameCleanupAreOneQuestion() {
        let artifacts = [
            artifact("/repo/app/.build", bytes: 2_000),
            artifact("/repo/app/web/node_modules", bytes: 3_000)
        ]
        var answers: [StorageCleanupLedger.Answer] = []

        for _ in 0..<3 {
            submit(artifacts) { answers.append($0) }
        }

        XCTAssertEqual(presented.count, 1, "the user was asked once per session")
        XCTAssertEqual(presented.first?.count, 2)

        reply(.approved(artifacts.map { .init(path: $0.url.path, byteCount: $0.byteCount) }))

        XCTAssertEqual(answers.count, 3, "a session was left waiting on a decision that landed")
        XCTAssertEqual(answers.map(\.removed.count), [2, 2, 2])
        XCTAssertEqual(answers.map(\.removedBytes), [5_000, 5_000, 5_000])
    }

    // MARK: - Helpers

    private func artifact(_ path: String, bytes: Int64) -> ReclaimableArtifact {
        ReclaimableArtifact(
            url: URL(fileURLWithPath: path),
            kind: .swiftPackage,
            byteCount: bytes,
            modifiedAt: Date(timeIntervalSinceNow: -86_400),
            checkoutPath: URL(fileURLWithPath: path).deletingLastPathComponent().path
        )
    }

    /// A presenter that records the batch and hands its reply back to the test.
    private typealias Reply = @MainActor (StorageCleanupLedger.SheetResult) -> Void

    private func presenter(
        _ onPresent: (@MainActor (StorageCleanupLedger.Batch, @escaping Reply) -> Void)? = nil
    ) -> StorageCleanupLedger.Presenting {
        { [weak self] batch, respond in
            self?.presented.append(batch.artifacts.map(\.url.path))
            self?.pending = respond
            onPresent?(batch, respond)
        }
    }

    private var pending: Reply?

    private func submit(
        _ artifacts: [ReclaimableArtifact],
        present: (@MainActor (StorageCleanupLedger.Batch, @escaping Reply) -> Void)? = nil,
        completion: @escaping @MainActor (StorageCleanupLedger.Answer) -> Void
    ) {
        ledger.submit(
            StorageCleanupGate.Resolution(
                matched: artifacts,
                unknown: [],
                isEmptyRequest: false
            ),
            reason: nil,
            asker: nil,
            present: presenter(present),
            completion: completion
        )
    }

    /// Answers the sheet that is up.
    private func reply(_ result: StorageCleanupLedger.SheetResult) {
        let respond = pending
        pending = nil
        respond?(result)
    }
}
