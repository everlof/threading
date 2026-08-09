import XCTest
@testable import Threading

final class UsageLimitHistoryJournalTests: XCTestCase {
    func testDailyJournalRoundTripsBoundsRetentionAndUsesPrivatePermissions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-limit-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let old = sample(at: now.addingTimeInterval(-181 * 86_400), fraction: 0.2)
        let first = sample(at: now.addingTimeInterval(-3_600), fraction: 0.4)
        let second = sample(at: now, fraction: 0.5)
        let journal = UsageLimitHistoryJournal(directory: directory)

        try await journal.append(samples: [old, first, second], resets: [], now: now)

        let reloaded = await UsageLimitHistoryJournal(directory: directory).load(now: now)
        XCTAssertEqual(reloaded.samples, [first, second])

        let directoryMode = try permissionMode(at: directory)
        XCTAssertEqual(directoryMode, 0o700)
        let journalURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "jsonl" })
        )
        XCTAssertEqual(try permissionMode(at: journalURL), 0o600)
    }

    func testJournalDeduplicatesResetEventsAndDeleteLeavesDirectoryIntact() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-limit-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let event = reset(at: now)
        let journal = UsageLimitHistoryJournal(directory: directory)
        try await journal.append(samples: [], resets: [event, event], now: now)

        let loaded = await journal.load(now: now)
        XCTAssertEqual(loaded.resets, [event])

        await journal.deleteHistory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
        )
    }

    private func sample(at: Date, fraction: Double) -> UsageSample {
        UsageSample(
            at: at,
            fraction: fraction,
            resetsAt: at.addingTimeInterval(7 * 86_400),
            runtimeID: AgentKind.codex.rawValue,
            accountID: "codex:work",
            accountName: "Work",
            windowID: "weekly",
            windowLabel: "Weekly",
            windowDuration: 7 * 86_400,
            source: .codexAPI,
            resetCreditCount: 2
        )
    }

    private func reset(at: Date) -> UsageLimitResetEvent {
        UsageLimitResetEvent(
            id: "stable-reset",
            runtimeID: AgentKind.codex.rawValue,
            accountID: "codex:work",
            accountName: "Work",
            windowID: "weekly",
            windowLabel: "Weekly",
            previousObservedAt: at.addingTimeInterval(-60),
            detectedAt: at,
            oldScheduledResetAt: at.addingTimeInterval(86_400),
            newScheduledResetAt: at.addingTimeInterval(8 * 86_400),
            restoredFraction: 0.8,
            elapsedFraction: 0.4,
            secondsEarly: 86_400,
            cause: .bankedCredit
        )
    }

    private func permissionMode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
}
