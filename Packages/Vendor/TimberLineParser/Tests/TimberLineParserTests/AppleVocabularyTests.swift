import XCTest
@testable import TimberLineParser

/// Apple's log vocabulary, which this detector did not have.
///
/// `Notice`, `Fault`, `Critical`, `Alert` and `Emergency` all came back `.unknown` — so a fault
/// read as *no level at all*, and a filter that cannot see a fault is worse than no filter. The
/// two vocabularies now meet in one enum with one ordering.
final class AppleVocabularyTests: XCTestCase {

    private func level(_ line: String) -> LogLevel {
        LevelDetector.detectLevel(bytes: Array(line.utf8))
    }

    func testTheUnifiedLogsOwnLevelsAreDetected() {
        XCTAssertEqual(level("Sep  1 16:21:01 kernel[0] <Notice>: vm: swapout"), .notice)
        XCTAssertEqual(level("Sep  1 16:21:01 SpringBoard[1] <Fault>: scene died"), .fault)
        XCTAssertEqual(level("Sep  1 16:21:01 daemon[2] <Critical>: disk full"), .critical)
        XCTAssertEqual(level("Sep  1 16:21:01 daemon[2] <Alert>: battery critical"), .alert)
        XCTAssertEqual(level("Sep  1 16:21:01 daemon[2] <Emergency>: halting"), .emergency)
    }

    /// `fatal` and `fault` share three letters and mean different things; the detector must not
    /// answer one for the other.
    func testFatalAndFaultAreNotConfused() {
        XCTAssertEqual(level("[fatal] the process gave up"), .error)
        XCTAssertEqual(level("[fault] the scene did not come back"), .fault)
    }

    /// The levels it already knew must keep answering the same.
    func testTheExistingVocabularyIsUnchanged() {
        XCTAssertEqual(level("[ERROR] nope"), .error)
        XCTAssertEqual(level("[warning] hm"), .warning)
        XCTAssertEqual(level("[info] fine"), .info)
        XCTAssertEqual(level("[debug] noisy"), .debug)
        XCTAssertEqual(level("nothing here at all"), .unknown)
    }

    /// One ordering, so a caller comparing a `Fault` against an `Error` gets an answer rather than
    /// a coin toss.
    func testSeverityOrdersBothVocabulariesTogether() {
        XCTAssertGreaterThan(LogLevel.fault.severity, LogLevel.error.severity)
        XCTAssertGreaterThan(LogLevel.emergency.severity, LogLevel.critical.severity)
        XCTAssertGreaterThan(LogLevel.error.severity, LogLevel.warning.severity)
        XCTAssertEqual(LogLevel.notice.severity, LogLevel.info.severity)
        XCTAssertGreaterThan(LogLevel.debug.severity, LogLevel.trace.severity)
    }
}
