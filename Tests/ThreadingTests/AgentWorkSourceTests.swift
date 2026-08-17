import XCTest
@testable import Threading

/// What the Activity card is allowed to claim about one session.
///
/// The bug this exists to prevent is a picture, not a crash: the panel drew a complete repository
/// silhouette and `0 of N files · 0 edits · 0 reads` beside it for a session nothing was feeding,
/// which is the same picture it draws for a chat that genuinely did nothing. These cases pin the
/// line between the two.
final class AgentWorkSourceTests: XCTestCase {

    func testARenderedConversationIsAlwaysItsOwnSource() {
        let source = AgentWorkSource.resolve(
            usesNativeUI: true,
            hasReadableTranscript: false,
            runtimeKeepsReadableTranscripts: false,
            hasTurnCheckpoints: false
        )
        XCTAssertEqual(source, .live)
        XCTAssertTrue(source.reportsExactCalls)
    }

    func testATerminalSessionWithATranscriptReportsExactCalls() {
        let source = AgentWorkSource.resolve(
            usesNativeUI: false,
            hasReadableTranscript: true,
            runtimeKeepsReadableTranscripts: true,
            hasTurnCheckpoints: true
        )
        XCTAssertEqual(source, .transcript)
        XCTAssertTrue(source.reportsExactCalls)
    }

    /// The floor, and the reason reads and edits are withheld rather than shown as zero: a tree
    /// pair cannot see a read at all, so "0 reads" would be a measurement nobody took.
    func testARuntimeWithNoTranscriptFallsBackToWhatTheCheckoutSaw() {
        let source = AgentWorkSource.resolve(
            usesNativeUI: false,
            hasReadableTranscript: false,
            runtimeKeepsReadableTranscripts: false,
            hasTurnCheckpoints: true
        )
        XCTAssertEqual(source, .gitObserved)
        XCTAssertFalse(source.reportsExactCalls)
        XCTAssertTrue(source.hasAnySource, "changed files are still a reading")
    }

    func testARuntimeWithNothingBehindItSaysSoRatherThanReportingZeros() {
        let source = AgentWorkSource.resolve(
            usesNativeUI: false,
            hasReadableTranscript: false,
            runtimeKeepsReadableTranscripts: false,
            hasTurnCheckpoints: false
        )
        XCTAssertEqual(source, .unavailable(.runtimeKeepsNoReadableTranscript))
        XCTAssertFalse(source.hasAnySource)
    }

    /// Told apart from the case above because the sentences differ: this session's runtime does
    /// write a readable transcript, and one will appear the first time it runs.
    func testASessionThatHasNotRunYetIsDistinctFromARuntimeThatNeverWill() {
        let source = AgentWorkSource.resolve(
            usesNativeUI: false,
            hasReadableTranscript: false,
            runtimeKeepsReadableTranscripts: true,
            hasTurnCheckpoints: false
        )
        XCTAssertEqual(source, .unavailable(.transcriptNotWrittenYet))
        XCTAssertFalse(source.hasAnySource)
    }

    /// Capability-shaped, not runtime-shaped. Claude and Codex carry `.transcriptReplay` today,
    /// and the classification follows the capability rather than the name, so a sixth runtime is
    /// covered the day it earns one.
    func testTheClassificationFollowsTheCapabilityRatherThanTheRuntimeName() {
        for kind in AgentKind.allCases {
            let source = AgentWorkSource.resolve(
                usesNativeUI: false,
                hasReadableTranscript: false,
                runtimeKeepsReadableTranscripts: kind.supports(.transcriptReplay),
                hasTurnCheckpoints: false
            )
            XCTAssertEqual(
                source,
                kind.supports(.transcriptReplay)
                    ? .unavailable(.transcriptNotWrittenYet)
                    : .unavailable(.runtimeKeepsNoReadableTranscript),
                "\(kind.displayName) was classified against its name rather than its capability"
            )
        }
    }
}
