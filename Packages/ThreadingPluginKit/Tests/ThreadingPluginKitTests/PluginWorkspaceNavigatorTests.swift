import XCTest
@testable import ThreadingPluginKit

@MainActor
final class PluginWorkspaceNavigatorTests: XCTestCase {
    func testContextAppliesContentDeltaWithoutReplacingUnchangedItems() {
        let project = item("shared", kind: .project)
        let first = item("first", kind: .session, title: "First")
        let second = item("shared", kind: .session, title: "Second")
        let context = context(items: [project, first, second])
        var delivered: PluginWorkspaceUpdate?
        context.observeUpdates { delivered = $0 }

        let changed = item("first", kind: .session, title: "Changed")
        context.receiveHostUpdate(PluginWorkspaceUpdate(
            revision: 2,
            items: [changed],
            removedItems: [identity("shared", kind: .session)]
        ))

        XCTAssertTrue(delivered?.items.first === changed)
        XCTAssertEqual(context.snapshot.items.map(\.title), ["Shared", "Changed"])
        XCTAssertTrue(context.snapshot.items[0] === project)
    }

    func testContextAppliesReplacementAndTypedSelectionAtomically() {
        let context = context(items: [item("old", kind: .session)])
        let replacement = item("same", kind: .session)
        let selected = identity("same", kind: .session)

        context.receiveHostUpdate(PluginWorkspaceUpdate(
            revision: 3,
            isReplacement: true,
            items: [replacement],
            selectionChanged: true,
            selectedItemIdentity: selected
        ))

        XCTAssertEqual(context.snapshot.revision, 3)
        XCTAssertEqual(context.snapshot.items.map { $0.identity.identifier }, ["same"])
        XCTAssertEqual(context.snapshot.selectedItemIdentity?.kind, .session)
        XCTAssertEqual(context.snapshot.selectedItemIdentity?.identifier, "same")
    }

    func testDuplicateChangesCannotTrapAndRemovalWins() {
        let context = context(items: [item("same", kind: .session, title: "Original")])
        var delivered: PluginWorkspaceUpdate?
        context.observeUpdates { delivered = $0 }

        context.receiveHostUpdate(PluginWorkspaceUpdate(
            revision: 2,
            items: [
                item("same", kind: .session, title: "First"),
                item("same", kind: .session, title: "Last"),
            ],
            removedItems: [identity("same", kind: .session)]
        ))

        XCTAssertTrue(context.snapshot.items.isEmpty)
        XCTAssertTrue(delivered?.items.isEmpty == true)
        XCTAssertEqual(delivered?.removedItems.count, 1)
    }

    func testRemovedIdentityCanReturnBeforeOrderCompactionWithoutDuplicating() {
        let context = context(items: [item("same", kind: .session, title: "Original")])
        context.receiveHostUpdate(PluginWorkspaceUpdate(
            revision: 2,
            items: [],
            removedItems: [identity("same", kind: .session)]
        ))
        context.receiveHostUpdate(PluginWorkspaceUpdate(
            revision: 3,
            items: [item("same", kind: .session, title: "Returned")]
        ))

        XCTAssertEqual(context.snapshot.items.count, 1)
        XCTAssertEqual(context.snapshot.items.first?.title, "Returned")
    }

    func testIdentityEqualityIncludesKindAndOpaqueIdentifier() {
        let first = identity("same", kind: .session)
        let equal = identity("same", kind: .session)
        let project = identity("same", kind: .project)

        XCTAssertEqual(first, equal)
        XCTAssertEqual(first.hash, equal.hash)
        XCTAssertNotEqual(first, project)
        XCTAssertEqual(Set([first, equal, project]).count, 2)
    }

    func testAOneItemDeltaKeepsTheDeliveredWorkBounded() {
        let items = (0..<5_000).map { item("\($0)", kind: .session) }
        let context = context(items: items)
        var deliveredCount = 0
        context.observeUpdates { deliveredCount = $0.items.count }

        context.receiveHostUpdate(PluginWorkspaceUpdate(
            revision: 2,
            items: [item("2500", kind: .session, title: "Changed")]
        ))

        XCTAssertEqual(deliveredCount, 1)
        XCTAssertEqual(context.snapshot.items[2_500].title, "Changed")
    }

    func testStaleUpdateIsIgnored() {
        let original = item("original", kind: .session)
        let context = context(items: [original], revision: 4)
        var deliveries = 0
        context.observeUpdates { _ in deliveries += 1 }

        context.receiveHostUpdate(PluginWorkspaceUpdate(
            revision: 4,
            isReplacement: true,
            items: [item("stale", kind: .session)]
        ))

        XCTAssertTrue(context.snapshot.items.first === original)
        XCTAssertEqual(deliveries, 0)
    }

    func testActivationAndMutationReturnTypedIdentityThroughHostHandlers() {
        var activation: PluginWorkspaceItemIdentity?
        var mutation: (PluginWorkspaceAction, PluginWorkspaceItemIdentity)?
        let context = PluginWorkspaceNavigatorContext(
            navigatorIdentifier: "focused",
            initialSnapshot: PluginWorkspaceSnapshot(
                revision: 1,
                items: [],
                selectedItemIdentity: nil
            ),
            activate: {
                activation = $0
                return true
            },
            perform: {
                mutation = ($0, $1)
                return false
            }
        )

        XCTAssertTrue(context.activate(identity: identity("project", kind: .project)))
        XCTAssertFalse(context.perform(
            action: .archive,
            identity: identity("session", kind: .session)
        ))
        XCTAssertEqual(activation?.kind, .project)
        XCTAssertEqual(activation?.identifier, "project")
        XCTAssertEqual(mutation?.0, .archive)
        XCTAssertEqual(mutation?.1.kind, .session)
        XCTAssertEqual(mutation?.1.identifier, "session")
    }

