import Foundation
import ThreadingRemoteKit
import UIKit
import XCTest
@testable import ThreadingMobile

final class RemoteAttachmentPreviewFailureTests: XCTestCase {
    func testTaskCancellationIsNotPresentedAsAPreviewFailure() {
        XCTAssertNil(RemoteAttachmentPreviewFailure.message(for: CancellationError()))
        XCTAssertNil(RemoteAttachmentPreviewFailure.message(for: URLError(.cancelled)))
    }

    func testRealFailureKeepsItsLocalizedReason() {
        let error = URLError(.notConnectedToInternet)

        XCTAssertEqual(
            RemoteAttachmentPreviewFailure.message(for: error),
            error.localizedDescription
        )
    }
}

/// Which transport failures are worth one more attempt at once, and which are not.
final class RemoteTransientTransportFailureTests: XCTestCase {
    /// `url.-1005`, twenty-seven times in one day's audit: the pooled connection the host had
    /// just closed, reused a moment too late.
    func testALostConnectionIsTransient() {
        XCTAssertTrue(RemoteTransientTransportFailure.isTransient(URLError(.networkConnectionLost)))
    }

    /// The same fact can arrive as the POSIX reset beneath whichever error wrapped it.
    func testAResetOrBrokenPipeBeneathAWrapperIsTransient() {
        for code in [ECONNRESET, EPIPE] {
            let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            let wrapped = NSError(
                domain: NSURLErrorDomain,
                code: URLError.cannotConnectToHost.rawValue,
                userInfo: [NSUnderlyingErrorKey: posix]
            )
            XCTAssertTrue(RemoteTransientTransportFailure.isTransient(wrapped), "\(code)")
        }
    }

    /// Asking again at once does not make an absent route, a slow host or a refusal better,
    /// and a cancellation is the caller's own doing.
    func testEverythingElseIsNot() {
        XCTAssertFalse(RemoteTransientTransportFailure.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertFalse(RemoteTransientTransportFailure.isTransient(URLError(.timedOut)))
        XCTAssertFalse(RemoteTransientTransportFailure.isTransient(URLError(.cannotFindHost)))
        XCTAssertFalse(RemoteTransientTransportFailure.isTransient(URLError(.cancelled)))
        XCTAssertFalse(RemoteTransientTransportFailure.isTransient(CancellationError()))
        XCTAssertFalse(RemoteTransientTransportFailure.isTransient(
            RemoteClientError.decodedRefusal(status: 404, data: Data())
        ))
    }

    /// The chain walk is bounded: a reset buried deeper than the limit is not found, so a
    /// hostile or runaway `userInfo` cannot make the classifier walk forever.
    func testTheUnderlyingChainWalkIsBounded() {
        var error = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        for _ in 0..<(RemoteClientDefaults.underlyingErrorDepthLimit + 1) {
            error = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: error])
        }
        XCTAssertFalse(RemoteTransientTransportFailure.isTransient(error))
    }
}

final class RemoteAttachmentPreviewLoadTests: XCTestCase {

    func testRouteRecoveryRestartsAnUnloadedPreviewTask() throws {
        let hosted = RemoteClient(
            link: try XCTUnwrap(RemoteConnectionLink(
                baseURL: URL(string: "https://127.0.0.1:41001/")!,
                token: "token"
            )),
            endpointKind: .hosted
        )
        let recovered = RemoteClient(
            link: try XCTUnwrap(RemoteConnectionLink(
                baseURL: URL(string: "https://127.0.0.1:41002/")!,
                token: "token"
            )),
            endpointKind: .hosted
        )

        XCTAssertNotEqual(
            RemoteAttachmentPreviewTaskIdentity(client: hosted, isCurrentPage: true),
            RemoteAttachmentPreviewTaskIdentity(client: recovered, isCurrentPage: true),
            "a mounted preview must ask through the replacement route"
        )
        XCTAssertNotEqual(
            RemoteAttachmentPreviewTaskIdentity(client: recovered, isCurrentPage: false),
            RemoteAttachmentPreviewTaskIdentity(client: recovered, isCurrentPage: true),
            "becoming current remains an independent retry boundary"
        )
        XCTAssertEqual(
            RemoteAttachmentPreviewTaskIdentity(client: recovered, isCurrentPage: true),
            RemoteAttachmentPreviewTaskIdentity(client: recovered, isCurrentPage: true),
            "an unchanged route and page state must not restart a completed task"
        )
    }

