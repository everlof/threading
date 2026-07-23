import XCTest
@testable import Skalman

/// The code-stats pipeline's pure halves: reading scc's JSON, and the bar arithmetic that
/// folds a reading into segments. Neither should need a view — or scc — to be tested.
final class CodeStatsTests: XCTestCase {

    // MARK: - Fixtures

    /// Verbatim scc 3.6.0 `--format json` output (trimmed to three languages), full key set
    /// included so the decoder is proven against what the tool actually writes.
    private let realOutput = """
    [{"Name":"Swift","Bytes":3491395,"CodeBytes":0,"Lines":89761,"Code":60965,"Comment":14970,\
    "Blank":13826,"Complexity":8945,"Count":374,"WeightedComplexity":0,"Files":[],\
    "LineLength":null,"ULOC":0},{"Name":"Markdown","Bytes":353621,"CodeBytes":0,"Lines":5887,\
    "Code":4762,"Comment":0,"Blank":1125,"Complexity":0,"Count":23,"WeightedComplexity":0,\
    "Files":[],"LineLength":null,"ULOC":0},{"Name":"Python","Bytes":19137,"CodeBytes":0,\
    "Lines":468,"Code":322,"Comment":77,"Blank":69,"Complexity":112,"Count":2,\
    "WeightedComplexity":0,"Files":[],"LineLength":null,"ULOC":0}]
    """

    private func stats(_ codes: [(String, Int)]) -> CodeStats {
        CodeStats(languages: codes.map {
            CodeStats.Language(
                name: $0.0, files: 1, code: $0.1, comments: 0, blanks: 0, complexity: 0, bytes: 0
            )
        })
    }

    // MARK: - Parsing

    func testParsesRealSCCOutput() throws {
        let stats = try CodeStats.parse(sccJSON: Data(realOutput.utf8))

        XCTAssertEqual(stats.languages.map(\.name), ["Swift", "Markdown", "Python"])
        XCTAssertEqual(stats.languages[0].code, 60_965)
        XCTAssertEqual(stats.languages[0].comments, 14_970)
        XCTAssertEqual(stats.languages[0].blanks, 13_826)
        XCTAssertEqual(stats.languages[0].files, 374)
        XCTAssertEqual(stats.languages[0].complexity, 8_945)
        XCTAssertEqual(stats.totalCode, 60_965 + 4_762 + 322)
        XCTAssertEqual(stats.totalFiles, 374 + 23 + 2)
    }

    func testParsingSortsByCodeDescendingRegardlessOfInputOrder() throws {
        let shuffled = """
        [{"Name":"YAML","Bytes":0,"Lines":0,"Code":81,"Comment":0,"Blank":0,"Complexity":0,"Count":1},
         {"Name":"Swift","Bytes":0,"Lines":0,"Code":900,"Comment":0,"Blank":0,"Complexity":0,"Count":1},
         {"Name":"JSON","Bytes":0,"Lines":0,"Code":500,"Comment":0,"Blank":0,"Complexity":0,"Count":1}]
        """
        let stats = try CodeStats.parse(sccJSON: Data(shuffled.utf8))
        XCTAssertEqual(stats.languages.map(\.name), ["Swift", "JSON", "YAML"])
    }

    /// scc reports an empty folder as `[]`, which is an answer rather than a failure.
    func testEmptyOutputParsesToEmptyStats() throws {
        let stats = try CodeStats.parse(sccJSON: Data("[]".utf8))
        XCTAssertTrue(stats.isEmpty)
        XCTAssertEqual(stats.totalCode, 0)
    }

    func testMalformedOutputThrows() {
        XCTAssertThrowsError(try CodeStats.parse(sccJSON: Data("not json".utf8)))
    }

    // MARK: - Bar Folding

    func testFoldsBeyondTheCapIntoOther() {
        let bar = CodeStatsBar.make(from: stats([
            ("Swift", 700), ("TypeScript", 100), ("Python", 80), ("Ruby", 60),
            ("Go", 30), ("YAML", 20), ("JSON", 10)
        ]), maximumSegments: 5)

        XCTAssertEqual(bar.segments.count, 6)
        XCTAssertEqual(bar.segments.last?.name, CodeStatsBarDefaults.otherName)
        XCTAssertEqual(bar.segments.last?.code, 30)
        XCTAssertNil(bar.segments.last?.colorIndex)
        XCTAssertEqual(bar.segments.dropLast().compactMap(\.colorIndex), [0, 1, 2, 3, 4])
    }

