import Foundation
import ThreadingRemoteKit

/// The customized terminal key bars on this phone or tablet.
///
/// Layouts are deliberately device-local — a phone and an iPad earn different bars, which is
/// also Termius's model — so this store owns them the way `MobileSessionContinuityStore` owns
/// drafts: a versioned archive in `UserDefaults`, an unreadable archive preserved for recovery
/// rather than overwritten, and writes latched off rather than guessed at when persistence
/// misbehaves. Customization is keyed by the session's `agentKind`, because the stock bars
/// already differ by runtime and an edit to the Claude bar should not restyle a Codex session.
@MainActor
final class MobileTerminalKeyboardStore: ObservableObject {
    @Published private(set) var customLayouts: [String: RemoteTerminalKeyboardLayout]
    @Published private(set) var recoveryMessage: String?

    private struct Archive: Codable {
        var version: Int?
        var layouts: [String: RemoteTerminalKeyboardLayout]
    }

    private enum Defaults {
        static let archiveKey = "threading.mobile.terminal-keyboard.v1"
        static let archiveVersion = 1
        static let unreadableKeyPrefix = "threading.mobile.terminal-keyboard.unreadable."
    }

    private let defaults: UserDefaults
    private var writesAllowed = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recoveryMessage = nil
        guard let data = defaults.data(forKey: Defaults.archiveKey) else {
            customLayouts = [:]
            return
        }
        do {
            let decoded = try JSONDecoder().decode(Archive.self, from: data)
            guard (decoded.version ?? 1) <= Defaults.archiveVersion else {
                customLayouts = [:]
                writesAllowed = false
                recoveryMessage = "Saved keyboards were created by a newer version."
                return
            }
            customLayouts = decoded.layouts
        } catch {
            let recoveryKey = Defaults.unreadableKeyPrefix + UUID().uuidString.lowercased()
            defaults.set(data, forKey: recoveryKey)
            if defaults.data(forKey: recoveryKey) == data {
                defaults.removeObject(forKey: Defaults.archiveKey)
                customLayouts = [:]
                recoveryMessage = "An unreadable saved keyboard was preserved for recovery."
            } else {
                customLayouts = [:]
                writesAllowed = false
                recoveryMessage = "Saved keyboards could not be read or preserved. Changes are paused."
            }
        }
    }

    /// The bar a session of this agent kind shows: the custom layout when one exists and
    /// still holds at least one key, the stock layout for that kind otherwise.
    func layout(forAgentKind agentKind: String) -> RemoteTerminalKeyboardLayout {
        if let custom = customLayouts[agentKind], !custom.keys.isEmpty {
            return custom
        }
        return .standard(forAgentKind: agentKind)
    }

    func hasCustomLayout(forAgentKind agentKind: String) -> Bool {
        customLayouts[agentKind] != nil
    }

    func setLayout(_ layout: RemoteTerminalKeyboardLayout, forAgentKind agentKind: String) {
        var layouts = customLayouts
        layouts[agentKind] = layout
        commit(layouts)
    }

    func resetLayout(forAgentKind agentKind: String) {
        guard customLayouts[agentKind] != nil else { return }
        var layouts = customLayouts
        layouts.removeValue(forKey: agentKind)
        commit(layouts)
    }

    private func commit(_ layouts: [String: RemoteTerminalKeyboardLayout]) {
        guard writesAllowed else { return }
        let archive = Archive(version: Defaults.archiveVersion, layouts: layouts)
        guard let data = try? JSONEncoder().encode(archive) else {
            writesAllowed = false
            recoveryMessage = "Keyboards could not be encoded. Changes are paused."
            return
        }
        defaults.set(data, forKey: Defaults.archiveKey)
        guard defaults.data(forKey: Defaults.archiveKey) == data else {
            writesAllowed = false
            recoveryMessage = "Keyboards could not be saved. Changes are paused."
            return
        }
        customLayouts = layouts
    }
}
