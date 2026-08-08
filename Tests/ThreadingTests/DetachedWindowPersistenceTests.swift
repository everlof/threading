import XCTest
@testable import Threading

/// The persisted layout once a session's tabs can live in a third kind of host.
///
/// Three hosts share one flat `tabs` list, told apart by each tab's `host` string. That is cheap
/// and it has one failure mode worth testing hard: a slice some writer forgets to carry through
/// is a slice the next save silently drops. So the document validates what it is handed rather
/// than interpreting it charitably — a tab naming a window that is not declared would be shown by
/// no pane and lost at the next write, which is exactly the silent loss to refuse instead.
final class DetachedWindowPersistenceTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func tab(_ id: String, host: String? = nil) -> PersistedTab {
        PersistedTab(id: id, kind: .browser, title: nil, subtitle: "browser", host: host)
    }

    private func roundTrip(_ panel: PersistedPanel) throws -> PersistedPanel {
        try decoder.decode(PersistedPanel.self, from: encoder.encode(panel))
    }

    private func decode(_ json: String) throws -> PersistedPanel {
        try decoder.decode(PersistedPanel.self, from: Data(json.utf8))
    }

    // MARK: - Round trip

    func testEveryHostsSliceSurvivesARoundTrip() throws {
        let windowID = UUID()
        let other = UUID()
        var panel = PersistedPanel(
            tabs: [
                tab("panel-1"),
                tab("drawer-1", host: PersistedTab.drawerHost),
                tab("window-1", host: PersistedTab.detachedWindowHost(windowID)),
                tab("window-2", host: PersistedTab.detachedWindowHost(other))
            ],
            activeTabID: "panel-1",
            observedSignature: nil
        )
        panel.drawerActiveTabID = "drawer-1"
        panel.detachedWindows = [
            PersistedDetachedWindow(
                id: windowID.uuidString,
                frame: "{{10, 20}, {800, 600}}",
                activeTabID: "window-1",
                isFullScreen: true
            ),
            PersistedDetachedWindow(
                id: other.uuidString,
                frame: nil,
                activeTabID: nil,
                isFullScreen: nil
            )
        ]

        let restored = try roundTrip(panel)

        XCTAssertEqual(restored.panelTabs.map(\.id), ["panel-1"])
        XCTAssertEqual(restored.drawerTabs.map(\.id), ["drawer-1"])
        XCTAssertEqual(restored.detachedWindowTabs.map(\.id), ["window-1", "window-2"])
        XCTAssertEqual(restored.tabs(inDetachedWindow: windowID).map(\.id), ["window-1"])
        XCTAssertEqual(restored.detachedWindows.count, 2)
        XCTAssertEqual(panel.requiredFormatVersion, 2, "a document with windows must declare 2")
        XCTAssertEqual(restored.detachedWindows.first?.frame, "{{10, 20}, {800, 600}}")
        XCTAssertEqual(restored.detachedWindows.first?.isFullScreen, true)
    }

    /// A session that has never detached a window must keep writing the document it always wrote,
    /// so the new key's absence stays the ordinary case rather than a migration.
    func testADocumentWithNoDetachedWindowsOmitsTheKey() throws {
        let panel = PersistedPanel(
            tabs: [tab("panel-1")],
            activeTabID: "panel-1",
            observedSignature: nil
        )
        let json = String(decoding: try encoder.encode(panel), as: UTF8.self)
        XCTAssertFalse(json.contains("detachedWindows"))
        // And it still declares version 1. Stamping 2 on a document an older build can read
        // perfectly would make that build refuse it — and that build has no quarantine, so
        // refusing means its next save wipes the panel, the drawer and every window slice.
        XCTAssertEqual(panel.requiredFormatVersion, 1)
        XCTAssertTrue(json.contains("\"formatVersion\" : 1") || json.contains("\"formatVersion\":1"))
    }

    /// The host string is the only thing separating the slices, so it is parsed both ways.
    func testTheWindowHostRoundTripsThroughItsIdentifier() {
        let windowID = UUID()
        let hosted = tab("t", host: PersistedTab.detachedWindowHost(windowID))
        XCTAssertEqual(hosted.detachedWindowID, windowID)
        XCTAssertTrue(hosted.namesADetachedWindow)
        XCTAssertNil(tab("t").detachedWindowID)
        XCTAssertNil(tab("t", host: PersistedTab.drawerHost).detachedWindowID)
    }

    // MARK: - Refusals

    /// The version is what tells an older build to refuse rather than read a layout it only
    /// partly understands — and then write that back over the parts it dropped.
    func testADocumentFromANewerFormatIsRefused() {
        let json = """
            {"formatVersion": \(PersistedPanel.currentFormatVersion + 1), "tabs": []}
            """
        XCTAssertThrowsError(try decode(json))
    }

    func testAnUnknownHostIsRefused() {
        let json = """
            {"formatVersion": 2, "tabs": [
              {"id": "a", "kind": "browser", "subtitle": "b", "host": "sidebar"}
            ]}
            """
        XCTAssertThrowsError(try decode(json))
    }

    /// `window:` followed by anything is a host no window will ever claim. Prefix-matching alone
    /// would have admitted it and left a tab no pane shows.
    func testAMalformedWindowHostIsRefused() {
        let json = """
            {"formatVersion": 2, "tabs": [
              {"id": "a", "kind": "browser", "subtitle": "b", "host": "window:not-a-uuid"}
            ]}
            """
        XCTAssertThrowsError(try decode(json))
    }

    func testATabNamingAnUndeclaredWindowIsRefused() {
        let json = """
            {"formatVersion": 2, "tabs": [
              {"id": "a", "kind": "browser", "subtitle": "b", "host": "window:\(UUID().uuidString)"}
            ]}
            """
        XCTAssertThrowsError(try decode(json))
    }

    func testDuplicateWindowIdentifiersAreRefused() {
        let windowID = UUID().uuidString
        let json = """
            {"formatVersion": 2, "tabs": [], "detachedWindows": [
              {"id": "\(windowID)"}, {"id": "\(windowID)"}
            ]}
            """
        XCTAssertThrowsError(try decode(json))
    }

    func testAWindowsActiveTabMustBeItsOwn() {
        let windowID = UUID()
        let json = """
            {"formatVersion": 2, "tabs": [
              {"id": "panel", "kind": "browser", "subtitle": "b"},
              {"id": "mine", "kind": "browser", "subtitle": "b",
               "host": "window:\(windowID.uuidString)"}
            ], "detachedWindows": [
              {"id": "\(windowID.uuidString)", "activeTabID": "panel"}
            ]}
            """
        XCTAssertThrowsError(
            try decode(json),
            "a window claimed a tab from another host as its selection"
        )
    }

    /// The documents already on disk predate all of this and must keep loading untouched.
    func testAVersionOneDocumentStillLoads() throws {
        let json = """
            {"formatVersion": 1, "tabs": [
              {"id": "a", "kind": "browser", "subtitle": "b"},
              {"id": "d", "kind": "terminal", "subtitle": "shell", "host": "drawer"}
            ], "activeTabID": "a", "drawerActiveTabID": "d", "drawerOpen": true}
            """
        let panel = try decode(json)
        XCTAssertEqual(panel.panelTabs.map(\.id), ["a"])
        XCTAssertEqual(panel.drawerTabs.map(\.id), ["d"])
        XCTAssertTrue(panel.detachedWindows.isEmpty)
        XCTAssertEqual(panel.drawerOpen, true)
    }

    /// A legacy document with no version key at all is the version-zero case the decoder has
    /// always accepted, and adding a format must not change that.
    func testAVersionlessDocumentStillLoads() throws {
        let panel = try decode("""
            {"tabs": [{"id": "a", "kind": "browser", "subtitle": "b"}], "activeTabID": "a"}
            """)
        XCTAssertEqual(panel.panelTabs.map(\.id), ["a"])
    }
}
