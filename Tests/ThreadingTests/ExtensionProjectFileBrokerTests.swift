import XCTest
@testable import Threading
@testable import ThreadingExtensionKit

/// `host.project.files.read`: what an extension may enumerate, what it may open, and every way
/// both are refused.
///
/// The load-bearing claim under test is that **a handle is not a path**. Everything else here —
/// the cursor's binding, the workspace rule, the symlink refusal, the revalidation at open — is
/// that claim defended against one particular way of getting around it.
@MainActor
final class ExtensionProjectFileBrokerTests: XCTestCase {

    private var root: URL!
    private var workspace: URL!
    private var outside: URL!
    private var provider: StubRootProvider!
    private let broker = ExtensionProjectFileBroker.shared
    private let generation = "generation-1"
    private let identifier = "codes.threading.animations"

    override func setUp() async throws {
        try await super.setUp()
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingFileBroker-\(UUID().uuidString)")
        root = base.appendingPathComponent("checkout")
        workspace = base.appendingPathComponent("worktree")
        outside = base.appendingPathComponent("elsewhere")
        for directory in [root!, workspace!, outside!] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        provider = StubRootProvider(
            projects: ["project-a": root, "project-b": outside],
            workspaces: ["project-a/session-1": workspace]
        )
        broker.rootProvider = provider
    }

    override func tearDown() async throws {
        broker.revoke(generation: generation)
        broker.rootProvider = nil
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        try await super.tearDown()
    }

    // MARK: - Enumeration

    func testEnumerationReturnsHandlesAndBoundedMetadataButNoPath() async throws {
        try write("animations/hero.json", LottieFixture.spinningDot())
        try write("animations/nested/second.json", LottieFixture.spinningDot())
        try write("README.md", Data("hello".utf8))

        let page = try await broker.page(
            for: query(),
            extensionIdentifier: identifier,
            generation: generation
        )

        XCTAssertEqual(page.handles.count, 2)
        XCTAssertEqual(
            page.handles.map(\.relativePath),
            ["animations/hero.json", "animations/nested/second.json"],
            "the walk is not in stable lexical order"
        )
        let handle = try XCTUnwrap(page.handles.first)
        XCTAssertEqual(handle.name, "hero.json")
        XCTAssertGreaterThan(handle.byteSize, 0)
        XCTAssertEqual(handle.contentHint, .lottie)
        XCTAssertFalse(
            handle.id.contains("/"),
            "the handle looks like a path: \(handle.id)"
        )
        XCTAssertFalse(
            handle.id.contains(root.path),
            "the handle carried the checkout's absolute path"
        )
    }

    func testTheWalkSkipsDependencyDirectoriesAndHiddenFiles() async throws {
        try write("animations/hero.json", LottieFixture.spinningDot())
        try write("node_modules/pkg/hero.json", LottieFixture.spinningDot())
        try write(".hidden/hero.json", LottieFixture.spinningDot())

        let page = try await broker.page(
            for: query(),
            extensionIdentifier: identifier,
            generation: generation
        )
        XCTAssertEqual(page.handles.map(\.relativePath), ["animations/hero.json"])
    }

    /// Resolving a symlink is how a link named `assets` walks out of the checkout and into the
    /// user's home directory.
    func testASymlinkOutOfTheCheckoutIsNotEnumerated() async throws {
        try write("animations/hero.json", LottieFixture.spinningDot())
        let secret = outside.appendingPathComponent("secret.json")
        try Data("{}".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.json"),
            withDestinationURL: secret
        )

        let page = try await broker.page(
            for: query(),
            extensionIdentifier: identifier,
            generation: generation
        )
        XCTAssertEqual(page.handles.map(\.relativePath), ["animations/hero.json"])
    }

    // MARK: - Pagination

