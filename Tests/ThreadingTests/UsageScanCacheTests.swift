import XCTest
@testable import Threading

final class UsageScanCacheTests: XCTestCase {
    private var directory: URL!
    private var source: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-usage-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("source.jsonl")
        try Data("one".utf8).write(to: source)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWarmSourceDoesNotParseAgain() {
        let cache = UsageScanCache(directory: directory.appendingPathComponent("cache"))
        var parseCount = 0
        cache.beginScan()
        let cold = cache.records(for: source, parserID: "fixture-v1") {
            parseCount += 1
            return [makeRecord(identity: "cold")]
        }
        cache.finishScan()

        cache.beginScan()
        let warm = cache.records(for: source, parserID: "fixture-v1") {
            parseCount += 1
            return [makeRecord(identity: "unexpected")]
        }
        cache.finishScan()

        XCTAssertFalse(cold.wasCacheHit)
        XCTAssertTrue(warm.wasCacheHit)
        XCTAssertEqual(parseCount, 1)
        XCTAssertEqual(warm.records.map(\.identity), ["cold"])
    }

    func testChangedSourceInvalidatesOnlyItsEntry() throws {
        let cache = UsageScanCache(directory: directory.appendingPathComponent("cache"))
        cache.beginScan()
        _ = cache.records(for: source, parserID: "fixture-v1") {
            [makeRecord(identity: "before")]
        }
        cache.finishScan()

        try Data("a larger revision".utf8).write(to: source, options: .atomic)
        cache.beginScan()
        let changed = cache.records(for: source, parserID: "fixture-v1") {
            [makeRecord(identity: "after")]
        }
        cache.finishScan()

        XCTAssertFalse(changed.wasCacheHit)
        XCTAssertEqual(changed.records.map(\.identity), ["after"])
    }

    func testOversizedCacheEntryIsAMissAndIsReplacedWithinTheBound() throws {
        let cacheDirectory = directory.appendingPathComponent("cache")
        let cache = UsageScanCache(directory: cacheDirectory)
        cache.beginScan()
        _ = cache.records(for: source, parserID: "fixture-v1") {
            [makeRecord(identity: "before")]
        }
        cache.finishScan()

        let entry = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        let handle = try FileHandle(forWritingTo: entry)
        try handle.truncate(atOffset: UInt64(UsageScanCacheDefaults.maximumEntryBytes + 1))
        try handle.close()

        var parses = 0
        cache.beginScan()
        let result = cache.records(for: source, parserID: "fixture-v1") {
            parses += 1
            return [makeRecord(identity: "reparsed")]
        }
        cache.finishScan()

        XCTAssertFalse(result.wasCacheHit)
        XCTAssertEqual(parses, 1)
        XCTAssertEqual(result.records.map(\.identity), ["reparsed"])
        XCTAssertLessThanOrEqual(
            try entry.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max,
            UsageScanCacheDefaults.maximumEntryBytes
        )
    }

    func testExportRevisionAvoidsRelaunchingDormantSession() throws {
        let cache = UsageScanCache(directory: directory.appendingPathComponent("cache"))
        let revision = Date(timeIntervalSince1970: 1_000)
        var exports = 0

        cache.beginScan()
        _ = try cache.records(forKey: "opencode:session", revision: revision, parserID: "export-v1") {
            exports += 1
            return [makeRecord(identity: "exported")]
        }
        cache.finishScan()

        cache.beginScan()
        let warm = try cache.records(forKey: "opencode:session", revision: revision, parserID: "export-v1") {
            exports += 1
            return []
        }
        cache.finishScan()

        XCTAssertTrue(warm.wasCacheHit)
        XCTAssertEqual(exports, 1)
        XCTAssertEqual(warm.records.map(\.identity), ["exported"])
    }

    func testLedgerIndexSkipsEnvelopeReadsAndStreamsOneGloballyDistinctRecord() throws {
        let cacheDirectory = directory.appendingPathComponent("cache")
        let secondSource = directory.appendingPathComponent("second.jsonl")
        try Data("two".utf8).write(to: secondSource)
        let cache = UsageScanCache(directory: cacheDirectory)
        let index = try UsageLedgerIndex(directory: cacheDirectory)
        var loads = 0

        cache.beginScan()
        index.beginScan()
        for candidate in [source!, secondSource] {
            _ = try index.update(source: candidate, parserID: "fixture-v1") {
                loads += 1
                return cache.records(for: candidate, parserID: "fixture-v1") {
                    [makeRecord(identity: "shared")]
                }
            }
        }
        XCTAssertEqual(try index.finishScan(), 2, "raw coverage still counts both sources")
        cache.finishScan()

        cache.beginScan()
        index.beginScan()
        for candidate in [source!, secondSource] {
            let warm = try index.update(source: candidate, parserID: "fixture-v1") {
                loads += 1
                XCTFail("an unchanged indexed source decoded its envelope")
                return cache.records(for: candidate, parserID: "fixture-v1") { [] }
            }
            XCTAssertTrue(warm.wasCacheHit)
        }
        XCTAssertEqual(try index.finishScan(), 2)
        cache.finishScan()

        var streamed: [UsageLedgerRecord] = []
        try index.forEachRecord { streamed.append($0) }
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(streamed.map(\.identity), ["shared"])
    }

