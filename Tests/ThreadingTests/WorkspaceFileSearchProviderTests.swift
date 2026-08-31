@testable import Threading
import XCTest

final class WorkspaceFileSearchProviderTests: XCTestCase {
    func testProjectScopeReturnsTypedRelativePathLocator() async throws {
        let root = try makeRoot(files: ["Sources/Search/Coordinator.swift", "README.md"])
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = ProjectID()
        let index = WorkspaceFileIndex(loader: { _ in
            ["Sources/Search/Coordinator.swift", "README.md"]
        })
        let provider = WorkspaceFileSearchProvider(
            projects: [WorkspaceFileSearchProject(
                projectID: projectID,
                projectName: "Threading",
                root: root,
                updatedAt: Date(timeIntervalSince1970: 1000)
            )],
            index: index
        )
        let query = try XCTUnwrap(try? SearchQueryParser.parse(
            "coordinator",
            scope: .project(projectID),
            generation: 7
        ).get())

        let batches = await collect(provider.search(SearchProviderRequest(
            query: query,
            clientCapabilities: .macOS
        )))

        let hit = try XCTUnwrap(batches.first?.hits.first)
        XCTAssertEqual(hit.title, "Coordinator.swift")
        XCTAssertEqual(hit.provenance.relativePath, "Sources/Search/Coordinator.swift")
        guard case .workspaceFile(let landedProject, nil, let location) = hit.locator else {
            return XCTFail("Expected a workspace-file locator")
        }
        XCTAssertEqual(landedProject, projectID)
        XCTAssertEqual(location.relativePath, "Sources/Search/Coordinator.swift")
    }

    func testFiltersAndNegativeTermsApplyAfterPathRanking() async throws {
        let root = try makeRoot(files: ["Sources/SearchIndex.swift", "Tests/SearchIndexTests.swift"])
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = ProjectID()
        let provider = WorkspaceFileSearchProvider(
            projects: [WorkspaceFileSearchProject(
                projectID: projectID,
                projectName: "Threading",
                root: root,
                updatedAt: .distantPast
            )],
            index: WorkspaceFileIndex(loader: { _ in
                ["Sources/SearchIndex.swift", "Tests/SearchIndexTests.swift"]
            })
        )
        let query = try SearchQueryParser.parse(
            "search -tests type:file project:Thread",
            scope: .everywhere,
            generation: 2
        ).get()

        let batches = await collect(provider.search(SearchProviderRequest(
            query: query,
            clientCapabilities: .macOS
        )))

        XCTAssertEqual(batches.flatMap(\.hits).map(\.provenance.relativePath), [
            "Sources/SearchIndex.swift",
        ])
    }

    func testEmptyQueryDoesNotMaterializeFileCatalogues() async throws {
        let root = try makeRoot(files: ["README.md"])
        defer { try? FileManager.default.removeItem(at: root) }
        let load = expectation(description: "loader must not run")
        load.isInverted = true
        let provider = WorkspaceFileSearchProvider(
            projects: [WorkspaceFileSearchProject(
                projectID: ProjectID(), projectName: "P", root: root, updatedAt: .distantPast
            )],
            index: WorkspaceFileIndex(loader: { _ in
                load.fulfill()
                return ["README.md"]
            })
        )
        let query = try SearchQueryParser.parse("", scope: .everywhere, generation: 1).get()

        let batches = await collect(provider.search(SearchProviderRequest(
            query: query,
            clientCapabilities: .macOS
        )))

        await fulfillment(of: [load], timeout: 0.05)
        XCTAssertEqual(batches.first?.hits, [])
    }

    private func makeRoot(files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-workspace-search-\(UUID().uuidString)", isDirectory: true)
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        }
        return root
    }

    private func collect(_ stream: AsyncStream<SearchBatch>) async -> [SearchBatch] {
        var batches: [SearchBatch] = []
        for await batch in stream {
            batches.append(batch)
        }
        return batches
    }
}
