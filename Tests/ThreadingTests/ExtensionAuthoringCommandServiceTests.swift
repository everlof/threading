import XCTest
@testable import Threading
import ThreadingExtensionKit

@MainActor
final class ExtensionAuthoringCommandServiceTests: XCTestCase {
    private var testDirectory: URL!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ExtensionAuthoringCommandServiceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
    }

    func testCatalogCommandsRunWithoutCoordinatorOrWindow() throws {
        let fixture = try makeFixture()

        let listed = fixture.service.listComponents()
        XCTAssertFalse(listed.isError, listed.text)
        XCTAssertTrue(listed.text.contains(#""sidebar.session-row""#))

        let described = fixture.service.describeComponent(
            ExtensionComponentReferenceArguments(
                component: "sidebar.session-identity",
                version: 1
            )
        )
        XCTAssertFalse(described.isError, described.text)
        XCTAssertTrue(described.text.contains(#""patchSchema""#))
    }

    func testValidationUsesTheAuthoritativeComponentCatalog() throws {
        let fixture = try makeFixture()
        let patch = try XCTUnwrap(
            ThreadingComponentCatalog.entries.first {
                $0.contract.id == .sidebarSessionIdentity
            }?.examplePatch
        )
        let patchJSON = String(decoding: try JSONEncoder().encode(patch), as: UTF8.self)

        let result = fixture.service.validateComponentPatch(
            ExtensionComponentPatchArguments(patch: patchJSON)
        )

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains(#""valid" : true"#))
        XCTAssertTrue(result.text.contains(#""two-part-session-identity""#))
    }

    func testScaffoldCommitsTheNewProjectBeforeReportingSuccess() throws {
        let fixture = try makeFixture()
        let destination = testDirectory.appendingPathComponent(
            "StatusExtension",
            isDirectory: true
        )

        let result = fixture.service.scaffoldProject(
            ExtensionScaffoldProjectArguments(
                name: "Status Extension",
                identifier: "com.example.status-extension",
                directory: destination.path
            )
        )

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("added it as a Threading project"), result.text)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("Package.swift").path
        ))
        XCTAssertEqual(
            fixture.store.projects.first { $0.folderPath == destination.path }?.name,
            "StatusExtension"
        )
    }

    func testScaffoldRefusesRelativeDestinationsBeforeTouchingTheSDK() throws {
        let fixture = try makeFixture()

        let result = fixture.service.scaffoldProject(
            ExtensionScaffoldProjectArguments(
                name: "Status Extension",
                identifier: "com.example.status-extension",
                directory: "relative/path"
            )
        )

        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "directory must be an absolute path")
    }

    private func makeFixture() throws -> Fixture {
        let store = ProjectStore(stateManager: StateManager(
            appSupportDirectory: testDirectory.appendingPathComponent("state", isDirectory: true)
        ))
        let sdk = try makeSDKSnapshot()
        return Fixture(
            store: store,
            service: ExtensionAuthoringCommandService(
                projects: store,
                sdkSnapshotURL: { sdk }
            )
        )
    }

    private func makeSDKSnapshot() throws -> URL {
        let root = testDirectory.appendingPathComponent("ExtensionSDK", isDirectory: true)
        let sdk = root.appendingPathComponent("ThreadingExtensionKit", isDirectory: true)
        let docs = root.appendingPathComponent("docs/extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: docs.appendingPathComponent("schema", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("1.2.3\n".utf8).write(to: sdk.appendingPathComponent("SDK_VERSION"))
        try Data("// fixture\n".utf8).write(to: sdk.appendingPathComponent("Package.swift"))
        for path in [
            "AGENT_AUTHORING.md",
            "API_V1.md",
            "schema/extension-manifest.schema.json"
        ] {
            try Data("fixture\n".utf8).write(to: docs.appendingPathComponent(path))
        }
        return sdk
    }
}

@MainActor
private struct Fixture {
    let store: ProjectStore
    let service: ExtensionAuthoringCommandService
}