    func testPagesAreStableAndTheCursorIsBoundToItsQuery() async throws {
        for index in 0..<5 {
            try write("animations/a\(index).json", LottieFixture.spinningDot())
        }

        let first = try await broker.page(
            for: query(maximumResults: 2),
            extensionIdentifier: identifier,
            generation: generation
        )
        XCTAssertEqual(first.handles.map(\.name), ["a0.json", "a1.json"])
        let cursor = try XCTUnwrap(first.nextCursor)

        let second = try await broker.page(
            for: query(maximumResults: 2, cursor: cursor),
            extensionIdentifier: identifier,
            generation: generation
        )
        XCTAssertEqual(second.handles.map(\.name), ["a2.json", "a3.json"])

        // A changed query invalidates the marker rather than silently continuing under it.
        await assertThrows(.invalidCursor) {
            _ = try await self.broker.page(
                for: self.query(
                    fileExtensions: ["json", "lottie"],
                    maximumResults: 2,
                    cursor: cursor
                ),
                extensionIdentifier: self.identifier,
                generation: self.generation
            )
        }

        // So does a different generation, which is what makes a replayed cursor useless.
        await assertThrows(.invalidCursor) {
            _ = try await self.broker.page(
                for: self.query(maximumResults: 2, cursor: cursor),
                extensionIdentifier: self.identifier,
                generation: "generation-2"
            )
        }
    }

    func testTheLastPageCarriesNoCursor() async throws {
        try write("animations/only.json", LottieFixture.spinningDot())
        let page = try await broker.page(
            for: query(maximumResults: 10),
            extensionIdentifier: identifier,
            generation: generation
        )
        XCTAssertNil(page.nextCursor)
    }

    // MARK: - Scope

    /// The broker never infers a workspace from what is selected: the query names the exact
    /// session, and a session that belongs to another project is refused.
    func testASessionWorkspaceResolvesOnlyForItsOwnProject() async throws {
        try write("animations/hero.json", LottieFixture.spinningDot(), in: workspace)

        let page = try await broker.page(
            for: query(scope: .sessionWorkspace(sessionID: "session-1")),
            extensionIdentifier: identifier,
            generation: generation
        )
        XCTAssertEqual(page.handles.map(\.name), ["hero.json"])

        await assertThrows(.unknownSessionWorkspace) {
            _ = try await self.broker.page(
                for: self.query(
                    projectID: "project-b",
                    scope: .sessionWorkspace(sessionID: "session-1")
                ),
                extensionIdentifier: self.identifier,
                generation: self.generation
            )
        }
    }

    func testAnUnknownProjectIsRefused() async {
        await assertThrows(.unknownProject) {
            _ = try await self.broker.page(
                for: self.query(projectID: "project-z"),
                extensionIdentifier: self.identifier,
                generation: self.generation
            )
        }
    }

    /// Two workspaces under one project prove the answer comes from the query rather than from
    /// anything ambient.
    func testTwoSessionWorkspacesUnderOneProjectAnswerSeparately() async throws {
        let second = workspace.deletingLastPathComponent().appendingPathComponent("worktree-2")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        provider.workspaces["project-a/session-2"] = second
        try write("animations/one.json", LottieFixture.spinningDot(), in: workspace)
        try write("animations/two.json", LottieFixture.spinningDot(), in: second)

        let first = try await broker.page(
            for: query(scope: .sessionWorkspace(sessionID: "session-1")),
            extensionIdentifier: identifier,
            generation: generation
        )
        let other = try await broker.page(
            for: query(scope: .sessionWorkspace(sessionID: "session-2")),
            extensionIdentifier: identifier,
            generation: generation
        )
        XCTAssertEqual(first.handles.map(\.name), ["one.json"])
        XCTAssertEqual(other.handles.map(\.name), ["two.json"])
    }

    // MARK: - Queries

    func testAQueryWithoutAUsableFilterIsRefused() async {
        for invalid in [
            ExtensionFileQuery(projectID: "project-a", fileExtensions: []),
            ExtensionFileQuery(projectID: "project-a", fileExtensions: ["*.json"]),
            ExtensionFileQuery(projectID: "project-a", fileExtensions: [".json"]),
            ExtensionFileQuery(
                projectID: "project-a",
                fileExtensions: ["json"],
                maximumResults: 10_000
            )
        ] {
            XCTAssertThrowsError(try invalid.validate(), "\(invalid.fileExtensions) was accepted")
        }
    }