    func testFailedReplacementRemovesStaleCompleteSourceFromLedger() throws {
        enum FixtureFailure: Error { case unreadable }

        let cacheDirectory = directory.appendingPathComponent("strict-index")
        let index = try UsageLedgerIndex(directory: cacheDirectory)
        index.beginScan()
        _ = try index.update(source: source, parserID: "fixture-v1") {
            UsageScanCache.Result(
                records: [makeRecord(identity: "old-complete")],
                wasCacheHit: false
            )
        }
        XCTAssertEqual(try index.finishScan(), 1)

        try Data("changed unreadable revision".utf8).write(to: source, options: .atomic)
        index.beginScan()
        XCTAssertThrowsError(try index.update(source: source, parserID: "fixture-v1") {
            throw FixtureFailure.unreadable
        })
        XCTAssertEqual(
            try index.finishScan(),
            0,
            "a partial scan must not retain the previous revision as current usage"
        )

        var streamed: [UsageLedgerRecord] = []
        try index.forEachRecord { streamed.append($0) }
        XCTAssertTrue(streamed.isEmpty)
    }

    func testParserGenerationLeavesLegacyLedgerUntouchedUntilFileLevelCommit() throws {
        let cacheDirectory = directory.appendingPathComponent("generation-cache")
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let legacyURL = cacheDirectory.appendingPathComponent(
            UsageLedgerIndexDefaults.legacyFileName
        )
        do {
            let legacy = try SQLiteDatabase(path: legacyURL.path)
            try legacy.execute("CREATE TABLE sentinel(value TEXT NOT NULL)")
            try legacy.execute("INSERT INTO sentinel(value) VALUES ('old-generation')")
            legacy.close()
        }
        let legacyBytes = try Data(contentsOf: legacyURL)
        let legacyWAL = URL(fileURLWithPath: legacyURL.path + "-wal")
        let legacySHM = URL(fileURLWithPath: legacyURL.path + "-shm")
        try Data("obsolete-wal".utf8).write(to: legacyWAL)
        try Data("obsolete-shm".utf8).write(to: legacySHM)

        let generation = "fixture-generation-v2"
        let index = try UsageLedgerIndex(
            directory: cacheDirectory,
            parserGenerationID: generation
        )
        index.beginScan()
        _ = try index.update(source: source, parserID: "fixture-v2") {
            UsageScanCache.Result(
                records: [makeRecord(identity: "new-generation")],
                wasCacheHit: false
            )
        }
        XCTAssertEqual(try index.finishScan(), 1)

        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyWAL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacySHM.path))

        try index.commitGeneration()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyWAL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacySHM.path))
        let currentName = UsageLedgerIndexDefaults.fileName(
            forParserGenerationID: generation
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cacheDirectory.appendingPathComponent(currentName).path
        ))
        let manifest = try String(
            contentsOf: cacheDirectory.appendingPathComponent(
                UsageLedgerIndexDefaults.manifestFileName
            ),
            encoding: .utf8
        )
        XCTAssertTrue(manifest.contains(currentName))
    }

    func testCommitPreservesFutureSchemaDatabaseAndSidecars() throws {
        let cacheDirectory = directory.appendingPathComponent("future-schema-cache")
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let futureVersion = UsageLedgerIndexDefaults.schemaVersion + 1
        let futureName = "\(UsageLedgerIndexDefaults.fileNamePrefix)\(futureVersion)-future.sqlite"
        let futureURLs = ([""] + UsageLedgerIndexDefaults.sidecarSuffixes).map { suffix in
            cacheDirectory.appendingPathComponent(futureName + suffix)
        }
        for (index, url) in futureURLs.enumerated() {
            try Data("future-artifact-\(index)".utf8).write(to: url)
        }
        let futureManifest = Data(
            """
            {"schemaVersion":\(futureVersion),"parserGenerationID":"future",\
            "databaseFileName":"\(futureName)"}
            """.utf8
        )
        let manifestURL = cacheDirectory.appendingPathComponent(
            UsageLedgerIndexDefaults.manifestFileName
        )
        try futureManifest.write(to: manifestURL)

        let index = try UsageLedgerIndex(
            directory: cacheDirectory,
            parserGenerationID: "fixture-current-schema"
        )
        index.beginScan()
        _ = try index.update(source: source, parserID: "fixture-current") {
            UsageScanCache.Result(
                records: [makeRecord(identity: "current")],
                wasCacheHit: false
            )
        }
        XCTAssertEqual(try index.finishScan(), 1)
        try index.commitGeneration()

        for (artifactIndex, url) in futureURLs.enumerated() {
            XCTAssertEqual(
                try Data(contentsOf: url),
                Data("future-artifact-\(artifactIndex)".utf8),
                "a downgraded build must not retire a future-schema ledger artifact"
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: manifestURL),
            futureManifest,
            "a downgraded build must not replace the future build's durable ledger pointer"
        )
    }

    func testAbandonedParserGenerationKeepsCommittedLedgerAndResumesPerSource() throws {
        let cacheDirectory = directory.appendingPathComponent("resumable-generation-cache")
        let secondSource = directory.appendingPathComponent("second-generation-source.jsonl")
        try Data("two".utf8).write(to: secondSource)
        let oldGeneration = "fixture-generation-v1"
        let newGeneration = "fixture-generation-v2"
        let oldName = UsageLedgerIndexDefaults.fileName(
            forParserGenerationID: oldGeneration
        )
        let newName = UsageLedgerIndexDefaults.fileName(
            forParserGenerationID: newGeneration
        )

        var oldIndex: UsageLedgerIndex? = try UsageLedgerIndex(
            directory: cacheDirectory,
            parserGenerationID: oldGeneration
        )
        oldIndex?.beginScan()
        _ = try oldIndex?.update(source: source, parserID: "fixture-v1") {
            UsageScanCache.Result(
                records: [makeRecord(identity: "old")],
                wasCacheHit: false
            )
        }
        XCTAssertEqual(try oldIndex?.finishScan(), 1)
        try oldIndex?.commitGeneration()
        oldIndex = nil

        var stagingIndex: UsageLedgerIndex? = try UsageLedgerIndex(
            directory: cacheDirectory,
            parserGenerationID: newGeneration
        )
        stagingIndex?.beginScan()
        _ = try stagingIndex?.update(source: source, parserID: "fixture-v2") {
            UsageScanCache.Result(
                records: [makeRecord(identity: "resumed")],
                wasCacheHit: false
            )
        }
        stagingIndex = nil // Simulates process loss before finish/commit.

        let manifestURL = cacheDirectory.appendingPathComponent(
            UsageLedgerIndexDefaults.manifestFileName
        )
        XCTAssertTrue(try String(contentsOf: manifestURL, encoding: .utf8).contains(oldName))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cacheDirectory.appendingPathComponent(oldName).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cacheDirectory.appendingPathComponent(newName).path
        ))

        let resumedIndex = try UsageLedgerIndex(
            directory: cacheDirectory,
            parserGenerationID: newGeneration
        )
        resumedIndex.beginScan()
        let resumed = try resumedIndex.update(source: source, parserID: "fixture-v2") {
            XCTFail("the completed source in an abandoned generation should resume warm")
            return UsageScanCache.Result(records: [], wasCacheHit: false)
        }
        XCTAssertTrue(resumed.wasCacheHit)
        _ = try resumedIndex.update(source: secondSource, parserID: "fixture-v2") {
            UsageScanCache.Result(
                records: [makeRecord(identity: "second")],
                wasCacheHit: false
            )
        }
        XCTAssertEqual(try resumedIndex.finishScan(), 2)

        var streamed: [UsageLedgerRecord] = []
        try resumedIndex.forEachRecord { streamed.append($0) }
        XCTAssertEqual(Set(streamed.map(\.identity)), ["resumed", "second"])
        try resumedIndex.commitGeneration()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: cacheDirectory.appendingPathComponent(oldName).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cacheDirectory.appendingPathComponent(newName).path
        ))
        XCTAssertTrue(try String(contentsOf: manifestURL, encoding: .utf8).contains(newName))
    }

    func testCacheEnforcesOneAggregateDirectoryBound() throws {
        let cacheDirectory = directory.appendingPathComponent("bounded-cache")
        let maximumBytes: Int64 = 2_500
        let cache = UsageScanCache(
            directory: cacheDirectory,
            maximumTotalBytes: maximumBytes
        )
        let sources = (0..<4).map { index in
            directory.appendingPathComponent("source-\(index).jsonl")
        }
        for (index, candidate) in sources.enumerated() {
            try Data("source-\(index)".utf8).write(to: candidate)
        }

        cache.beginScan()
        for (index, candidate) in sources.enumerated() {
            _ = cache.records(for: candidate, parserID: "fixture-v1") {
                [makeRecord(identity: String(repeating: "x", count: 900) + "-\(index)")]
            }
        }
        cache.finishScan()

        let total = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ).filter { $0.pathExtension == UsageScanCacheDefaults.extensionName }
            .reduce(Int64(0)) { sum, url in
                sum + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
        XCTAssertLessThanOrEqual(total, maximumBytes)
    }

    private func makeRecord(identity: String) -> UsageLedgerRecord {
        UsageLedgerRecord(
            identity: identity,
            sessionID: "session",
            at: Date(timeIntervalSince1970: 1_000),
            origin: .direct(.claude),
            accountID: "claude:default",
            accountName: "Claude",
            model: "model",
            workingDirectory: "/work",
            tokens: .init(uncachedInput: 1)
        )
    }
}