    /// The report this pins: an image whose ledger thumbnail arrived, whose page never did.
    ///
    /// A cancelled page releases its in-flight flag only after hopping back to the main actor,
    /// which is after SwiftUI has started the page's next task. Gating on that flag made the
    /// retry a no-op, and because a cancelled attempt correctly presents no error, the page
    /// kept its loading placeholder with nothing to tap and nothing in the journal. Asking
    /// again while the page still holds nothing must always be allowed.
    func testACancelledPageAsksAgainAndAPageHoldingItsBytesStops() {
        func asks(hasData: Bool) -> Bool {
            RemoteAttachmentPreviewLoad.shouldRequestBytes(
                kind: .image,
                hasData: hasData,
                loadsRemotely: true
            )
        }

        // The page appears and asks.
        XCTAssertTrue(asks(hasData: false))
        // A swipe cancels that attempt, so no bytes arrived. Becoming the current page again
        // must ask again: the previous attempt's existence decides nothing here, which is the
        // whole reason this gate takes no in-flight flag.
        XCTAssertTrue(asks(hasData: false))
        // The retry lands, and the page stops asking for good.
        XCTAssertFalse(asks(hasData: true))
    }

    func testHoldingTheBytesEndsTheAskingForEveryDrawableKind() {
        for kind in [RemoteAttachmentKind.image, .pdf, .html, .text, .diff] {
            XCTAssertFalse(
                RemoteAttachmentPreviewLoad.shouldRequestBytes(
                    kind: kind,
                    hasData: true,
                    loadsRemotely: true
                ),
                "becoming the current page again must not refetch a \(kind.rawValue) in hand"
            )
        }
    }

    /// These kinds never use the whole-file route: movies stream through bounded ranges and the
    /// others have no phone renderer, so none spends the byte cap on an unusable full response.
    func testKindsExcludedFromWholeFileLoadingNeverAskForTheirBytes() {
        for kind in RemoteAttachmentPreviewLoad.excludesFromWholeFileLoad {
            XCTAssertFalse(
                RemoteAttachmentPreviewLoad.shouldRequestBytes(
                    kind: kind,
                    hasData: false,
                    loadsRemotely: true
                ),
                "\(kind.rawValue) must not use the whole-file route"
            )
        }

        for kind in [RemoteAttachmentKind.image, .pdf, .html, .text, .diff] {
            XCTAssertTrue(RemoteAttachmentPreviewLoad.shouldRequestBytes(
                kind: kind,
                hasData: false,
                loadsRemotely: true
            ))
        }
    }

    func testADemoPageAsksForNothing() {
        XCTAssertFalse(RemoteAttachmentPreviewLoad.shouldRequestBytes(
            kind: .image,
            hasData: false,
            loadsRemotely: false
        ))
    }

    func testTheDecisionKeepsEveryEarlyReturnReasonDistinct() {
        XCTAssertEqual(
            RemoteAttachmentPreviewLoad.decision(
                kind: .image,
                hasData: false,
                loadsRemotely: true
            ),
            .requestBytes
        )
        XCTAssertEqual(
            RemoteAttachmentPreviewLoad.decision(
                kind: .image,
                hasData: true,
                loadsRemotely: true
            ),
            .alreadyLoaded
        )
        XCTAssertEqual(
            RemoteAttachmentPreviewLoad.decision(
                kind: .image,
                hasData: false,
                loadsRemotely: false
            ),
            .localFixture
        )
        XCTAssertEqual(
            RemoteAttachmentPreviewLoad.decision(
                kind: .archive,
                hasData: false,
                loadsRemotely: true
            ),
            .previewUnavailable
        )
    }
}

/// A kept comparison is `git diff --no-index` of two absolute paths. The phone draws it with
/// Review's renderer, whose header shows the file's own name over the folder it lives in.
final class RemoteDiffAttachmentTests: XCTestCase {
    func testAKeptComparisonParsesIntoOneNamedFile() async {
        let diff = """
        diff --git a/var/folders/p5/T/brain-diff/design-system.md b/Users/me/repo/docs/design-system.md
        index 3f1c2aa..8d04e71 100644
        --- a/var/folders/p5/T/brain-diff/design-system.md
        +++ b/Users/me/repo/docs/design-system.md
        @@ -1,3 +1,3 @@
         # Icons
        -Brains are drawn in outline.
        +Brains are drawn filled, with thought bubbles.
         End.

        """

        let document = await RemoteDiffAttachmentView.document(from: Data(diff.utf8))

        XCTAssertEqual(document.files.count, 1)
        XCTAssertEqual(document.files.first?.fileName, "design-system.md")
        XCTAssertEqual(document.files.first?.added, 1)
        XCTAssertEqual(document.files.first?.removed, 1)
        XCTAssertEqual(document.summary.files, 1)
    }

