import XCTest
@testable import ThreadingPTYHost

/// The Linux start time is two numbers read out of kernel text, and the text has one trap: the
/// command name in field 2 is whatever the process called itself, spaces and parentheses included.
/// Tested as strings so it runs on every platform, not only where `/proc` exists.
final class PTYHostProcStatTests: XCTestCase {

    /// A real `/proc/<pid>/stat` line from a `sleep`, with field 22 (start time) set to 4242.
    private static let sleepStat = "1234 (sleep) S 1 1234 1234 34816 1234 4194304 91 0 0 0 0 0 0 0 "
        + "20 0 1 0 4242 2289664 172 18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 0 17 3 0 0 0 0 0\n"

    func testReadsTheStartTicksFromField22() {
        XCTAssertEqual(PTYHostProcStat.startTicks(fromStat: Self.sleepStat), 4242)
    }

    func testCountsFieldsFromTheLastParenthesisSoACommandNameCannotShiftThem() {
        let hostile = Self.sleepStat.replacingOccurrences(of: "(sleep)", with: "(a ) b (c) d)")
        XCTAssertEqual(PTYHostProcStat.startTicks(fromStat: hostile), 4242)
    }

    func testAnswersNilForTextThatIsNotAStatLine() {
        XCTAssertNil(PTYHostProcStat.startTicks(fromStat: ""))
        XCTAssertNil(PTYHostProcStat.startTicks(fromStat: "1234 (sleep) S 1 1234"))
        XCTAssertNil(PTYHostProcStat.startTicks(fromStat: "no parenthesis here"))
    }

    func testReadsBootTimeFromItsLineAndNoOther() {
        let procStat = """
            cpu  10 0 10 1000 0 0 0 0 0 0
            intr 12345 0 0 0 0 0
            ctxt 99999
            btime 1726550000
            processes 4321
            """
        XCTAssertEqual(PTYHostProcStat.bootTime(fromProcStat: procStat), 1_726_550_000)
        XCTAssertNil(PTYHostProcStat.bootTime(fromProcStat: "cpu 1 2 3\nctxt 4\n"))
    }

    #if os(Linux)
    /// On Linux the whole path, against this process: a start time exists, and a second read
    /// agrees with the first, which is what a restart's identity probe depends on.
    func testThisProcessHasAStableStartTime() {
        let first = PTYHostPOSIX.startTime(of: getpid())
        XCTAssertNotNil(first)
        XCTAssertEqual(first, PTYHostPOSIX.startTime(of: getpid()))
    }
    #endif
}
