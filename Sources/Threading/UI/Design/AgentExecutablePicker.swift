import AppKit

/// System-owned file selection, contained behind a value-only result. Verification and the
/// decision to use the executable remain in the runtime installation service.
@MainActor
enum AgentExecutablePicker {
    static func choose(completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.string("Select the agent executable to use for new sessions.")
        panel.prompt = L10n.string("Choose")
        panel.begin { response in completion(response == .OK ? panel.url : nil) }
    }
}
