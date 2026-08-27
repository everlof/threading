import XCTest
@testable import Threading

/// What `LiveExtensionHostSnapshotProvider` answers when the broker asks for a root.
///
/// The broker's own tests use a stub, which is the right seam for the parse. This is the other
/// half: the resolver that actually reads `ProjectStore`, and the one rule it exists to state —
/// a session workspace resolves only for the project that owns the session. That rule used to be
/// enforced by comparing two lowercased UUID strings, so the project and the session were the
/// same type and a swapped call site compiled. They are typed now, and these tests pin the
/// behaviour that swap has to keep failing closed.
@MainActor
final class ExtensionFileRootResolutionTests: HostedStoreTestCase {

    private let provider = LiveExtensionHostSnapshotProvider()

    func testAProjectsCheckoutResolvesAndAnUnknownProjectDoesNot() throws {
        let store = ProjectStore.shared
        let folder = Self.uniqueFolder("checkout")
        let project = try XCTUnwrap(store.addProject(folderURL: folder))
        defer { store.removeProject(id: project.id) }

        XCTAssertEqual(
            provider.projectCheckoutRoot(projectID: project.id)?.path,
            folder.path
        )
        XCTAssertNil(
            provider.projectCheckoutRoot(projectID: ProjectID()),
            "a project id nothing was ever stored under resolved to a root"
        )
    }

    /// The project check is the rule, not a convenience. A session that lives in project B is
    /// refused when the query names project A, rather than answered from B's workspace.
    func testASessionWorkspaceResolvesOnlyUnderTheProjectThatOwnsTheSession() throws {
        let store = ProjectStore.shared
        let ownerFolder = Self.uniqueFolder("owner")
        let otherFolder = Self.uniqueFolder("other")
        let owner = try XCTUnwrap(store.addProject(folderURL: ownerFolder))
        let other = try XCTUnwrap(store.addProject(folderURL: otherFolder))
        defer {
            store.removeProject(id: owner.id)
            store.removeProject(id: other.id)
        }
        let session = try XCTUnwrap(store.addSession(to: owner.id, kind: .claude))

        XCTAssertEqual(
            provider.sessionWorkspaceRoot(projectID: owner.id, sessionID: session.id)?.path,
            ownerFolder.path
        )
        XCTAssertNil(
            provider.sessionWorkspaceRoot(projectID: other.id, sessionID: session.id),
            "a session resolved a workspace under a project that does not own it"
        )
        XCTAssertNil(
            provider.sessionWorkspaceRoot(projectID: owner.id, sessionID: SessionID()),
            "a session id nothing was ever stored under resolved to a workspace"
        )
    }

    /// The identifiers were two `String`s until this change, so a caller could hand the session
    /// where the project belonged and the code compiled. It failed closed then and still does —
    /// and the swap is now spelled with the wrappers' raw UUIDs, because the typed signature no
    /// longer allows the mistake it is describing.
    func testTheSwappedPairResolvesNothing() throws {
        let store = ProjectStore.shared
        let folder = Self.uniqueFolder("swap")
        let project = try XCTUnwrap(store.addProject(folderURL: folder))
        defer { store.removeProject(id: project.id) }
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))

        XCTAssertNil(
            provider.sessionWorkspaceRoot(
                projectID: ProjectID(session.id.rawValue),
                sessionID: SessionID(project.id.rawValue)
            ),
            "the project and the session were interchangeable after all"
        )
    }

    // MARK: - Fixtures

    /// A path of its own per test: `addProject` returns the existing project for a folder it
    /// already knows, so a shared temporary directory would hand this test a sibling's project
    /// and then delete it on the way out.
    private static func uniqueFolder(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("threading-extension-roots-\(name)-\(UUID().uuidString)")
    }
}
