import XCTest
@testable import DeviceLogsPlugin

/// The two log shapes the pane accepts.
///
/// These are the parsers most able to fail silently: a row that does not decode simply never
/// appears, and a firehose makes one missing row invisible. Both fixtures are real lines captured
/// from a booted simulator and a paired iPhone on 2026-09-01.
final class DeviceLogDecodingTests: XCTestCase {

    private func decodeNDJSON(_ text: String) -> DeviceLogRow? {
        DeviceLogDecoding.ndjson(ArraySlice(Array(text.utf8)))
    }

    private func decodeSyslog(_ text: String) -> DeviceLogRow? {
        DeviceLogDecoding.syslog(ArraySlice(Array(text.utf8)))
    }

    // MARK: NDJSON

    func testTheSimulatorStreamDecodesEveryColumn() throws {
        let row = try XCTUnwrap(decodeNDJSON("""
        {"timestamp":"2026-09-01 21:13:45.282914+0200","messageType":"Debug",\
        "processImagePath":"\\/usr\\/libexec\\/backboardd","subsystem":"com.apple.xpc",\
        "category":"transaction","eventMessage":"Transaction created"}
        """))
        XCTAssertEqual(row.time, "21:13:45.282")
        XCTAssertEqual(row.level, "Debug")
        XCTAssertEqual(row.process, "backboardd", "the last path component is the process")
        XCTAssertEqual(row.subsystem, "com.apple.xpc")
        XCTAssertEqual(row.message, "Transaction created")
    }

    /// An empty subsystem is absent, not an empty string, so the column stays blank rather than
    /// implying the daemon reported one.
    func testAnEmptySubsystemBecomesNil() throws {
        let row = try XCTUnwrap(decodeNDJSON(
            #"{"timestamp":"2026-09-01 21:13:45.282914+0200","subsystem":"","eventMessage":"hi"}"#
        ))
        XCTAssertNil(row.subsystem)
        XCTAssertEqual(row.level, "Default", "a missing messageType falls back rather than drops")
    }

    func testNonJSONLinesAreRejectedRatherThanGuessedAt() {
        XCTAssertNil(decodeNDJSON("Filtering the log data using \"subsystem == \\\"x\\\"\""))
        XCTAssertNil(decodeNDJSON(""))
        XCTAssertNil(decodeNDJSON("{not json at all"))
    }

    // MARK: Syslog

    func testTheDeviceRelayDecodesProcessSenderAndLevel() throws {
        let row = try XCTUnwrap(decodeSyslog(
            "Sep  1 16:21:01.549408 AccessibilityUIServer(CoreMotion)[41737] <Debug>: CMDeviceMotion: <private>"
        ))
        XCTAssertEqual(row.time, "16:21:01.549")
        XCTAssertEqual(row.level, "Debug")
        XCTAssertEqual(row.process, "AccessibilityUIServer")
        XCTAssertEqual(row.subsystem, "CoreMotion", "the sender image stands in for a subsystem")
        XCTAssertEqual(row.message, "CMDeviceMotion: <private>")
    }

    /// A process logging from its own binary has no parenthesised sender, and that is the shape
    /// an app's own `os_log` takes. Getting this wrong would drop exactly the rows worth reading.
    func testAProcessLoggingFromItsOwnBinaryHasNoSubsystem() throws {
        let row = try XCTUnwrap(decodeSyslog(
            "Sep  1 16:21:01.548727 kernel[0] <Notice>: vm: segments queued for swapout"
        ))
        XCTAssertEqual(row.process, "kernel")
        XCTAssertNil(row.subsystem)
        XCTAssertEqual(row.level, "Notice")
        XCTAssertEqual(row.message, "vm: segments queued for swapout")
    }

    /// A message containing "&gt;: " must not be mistaken for the header separator.
    func testAMessageContainingTheSeparatorKeepsAllOfItself() throws {
        let row = try XCTUnwrap(decodeSyslog(
            "Sep  1 16:21:01.100000 SpringBoard[41736] <Error>: scene <private>: state a>: b"
        ))
        XCTAssertEqual(row.process, "SpringBoard")
        XCTAssertEqual(row.message, "scene <private>: state a>: b")
    }

    func testTheRelaysConnectionNoticesAreNotRows() {
        XCTAssertNil(decodeSyslog("[connected:00008140-000C208C1108801C]"))
        XCTAssertNil(decodeSyslog("[disconnected:00008140-000C208C1108801C]"))
        XCTAssertNil(decodeSyslog("Waiting for device to become available..."))
    }