    func testBytesThatAreNotADiffParseToNothingRatherThanFailing() async {
        let document = await RemoteDiffAttachmentView.document(from: Data([0xFF, 0xFE, 0x00]))
        XCTAssertTrue(document.files.isEmpty)
    }

    func testTheKindHasItsOwnGlyphAndDiagnosticToken() async {
        XCTAssertEqual(RemoteAttachmentGlyph.name(for: .diff), "plus.forwardslash.minus")
        let token = await MainActor.run { MobileAttachmentPreviewLog.kindToken(for: .diff) }
        XCTAssertEqual(token, .diff)
    }
}

/// The phone's picture comparison: the Mac's shared-scale rule, and the record naming both sides.
final class RemoteImageComparisonTests: XCTestCase {
    func testBothSidesDrawAtOneSharedScaleSoAResizedPictureLooksResized() {
        let layout = MobileImageCompareLayout.layout(
            oldSize: CGSize(width: 100, height: 100),
            newSize: CGSize(width: 200, height: 200),
            in: CGRect(x: 0, y: 0, width: 400, height: 400),
            mode: .wipeHorizontal,
            gap: 8
        )
        XCTAssertEqual(layout.newRect.width, 400)
        XCTAssertEqual(layout.oldRect.width, 200, "fitting each side alone would hide the resize")
        XCTAssertEqual(layout.oldRect.midX, layout.newRect.midX)
        XCTAssertNil(layout.secondaryCanvas)
    }

    func testSideBySideSplitsWhicheverWayGivesThePicturesMoreRoom() {
        let landscape = CGSize(width: 1600, height: 900)
        let portraitScreen = MobileImageCompareLayout.layout(
            oldSize: landscape, newSize: landscape,
            in: CGRect(x: 0, y: 0, width: 360, height: 600),
            mode: .sideBySide, gap: 8
        )
        XCTAssertTrue(portraitScreen.placesNewBelow, "wide pictures stack on a tall screen")

        let tall = CGSize(width: 1179, height: 2556)
        let beside = MobileImageCompareLayout.layout(
            oldSize: tall, newSize: tall,
            in: CGRect(x: 0, y: 0, width: 360, height: 600),
            mode: .sideBySide, gap: 8
        )
        XCTAssertFalse(beside.placesNewBelow, "tall screenshots stand beside each other")
        XCTAssertEqual(beside.oldRect.width, beside.newRect.width)
    }

    func testTheSeamAndTheFractionAreOneAnother() {
        let layout = MobileImageCompareLayout.layout(
            oldSize: CGSize(width: 100, height: 50),
            newSize: CGSize(width: 100, height: 50),
            in: CGRect(x: 0, y: 0, width: 200, height: 400),
            mode: .wipeHorizontal,
            gap: 8
        )
        let seam = layout.seam(for: .wipeHorizontal, at: 0.25)
        XCTAssertEqual(seam, layout.canvas.minX + layout.canvas.width * 0.25)
        XCTAssertEqual(
            layout.fraction(at: CGPoint(x: seam, y: layout.canvas.midY), for: .wipeHorizontal),
            0.25,
            accuracy: 0.0001
        )
        XCTAssertEqual(layout.fraction(at: CGPoint(x: -50, y: 0), for: .wipeHorizontal), 0)
        XCTAssertEqual(layout.fraction(at: CGPoint(x: 0, y: 10_000), for: .wipeVertical), 1)
    }

    func testARecordThatIsNotOneSaysSoRatherThanDrawingHalf() throws {
        let record = RemoteImageComparisonDTO(
            old: .init(attachmentID: "a", title: "Before"),
            new: .init(attachmentID: "b", title: "After")
        )
        XCTAssertEqual(
            try RemoteImageComparisonLoad.decodeManifest(JSONEncoder().encode(record)),
            record
        )
        XCTAssertThrowsError(try RemoteImageComparisonLoad.decodeManifest(Data("{}".utf8))) {
            XCTAssertEqual($0 as? RemoteImageComparisonLoad.Failure, .unreadable)
        }
    }

    func testASideKeepsItsTruePixelSizeWhenDecodedSmaller() throws {
        let wide = try Self.png(width: 3_000, height: 12)
        let side = try RemoteImageComparisonLoad.side(from: wide, title: "Wide")
        XCTAssertEqual(side.pixelSize, CGSize(width: 3_000, height: 12))
        let decoded = try XCTUnwrap(side.image.cgImage)
        XCTAssertLessThanOrEqual(
            max(decoded.width, decoded.height),
            RemoteImageComparisonLoad.maximumDecodedPixelDimension
        )
        XCTAssertThrowsError(try RemoteImageComparisonLoad.side(from: Data("no".utf8), title: "x"))
    }