    func testChangeRequestSummaryCarriesOnlyBoundedProviderNeutralState() {
        let url = URL(string: "https://forge.example/team/project/pulls/42")!
        let summary = PluginWorkspaceChangeRequest(
            providerName: "Forgejo",
            changeRequestName: "pull request",
            number: 42,
            title: "Keep navigator provider-neutral",
            webURL: url,
            lifecycle: .draft,
            successfulChecks: 3,
            nonBlockingChecks: 1,
            activeChecks: 2,
            checksNeedingAttention: 1,
            unknownChecks: 1,
            checksAreIncomplete: true,
            approvals: 2,
            changesRequested: 1,
            reviewsRequested: 3
        )
        let row = PluginWorkspaceItem(
            identity: identity("session", kind: .session),
            title: "Session",
            changeRequest: summary
        )

        XCTAssertTrue(row.changeRequest === summary)
        XCTAssertEqual(summary.providerName, "Forgejo")
        XCTAssertEqual(summary.number, 42)
        XCTAssertEqual(summary.webURL, url)
        XCTAssertEqual(summary.lifecycle, .draft)
        XCTAssertEqual(summary.successfulChecks, 3)
        XCTAssertEqual(summary.checksNeedingAttention, 1)
        XCTAssertEqual(summary.approvals, 2)
        XCTAssertEqual(summary.reviewsRequested, 3)
    }

    func testVisibleInterestIsDeduplicatedBoundedAndLimitedToLiveSessions() {
        let liveItems = (0..<200).map { item("session-\($0)", kind: .session) }
        let contextItems = liveItems + [item("project", kind: .project)]
        var delivered: [PluginWorkspaceItemIdentity] = []
        let context = PluginWorkspaceNavigatorContext(
            navigatorIdentifier: "focused",
            initialSnapshot: PluginWorkspaceSnapshot(
                revision: 1,
                items: contextItems,
                selectedItemIdentity: nil
            ),
            activate: { _ in false },
            perform: { _, _ in false },
            visibleItemsDidChange: { delivered = $0 }
        )

        let requested = [
            identity("project", kind: .project),
            identity("missing", kind: .session),
            identity("session-0", kind: .session),
            identity("session-0", kind: .session),
        ] + (1..<124).map { identity("session-\($0)", kind: .session) }
        XCTAssertTrue(context.setVisibleItemIdentities(requested))

        XCTAssertEqual(delivered.count, 124)
        XCTAssertEqual(delivered.first?.identifier, "session-0")
        XCTAssertTrue(delivered.allSatisfy { $0.kind == .session })

        let oversized = (0...PluginWorkspaceNavigatorContext.maximumVisibleItemCount).map {
            identity("session-\($0)", kind: .session)
        }
        XCTAssertFalse(context.setVisibleItemIdentities(oversized))
        XCTAssertEqual(delivered.first?.identifier, "session-0")
    }

    func testRepeatedVisibleInterestDoesNotNotifyTheHostAgain() {
        var deliveries = 0
        let session = item("session", kind: .session)
        let context = PluginWorkspaceNavigatorContext(
            navigatorIdentifier: "focused",
            initialSnapshot: PluginWorkspaceSnapshot(
                revision: 1,
                items: [session],
                selectedItemIdentity: nil
            ),
            activate: { _ in false },
            perform: { _, _ in false },
            visibleItemsDidChange: { _ in deliveries += 1 }
        )

        context.setVisibleItemIdentities([session.identity])
        context.setVisibleItemIdentities([session.identity])

        XCTAssertEqual(deliveries, 1)
    }

    func testObserverCanBeReplacedAndStopped() {
        let context = context(items: [])
        var first = 0
        var second = 0
        context.observeUpdates { _ in first += 1 }
        context.observeUpdates { _ in second += 1 }
        context.receiveHostUpdate(PluginWorkspaceUpdate(revision: 2, items: []))
        context.stopObservingUpdates()
        context.receiveHostUpdate(PluginWorkspaceUpdate(revision: 3, items: []))

        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
    }

    private func context(
        items: [PluginWorkspaceItem],
        revision: UInt64 = 1
    ) -> PluginWorkspaceNavigatorContext {
        PluginWorkspaceNavigatorContext(
            navigatorIdentifier: "focused",
            initialSnapshot: PluginWorkspaceSnapshot(
                revision: revision,
                items: items,
                selectedItemIdentity: nil
            ),
            activate: { _ in false },
            perform: { _, _ in false }
        )
    }

    private func identity(
        _ identifier: String,
        kind: PluginWorkspaceItemKind
    ) -> PluginWorkspaceItemIdentity {
        PluginWorkspaceItemIdentity(kind: kind, identifier: identifier)
    }

    private func item(
        _ identifier: String,
        kind: PluginWorkspaceItemKind,
        title: String? = nil
    ) -> PluginWorkspaceItem {
        PluginWorkspaceItem(
            identity: identity(identifier, kind: kind),
            title: title ?? identifier.capitalized
        )
    }
}