    // MARK: Severity

    /// The level filter orders two different vocabularies. `log` says Default and Fault; the
    /// relay says Notice and Emergency. A filter that understood only one would silently hide
    /// errors from the other source.
    func testBothLevelVocabulariesOrderTogether() {
        func severity(_ level: String) -> Int {
            DeviceLogRow(time: "", level: level, process: "", subsystem: nil, message: "").severity
        }
        XCTAssertGreaterThan(severity("Error"), severity("Default"))
        XCTAssertGreaterThan(severity("Error"), severity("Notice"))
        XCTAssertGreaterThan(severity("Fault"), severity("Error"))
        XCTAssertGreaterThan(severity("Emergency"), severity("Error"))
        XCTAssertEqual(severity("Default"), severity("Notice"))
        XCTAssertGreaterThan(severity("Info"), severity("Debug"))
    }

    // MARK: Handoff

    /// The bound exists so a stalled consumer cannot grow memory without limit. Dropping is the
    /// honest outcome, and the count is what makes it visible instead of silent.
    func testTheHandoffDropsRatherThanGrowsWhenTheConsumerStalls() {
        let source = BufferedDeviceLogSource()
        let row = DeviceLogRow(time: "", level: "Default", process: "p", subsystem: nil, message: "m")
        source.enqueue(Array(repeating: row, count: BufferedDeviceLogSource.handoffCapacity + 500))
        XCTAssertEqual(source.dropped, 500)
        XCTAssertEqual(source.drain().count, BufferedDeviceLogSource.handoffCapacity)
        XCTAssertTrue(source.drain().isEmpty, "a drain takes everything it reported")
    }

    // MARK: App container log

    private func decodeAppLog(_ text: String) -> DeviceLogRow? {
        DeviceLogDecoding.appLogLine(text, appName: "Lotus")
    }

    /// A real line from `ananke-2026-09-02T10-34-23Z.log`, pulled off the device. This is the
    /// route that carries what the app actually recorded: `--console` shows none of these, and the
    /// unified log redacts them.
    func testAnAppLogLineKeepsItsLevelCategoryAndOrigin() throws {
        let row = try XCTUnwrap(decodeAppLog(
            "2026-09-02T10:34:33.242Z [DEBUG] [kmp-interface] "
                + "WatchLibLogger.swift:26 log(level:tag:message:throwable:) - [DeviceWriter] Read"
        ))
        XCTAssertEqual(row.time, "10:34:33.242")
        XCTAssertEqual(row.level, "Debug")
        XCTAssertEqual(row.subsystem, "kmp-interface")
        XCTAssertEqual(row.process, "Lotus")
        XCTAssertTrue(
            row.message.hasPrefix("WatchLibLogger.swift:26"),
            "the file and line are kept: they are most of why this route is worth having"
        )
    }

    /// The app's vocabulary is not the unified log's, and the level filter orders both. A WARN that
    /// decoded as Default would hide behind "Errors only" while looking fine.
    func testAppLevelsMapOntoTheOrderingTheFilterUses() {
        func level(_ token: String) -> String? {
            decodeAppLog("2026-09-02T10:34:33.242Z [\(token)] [app] hello")?.level
        }
        XCTAssertEqual(level("ERROR"), "Error")
        XCTAssertEqual(level("WARN"), "Warning")
        XCTAssertEqual(level("INFO"), "Info")
        XCTAssertEqual(level("DEBUG"), "Debug")
        XCTAssertEqual(level("CRITICAL"), "Fault")
        XCTAssertEqual(level("shouty-nonsense"), "Default", "an unknown level is not an error")
    }

    /// A log file opens with a banner that carries no timestamp. It is context worth showing, so
    /// it must survive rather than be dropped as unparseable.
    func testTheFileBannerSurvivesWithoutATimestamp() throws {
        let row = try XCTUnwrap(decodeAppLog("App Version: 1.0.0"))
        XCTAssertEqual(row.message, "App Version: 1.0.0")
        XCTAssertEqual(row.time, "--:--:--")
        XCTAssertNil(row.subsystem)
    }

    func testSeparatorRulesAndBlankLinesAreNotRows() {
        XCTAssertNil(decodeAppLog(String(repeating: "=", count: 80)))
        XCTAssertNil(decodeAppLog("   "))
        XCTAssertNil(decodeAppLog(""))
    }
}