    /// With exactly one language past the cap, "Other" would be a name withheld for nothing.
    func testTheFoldNeverStandsForASingleLanguage() {
        let bar = CodeStatsBar.make(from: stats([
            ("Swift", 700), ("TypeScript", 100), ("Python", 80), ("Ruby", 60),
            ("Go", 30), ("YAML", 20)
        ]), maximumSegments: 5)

        XCTAssertEqual(bar.segments.count, 6)
        XCTAssertEqual(bar.segments.last?.name, "YAML")
        XCTAssertEqual(bar.segments.last?.colorIndex, 5)
    }

    func testZeroCodeLanguagesAreNotSegments() {
        let bar = CodeStatsBar.make(from: stats([("Swift", 500), ("License", 0)]))
        XCTAssertEqual(bar.segments.map(\.name), ["Swift"])
    }

    func testFractionsCoverTheWholeBar() {
        let bar = CodeStatsBar.make(from: stats([
            ("A", 700), ("B", 100), ("C", 80), ("D", 60), ("E", 30), ("F", 20), ("G", 10)
        ]))
        XCTAssertEqual(bar.segments.reduce(0) { $0 + $1.fraction }, 1, accuracy: 0.0001)
    }

    func testAnEmptyReadingMakesAnEmptyBar() {
        XCTAssertTrue(CodeStatsBar.make(from: stats([])).isEmpty)
        XCTAssertTrue(CodeStatsBar.make(from: stats([("License", 0)])).isEmpty)
    }

    // MARK: - Widths

    func testWidthsSumToTheAvailableWidth() {
        let bar = CodeStatsBar.make(from: stats([("A", 900), ("B", 90), ("C", 10)]))
        let widths = bar.widths(totalWidth: 300, gap: 1, minimumWidth: 2)

        XCTAssertEqual(widths.count, 3)
        XCTAssertEqual(widths.reduce(0, +), 300 - 2, accuracy: 0.001)
    }

    /// A 99%-one-language repository still *shows* the languages it names.
    func testTinySegmentsAreFlooredToVisibility() {
        let bar = CodeStatsBar.make(from: stats([("Swift", 99_900), ("YAML", 50), ("JSON", 50)]))
        let widths = bar.widths(totalWidth: 300, gap: 1, minimumWidth: 2)

        XCTAssertGreaterThanOrEqual(widths[1], 2)
        XCTAssertGreaterThanOrEqual(widths[2], 2)
        XCTAssertGreaterThan(widths[0], 280)
    }

    func testOrderIsPreservedLargestFirst() {
        let bar = CodeStatsBar.make(from: stats([("A", 500), ("B", 300), ("C", 200)]))
        let widths = bar.widths(totalWidth: 300, gap: 1, minimumWidth: 2)
        XCTAssertEqual(widths, widths.sorted(by: >))
    }

    func testDegradesToProportionWhenFloorsCannotFit() {
        let bar = CodeStatsBar.make(from: stats([
            ("A", 700), ("B", 100), ("C", 80), ("D", 60), ("E", 30), ("F", 20)
        ]))
        // Six floors of 2pt cannot fit in 10pt of bar; proportion is the honest fallback.
        let widths = bar.widths(totalWidth: 10, gap: 0, minimumWidth: 2)
        XCTAssertEqual(widths.reduce(0, +), 10, accuracy: 0.001)
        XCTAssertLessThan(widths.last ?? 0, 2)
    }

    func testAnEmptyBarHasNoWidths() {
        let bar = CodeStatsBar(segments: [])
        XCTAssertTrue(bar.widths(totalWidth: 300, gap: 1, minimumWidth: 2).isEmpty)
    }

    // MARK: - Locating

    /// A login shell is free to print a greeting or a version-manager warning before the
    /// answer; only the last non-empty line is the path.
    func testLocateReadsPastALoginShellGreeting() throws {
        let shell = try stubShell("echo 'Welcome to this machine'; echo '/usr/bin/true'")
        defer { try? FileManager.default.removeItem(at: shell) }

        XCTAssertEqual(
            CodeStatsRunner.locate(shell: shell.path, fileManager: OnlyTrueIsExecutable()),
            "/usr/bin/true"
        )
    }

    func testLocateAnswersNilWhenTheShellFindsNothing() throws {
        let shell = try stubShell("exit 1")
        defer { try? FileManager.default.removeItem(at: shell) }

        XCTAssertNil(CodeStatsRunner.locate(shell: shell.path, fileManager: OnlyTrueIsExecutable()))
    }

    /// Stands in for the login shell: ignores its `-l -c` arguments and runs `body`.
    private func stubShell(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-shell-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Denies the fixed candidate paths — this machine may genuinely have scc installed — so
    /// a locate test exercises the shell probe rather than short-circuiting past it.
    private final class OnlyTrueIsExecutable: FileManager {
        override func isExecutableFile(atPath path: String) -> Bool {
            path == "/usr/bin/true"
        }
    }
}
