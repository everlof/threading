#if DEBUG
import Foundation

/// Creates synthetic installations from the signed helper on a worker before receipts load.
/// Executables written by the sandboxed UI runner receive quarantine and cannot be launched.
enum UIScenarioManagedAgents {
    static func prepareIfRequested() -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard let requested = environment["THREADING_UI_SCENARIO_MANAGED_AGENTS"] else { return nil }
        guard requested == "1", let home = environment["THREADING_UI_SCENARIO_HOME"],
              environment["HOME"] == home, environment["CFFIXED_USER_HOME"] == home else {
            return "managed agent fixture does not own its scenario home"
        }
        let root = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath()
        guard UUID(uuidString: root.lastPathComponent) != nil,
              root.deletingLastPathComponent().lastPathComponent == "ThreadingUITests",
              (try? Data(contentsOf: root.appendingPathComponent(".threading-ui-scenario-home")))
                == Data("Threading UI scenario home\n".utf8) else {
            return "managed agent fixture home marker is invalid"
        }
        let provider = root.appendingPathComponent("AgentTools/claude")
        let receipt = provider.appendingPathComponent("active.json")
        let files = FileManager.default
        // Relaunch must keep the generation selected through the shipping settings action.
        guard !files.fileExists(atPath: receipt.path) else { return nil }
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
            .standardizedFileURL.resolvingSymlinksInPath()
        let helper = helpers.appendingPathComponent("threading-scenario").resolvingSymlinksInPath()
        guard helper.deletingLastPathComponent() == helpers,
              files.isExecutableFile(atPath: helper.path) else {
            return "the signed UI scenario helper is not embedded"
        }
        do {
            let active = try installation("2.0.0", helper: helper, provider: provider)
            let previous = try installation("1.0.0", helper: helper, provider: provider)
            try JSONEncoder().encode(ManagedAgentReceipt(active: active, previous: previous))
                .write(to: receipt, options: .atomic)
            return nil
        } catch {
            return "could not prepare managed agent fixture: \(error.localizedDescription)"
        }
    }

    private static func installation(
        _ version: String, helper: URL, provider: URL
    ) throws -> ManagedAgentInstallation {
        let installation = ManagedAgentInstallation(
            version: version, directory: UUID().uuidString,
            executable: "managed-agent-\(version)", archiveIntegrity: "signed-ui-fixture"
        )
        let directory = provider.appendingPathComponent(installation.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: helper, to: directory.appendingPathComponent(installation.executable))
        try JSONEncoder().encode(installation)
            .write(to: directory.appendingPathComponent(".threading-installation.json"), options: .atomic)
        return installation
    }
}
#endif
