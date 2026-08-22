import Foundation
import XCTest
@testable import Threading

/// Owns the non-shared artifacts created for one main-window fixture. The hosted store, runtime,
/// and settings are the redirected shared test graph; only the diagnostic journal is isolated
/// per controller. Teardown releases the controller (and therefore its environment and EventLog)
/// before removing that directory.
@MainActor
final class MainWindowTestFixtureOwner {
    private var controller: MainWindowController?
    private let directory: URL

    init(controller: MainWindowController, directory: URL) {
        self.controller = controller
        self.directory = directory
    }

    func tearDown(file: StaticString = #filePath, line: UInt = #line) {
        controller = nil
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        } catch {
            XCTFail(
                "Main-window fixture left diagnostics at \(directory.path): \(error)",
                file: file,
                line: line
            )
        }
    }
}

extension HostedStoreTestCase {
    /// Builds a main window against the hosted test process's redirected shared service graph.
    ///
    /// MainWindowController intentionally has no live fallback. Keeping this composition in
    /// test support makes every caller inherit the store redirect and teardown proof. These are
    /// not independently constructed services: the project store is the per-process scratch
    /// singleton, the runtime shares that exact store, and behavioural settings use the hosted
    /// app's shared settings. Diagnostics alone stay UUID-scoped and are owned until teardown.
    @MainActor
    func makeMainWindowController(
        initialFramePlan: MainWindowInitialFramePlan = .restoreSavedFrame,
        file _: StaticString = #filePath,
        line _: UInt = #line
    ) -> MainWindowController {
        let identity = "MainWindowTestSupport.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(identity, isDirectory: true)
        let environment = AppEnvironment(
            projectStore: ProjectStore.shared,
            agentRuntime: AgentRuntime.shared,
            settings: AppSettings.shared,
            eventLog: EventLog(directory: directory.appendingPathComponent("Logs"))
        )
        let controller = MainWindowController(
            environment: environment,
            initialFramePlan: initialFramePlan
        )
        retainMainWindowFixture(
            MainWindowTestFixtureOwner(controller: controller, directory: directory)
        )
        return controller
    }
}