    // MARK: - Handles

    func testAHandleOpensItsDocumentAndOnlyForItsOwnExtension() async throws {
        try write("animations/hero.json", LottieFixture.spinningDot())
        let page = try await broker.page(
            for: query(),
            extensionIdentifier: identifier,
            generation: generation
        )
        let handle = try XCTUnwrap(page.handles.first)

        XCTAssertNotNil(broker.documentData(
            forHandle: handle.id,
            extensionIdentifier: identifier,
            maximumBytes: 1_024 * 1_024
        ))
        XCTAssertNil(
            broker.documentData(
                forHandle: handle.id,
                extensionIdentifier: "codes.threading.other",
                maximumBytes: 1_024 * 1_024
            ),
            "another extension opened a handle it was never given"
        )
        XCTAssertNil(broker.documentData(
            forHandle: "not-a-handle",
            extensionIdentifier: identifier,
            maximumBytes: 1_024 * 1_024
        ))
    }

    /// The second containment check is not paranoia about the first: enumeration and rendering are
    /// separated by however long the user took to click.
    func testAFileReplacedWithASymlinkOutOfTheCheckoutStopsResolving() async throws {
        let file = root.appendingPathComponent("animations/hero.json")
        try write("animations/hero.json", LottieFixture.spinningDot())
        let page = try await broker.page(
            for: query(),
            extensionIdentifier: identifier,
            generation: generation
        )
        let handle = try XCTUnwrap(page.handles.first)

        let secret = outside.appendingPathComponent("secret.json")
        try Data("{\"secret\":true}".utf8).write(to: secret)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)

        XCTAssertNil(
            broker.resolvedURL(forHandle: handle.id, extensionIdentifier: identifier),
            "a replaced file resolved out of the checkout"
        )
    }

    /// Handles die with the token they were minted beside, so one cannot outlive the disclosure
    /// the user answered.
    func testHandlesAreRevokedWithTheirGeneration() async throws {
        try write("animations/hero.json", LottieFixture.spinningDot())
        let page = try await broker.page(
            for: query(),
            extensionIdentifier: identifier,
            generation: generation
        )
        let handle = try XCTUnwrap(page.handles.first)
        XCTAssertNotNil(broker.resolvedURL(
            forHandle: handle.id,
            extensionIdentifier: identifier
        ))

        broker.revoke(generation: generation)
        XCTAssertNil(
            broker.resolvedURL(forHandle: handle.id, extensionIdentifier: identifier),
            "a handle survived the generation that minted it"
        )
    }

    // MARK: - Fixtures

    private func query(
        projectID: String = "project-a",
        scope: ExtensionFileScope = .projectCheckout,
        fileExtensions: [String] = ["json"],
        maximumResults: Int = 200,
        cursor: String? = nil
    ) -> ExtensionFileQuery {
        ExtensionFileQuery(
            projectID: projectID,
            scope: scope,
            fileExtensions: fileExtensions,
            maximumResults: maximumResults,
            cursor: cursor
        )
    }

    private func write(_ relativePath: String, _ data: Data, in base: URL? = nil) throws {
        let url = (base ?? root).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func assertThrows(
        _ expected: ExtensionProjectFileError,
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as ExtensionProjectFileError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

@MainActor
private final class StubRootProvider: ExtensionProjectFileRootProviding {
    var projects: [String: URL]
    var workspaces: [String: URL]

    init(projects: [String: URL], workspaces: [String: URL]) {
        self.projects = projects
        self.workspaces = workspaces
    }

    func projectCheckoutRoot(projectID: String) -> URL? {
        projects[projectID]
    }

    func sessionWorkspaceRoot(projectID: String, sessionID: String) -> URL? {
        workspaces["\(projectID)/\(sessionID)"]
    }
}
