@testable import ThreadingMobile
import ThreadingRemoteKit
import XCTest

@MainActor
final class MobileThemeCacheStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MobileThemeCacheStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLastThemeReloadsForTheSameMacOnly() {
        let store = MobileThemeCacheStore(defaults: defaults)
        let theme = theme(id: "cyberpunk", ground: "#101015")

        XCTAssertTrue(store.remember(theme, for: "host:mac-a"))
        XCTAssertNil(store.theme(for: "host:mac-b"))

        let reloaded = MobileThemeCacheStore(defaults: defaults)
        XCTAssertEqual(reloaded.theme(for: "host:mac-a"), theme)
        XCTAssertNil(reloaded.theme(for: "host:mac-b"))
    }

    func testCachedThemeBridgesLaunchButLiveThemeWinsAfterReconnect() {
        let cached = theme(id: "cached", ground: "#111111")
        let live = theme(id: "live", ground: "#F8F8F8", mode: .light)

        XCTAssertEqual(MobileThemeResolution.current(live: nil, cached: cached), cached)
        XCTAssertEqual(MobileThemeResolution.current(live: live, cached: cached), live)
    }

    func testSameThemeDoesNotRewriteTheArchive() throws {
        let store = MobileThemeCacheStore(defaults: defaults)
        let theme = theme(id: "threading", ground: "#101A2A")
        XCTAssertTrue(store.remember(theme, for: "host:mac"))
        let first = try XCTUnwrap(defaults.data(forKey: MobileThemeCacheStore.archiveKey))

        XCTAssertTrue(store.remember(theme, for: "host:mac"))

        XCTAssertEqual(defaults.data(forKey: MobileThemeCacheStore.archiveKey), first)
    }

    func testRecordsAreBoundedToTheMostRecentlyChangedMacs() {
        let store = MobileThemeCacheStore(defaults: defaults)
        for index in 0 ... MobileThemeCacheStore.maximumRecordCount {
            XCTAssertTrue(store.remember(
                theme(id: "theme-\(index)", ground: "#111111"),
                for: "host:mac-\(index)"
            ))
        }

        XCTAssertNil(store.theme(for: "host:mac-0"))
        XCTAssertEqual(
            store.theme(for: "host:mac-\(MobileThemeCacheStore.maximumRecordCount)")?.id,
            "theme-\(MobileThemeCacheStore.maximumRecordCount)"
        )
    }

    func testRejectedCandidateLeavesLastGoodThemeUntouched() {
        let store = MobileThemeCacheStore(defaults: defaults)
        let good = theme(id: "threading", ground: "#101A2A")
        XCTAssertTrue(store.remember(good, for: "host:mac"))
        let persisted = defaults.data(forKey: MobileThemeCacheStore.archiveKey)
        let invalid = theme(
            id: String(
                repeating: "x",
                count: MobileThemeCacheStore.maximumIdentifierBytes + 1
            ),
            ground: "#FFFFFF",
            mode: .light
        )

        XCTAssertFalse(store.remember(invalid, for: "host:mac"))
        XCTAssertEqual(store.theme(for: "host:mac"), good)
        XCTAssertEqual(defaults.data(forKey: MobileThemeCacheStore.archiveKey), persisted)
    }

    func testCorruptArchiveIsQuarantinedBeforeAReplacementIsWritten() {
        let original = Data("not-json".utf8)
        defaults.set(original, forKey: MobileThemeCacheStore.archiveKey)

        let store = MobileThemeCacheStore(defaults: defaults)

        XCTAssertNil(defaults.data(forKey: MobileThemeCacheStore.archiveKey))
        XCTAssertTrue(defaults.dictionaryRepresentation().contains { key, value in
            key.hasPrefix(MobileThemeCacheStore.unreadableKeyPrefix)
                && (value as? Data) == original
        })
        XCTAssertTrue(store.remember(
            theme(id: "threading", ground: "#101A2A"),
            for: "host:mac"
        ))
    }

    func testNewerArchiveRemainsUntouchedAndDisablesThisOlderWriter() {
        let newer = Data(#"{"version":2,"records":[]}"#.utf8)
        defaults.set(newer, forKey: MobileThemeCacheStore.archiveKey)
        let store = MobileThemeCacheStore(defaults: defaults)

        XCTAssertFalse(store.remember(
            theme(id: "threading", ground: "#101A2A"),
            for: "host:mac"
        ))
        XCTAssertEqual(defaults.data(forKey: MobileThemeCacheStore.archiveKey), newer)
    }

    private func theme(
        id: String,
        ground: String,
        mode: RemoteThemeMode = .dark
    ) -> RemoteThemeDTO {
        RemoteThemeDTO(
            id: id,
            name: id,
            mode: mode,
            colors: [
                "ground": ground,
                "label": mode == .light ? "#111111" : "#F8F8F8",
                "accent": "#FF7A45",
            ],
            material: RemoteThemeDTO.Material(
                panelRadius: 18,
                controlRadius: 9,
                borderWidth: 1,
                glow: .init(color: "#FF7A45", radius: 12, opacity: 0.2),
                textScale: 1,
                typeface: .rounded
            )
        )
    }
}
