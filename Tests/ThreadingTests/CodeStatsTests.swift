import XCTest
@testable import Threading

/// The project-stats pipeline's pure halves plus the one packaging contract that makes code
/// composition installation-free.
final class CodeStatsTests: XCTestCase {

    private struct ActivityCacheFixture: Codable, Equatable, Sendable {
        let measuredAt: Date
        let activity: ProjectActivity?
    }

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

    // MARK: - Bundled Tool

    func testBundledSCCIsExecutableAndAnswersPinnedVersion() throws {
        let executable = try XCTUnwrap(CodeStatsRunner.bundledExecutable())
        let result = try BoundedChildProcess.run(
            executable: executable,
            arguments: ["--version"],
            timeout: 5,
            maximumOutputBytes: 4_096,
            output: .standardOutput
        )

        XCTAssertEqual(result.termination, .exited(0))
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "scc version 3.7.0\n")
    }

    func testBundledSCCMeasuresAProjectFolder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Threading-CodeStats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("struct BundledCounter { let value = 1 }\n".utf8)
            .write(to: directory.appendingPathComponent("Counter.swift"))

        let stats = try XCTUnwrap(CodeStatsRunner.measure(folder: directory.path))
        XCTAssertEqual(stats.languages.first?.name, "Swift")
        XCTAssertGreaterThan(stats.totalCode, 0)
    }

    func testBundledSCCDoesNotCountClaudeWorktreesInsideAProject() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Threading-CodeStats-Worktrees-\(UUID().uuidString)", isDirectory: true)
        let worktree = directory
            .appendingPathComponent(CodeStatsDefaults.claudeWorktreesDirectory, isDirectory: true)
            .appendingPathComponent("agent-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("struct ProjectSource {}\n".utf8)
            .write(to: directory.appendingPathComponent("ProjectSource.swift"))
        try Data("struct NestedWorktreeCopy {}\n".utf8)
            .write(to: worktree.appendingPathComponent("NestedWorktreeCopy.swift"))

        let stats = try XCTUnwrap(CodeStatsRunner.measure(folder: directory.path))
        let swift = try XCTUnwrap(stats.languages.first { $0.name == "Swift" })
        XCTAssertEqual(swift.files, 1)
        XCTAssertEqual(swift.code, 1)
    }

    func testBundledSCCHonorsEveryGitIgnoreSourceAndKeepsMetadataExcluded() throws {
        let directory = try makeGitRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("Tracked.swift\nIgnored+.swift\n".utf8)
            .write(to: directory.appendingPathComponent(".gitignore"))
        try Data("struct TrackedSource {}\n".utf8)
            .write(to: directory.appendingPathComponent("Tracked.swift"))
        try git(["add", "--force", ".gitignore", "Tracked.swift"], in: directory)

        try Data("struct IgnoredByGitignore {}\n".utf8)
            .write(to: directory.appendingPathComponent("Ignored+.swift"))

        let configuredExcludes = directory.appendingPathComponent(
            ".git/info/threading-configured-excludes"
        )
        try Data("Configured*.swift\n".utf8).write(to: configuredExcludes)
        try git(["config", "core.excludesFile", configuredExcludes.path], in: directory)
        try Data("struct IgnoredByConfiguredExcludesFile {}\n".utf8)
            .write(to: directory.appendingPathComponent("ConfiguredSource.swift"))

        let localClone = directory.appendingPathComponent(".tmp,local", isDirectory: true)
        try FileManager.default.createDirectory(at: localClone, withIntermediateDirectories: true)
        try Data("struct IgnoredByInfoExclude {}\n".utf8)
            .write(to: localClone.appendingPathComponent("NestedCloneCopy.swift"))
        try Data("/.tmp,local/\n".utf8).write(
            to: directory.appendingPathComponent(".git/info/exclude")
        )

        try Data("struct GitMetadataIsNotProjectSource {}\n".utf8)
            .write(to: directory.appendingPathComponent(".git/ShouldNeverCount.swift"))

        let stats = try XCTUnwrap(CodeStatsRunner.measure(folder: directory.path))
        let swift = try XCTUnwrap(stats.languages.first { $0.name == "Swift" })
        XCTAssertEqual(swift.files, 1)
        XCTAssertEqual(swift.code, 1)
    }

    func testBundledSCCSkipsAFolderThatDisappeared() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("Threading-CodeStats-Missing-\(UUID().uuidString)")
        XCTAssertNil(CodeStatsRunner.measure(folder: missing.path))
    }

    // MARK: - Recent Activity

    func testActivityBucketsRunOldestToNewestAcrossTwelveWeeks() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let start = now.addingTimeInterval(
            -Double(ProjectActivity.bucketCount) * ProjectActivity.bucketDuration
        )
        let activity = ProjectActivity.make(
            recentCommitDates: [
                start.addingTimeInterval(1),
                start.addingTimeInterval(ProjectActivity.bucketDuration + 1),
                now.addingTimeInterval(-1),
                start.addingTimeInterval(-1)
            ],
            latestCommitAt: now.addingTimeInterval(-1),
            now: now
        )

        XCTAssertEqual(activity.weeklyCommits.count, 12)
        XCTAssertEqual(activity.weeklyCommits[0], 1)
        XCTAssertEqual(activity.weeklyCommits[1], 1)
        XCTAssertEqual(activity.weeklyCommits[11], 1)
        XCTAssertEqual(activity.commitCount, 3, "A timestamp before the window is not counted")
    }

    func testActivityKeepsAQuietWindowAndOlderLatestCommit() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let latest = now.addingTimeInterval(-20 * ProjectActivity.bucketDuration)
        let activity = ProjectActivity.make(
            recentCommitDates: [],
            latestCommitAt: latest,
            now: now
        )

        XCTAssertEqual(activity.weeklyCommits, Array(repeating: 0, count: 12))
        XCTAssertEqual(activity.commitCount, 0)
        XCTAssertEqual(activity.latestCommitAt, latest)
    }

    func testActivityTimestampParserFailsClosedOnMalformedGitOutput() {
        XCTAssertEqual(
            ProjectActivityRunner.parseTimestamps(Data("2000000000\n1999999000\n".utf8)),
            [Date(timeIntervalSince1970: 2_000_000_000), Date(timeIntervalSince1970: 1_999_999_000)]
        )
        XCTAssertNil(ProjectActivityRunner.parseTimestamps(Data("2000000000\nnot-a-date\n".utf8)))
    }

    func testActivityRunnerScopesHistoryToTheProjectFolder() throws {
        let root = try makeGitRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        let neighboringFolder = root.appendingPathComponent("neighbor", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: neighboringFolder,
            withIntermediateDirectories: true
        )

        let now = Date()
        let projectCommit = now.addingTimeInterval(-3 * 24 * 60 * 60)
        try Data("let project = true\n".utf8)
            .write(to: project.appendingPathComponent("Project.swift"))
        try git(["add", "."], in: root)
        try gitCommit("project", at: projectCommit, in: root)

        try Data("not part of the project folder\n".utf8)
            .write(to: neighboringFolder.appendingPathComponent("README.md"))
        try git(["add", "."], in: root)
        try gitCommit("neighbor", at: now.addingTimeInterval(-24 * 60 * 60), in: root)

        guard case .activity(let activity) = ProjectActivityRunner.measure(
            folder: project.path,
            now: now
        ) else {
            return XCTFail("Expected path-scoped Git activity")
        }
        XCTAssertEqual(activity.commitCount, 1)
        XCTAssertEqual(activity.weeklyCommits.reduce(0, +), 1)
        XCTAssertEqual(
            try XCTUnwrap(activity.latestCommitAt).timeIntervalSince1970,
            Double(Int(projectCommit.timeIntervalSince1970)),
            accuracy: 0.001
        )
    }

    func testActivityRunnerDistinguishesNonRepositoryAndUnbornRepository() throws {
        let nonRepository = FileManager.default.temporaryDirectory
            .appendingPathComponent("Threading-Activity-Plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: nonRepository,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: nonRepository) }
        XCTAssertEqual(
            ProjectActivityRunner.measure(folder: nonRepository.path),
            .notRepository
        )

        let unborn = try makeGitRepository()
        defer { try? FileManager.default.removeItem(at: unborn) }
        guard case .activity(let activity) = ProjectActivityRunner.measure(folder: unborn.path)
        else {
            return XCTFail("Expected an empty activity reading for an unborn repository")
        }
        XCTAssertEqual(activity.weeklyCommits, Array(repeating: 0, count: 12))
        XCTAssertEqual(activity.commitCount, 0)
        XCTAssertNil(activity.latestCommitAt)
        XCTAssertFalse(activity.isTruncated)
    }

    func testProjectStatsCacheWriterCoalescesExactUpdatesAndPreservesExistingValues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Threading-ProjectStats-Writer-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.json")
        let preservedID = ProjectID()
        let changedID = ProjectID()
        let store = RecoverableFileStore<[ProjectID: Int]>(
            url: url,
            fileManager: .default,
            criticality: .rebuildableCache,
            sizePolicy: .derivedCache
        )
        XCTAssertTrue(store.save([preservedID: 7]))

        let writer = ProjectStatsCacheWriter(
            store: store,
            cacheKind: "test",
            coalescingInterval: 60
        )
        writer.schedule(1, for: changedID)
        writer.schedule(2, for: changedID)

        XCTAssertTrue(writer.flushForTesting())
        XCTAssertEqual(writer.completedWriteCountForTesting, 1)
        XCTAssertEqual(writer.lastBatchSizeForTesting, 2)

        let reader = RecoverableFileStore<[ProjectID: Int]>(
            url: url,
            fileManager: .default,
            criticality: .rebuildableCache,
            sizePolicy: .derivedCache
        )
        let persisted = reader.load(defaultValue: [:]).value
        XCTAssertEqual(persisted[preservedID], 7)
        XCTAssertEqual(persisted[changedID], 2)
    }

    /// Compares the old per-completion whole-cache rewrite with the current exact-update worker.
    /// Opt-in because it is a performance comparison, not a correctness test.
    func testStressProjectStatsPersistenceWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["THREADING_PROJECT_STATS_STRESS"] == "1"
        else { throw XCTSkip("Set THREADING_PROJECT_STATS_STRESS=1") }

        let count = Int(
            ProcessInfo.processInfo.environment["THREADING_PROJECT_STATS_STRESS_COUNT"] ?? "250"
        ) ?? 250
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Threading-ProjectStats-Stress-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("activity-whole-cache.json")
        let store = RecoverableFileStore<[ProjectID: ActivityCacheFixture]>(
            url: url,
            fileManager: .default,
            criticality: .rebuildableCache,
            sizePolicy: .derivedCache,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )
        let activity = ProjectActivity(
            weeklyCommits: Array(1...ProjectActivity.bucketCount),
            commitCount: 78,
            latestCommitAt: Date(timeIntervalSince1970: 2_000_000_000),
            isTruncated: false
        )
        let fixture = ActivityCacheFixture(
            measuredAt: Date(timeIntervalSince1970: 2_000_000_001),
            activity: activity
        )
        let updates = (0..<count).map { _ in (ProjectID(), fixture) }
        var cache: [ProjectID: ActivityCacheFixture] = [:]
        cache.reserveCapacity(count)
        var samples: [UInt64] = []
        samples.reserveCapacity(count)

        let totalStarted = DispatchTime.now().uptimeNanoseconds
        for (projectID, reading) in updates {
            cache[projectID] = reading
            let started = DispatchTime.now().uptimeNanoseconds
            XCTAssertTrue(store.save(cache))
            samples.append(DispatchTime.now().uptimeNanoseconds - started)
        }
        let total = DispatchTime.now().uptimeNanoseconds - totalStarted
        let ordered = samples.sorted()
        let p95Index = Int((Double(max(ordered.count - 1, 0)) * 0.95).rounded(.up))
        let bytes = (try? Data(contentsOf: url).count) ?? 0
        print(
            "THREADING_PERF project-stats-persistence mode=whole-cache-per-result "
                + "projects=\(count) writes=\(samples.count) bytes=\(bytes) "
                + "total_ms=\(Self.milliseconds(total)) "
                + "p95_ms=\(Self.milliseconds(ordered[p95Index])) "
                + "max_ms=\(Self.milliseconds(ordered.last ?? 0))"
        )

        let coalescedURL = root.appendingPathComponent("activity-coalesced.json")
        let coalescedStore = RecoverableFileStore<[ProjectID: ActivityCacheFixture]>(
            url: coalescedURL,
            fileManager: .default,
            criticality: .rebuildableCache,
            sizePolicy: .derivedCache,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )
        let writer = ProjectStatsCacheWriter(
            store: coalescedStore,
            cacheKind: "stress",
            coalescingInterval: 60
        )
        // The app opens its first performance span during launch. Do the same outside this
        // boundary so the comparison measures cache work, not OSSignposter initialization.
        let recorderWarmup = PerformanceRecorder.shared.begin(
            "project-stats.cache-stress-warmup",
            category: "test"
        )
        recorderWarmup.end()
        let coalescedStarted = DispatchTime.now().uptimeNanoseconds
        for (projectID, reading) in updates {
            writer.schedule(reading, for: projectID)
        }
        let enqueueElapsed = DispatchTime.now().uptimeNanoseconds - coalescedStarted
        XCTAssertTrue(writer.flushForTesting())
        let coalescedElapsed = DispatchTime.now().uptimeNanoseconds - coalescedStarted

        let coalescedReader = RecoverableFileStore<[ProjectID: ActivityCacheFixture]>(
            url: coalescedURL,
            fileManager: .default,
            criticality: .rebuildableCache,
            sizePolicy: .derivedCache,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )
        let persisted = coalescedReader.load(defaultValue: [:]).value
        XCTAssertEqual(persisted.count, count)
        XCTAssertEqual(persisted, cache)
        let coalescedBytes = (try? Data(contentsOf: coalescedURL).count) ?? 0
        print(
            "THREADING_PERF project-stats-persistence mode=coalesced-exact-worker "
                + "projects=\(count) updates=\(updates.count) "
                + "writes=\(writer.completedWriteCountForTesting) "
                + "batch=\(writer.lastBatchSizeForTesting) bytes=\(coalescedBytes) "
                + "enqueue_ms=\(Self.milliseconds(enqueueElapsed)) "
                + "total_ms=\(Self.milliseconds(coalescedElapsed))"
        )
    }

    // MARK: - Git Fixture

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }

    private func makeGitRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Threading-Activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--quiet"], in: root)
        return root
    }

    private func gitCommit(_ message: String, at date: Date, in directory: URL) throws {
        let timestamp = "@\(Int(date.timeIntervalSince1970)) +0000"
        try git(
            [
                "-c", "user.email=tests@threading.codes",
                "-c", "user.name=Threading Tests",
                "-c", "commit.gpgsign=false",
                "commit", "--quiet", "--message", message
            ],
            in: directory,
            environment: ["GIT_AUTHOR_DATE": timestamp, "GIT_COMMITTER_DATE": timestamp]
        )
    }

    private func git(
        _ arguments: [String],
        in directory: URL,
        environment additions: [String: String] = [:]
    ) throws {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        for (key, value) in additions { environment[key] = value }

        let result = try BoundedChildProcess.run(
            executable: GitDefaults.executablePath,
            arguments: arguments,
            environment: environment,
            workingDirectory: directory,
            timeout: 5,
            maximumOutputBytes: 64 * 1_024
        )
        XCTAssertEqual(
            result.termination,
            .exited(0),
            "git \(arguments.joined(separator: " ")): \(String(decoding: result.output, as: UTF8.self))"
        )
    }
}