    func testBothSidesAreFetchedByTheirAttachmentIDs() async throws {
        let before = try Self.png(width: 4, height: 4)
        let after = try Self.png(width: 6, height: 4)
        let record = try JSONEncoder().encode(RemoteImageComparisonDTO(
            old: .init(attachmentID: "before-id", title: "Before"),
            new: .init(attachmentID: "after-id", title: "After")
        ))
        let sides = try await RemoteImageComparisonLoad.load(manifestData: record) { id in
            switch id {
            case "before-id": return before
            case "after-id": return after
            default: throw URLError(.fileDoesNotExist)
            }
        }
        XCTAssertEqual(sides.old.title, "Before")
        XCTAssertEqual(sides.new.pixelSize, CGSize(width: 6, height: 4))
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.pngData())
    }
}

@MainActor
final class MobileAttachmentPreviewLogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MobileAttachmentPreviewLog.reset()
    }

    override func tearDown() {
        MobileAttachmentPreviewLog.reset()
        super.tearDown()
    }

    func testTheHistoryPreservesAttemptOrderingAndRepeatedOutcomes() {
        let base = Date(timeIntervalSince1970: 1_000)
        MobileAttachmentPreviewLog.record(kind: .image, outcome: .start, at: base)
        MobileAttachmentPreviewLog.record(kind: .image, outcome: .cancel, at: base)
        MobileAttachmentPreviewLog.record(
            kind: .image,
            outcome: .start,
            at: base.addingTimeInterval(2)
        )
        MobileAttachmentPreviewLog.record(
            kind: .image,
            outcome: .ok,
            at: base.addingTimeInterval(2)
        )

        XCTAssertEqual(
            MobileAttachmentPreviewLog.summary(now: base.addingTimeInterval(4)),
            "image.start-4:image.cancel-4:image.start-2:image.ok-2"
        )
    }

    func testRepeatedStartsAreAttemptsAndAreNotCoalesced() {
        let base = Date(timeIntervalSince1970: 1_000)
        for offset in 0..<3 {
            MobileAttachmentPreviewLog.record(
                kind: .pdf,
                outcome: .start,
                at: base.addingTimeInterval(Double(offset))
            )
        }

        XCTAssertEqual(
            MobileAttachmentPreviewLog.summary(now: base.addingTimeInterval(3)),
            "pdf.start-3:pdf.start-2:pdf.start-1"
        )
    }

    func testTheRingKeepsOnlyTheEightNewestOutcomes() throws {
        let base = Date(timeIntervalSince1970: 1_000)
        for offset in 0..<20 {
            MobileAttachmentPreviewLog.record(
                kind: .text,
                outcome: .fail,
                at: base.addingTimeInterval(Double(offset))
            )
        }

        let value = try XCTUnwrap(
            MobileAttachmentPreviewLog.summary(now: base.addingTimeInterval(20))
        )
        XCTAssertEqual(value.split(separator: ":").count, MobileAttachmentPreviewLog.capacity)
        XCTAssertEqual(value.split(separator: ":").first, "text.fail-8")
        XCTAssertEqual(value.split(separator: ":").last, "text.fail-1")
    }

    func testUnknownKindsCollapseToAClosedToken() {
        XCTAssertEqual(
            MobileAttachmentPreviewLog.kindToken(for: .unknown("/private/path")),
            .unk
        )
    }

    /// This assertion protects the public intake's 160-byte value ceiling if either vocabulary
    /// grows. Eight longest possible entries plus seven separators must always fit intact.
    func testEveryPossibleRingFitsThePublicReportField() {
        let longestKind = MobileAttachmentPreviewLog.KindToken.allCases
            .map(\.rawValue.utf8.count)
            .max() ?? 0
        let longestOutcome = MobileAttachmentPreviewLog.Outcome.allCases
            .map(\.rawValue.utf8.count)
            .max() ?? 0
        let ageDigits = String(MobileAttachmentPreviewLog.maximumAgeSeconds).utf8.count
        let entryBytes = longestKind + 1 + longestOutcome + 1 + ageDigits
        let ringBytes = entryBytes * MobileAttachmentPreviewLog.capacity
            + MobileAttachmentPreviewLog.capacity - 1

        XCTAssertLessThanOrEqual(ringBytes, 160)
    }

    func testAnEmptyRingHasNoSummary() {
        XCTAssertNil(MobileAttachmentPreviewLog.summary())
    }
}
