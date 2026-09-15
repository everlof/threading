import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

@MainActor
final class MobileProjectChatPreviewTests: XCTestCase {
    func testPreviewCapsBeforeCreatingRowsAndFullViewPreservesOrder() {
        for count in [0, 1, 3, 4, 1_000] {
            let source = (0..<count).map { session(id: String($0)) }
            let compact = MobileProjectChatPreview(sessions: source, isExpanded: false, isLive: true)
            let full = MobileProjectChatPreview(sessions: source, isExpanded: true, isLive: true)
            XCTAssertEqual(compact.sessions.map(\.id), source.prefix(3).map(\.id))
            XCTAssertEqual(compact.hiddenCount, max(0, count - 3))
            XCTAssertEqual(compact.canExpand, count > 3)
            XCTAssertEqual(full.sessions.map(\.id), source.map(\.id))
            XCTAssertEqual(full.hiddenCount, 0)
        }
    }

    func testPinnedAndEqualDateOrderingIsStableAtThePreviewBoundary() {
        let source = [session(id: "z", pinned: true), session(id: "d"),
                      session(id: "c"), session(id: "b"), session(id: "a")]
        let ordered = MobileSessionOrdering.sorted(source, archived: false)
        let preview = MobileProjectChatPreview(sessions: ordered, isExpanded: false, isLive: true)
        XCTAssertEqual(preview.sessions.map(\.id), ["z", "a", "b"])
        XCTAssertEqual(MobileSessionOrdering.sorted(source.reversed(), archived: false).map(\.id),
                       ordered.map(\.id))
    }

    func testHiddenActivityUsesLiveFactsAndNeverCountsVisibleChats() {
        let source = [session(id: "a", state: .working), session(id: "b"), session(id: "c")]
            + [session(id: "d", state: .needsAttention), session(id: "e", state: .awaitingUser),
               session(id: "f", state: .working), session(id: "g", state: .limitReached),
               session(id: "h", state: .working, available: false),
               session(id: "i", state: .unknown("future"))]
        let preview = MobileProjectChatPreview(sessions: source, isExpanded: false, isLive: true)
        XCTAssertEqual(preview.attentionCount, 3)
        XCTAssertEqual(preview.workingCount, 1)
        for (expanded, live) in [(true, true), (false, false)] {
            let quiet = MobileProjectChatPreview(sessions: source, isExpanded: expanded, isLive: live)
            XCTAssertEqual(quiet.attentionCount, 0)
            XCTAssertEqual(quiet.workingCount, 0)
            XCTAssertTrue(quiet.activityDescription.isEmpty)
        }
    }

    func testPreviewStateSurvivesFoldingAndIsSeparateForEveryHost() {
        let name = "MobileProjectChatPreviewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MobileProjectDisclosureStore(defaults: defaults)
        let project = MobileProjectDisclosureStore.projectKey(id: "a", name: "Original")
        store.setChatPreviewStage(.firstBatch, hostID: "mac-a", projectKey: project)
        XCTAssertTrue(store.setExpanded(false, hostID: "mac-a", projectKey: project))
        XCTAssertTrue(store.setExpanded(true, hostID: "mac-a", projectKey: project))
        XCTAssertEqual(store.chatPreviewStage(hostID: "mac-a", projectKey:
            MobileProjectDisclosureStore.projectKey(id: "a", name: "Renamed")), .firstBatch)
        XCTAssertEqual(store.chatPreviewStage(hostID: "mac-b", projectKey: project), .compact)
        XCTAssertEqual(store.chatPreviewStage(hostID: "mac-a", projectKey: "other"), .compact)
        XCTAssertEqual(MobileProjectDisclosureStore(defaults: defaults)
            .chatPreviewStage(hostID: "mac-a", projectKey: project), .compact)
        store.setChatPreviewStage(.compact, hostID: "mac-a", projectKey: project)
        XCTAssertTrue(store.isExpanded(hostID: "mac-a", projectKey: project))
    }

    func testPreviewExpansionAndDeepCollapseUseTheShippingCollection() async {
        let metrics = await MobileDashboardChatPreviewProbe.exercise(rowCount: 1_000)
        XCTAssertEqual(metrics.itemCounts, [5, 1_002, 5]) // header + chats + disclosure
        XCTAssertLessThan(metrics.maximumMountedCells, 40)
        XCTAssertEqual(metrics.headerOffsetAfterCollapse, 0, accuracy: 1)
        XCTAssertEqual(metrics.expansionAnchorDelta, 0, accuracy: 1)
        print("Chat preview: \(metrics)")
    }

    func testStagedExpansionRevealsFiveTwiceThenRemainingAndResets() {
        for count in [4, 8, 9, 13, 14, 1_000] {
            let source = (0..<count).map { session(id: String($0), state: .working) }
            var stage = MobileProjectChatPreview.Stage.compact
            for limit in [3, 8, 13, count] {
                let preview = MobileProjectChatPreview(sessions: source, stage: stage, isLive: true)
                XCTAssertEqual(preview.sessions.map(\.id), source.prefix(limit).map(\.id))
                XCTAssertEqual(preview.workingCount, max(0, count - limit))
                if preview.isExpanded {
                    XCTAssertEqual(preview.nextStage, .compact)
                    break
                }
                XCTAssertEqual(preview.nextRevealCount, min(count, stage.next.limit) - min(count, limit))
                stage = preview.nextStage
            }
        }
    }

    private func session(id: String, state: RemoteSessionActivity = .idle,
                         available: Bool = true, pinned: Bool = false) -> RemoteSessionSummaryDTO {
        .init(id: id, title: id, agentKind: "codex", surface: .conversation, state: state,
              projectName: "Project", isAvailable: available, lastActiveAt: 10, isPinned: pinned)
    }
}
