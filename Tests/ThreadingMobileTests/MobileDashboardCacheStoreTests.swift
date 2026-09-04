@testable import ThreadingMobile
import ThreadingRemoteKit
import XCTest

final class MobileDashboardCacheStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MobileDashboardCacheStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSnapshotReloadsForTheExactPairingOnly() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try XCTUnwrap(MobileDashboardCacheSnapshot.make(
            from: response(),
            capturedAt: now
        ))
        let store = MobileDashboardCacheStore(suiteName: suiteName)

        let remembered = await store.remember(snapshot, for: "pairing-a")
        XCTAssertTrue(remembered)

        let reloaded = MobileDashboardCacheStore(suiteName: suiteName)
        let catalogues = await reloaded.loadCatalogues(at: now)
        XCTAssertEqual(catalogues["pairing-a"]?.sessions.map(\.id), ["session-a"])
        XCTAssertNil(catalogues["pairing-b"])
    }

    func testCachedProjectionDropsTransientLiveClaims() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try XCTUnwrap(MobileDashboardCacheSnapshot.make(
            from: response(),
            capturedAt: now
        ))
        let cached = try XCTUnwrap(MobileDashboardCatalogue.current(
            live: nil,
            cached: snapshot,
            now: now
        ))
        let session = try XCTUnwrap(cached.sessions.first)
        let terminal = try XCTUnwrap(cached.terminals.first)

        XCTAssertFalse(cached.isLive)
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.isShared)
        XCTAssertNil(session.terminalTheme)
        XCTAssertNil(session.accountID)
        XCTAssertEqual(terminal.state, .idle)
        XCTAssertFalse(terminal.isShared)
        XCTAssertNil(terminal.terminalTheme)
    }

    func testLiveCatalogueAtomicallyWinsOverCachedRows() throws {
        let cachedResponse = response(sessionTitle: "Saved title")
        let liveResponse = response(sessionTitle: "Current title")
        let snapshot = try XCTUnwrap(MobileDashboardCacheSnapshot.make(from: cachedResponse))
        let catalogue = try XCTUnwrap(MobileDashboardCatalogue.current(
            live: liveResponse,
            cached: snapshot
        ))

        XCTAssertTrue(catalogue.isLive)
        XCTAssertEqual(catalogue.sessions.first?.title, "Current title")
        XCTAssertEqual(catalogue.sessions.first?.state, .working)
    }

    func testExpiredShareNeverProducesACachedCatalogue() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try XCTUnwrap(MobileDashboardCacheSnapshot.make(
            from: response(expiresAt: now.addingTimeInterval(-1).timeIntervalSince1970),
            capturedAt: now.addingTimeInterval(-60)
        ))

        XCTAssertNil(MobileDashboardCatalogue.current(live: nil, cached: snapshot, now: now))
    }

    func testRemovingAPairingPurgesItsPersistedSnapshot() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try XCTUnwrap(MobileDashboardCacheSnapshot.make(
            from: response(),
            capturedAt: now
        ))
        let store = MobileDashboardCacheStore(suiteName: suiteName)
        let remembered = await store.remember(snapshot, for: "pairing-a")
        XCTAssertTrue(remembered)

        let removed = await store.remove(identity: "pairing-a")
        XCTAssertTrue(removed)

        let reloaded = MobileDashboardCacheStore(suiteName: suiteName)
        let loaded = await reloaded.load(at: now)
        XCTAssertTrue(loaded.isEmpty)
    }

    func testRemovingAPairingAlsoPurgesUnreadableRecoveryCopies() async throws {
        let recoveryKey = MobileDashboardCacheStore.unreadableKeyPrefix + "old"
        defaults.set(Data("old-cache".utf8), forKey: recoveryKey)
        let snapshot = try XCTUnwrap(MobileDashboardCacheSnapshot.make(from: response()))
        let store = MobileDashboardCacheStore(suiteName: suiteName)
        let remembered = await store.remember(snapshot, for: "pairing-a")
        XCTAssertTrue(remembered)

        let removed = await store.remove(identity: "pairing-a")
        XCTAssertTrue(removed)
        XCTAssertNil(defaults.data(forKey: recoveryKey))
    }

    func testOversizedCatalogueIsRejectedBeforeProjection() {
        let session = response().sessions[0]
        let oversized = RemoteMeDTO(
            serverProtocol: RemoteProtocolInfo(),
            share: response().share,
            sessions: Array(
                repeating: session,
                count: MobileDashboardCacheStore.maximumSessionsPerList + 1
            )
        )

        XCTAssertNil(MobileDashboardCacheSnapshot.make(from: oversized))
    }

    func testCorruptArchiveIsQuarantinedBeforeReplacement() async throws {
        let original = Data("not-json".utf8)
        defaults.set(original, forKey: MobileDashboardCacheStore.archiveKey)
        let store = MobileDashboardCacheStore(suiteName: suiteName)

        let loaded = await store.load()
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertNil(defaults.data(forKey: MobileDashboardCacheStore.archiveKey))
        XCTAssertTrue(defaults.dictionaryRepresentation().contains { key, value in
            key.hasPrefix(MobileDashboardCacheStore.unreadableKeyPrefix)
                && (value as? Data) == original
        })
        let snapshot = try XCTUnwrap(MobileDashboardCacheSnapshot.make(from: response()))
        let remembered = await store.remember(snapshot, for: "pairing-a")
        XCTAssertTrue(remembered)
    }

    func testNewerArchiveRemainsUntouchedAndDisablesWriter() async throws {
        let newer = Data(#"{"version":2,"records":[]}"#.utf8)
        defaults.set(newer, forKey: MobileDashboardCacheStore.archiveKey)
        let store = MobileDashboardCacheStore(suiteName: suiteName)
        let snapshot = try XCTUnwrap(MobileDashboardCacheSnapshot.make(from: response()))

        let loaded = await store.load()
        XCTAssertTrue(loaded.isEmpty)
        let remembered = await store.remember(snapshot, for: "pairing-a")
        XCTAssertFalse(remembered)
        XCTAssertEqual(defaults.data(forKey: MobileDashboardCacheStore.archiveKey), newer)
    }

    func testSecurityRemovalDropsANewerArchiveThatCannotBeRewritten() async {
        let newer = Data(#"{"version":2,"records":[]}"#.utf8)
        defaults.set(newer, forKey: MobileDashboardCacheStore.archiveKey)
        let store = MobileDashboardCacheStore(suiteName: suiteName)

        _ = await store.load()
        let removed = await store.remove(identity: "pairing-a")

        XCTAssertTrue(removed)
        XCTAssertNil(defaults.data(forKey: MobileDashboardCacheStore.archiveKey))
    }

    func testOnlyAuthorizationRefusalsDiscardLastGoodRows() {
        XCTAssertTrue(MobileDashboardCachePolicy.discardsSnapshot(after: RemoteClientError.unauthorized))
        XCTAssertTrue(MobileDashboardCachePolicy.discardsSnapshot(
            after: RemoteClientError.server(status: 403)
        ))
        XCTAssertFalse(MobileDashboardCachePolicy.discardsSnapshot(
            after: URLError(.timedOut)
        ))
    }

    private func response(
        sessionTitle: String = "Last good session",
        expiresAt: Double? = nil
    ) -> RemoteMeDTO {
        let terminalTheme = RemoteTerminalThemeDTO(
            id: "cache-test",
            name: "Cache test",
            foreground: "#FFFFFF",
            boldForeground: "#FFFFFF",
            background: "#000000",
            cursor: "#FFFFFF",
            selection: "#333333",
            ansi: Array(repeating: "#808080", count: 16)
        )
        return RemoteMeDTO(
            serverProtocol: RemoteProtocolInfo(),
            share: .init(
                label: "Phone",
                scope: .all,
                capability: .interact,
                expiresAt: expiresAt
            ),
            sessions: [
                RemoteSessionSummaryDTO(
                    id: "session-a",
                    title: sessionTitle,
                    agentKind: "codex",
                    surface: .conversation,
                    state: .working,
                    projectName: "Threading",
                    projectID: "project-a",
                    isAvailable: true,
                    lastActiveAt: 1_799_999_700,
                    isPinned: true,
                    isShared: true,
                    terminalTheme: terminalTheme,
                    account: .init(name: "Work", glyph: "W", isEmoji: false, hue: 0.2),
                    accountID: "work",
                    limitRecovery: .resumeOnBestAccount,
                    model: "gpt-5.6-sol"
                ),
            ],
            terminals: [
                RemoteProjectTerminalSummaryDTO(
                    id: "terminal-a",
                    title: "Server",
                    projectName: "Threading",
                    projectID: "project-a",
                    state: .working,
                    isAvailable: true,
                    createdAt: 1_799_999_600,
                    isShared: true,
                    terminalTheme: terminalTheme
                ),
            ],
            archivedSessions: [
                RemoteSessionSummaryDTO(
                    id: "session-archived",
                    title: "Archived session",
                    agentKind: "claude",
                    surface: .terminal,
                    state: .dormant,
                    projectName: "Threading",
                    isAvailable: false,
                    isArchived: true,
                    archivedAt: 1_799_990_000
                ),
            ]
        )
    }
}
