import Foundation
import ThreadingRemoteKit
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
        for kind in [RemoteAttachmentKind.image, .pdf, .html, .text] {
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

        for kind in [RemoteAttachmentKind.image, .pdf, .html, .text] {
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
