import Foundation
import XCTest
@testable import Threading

/// The payload's evolution rules: every layout written before the drawer became a host decodes
/// unchanged and lands wholly in the panel, the two hosts' slices stay separate, and the
/// agent-facing signature keeps describing only the panel.
final class DisplayPaneStoreMigrationTests: XCTestCase {

    // MARK: - Decode Compatibility

    /// A pre-drawer layout, verbatim in shape: no `host`, no drawer fields.
    private let legacyJSON = """
    {
      "tabs": [
        {"id": "11111111-1111-1111-1111-111111111111", "kind": "browser",
         "subtitle": "", "url": "https://example.com"},
        {"id": "22222222-2222-2222-2222-222222222222", "kind": "terminal", "subtitle": ""}
      ],
      "activeTabID": "11111111-1111-1111-1111-111111111111",
      "observedSignature": "b:https://example.com|t#11111111-1111-1111-1111-111111111111"
    }
    """

    func testALegacyLayoutDecodesWhollyIntoThePanel() throws {
        let panel = try JSONDecoder().decode(
            PersistedPanel.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(panel.panelTabs.count, 2, "Absent host means panel — the whole migration")
        XCTAssertTrue(panel.drawerTabs.isEmpty)
        XCTAssertNil(panel.drawerOpen)
        XCTAssertNil(panel.drawerActiveTabID)
        XCTAssertEqual(panel.activeTabID, "11111111-1111-1111-1111-111111111111")
    }

    /// Re-encoding states a version where the legacy document stated none — but the version the
    /// document *needs*, not the newest this build knows.
    ///
    /// A layout with no detached window is byte-identical to what version 1 always wrote, and an
    /// older build reads it perfectly. Stamping 2 on it would make that build refuse a document it
    /// understands, and that build has no quarantine: refusing means its next save wipes the panel,
    /// the drawer and every window slice. The bump costs only the sessions that used the feature.
    func testReencodingALegacyLayoutStatesTheVersionItNeeds() throws {
        let panel = try JSONDecoder().decode(
            PersistedPanel.self,
            from: Data(legacyJSON.utf8)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(panel))
                as? [String: Any]
        )

        XCTAssertEqual(object["formatVersion"] as? Int, 1)
        XCTAssertEqual(panel.requiredFormatVersion, 1)
        XCTAssertLessThan(
            panel.requiredFormatVersion,
            PersistedPanel.currentFormatVersion,
            "This test is only meaningful while the two can differ"
        )
    }

    /// The other half: a layout that actually uses a detached window declares the version that
    /// carries it, so a build without the feature refuses rather than silently dropping the window.
    ///
    /// That version is 2, stated as a literal on purpose. It was once also the newest this build
    /// knew, and asserting `currentFormatVersion` read as the same thing — until the adopted
    /// Simulator added 3 and the two parted, failing this test while both the encoder and the rule
    /// above were behaving exactly as designed. A document declares what it *needs*; the newest
    /// version this build can write is a different number, and only the tab that needs it may
    /// raise it.
    func testALayoutWithADetachedWindowDeclaresTheNewerVersion() throws {
        let windowID = UUID()
        let panel = PersistedPanel(
            tabs: [
                PersistedTab(
                    id: "w1", kind: .browser, title: nil, subtitle: "",
                    url: "https://example.com", html: nil, cacheFile: nil,
                    host: PersistedTab.detachedWindowHost(windowID)
                )
            ],
            activeTabID: nil,
            observedSignature: nil,
            detachedWindows: [
                PersistedDetachedWindow(id: windowID.uuidString, frame: nil, activeTabID: "w1")
            ]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(panel)) as? [String: Any]
        )
        XCTAssertEqual(object["formatVersion"] as? Int, 2)
        XCTAssertEqual(panel.requiredFormatVersion, 2)
        XCTAssertLessThanOrEqual(
            panel.requiredFormatVersion,
            PersistedPanel.currentFormatVersion,
            "A document may never declare a version this build cannot itself write"
        )
    }

    func testFutureLayoutVersionIsRefused() throws {
        let future = legacyJSON.replacingOccurrences(
            of: "{",
            with: #"{"formatVersion":99,"#,
            options: [],
            range: legacyJSON.range(of: "{")
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(PersistedPanel.self, from: Data(future.utf8))
        )
    }

    func testTheSignatureOfALegacyLayoutIsUnchangedByTheSchema() throws {
        let panel = try JSONDecoder().decode(
            PersistedPanel.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertEqual(
            panel.signature,
            "b:https://example.com|t#11111111-1111-1111-1111-111111111111",
            "A schema change that shifts signatures would re-brief every agent for nothing"
        )
    }

    // MARK: - Host Separation

    private func mixedPanel() -> PersistedPanel {
        PersistedPanel(
            tabs: [
                PersistedTab(id: "p1", kind: .review, title: nil, subtitle: "", url: nil, html: nil, cacheFile: nil),
                PersistedTab(
                    id: "d1", kind: .terminal, title: nil, subtitle: "",
                    url: nil, html: nil, cacheFile: nil,
                    host: PersistedTab.drawerHost
                ),
                PersistedTab(id: "p2", kind: .info, title: nil, subtitle: "", url: nil, html: nil, cacheFile: nil)
            ],
            activeTabID: "p1",
            observedSignature: nil,
            drawerActiveTabID: "d1",
            drawerOpen: true
        )
    }

    func testTheTwoHostsSlicesStaySeparate() {
        let panel = mixedPanel()

        XCTAssertEqual(panel.panelTabs.map(\.id), ["p1", "p2"])
        XCTAssertEqual(panel.drawerTabs.map(\.id), ["d1"])
    }

    func testTheSignatureIgnoresDrawerTabs() {
        var withDrawer = mixedPanel()
        let without = PersistedPanel(
            tabs: withDrawer.panelTabs,
            activeTabID: withDrawer.activeTabID,
            observedSignature: nil
        )

        XCTAssertEqual(
            withDrawer.signature,
            without.signature,
            "The drawer is the user's furniture; its tabs changing must not re-brief the agent"
        )

        withDrawer.tabs.append(
            PersistedTab(id: "d2", kind: .browser, title: nil, subtitle: "", url: nil, html: nil, cacheFile: nil, host: PersistedTab.drawerHost)
        )
        XCTAssertEqual(withDrawer.signature, without.signature)
    }

    func testTheAgentDescriptionListsOnlyPanelTabs() {
        let description = mixedPanel().agentDescription

        XCTAssertTrue(description.contains("git review panel"))
        XCTAssertFalse(
            description.contains("a shell the user opened"),
            "A drawer shell is not in the panel the agent is being briefed about"
        )
    }

    // MARK: - Round Trip

    func testAMixedLayoutRoundTripsExactly() throws {
        let panel = mixedPanel()
        let data = try JSONEncoder().encode(panel)
        let decoded = try JSONDecoder().decode(PersistedPanel.self, from: data)

        XCTAssertEqual(decoded.panelTabs.map(\.id), panel.panelTabs.map(\.id))
        XCTAssertEqual(decoded.drawerTabs.map(\.id), panel.drawerTabs.map(\.id))
        XCTAssertEqual(decoded.drawerActiveTabID, "d1")
        XCTAssertEqual(decoded.drawerOpen, true)
        XCTAssertEqual(decoded.drawerTabs.first?.host, PersistedTab.drawerHost)
    }
}
