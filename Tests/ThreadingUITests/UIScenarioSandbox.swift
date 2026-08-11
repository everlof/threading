import Foundation
import XCTest

/// One disposable Cocoa home per application-level scenario.
///
/// `CFFIXED_USER_HOME` is the isolation boundary Foundation uses for Application Support and
/// preferences; `HOME` gives child-process discovery the same answer. A UI test must never launch
/// the production app against the developer's real stores, even when the test fails halfway.
struct UIScenarioSandbox {
    private enum Defaults {
        static let markerName = ".threading-ui-scenario-home"
        static let markerContents = "Threading UI scenario home\n"
        static let onboardingCompletedVersion = "onboardingCompletedVersion"
    }

    let root: URL

    static func make(fileManager: FileManager = .default) throws -> UIScenarioSandbox {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ThreadingUITests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(Defaults.markerContents.utf8).write(
            to: root.appendingPathComponent(Defaults.markerName),
            options: .atomic
        )
        return UIScenarioSandbox(root: root)
    }

    func configure(_ application: XCUIApplication) {
        application.launchEnvironment["CFFIXED_USER_HOME"] = root.path
        application.launchEnvironment["HOME"] = root.path
        application.launchEnvironment["THREADING_UI_SCENARIO_HOME"] = root.path
        application.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
            "-\(Defaults.onboardingCompletedVersion)", "1",
        ]
    }

    func remove(fileManager: FileManager = .default) throws {
        let marker = root.appendingPathComponent(Defaults.markerName)
        guard UUID(uuidString: root.lastPathComponent) != nil,
              root.deletingLastPathComponent().lastPathComponent == "ThreadingUITests",
              fileManager.fileExists(atPath: marker.path)
        else {
            throw UIScenarioSandboxError.refusedUnsafeRemoval(root)
        }
        try fileManager.removeItem(at: root)
    }
}

enum UIScenarioSandboxError: LocalizedError {
    case refusedUnsafeRemoval(URL)

    var errorDescription: String? {
        switch self {
        case .refusedUnsafeRemoval(let url):
            return "refused to remove unverified UI scenario directory at \(url.path)"
        }
    }
}
