import XCTest
import PencilKit
import ThreadingRemoteKit
@testable import ThreadingMobile

final class RemoteConversationStoreTests: XCTestCase {
    func testDictationConsentDescriptionsShipInTheAppBundle() {
        for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
            XCTAssertFalse((Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "").isEmpty,
                           "Requesting consent without \(key) terminates the app")
        }
    }
    func testSemanticActivityUpdatesStayTruthfulWhenToolsChange() throws {
        var groups = RemoteConversationToolGroups()
        groups.rebuild([
            .init(id: "read", kind: .tool, toolName: "Read", result: "File"),
            .init(id: "run", kind: .tool, toolName: "Bash", summary: "echo tests passed", result: nil),
            .init(id: "unknown", kind: .tool, toolName: "future_tool", result: "Done"),
        ])
        let group = try XCTUnwrap(groups.groups["read"])
        XCTAssertEqual(group.activities[.read], 1)
        XCTAssertEqual(group.activities[.command], 1)
        XCTAssertEqual(group.activities[.other], 1)
        XCTAssertEqual(group.pendingActivities[.command], 1)
        _ = groups.update([.init(id: "run", kind: .tool, toolName: "Grep", result: "Found", isError: true)])
        XCTAssertEqual(groups.groups["read"]?.activities[.command], 0)
        XCTAssertEqual(groups.groups["read"]?.activities[.search], 1)
        XCTAssertNil(groups.groups["read"]?.runningSummary)
        XCTAssertEqual(groups.groups["read"]?.failureCount, 1)
    }

    func testCatchUpCountsOnlyRowsAfterTheBookmarkAndLabelsMissingHistory() {
        let rows: [RemoteConversationRowDTO] = [.init(id: "seen", kind: .assistant), tool("new"), .init(id: "reply", kind: .assistant)]
        var recap = RemoteConversationCatchUp(rows: rows, after: "seen", hasEarlier: true)
        XCTAssertEqual(recap.firstUnreadID, "new")
        XCTAssertEqual(recap.replies, 1)
        XCTAssertEqual(recap.actions, 1)
        XCTAssertFalse(recap.isPartial)
        recap.append([tool("later"), .init(id: "latest", kind: .assistant)])
        XCTAssertEqual(recap.firstUnreadID, "new")
        XCTAssertEqual(recap.latestReplyID, "latest")
        XCTAssertEqual(recap.actions, 2)
        XCTAssertTrue(RemoteConversationCatchUp(rows: rows, after: "missing", hasEarlier: true).isPartial)
        XCTAssertNil(RemoteConversationCatchUp(rows: rows, after: "replaced-history", hasEarlier: false).firstUnreadID)
    }

    @MainActor
    func testPhoneReadBookmarkSurvivesRelaunchAndIsHostScoped() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MobileSessionContinuityStore(defaults: defaults)
        store.setConversationLastSeenRow("row-42", hostID: "mac-a", sessionID: "chat")
        let reopened = MobileSessionContinuityStore(defaults: defaults)
        XCTAssertEqual(reopened.state(hostID: "mac-a", sessionID: "chat").conversationLastSeenRowID, "row-42")
        XCTAssertNil(reopened.state(hostID: "mac-b", sessionID: "chat").conversationLastSeenRowID)
    }

    func testResultCardsUseAdmittedAttachmentIdentityAndCurrentWorkspace() {
        let shot = RemoteAttachmentDTO(path: "screens/result.png", name: "result.png", kind: .image, byteCount: 100, id: "opaque-id")
        let links = RemoteConversationResultLink.links(answer: "See screens/result.png", attachments: [shot], workspace: .init(browserTabs: [
            .init(id: "private", title: "Secret", displayURL: nil, isActive: true, isPrivate: true, canPreview: false)
        ]))
        XCTAssertEqual(links.map(\.route), [.review, .attachment(id: "opaque-id")])
        let missing = RemoteConversationResultLink.links(answer: "A different answer", attachments: [shot], workspace: nil)
        XCTAssertEqual(missing.map(\.route), [.review, .attachments])
    }

    @MainActor
    func testDeliveryOnlySnapshotAndDeltaNotifyWithoutRebuildingRows() {
        let store = RemoteConversationStore()
        let rows = [tool("a")]
        _ = store.replace(with: .init(rows: rows, canSend: false, revision: 1))
        var receipts: [RemoteConversationDeliveryDTO?] = []
        store.onDeliveryChange = { receipts.append($0) }
        let queued = RemoteConversationDeliveryDTO(canQueue: true, canSteer: false, messages: [.init(id: "m", summary: "Later", state: .queued)])
        XCTAssertNotEqual(store.replace(with: .init(rows: rows, canSend: false, revision: 2, delivery: queued)), .unchanged)
        let working = RemoteConversationDeliveryDTO(canQueue: true, canSteer: true, messages: [.init(id: "m", summary: "Later", state: .working)])
        XCTAssertTrue(store.apply(.init(baseRevision: 2, revision: 3, streamingText: "", canSend: false, delivery: working)))
        XCTAssertEqual(receipts, [queued, working])
        XCTAssertEqual(store.state.rows, rows)
    }

    @MainActor
    func testMarkupExportCapsPixelsAndRetainsSourceImage() async throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2_500, height: 100)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2_500, height: 100))
        }
        let originalSize = source.size
        let bounded = await Task.detached { MobileScreenshotMarkupController.boundedImage(source) }.value
        XCTAssertEqual(bounded.size.width, 2_048, accuracy: 1)
        XCTAssertEqual(bounded.scale, 1)
        let drawing = PKDrawing().dataRepresentation()
        let data = await Task.detached { MobileScreenshotMarkupController.flatten(image: bounded, drawing: drawing) }.value
        let image = try XCTUnwrap(data.flatMap(UIImage.init(data:)))
        XCTAssertEqual(image.size.width, 2_048, accuracy: 1)
        XCTAssertEqual(source.size, originalSize)
        let marked = MobileScreenshotMarkupController.evidenceDrawing(size: bounded.size).dataRepresentation()
        let markedData = await Task.detached { MobileScreenshotMarkupController.flatten(image: bounded, drawing: marked) }.value
        XCTAssertNotEqual(markedData, data, "Export must composite the ink, not only return the original image")
    }

    @MainActor
    func testShippingTimelineAddsUnreadMarkerAndResultCardsWithoutExpandingTools() async throws {
        let connection = RemoteSessionConnection.demoConversation()
        let rows: [RemoteConversationRowDTO] = [.init(id: "seen", kind: .user), tool("a"), tool("b"), .init(id: "answer", kind: .assistant, text: "Done")]
        connection.conversationStore.replace(with: .init(rows: rows, canSend: true))
        let controller = RemoteConversationTimelineViewController(connection: connection, theme: .init(nil), initialViewport: nil, onViewportChange: { _, _ in })
        controller.restoreReadThrough("seen")
        var recap: RemoteConversationCatchUp?
        controller.onCatchUpChange = { recap = $0 }
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        controller.view.layoutIfNeeded()
        await Task.yield()
        let collection = try XCTUnwrap(descendants(of: UICollectionView.self, in: controller.view).first)
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 4)
        XCTAssertEqual(recap?.firstUnreadID, "a")
        controller.showResults(RemoteConversationResultLink.links(answer: "Done", attachments: [], workspace: nil), after: "answer")
        await Task.yield()
        collection.layoutIfNeeded()
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 5)
        XCTAssertTrue(descendants(of: RemoteToolDisclosureControl.self, in: collection).isEmpty)
        controller.markCaughtUp()
        await Task.yield()
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 4)
        XCTAssertNil(recap)
        connection.conversationStore.replace(with: .init(
            rows: rows + [.init(id: "next-visit", kind: .assistant, text: "Another update")], canSend: true
        ))
        await Task.yield()
        XCTAssertEqual(recap?.firstUnreadID, "next-visit", "Mark as read must retain the bookmark for the next visit")
        XCTAssertEqual(recap?.replies, 1)
    }

    func testToolGroupsPreserveChronologyAndBreakAtEveryOtherRowKind() {
        let rows: [RemoteConversationRowDTO] = [
            .init(id: "user", kind: .user, text: "Check this"), tool("a"), tool("b"),
            .init(id: "comment", kind: .assistant, text: "Still checking"), tool("c"),
            .init(id: "notice", kind: .notice, text: "Stopped"), tool("d"), tool("e"),
        ]
        var groups = RemoteConversationToolGroups()
        groups.rebuild(rows)
        XCTAssertEqual(groups.visibleItems(), [.row("user"), .group("a"), .row("comment"),
                                               .row("c"), .row("notice"), .group("d")])
        groups.toggle("a")
        XCTAssertEqual(groups.visibleItems(), [.row("user"), .group("a"), .row("a"), .row("b"),
                                               .row("comment"), .row("c"), .row("notice"), .group("d")])
    }

    func testLiveToolGroupCountsRefreshWithoutChangingIdentityOrDisclosure() throws {
        var groups = RemoteConversationToolGroups()
        groups.rebuild([tool("a")])
        XCTAssertEqual(groups.visibleItems(), [.row("a")])
        XCTAssertEqual(groups.append([tool("b", result: nil)], openedRows: []), ["a"])
        groups.toggle("a")
        XCTAssertEqual(groups.append([tool("c", failed: true)], openedRows: []), ["a"])
        XCTAssertEqual(groups.groups["a"]?.rowIDs, ["a", "b", "c"])
        XCTAssertEqual(groups.groups["a"]?.pendingCount, 1)
        XCTAssertEqual(groups.groups["a"]?.failureCount, 1)
        XCTAssertEqual(groups.update([tool("b", failed: true)]), ["a"])
        XCTAssertEqual(groups.groups["a"]?.pendingCount, 0)
        XCTAssertEqual(groups.groups["a"]?.failureCount, 2)
        XCTAssertEqual(groups.expanded, ["a"])
        XCTAssertEqual(groups.update([tool("b")]), ["a"])
        XCTAssertEqual(groups.groups["a"]?.failureCount, 1)
    }

    func testPrependingAndReconnectPreserveGroupIdentityAndExplicitCollapse() {
        var groups = RemoteConversationToolGroups()
        groups.rebuild([tool("c"), tool("d")])
        groups.toggle("c")
        groups.rebuild([tool("a"), tool("b"), tool("c"), tool("d")])
        XCTAssertEqual(groups.roots, [.group("c")])
        XCTAssertEqual(groups.expanded, ["c"])
        groups.toggle("c")
        groups.rebuild([tool("a"), tool("b"), tool("c"), tool("d")], openedRows: ["c"])
        XCTAssertEqual(groups.visibleItems(), [.group("c")], "An opened result must not undo explicit group collapse")
        XCTAssertEqual(groups.visibleItem(forRow: "a"), .group("c"))
    }

    func testAnOpenedLoneToolStaysVisibleWhenASecondArrives() {
        var groups = RemoteConversationToolGroups()
        groups.rebuild([tool("a")])
        _ = groups.append([tool("b")], openedRows: ["a"])
        XCTAssertEqual(groups.visibleItems(), [.group("a"), .row("a"), .row("b")])
    }

    func testCorrectedRowKindsSplitAGroupWithoutDuplicateIdentities() {
        var groups = RemoteConversationToolGroups()
        groups.rebuild([tool("c"), tool("d"), tool("e")])
        groups.rebuild([tool("a"), tool("b"), tool("c"), tool("d"), tool("e")])
        let correction = RemoteConversationRowDTO(id: "c", kind: .notice, text: "Recovered")
        XCTAssertTrue(groups.needsRebuild(for: [correction]))
        groups.rebuild([tool("a"), tool("b"), correction, tool("d"), tool("e")])
        let items = groups.visibleItems()
        XCTAssertEqual(Set(items).count, items.count)
        XCTAssertEqual(groups.groups.count, 2)
        XCTAssertEqual(items[1], .row("c"))
    }

    @MainActor
    func testGroupControlExposesOutcomesAndSurvivesThemeAndActionReplacement() throws {
        let control = RemoteToolGroupControl()
        let group = RemoteConversationToolGroups.Group(id: "a", rowIDs: ["a", "b", "c"], failureCount: 1, pendingCount: 1)
        var count = 0
        control.configure(group: group, isExpanded: false, theme: .init(nil)) { XCTFail("Replaced action") }
        control.configure(group: group, isExpanded: true, theme: .init(RemoteAppModel.demoTheme)) { count += 1 }
        control.sendActions(for: .touchUpInside)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(control.accessibilityActivate())
        XCTAssertEqual(count, 2)
        XCTAssertTrue(control.accessibilityLabel?.contains(MobileL10n.string("%lld failed", 1)) == true)
        XCTAssertTrue(control.accessibilityLabel?.contains(MobileL10n.string("%lld running", 1)) == true)
        XCTAssertEqual(control.accessibilityValue, MobileL10n.string("Expanded"))
        XCTAssertTrue(MobileButtonHaptics.isInstalled(on: control))
        let size = control.systemLayoutSizeFitting(CGSize(width: 280, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        XCTAssertGreaterThanOrEqual(size.height, MobileDesign.Size.minimumTapTarget)
        XCTAssertTrue(descendants(of: UITextView.self, in: control).isEmpty)
    }

    @MainActor
    func testShippingTimelineGroupsLiveCallsAndKeepsDecisionsOutsideTheFold() async throws {
        let connection = RemoteSessionConnection.demoConversation()
        connection.conversationStore.replace(with: snapshot(rows: [tool("a")], revision: 1))
        let controller = RemoteConversationTimelineViewController(connection: connection, theme: .init(nil),
            initialViewport: nil, onViewportChange: { _, _ in })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        controller.view.layoutIfNeeded()
        await Task.yield()
        let collection = try XCTUnwrap(descendants(of: UICollectionView.self, in: controller.view).first)
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 1)
        let permission = RemotePermissionRequestDTO(id: "approval", toolName: "Bash", summary: "Run a command")
        XCTAssertTrue(connection.conversationStore.apply(.init(baseRevision: 1, revision: 2,
            appendedRows: [tool("b")], streamingText: "", canSend: false, permission: permission)))
        await Task.yield()
        collection.layoutIfNeeded()
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 2, "One group plus the separate permission")
        let header = try XCTUnwrap(descendants(of: RemoteToolGroupControl.self, in: collection).first)
        header.sendActions(for: .touchUpInside)
        await Task.yield()
        collection.layoutIfNeeded()
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 4)
        XCTAssertEqual(descendants(of: RemoteToolDisclosureControl.self, in: collection).count, 2)
        XCTAssertTrue(connection.conversationStore.apply(.init(baseRevision: 2, revision: 3,
            updatedRows: [tool("b", failed: true)], streamingText: "", canSend: false, permission: permission)))
        XCTAssertTrue(header.accessibilityLabel?.contains(MobileL10n.string("%lld failed", 1)) == true)
        header.sendActions(for: .touchUpInside)
        await Task.yield()
        collection.layoutIfNeeded()
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 2)
    }

    @MainActor
    func testGroupDisclosureAndOlderPagesKeepTheVisibleHeaderInPlace() async throws {
        let before = (0..<20).map { RemoteConversationRowDTO(id: "before-\($0)", kind: .notice, text: "Earlier activity") }
        let after = (0..<40).map { RemoteConversationRowDTO(id: "after-\($0)", kind: .notice, text: "Later activity") }
        let connection = RemoteSessionConnection.demoConversation()
        connection.conversationStore.replace(with: snapshot(rows: before + [tool("a"), tool("b")] + after, revision: 1))
        let controller = RemoteConversationTimelineViewController(connection: connection, theme: .init(nil),
            initialViewport: (progress: 0, followsBottom: false), onViewportChange: { _, _ in })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        controller.view.layoutIfNeeded()
        await Task.yield()
        let collection = try XCTUnwrap(descendants(of: UICollectionView.self, in: controller.view).first)
        let frame = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 20, section: 0))?.frame)
        collection.setContentOffset(CGPoint(x: 0, y: frame.minY - 120), animated: false)
        collection.layoutIfNeeded()
        let header = try XCTUnwrap(descendants(of: RemoteToolGroupControl.self, in: collection).first)
        let origin = header.convert(.zero, to: controller.view).y
        header.sendActions(for: .touchUpInside)
        await Task.yield()
        collection.layoutIfNeeded()
        XCTAssertEqual(header.convert(.zero, to: controller.view).y, origin, accuracy: 1)
        connection.conversationStore.prepend(.init(rows: [
            .init(id: "older", kind: .notice, text: "Loaded from an older page")
        ], beforeRowID: "before-0", hasEarlier: false))
        await Task.yield()
        collection.layoutIfNeeded()
        let retainedHeader = try XCTUnwrap(descendants(of: RemoteToolGroupControl.self, in: collection).first)
        XCTAssertEqual(retainedHeader.convert(.zero, to: controller.view).y, origin, accuracy: 1)
        XCTAssertEqual(retainedHeader.accessibilityValue, MobileL10n.string("Expanded"))
        retainedHeader.sendActions(for: .touchUpInside)
        await Task.yield()
        collection.layoutIfNeeded()
        XCTAssertEqual(retainedHeader.convert(.zero, to: controller.view).y, origin, accuracy: 1)
    }

    @MainActor
    func testToolHeavyTimelineVirtualizesExpandedMembers() async throws {
        let rows = (0..<5_000).map { tool("stress-\($0)") }
        let connection = RemoteSessionConnection.demoConversation()
        connection.conversationStore.replace(with: snapshot(rows: rows, revision: 1))
        let start = ProcessInfo.processInfo.systemUptime
        let controller = RemoteConversationTimelineViewController(connection: connection, theme: .init(nil),
            initialViewport: nil, onViewportChange: { _, _ in })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        controller.view.layoutIfNeeded()
        await Task.yield()
        let collection = try XCTUnwrap(descendants(of: UICollectionView.self, in: controller.view).first)
        collection.layoutIfNeeded()
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 1)
        XCTAssertEqual(collection.visibleCells.count, 1)
        XCTAssertTrue(descendants(of: RemoteToolDisclosureControl.self, in: collection).isEmpty)
        let header = try XCTUnwrap(descendants(of: RemoteToolGroupControl.self, in: collection).first)
        let mountMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        let expandStart = ProcessInfo.processInfo.systemUptime
        header.sendActions(for: .touchUpInside)
        await Task.yield()
        collection.layoutIfNeeded()
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 5_001)
        XCTAssertLessThan(collection.visibleCells.count, 30)
        XCTAssertTrue(descendants(of: UITextView.self, in: collection).isEmpty, "Tool output remains lazy")
        print("THREADING_PERF ios-tool-groups rows=5000 mount_ms=\(mountMS) expand_ms=\((ProcessInfo.processInfo.systemUptime - expandStart) * 1_000) visible_cells=\(collection.visibleCells.count)")
    }

    private func tool(_ id: String, result: String? = "Done", failed: Bool = false) -> RemoteConversationRowDTO {
        .init(id: id, kind: .tool, toolName: "Bash", summary: "git status", result: result, isError: failed)
    }

    @MainActor
    func testToolDisclosureStaysCompactAndMaterializesOutputOnlyWhenExpanded() throws {
        let row = RemoteConversationRowDTO(
            id: "tool-a",
            kind: .tool,
            toolName: "Bash",
            summary: "swift test --filter KeyboardLifecycleTests",
            result: "All focused tests passed"
        )
        var toggleCount = 0
        let view = RemoteToolMessageView(
            row: row,
            isExpanded: false,
            theme: RemoteThemePalette(nil),
            toggle: { toggleCount += 1 }
        )

        let collapsed = view.systemLayoutSizeFitting(
            CGSize(width: 360, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        XCTAssertLessThanOrEqual(collapsed.height, 54)
        XCTAssertTrue(descendants(of: UITextView.self, in: view).isEmpty)

        let disclosure = try XCTUnwrap(
            descendants(of: RemoteToolDisclosureControl.self, in: view).first
        )
        disclosure.sendActions(for: .touchUpInside)
        XCTAssertEqual(toggleCount, 1)

        view.configure(
            row: row,
            isExpanded: true,
            theme: RemoteThemePalette(nil),
            toggle: {}
        )
        let expanded = view.systemLayoutSizeFitting(
            CGSize(width: 360, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        XCTAssertGreaterThan(expanded.height, collapsed.height)
        XCTAssertEqual(descendants(of: UITextView.self, in: view).count, 1)
    }

    @MainActor
    func testRunningToolHasNoFalseDisclosureAction() throws {
        let row = RemoteConversationRowDTO(
            id: "tool-running",
            kind: .tool,
            toolName: "Read",
            summary: "RemoteConversationViewController.swift"
        )
        let control = RemoteToolDisclosureControl()
        control.configure(
            row: row,
            isExpanded: false,
            theme: RemoteThemePalette(nil),
            toggle: { XCTFail("A tool without output cannot expand") }
        )

        XCTAssertFalse(control.isEnabled)
        XCTAssertEqual(control.accessibilityTraits, .staticText)
        XCTAssertNil(control.accessibilityValue)
        XCTAssertEqual(control.accessibilityHint, MobileL10n.string("Tool is running"))
    }

    @MainActor
    func testIdenticalReplacementAdvancesRevisionWithoutNotifyingTimeline() {
        let store = RemoteConversationStore()
        let row = RemoteConversationRowDTO(id: "row-a", kind: .user, text: "Hello")
        store.replace(with: snapshot(rows: [row], revision: 1))

        var changes: [RemoteConversationStore.Change] = []
        _ = store.observe { changes.append($0) }
        let change = store.replace(with: snapshot(rows: [row], revision: 2))

        XCTAssertEqual(change, .unchanged)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(store.state.revision, 2)
    }

    @MainActor
    func testStableIdentitiesReportOnlyChangedRows() {
        let store = RemoteConversationStore()
        let first = RemoteConversationRowDTO(id: "row-a", kind: .user, text: "Before")
        let second = RemoteConversationRowDTO(id: "row-b", kind: .assistant, text: "Stable")
        store.replace(with: snapshot(rows: [first, second], revision: 1))

        let updated = RemoteConversationRowDTO(id: "row-a", kind: .user, text: "After")
        let change = store.replace(with: snapshot(rows: [updated, second], revision: 2))

        XCTAssertEqual(
            change,
            .delta(
                inserted: [],
                updated: ["row-a"],
                streamingChanged: false,
                permissionChanged: false,
                capabilitiesChanged: false,
                historyChanged: false
            )
        )
        XCTAssertEqual(store.row(withID: "row-a"), updated)
    }

    @MainActor
    func testChangedIdentityOrderRequiresStructuralReset() {
        let store = RemoteConversationStore()
        let first = RemoteConversationRowDTO(id: "row-a", kind: .user, text: "First")
        let second = RemoteConversationRowDTO(id: "row-b", kind: .assistant, text: "Second")
        store.replace(with: snapshot(rows: [first, second], revision: 1))

        let change = store.replace(with: snapshot(rows: [second, first], revision: 2))

        XCTAssertEqual(change, .reset(updated: []))
    }

    @MainActor
    func testStructuralReplacementStillNamesChangedRetainedRows() {
        let store = RemoteConversationStore()
        let first = RemoteConversationRowDTO(id: "row-a", kind: .user, text: "Before")
        store.replace(with: snapshot(rows: [first], revision: 1))

        let updated = RemoteConversationRowDTO(id: "row-a", kind: .user, text: "After")
        let inserted = RemoteConversationRowDTO(id: "row-b", kind: .assistant, text: "New")
        let change = store.replace(with: snapshot(rows: [updated, inserted], revision: 2))

        XCTAssertEqual(change, .reset(updated: ["row-a"]))
    }

    @MainActor
    func testReplacementClearsHistoryLoadingWithoutResettingRows() {
        let store = RemoteConversationStore()
        let row = RemoteConversationRowDTO(id: "row-a", kind: .user, text: "Hello")
        let initial = snapshot(rows: [row], revision: 1, hasEarlier: true)
        store.replace(with: initial)
        XCTAssertEqual(store.beginLoadingEarlier(), "row-a")

        let change = store.replace(with: snapshot(rows: [row], revision: 2, hasEarlier: true))

        XCTAssertEqual(
            change,
            .delta(
                inserted: [],
                updated: [],
                streamingChanged: false,
                permissionChanged: false,
                capabilitiesChanged: false,
                historyChanged: true
            )
        )
        XCTAssertFalse(store.isLoadingEarlier)
    }

    @MainActor
    func testRunPlanPagesAreRevisionBoundAndTurnEndClearsTheStrip() throws {
        let connection = RemoteSessionConnection(
            session: RemoteSessionSummaryDTO(
                id: "run-plan-fixture",
                title: "Plan fixture",
                agentKind: "codex",
                surface: .conversation,
                state: .working,
                projectName: "Threading"
            ),
            client: RemoteClient(
                link: RemoteConnectionLink(string: "https://run-plan.invalid/#fixture")!
            )
        )
        let summary = RemoteRunPlanUpdateDTO(
            revision: 4,
            plan: .init(
                activeTitle: "Implement",
                current: 2,
                completed: 1,
                active: 1,
                total: 3
            )
        )
        connection.receiveServerTextForTesting(encoded(summary))

        let firstPage = RemoteRunPlanPageDTO(
            revision: 4,
            offset: 0,
            total: 3,
            steps: [
                .init(id: "step-0", title: "Inspect", status: .completed),
                .init(id: "step-1", title: "Implement", status: .inProgress),
            ]
        )
        connection.receiveServerTextForTesting(encoded(firstPage))
        XCTAssertEqual(connection.runPlan?.activeTitle, "Implement")
        XCTAssertEqual(connection.runPlanSteps.map(\.title), ["Inspect", "Implement"])

        // A duplicated first page is older than the displayed prefix. It must not replace the
        // rows or make a later page request appear to have completed.
        connection.receiveServerTextForTesting(encoded(firstPage))
        XCTAssertEqual(connection.runPlanSteps.map(\.title), ["Inspect", "Implement"])

        let stale = RemoteRunPlanPageDTO(
            revision: 3,
            offset: 2,
            total: 3,
            steps: [.init(id: "stale", title: "Stale", status: .pending)]
        )
        connection.receiveServerTextForTesting(encoded(stale))
        XCTAssertEqual(connection.runPlanSteps.count, 2)

        let outOfOrder = RemoteRunPlanPageDTO(
            revision: 4,
            offset: 1,
            total: 3,
            steps: [.init(id: "gap", title: "Gap", status: .pending)]
        )
        connection.receiveServerTextForTesting(encoded(outOfOrder))
        XCTAssertEqual(connection.runPlanSteps.count, 2)

        let wrongTotal = RemoteRunPlanPageDTO(
            revision: 4,
            offset: 2,
            total: 4,
            steps: [.init(id: "step-2", title: "Wrong total", status: .pending)]
        )
        connection.receiveServerTextForTesting(encoded(wrongTotal))
        XCTAssertEqual(connection.runPlanSteps.count, 2)

        let duplicateID = RemoteRunPlanPageDTO(
            revision: 4,
            offset: 2,
            total: 3,
            steps: [.init(id: "step-1", title: "Duplicate", status: .pending)]
        )
        connection.receiveServerTextForTesting(encoded(duplicateID))
        XCTAssertEqual(connection.runPlanSteps.count, 2)

        let oversizedPage = RemoteRunPlanPageDTO(
            revision: 4,
            offset: 2,
            total: 3,
            steps: [.init(
                id: "overflow",
                title: String(
                    repeating: "x",
                    count: RemoteMobileConnectionDefaults.runPlanMaximumTitleUTF8Bytes + 1
                ),
                status: .pending
            )]
        )
        connection.receiveServerTextForTesting(encoded(oversizedPage))
        XCTAssertEqual(connection.runPlanSteps.count, 2)

        let tail = RemoteRunPlanPageDTO(
            revision: 4,
            offset: 2,
            total: 3,
            steps: [.init(id: "step-2", title: "Verify", status: .pending)]
        )
        connection.receiveServerTextForTesting(encoded(tail))
        XCTAssertEqual(connection.runPlanSteps.map(\.title), ["Inspect", "Implement", "Verify"])

        // A malformed newer summary cannot clear a complete, valid revision or advance the
        // revision gate past a corrected frame carrying the same number.
        connection.receiveServerTextForTesting(encoded(RemoteRunPlanUpdateDTO(
            revision: 5,
            plan: .init(
                activeTitle: "Invalid",
                current: 4,
                completed: 1,
                active: 1,
                total: 3
            )
        )))
        XCTAssertEqual(connection.runPlan?.activeTitle, "Implement")
        XCTAssertEqual(connection.runPlanSteps.count, 3)

        connection.receiveServerTextForTesting(encoded(RemoteRunPlanUpdateDTO(
            revision: 5,
            plan: .init(
                activeTitle: "Verify",
                current: 1,
                completed: 0,
                active: 1,
                total: 1
            )
        )))
        XCTAssertTrue(connection.runPlanSteps.isEmpty)

        connection.receiveServerTextForTesting(encoded(RemoteRunPlanUpdateDTO(
            revision: 6,
            plan: nil
        )))
        XCTAssertNil(connection.runPlan)
        XCTAssertTrue(connection.runPlanSteps.isEmpty)

        connection.receiveServerTextForTesting(encoded(RemoteRunPlanUpdateDTO(
            revision: 7,
            plan: .init(
                activeTitle: "Do not survive disconnect",
                current: 1,
                completed: 0,
                active: 1,
                total: 1
            )
        )))
        connection.disconnect(markEnded: false)
        XCTAssertNil(connection.runPlan)
        XCTAssertTrue(connection.runPlanSteps.isEmpty)
    }

    private func snapshot(
        rows: [RemoteConversationRowDTO],
        revision: Int,
        hasEarlier: Bool = false
    ) -> RemoteConversationSnapshotDTO {
        RemoteConversationSnapshotDTO(
            rows: rows,
            canSend: true,
            revision: revision,
            hasEarlier: hasEarlier
        )
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        root.subviews.flatMap { view -> [T] in
            let own = (view as? T).map { [$0] } ?? []
            return own + descendants(of: type, in: view)
        }
    }

    private func encoded<T: Encodable>(_ value: T) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }
}
