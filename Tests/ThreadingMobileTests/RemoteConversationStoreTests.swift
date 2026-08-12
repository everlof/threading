import XCTest
import ThreadingRemoteKit
@testable import ThreadingMobile

final class RemoteConversationStoreTests: XCTestCase {
    @MainActor
    func testToolDisclosureStaysCompactAndMaterializesOutputOnlyWhenExpanded() throws {
        let row = RemoteConversationRowDTO(
            id: "tool-a",
            kind: "tool",
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
            kind: "tool",
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
        let row = RemoteConversationRowDTO(id: "row-a", kind: "user", text: "Hello")
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
        let first = RemoteConversationRowDTO(id: "row-a", kind: "user", text: "Before")
        let second = RemoteConversationRowDTO(id: "row-b", kind: "assistant", text: "Stable")
        store.replace(with: snapshot(rows: [first, second], revision: 1))

        let updated = RemoteConversationRowDTO(id: "row-a", kind: "user", text: "After")
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
        let first = RemoteConversationRowDTO(id: "row-a", kind: "user", text: "First")
        let second = RemoteConversationRowDTO(id: "row-b", kind: "assistant", text: "Second")
        store.replace(with: snapshot(rows: [first, second], revision: 1))

        let change = store.replace(with: snapshot(rows: [second, first], revision: 2))

        XCTAssertEqual(change, .reset(updated: []))
    }

    @MainActor
    func testStructuralReplacementStillNamesChangedRetainedRows() {
        let store = RemoteConversationStore()
        let first = RemoteConversationRowDTO(id: "row-a", kind: "user", text: "Before")
        store.replace(with: snapshot(rows: [first], revision: 1))

        let updated = RemoteConversationRowDTO(id: "row-a", kind: "user", text: "After")
        let inserted = RemoteConversationRowDTO(id: "row-b", kind: "assistant", text: "New")
        let change = store.replace(with: snapshot(rows: [updated, inserted], revision: 2))

        XCTAssertEqual(change, .reset(updated: ["row-a"]))
    }

    @MainActor
    func testReplacementClearsHistoryLoadingWithoutResettingRows() {
        let store = RemoteConversationStore()
        let row = RemoteConversationRowDTO(id: "row-a", kind: "user", text: "Hello")
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
}
