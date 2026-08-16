import XCTest
@testable import Threading

/// A test case that leaves nothing behind in the shared project store.
///
/// The hosted test bundle runs *inside* the shipping app, so `ProjectStore.shared` is the same
/// singleton the developer's running copy uses, and `StateManager.shared` used to resolve the
/// same Application Support directory. `ProjectDatabase.save(_:)` reconciles the whole graph —
/// it deletes every project the state it is handed does not mention — so a fixture's `addProject`
/// wrote the test's list over the real store and deleted the projects its stale snapshot had
/// never seen, taking their chats with them through `ON DELETE CASCADE`. Projects were lost
/// this way; fixture rows for `/var/folders/…/T/sound-scope-…` were still recoverable from the
/// user's live database afterwards.
///
/// `StateManager` now redirects the singleton to a per-process scratch directory, which is the
/// fix. This base class is the second half: it proves the redirect is still in place and erases
/// what the test stored, so a suite cannot accumulate state across its own cases either. Both
/// matter — the redirect makes leakage harmless, and the teardown keeps one test's projects out
/// of the next test's assertions.
///
/// **Inherit from this instead of `XCTestCase` in any test that mutates `ProjectStore.shared`.**
/// A test that only reads it may too; erasing an already-empty store costs nothing.
class HostedStoreTestCase: XCTestCase {
    private var mainWindowFixtureOwners: [MainWindowTestFixtureOwner] = []

    /// Overrides the async hook rather than `tearDown()` so subclasses keep their own sync
    /// teardown, and so the main-actor work can be awaited instead of asserted into place —
    /// `MainActor.assumeIsolated` would trap here for an async test case.
    override func tearDown() async throws {
        try await super.tearDown()
        await MainActor.run {
            tearDownMainWindowFixtures()
            Self.eraseHostedStore()
        }
    }

    /// Retains the explicit owner of a main-window fixture until XCTest has run the subclass's
    /// synchronous teardown and the test method's local controller references have left scope.
    @MainActor
    func retainMainWindowFixture(_ owner: MainWindowTestFixtureOwner) {
        mainWindowFixtureOwners.append(owner)
    }

    @MainActor
    private func tearDownMainWindowFixtures() {
        for owner in mainWindowFixtureOwners {
            owner.tearDown()
        }
        mainWindowFixtureOwners.removeAll()
    }

    /// Removes every project from the shared store and erases the scratch state on disk.
    ///
    /// Removal goes through `ProjectStore.removeProject` rather than deleting the database, so
    /// the stores that hang off a project — drafts, work traces, git checkpoints, scheduled
    /// messages, the audit chain — are cleaned by the same code that cleans them in the app.
    /// The directory is erased afterwards for whatever a test wrote outside that graph.
    @MainActor
    static func eraseHostedStore(file: StaticString = #filePath, line: UInt = #line) {
        guard StateManager.sharedUsesHostedTestState else {
            XCTFail(
                """
                Refusing to erase: the shared store is NOT the hosted-test store. Something has \
                undone StateManager's hosted-test redirect, which means this test bundle is \
                writing to the developer's real projects database — the failure that has already \
                cost projects and their chats once. Fix the redirect; do not delete anything here.
                """,
                file: file,
                line: line
            )
            return
        }

        let store = ProjectStore.shared
        for project in store.projects {
            _ = store.removeProject(id: project.id)
        }
        XCTAssertTrue(
            store.projects.isEmpty,
            "a project survived teardown, so the next test starts on this one's state",
            file: file,
            line: line
        )

        StateManager.eraseHostedTestState()
    }
}
