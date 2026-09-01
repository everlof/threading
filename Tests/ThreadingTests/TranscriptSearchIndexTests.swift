@testable import Threading
import XCTest

final class TranscriptSearchIndexTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!
    private var transcriptURL: URL!
    private let projectID = ProjectID()
    private let sessionID = SessionID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptSearchIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("search.sqlite")
        transcriptURL = directory.appendingPathComponent("rollout.jsonl")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    func testNormalizationIndexesDialogueAndToolSubjectButNotReasoningOrRawOutput() throws {
        try write([
            codexUser("find the cobalt marker"),
            codexAgent("the vermilion answer"),
            #"{"type":"event_msg","payload":{"type":"agent_reasoning","text":"private chartreuse thought"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","call_id":"c1","name":"shell","arguments":"{\"command\":\"touch /tmp/cerulean-file\"}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"raw magenta tool output"}}"#,
        ])

        let result = TranscriptReplay.searchRecords(
            at: transcriptURL,
            kind: .codex,
            scanLimit: .max
        )

        XCTAssertTrue(result.records.contains { $0.body.contains("cobalt marker") })
        XCTAssertTrue(result.records.contains { $0.body.contains("vermilion answer") })
        XCTAssertTrue(result.records.contains { $0.body.contains("cerulean-file") })
        XCTAssertFalse(result.records.contains { $0.body.contains("chartreuse") })
        XCTAssertFalse(result.records.contains { $0.body.contains("magenta") })
        XCTAssertEqual(Set(result.records.map(\.recordID)).count, result.records.count)
        XCTAssertGreaterThan(result.endOffset, 0)
    }

    func testIndexReturnsTypedStableConversationLocatorAndHonoursFilters() async throws {
        try write([codexUser("needle in durable history")])
        let index = try TranscriptSearchIndex(databaseURL: databaseURL)
        await index.refresh(sources: [source(isArchived: true)])

        let included = try await index.search(query("needle type:conversation is:archived"))
        let hit = try XCTUnwrap(included.hits.first)
        XCTAssertEqual(hit.provenance.projectID, projectID)
        XCTAssertEqual(hit.provenance.sessionID, sessionID)
        XCTAssertEqual(hit.provenance.author, .you)
        XCTAssertTrue(hit.provenance.isArchived)
        guard case let .conversation(locator) = hit.locator else {
            return XCTFail("Expected a conversation locator")
        }
        XCTAssertEqual(locator.projectID, projectID)
        XCTAssertEqual(locator.sessionID, sessionID)
        XCTAssertEqual(locator.sourceGeneration, 1)
        XCTAssertTrue(locator.recordID.rawValue.contains(":"))

        let excluded = try await index.search(query("needle -is:archived"))
        XCTAssertTrue(excluded.hits.isEmpty)
    }

    func testAppendIsIncrementalAndRewriteInvalidatesOldRowsAndGeneration() async throws {
        try write([codexUser("first amber term")])
        let index = try TranscriptSearchIndex(databaseURL: databaseURL)
        await index.refresh(sources: [source()])
        let initialAmber = try await index.search(query("amber"))
        XCTAssertEqual(initialAmber.hits.count, 1)

        try append(codexAgent("second indigo term") + "\n")
        await index.refresh(sources: [source()])
        let appended = try await index.search(query("indigo"))
        XCTAssertEqual(appended.hits.count, 1)
        guard case let .conversation(appendedLocator) = appended.hits[0].locator else {
            return XCTFail("Expected a conversation locator")
        }
        XCTAssertEqual(appendedLocator.sourceGeneration, 1)
        let appendedAmber = try await index.search(query("amber"))
        XCTAssertEqual(appendedAmber.hits.count, 1)

        try write([codexUser("replacement violet term")])
        await index.refresh(sources: [source()])
        let rewrittenAmber = try await index.search(query("amber"))
        XCTAssertTrue(rewrittenAmber.hits.isEmpty)
        let rewrittenViolet = try await index.search(query("violet"))
        let replacement = try XCTUnwrap(rewrittenViolet.hits.first)
        guard case let .conversation(replacementLocator) = replacement.locator else {
            return XCTFail("Expected a conversation locator")
        }
        XCTAssertEqual(replacementLocator.sourceGeneration, 2)
    }

    func testHistoricalWindowIsBoundedAroundExactSourceRecord() async throws {
        try write((0 ..< 15).map { index in
            codexUser(index == 7 ? "the centered ultramarine target" : "ordinary row \(index)")
        })
        let index = try TranscriptSearchIndex(databaseURL: databaseURL)
        await index.refresh(sources: [source()])
        let result = try await index.search(query("ultramarine"))
        let hit = try XCTUnwrap(result.hits.first)
        guard case let .conversation(locator) = hit.locator else {
            return XCTFail("Expected a conversation locator")
        }

        let window = try await ConversationWindowLoader(index: index).load(
            centeredOn: locator,
            radius: 3
        )

        XCTAssertEqual(window.rows.count, 7)
        XCTAssertEqual(window.rows[3].id, window.anchorRowID)
        XCTAssertEqual(window.rows[3].body, "the centered ultramarine target")
        XCTAssertEqual(window.anchorMatch, SearchTextRange(utf16Location: 13, utf16Length: 11))
        XCTAssertTrue(window.hasEarlier)
        XCTAssertTrue(window.hasLater)
    }

    func testHistoricalWindowRejectsARewrittenAnchorBeforeRefresh() async throws {
        try write([
            codexUser("prefix row"),
            codexUser("middle sapphire target"),
            codexUser("suffix row"),
        ])
        let index = try TranscriptSearchIndex(databaseURL: databaseURL)
        await index.refresh(sources: [source()])
        let result = try await index.search(query("sapphire"))
        let hit = try XCTUnwrap(result.hits.first)
        guard case let .conversation(locator) = hit.locator else {
            return XCTFail("Expected a conversation locator")
        }

        try write([
            codexUser("prefix row"),
            codexUser("middle charcoal target"),
            codexUser("suffix row"),
        ])

        do {
            _ = try await ConversationWindowLoader(index: index).load(centeredOn: locator)
            XCTFail("A rewritten provider record must not open stale indexed text")
        } catch let error as ConversationWindowLoadError {
            XCTAssertEqual(error, .resultNoLongerAvailable)
        }
    }

    func testHistoricalWindowClipsALongAnchorAroundTheExactMatch() async throws {
        let prefix = String(repeating: "p", count: 20000)
        let suffix = String(repeating: "s", count: 20000)
        try write([codexUser(prefix + " ultramarine " + suffix)])
        let index = try TranscriptSearchIndex(databaseURL: databaseURL)
        await index.refresh(sources: [source()])
        let result = try await index.search(query("ultramarine"))
        let hit = try XCTUnwrap(result.hits.first)
        guard case let .conversation(locator) = hit.locator else {
            return XCTFail("Expected a conversation locator")
        }

        let window = try await ConversationWindowLoader(index: index).load(
            centeredOn: locator,
            radius: 1
        )
        let anchor = try XCTUnwrap(window.rows.first)
        let match = try XCTUnwrap(window.anchorMatch)

        XCTAssertLessThan(anchor.body.utf8.count, TranscriptSearchIndex.maximumWindowRowUTF8Bytes + 16)
        XCTAssertTrue(anchor.body.hasPrefix("…\n"))
        XCTAssertTrue(anchor.body.hasSuffix("\n…"))
        XCTAssertEqual(
            (anchor.body as NSString).substring(with: NSRange(
                location: match.utf16Location,
                length: match.utf16Length
            )),
            "ultramarine"
        )
    }

    func testIndexMakesProgressPastARecordLargerThanOneIngestionPass() async throws {
        let oversized = #"{"type":"ignored","payload":""#
            + String(repeating: "x", count: TranscriptSearchIndex.ingestionScanBytes + 1024)
            + #""}"#
        try write([oversized, codexUser("target after oversized record")])
        let index = try TranscriptSearchIndex(databaseURL: databaseURL)

        await index.refresh(sources: [source()])

        let result = try await index.search(query("oversized"))
        XCTAssertEqual(result.hits.count, 1)
    }

    /// A refresh that changes nothing must not rewrite the indexed metadata.
    ///
    /// The rewrite is `UPDATE transcript_search_fts … WHERE source_id = ?`, and FTS5 has no index
    /// on `source_id`, so SQLite answers it by scanning every indexed row in the database and
    /// re-tokenizing each one it matches. It used to run unconditionally, once per source per
    /// refresh — 40-90 ms each against a real 350-source index, and `ProjectsDidChange` restarts a
    /// refresh, so renaming one session paid for all of them.
    func testRepeatedRefreshOfUnchangedMetadataRewritesNothing() async throws {
        try write([codexUser("stable saffron term")])
        let index = try TranscriptSearchIndex(databaseURL: databaseURL)

        await index.refresh(sources: [source()])
        let afterFirst = await index.metadataRewriteCount
        XCTAssertEqual(afterFirst, 1, "The first pass has no recorded signature to compare against")

        for _ in 0 ..< 5 { await index.refresh(sources: [source()]) }
        let afterRepeats = await index.metadataRewriteCount
        XCTAssertEqual(afterRepeats, 1, "An unchanged source must not be rewritten again")

        // The guard must not have cost the index its answer.
        let found = try await index.search(query("saffron"))
        XCTAssertEqual(found.hits.count, 1)
    }

    /// Appending to a transcript indexes the new rows without rewriting the standing ones: the
    /// appended rows are inserted carrying current metadata, so nothing is stale.
    func testAppendingToATranscriptDoesNotRewriteMetadata() async throws {
        try write([codexUser("first sienna term")])
        let index = try TranscriptSearchIndex(databaseURL: databaseURL)
        await index.refresh(sources: [source()])

        try append(codexAgent("second sienna term") + "\n")
        await index.refresh(sources: [source()])

        let rewrites = await index.metadataRewriteCount
        XCTAssertEqual(rewrites, 1)
        let found = try await index.search(query("sienna"))
        XCTAssertEqual(found.hits.count, 2)
    }

    /// The other half of the contract: when the labels genuinely move, the standing rows are
    /// rewritten, so they are still found by what they are now called rather than what they were.
    func testRenamingASessionRewritesStandingRowsExactlyOnce() async throws {
        try write([codexUser("titled cerise term")])
        let index = try TranscriptSearchIndex(databaseURL: databaseURL)
        await index.refresh(sources: [source()])

        await index.refresh(sources: [source(sessionTitle: "Renamed conversation")])
        let afterRename = await index.metadataRewriteCount
        XCTAssertEqual(afterRename, 2, "A changed title must reach the standing rows")

        let renamed = try await index.search(query("cerise"))
        let hit = try XCTUnwrap(renamed.hits.first)
        XCTAssertEqual(hit.provenance.sessionTitle, "Renamed conversation")

        // Settling again is free.
        await index.refresh(sources: [source(sessionTitle: "Renamed conversation")])
        let afterSettle = await index.metadataRewriteCount
        XCTAssertEqual(afterSettle, 2)
    }

    /// Archiving is a metadata change like any other, and `is:archived` filters on the column it
    /// writes — so the guard must not strand a conversation on the wrong side of that filter.
    func testArchivingRewritesRowsSoTheArchivedFilterFollows() async throws {
        try write([codexUser("filed puce term")])
        let index = try TranscriptSearchIndex(databaseURL: databaseURL)
        await index.refresh(sources: [source(isArchived: false)])
        let beforeArchiving = try await index.search(query("puce is:archived"))
        XCTAssertTrue(beforeArchiving.hits.isEmpty)

        await index.refresh(sources: [source(isArchived: true)])

        let afterArchiving = try await index.search(query("puce is:archived"))
        XCTAssertEqual(afterArchiving.hits.count, 1)
        XCTAssertTrue(try XCTUnwrap(afterArchiving.hits.first).provenance.isArchived)
    }

    /// The signature lives in the database, not in the actor, so a relaunch inherits the work the
    /// previous one did rather than rewriting every source once per launch.
    func testARecordedSignatureSurvivesReopeningTheIndex() async throws {
        try write([codexUser("persistent teal term")])
        let first = try TranscriptSearchIndex(databaseURL: databaseURL)
        await first.refresh(sources: [source()])
        let firstRewrites = await first.metadataRewriteCount
        XCTAssertEqual(firstRewrites, 1)

        let reopened = try TranscriptSearchIndex(databaseURL: databaseURL)
        await reopened.refresh(sources: [source()])

        let reopenedRewrites = await reopened.metadataRewriteCount
        XCTAssertEqual(
            reopenedRewrites,
            0,
            "A relaunch must not rewrite metadata the previous run already applied"
        )
        let stillFound = try await reopened.search(query("teal"))
        XCTAssertEqual(stillFound.hits.count, 1)
    }

    private func source(
        isArchived: Bool = false,
        sessionTitle: String = "Search conversation"
    ) -> TranscriptSearchSource {
        TranscriptSearchSource(
            sourceID: SearchSourceID(rawValue: "codex:test:transcript"),
            url: transcriptURL,
            kind: .codex,
            projectID: projectID,
            projectName: "Index Project",
            sessionID: sessionID,
            sessionTitle: sessionTitle,
            providerName: "Codex",
            isArchived: isArchived,
            updatedAt: Date(timeIntervalSince1970: 1000)
        )
    }

    private func query(_ text: String) throws -> SearchQuery {
        try SearchQueryParser.parse(text, scope: .everywhere, generation: 1).get()
    }

    private func codexUser(_ text: String) -> String {
        #"{"type":"event_msg","timestamp":"2026-08-31T10:00:00Z","payload":{"type":"user_message","message":"\#(text)"}}"#
    }

    private func codexAgent(_ text: String) -> String {
        #"{"type":"event_msg","timestamp":"2026-08-31T10:01:00Z","payload":{"type":"agent_message","message":"\#(text)"}}"#
    }

    private func write(_ records: [String]) throws {
        try Data((records.joined(separator: "\n") + "\n").utf8).write(to: transcriptURL)
    }

    private func append(_ value: String) throws {
        let handle = try FileHandle(forWritingTo: transcriptURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(value.utf8))
    }
}
