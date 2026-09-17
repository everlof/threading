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
        static let maximumArchiveBytes = 1 * 1_024 * 1_024
        static let maximumLayoutCount = 64
        static let maximumKeysPerLayout = 64
        static let maximumAgentKindBytes = 1_024
        static let maximumLabelBytes = 256
        static let maximumActionBytes = 64 * 1_024
        static let maximumAggregateStringBytes = 768 * 1_024
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
            guard data.count <= Defaults.maximumArchiveBytes else {
                throw ValidationError.invalidArchive
            }
            let decoded = try JSONDecoder().decode(Archive.self, from: data)
            guard (decoded.version ?? 1) <= Defaults.archiveVersion else {
                customLayouts = [:]
                writesAllowed = false
                recoveryMessage = "Saved keyboards were created by a newer version."
                MobileDiagnostics.logDegraded(.keyboardStorage, code: .newerFormat)
                return
            }
            try Self.validate(decoded.layouts)
            customLayouts = decoded.layouts
        } catch {
            MobileDiagnostics.logFailure(.keyboardStorage, error: error)
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
#if DEBUG
        if ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_ID"]?
            .hasPrefix("terminal-custom-key-layout-") == true,
           agentKind == "codex"
        {
            var keys = RemoteTerminalKeyboardLayout.standard(forAgentKind: agentKind).keys
            keys.insert(RemoteTerminalKeyDefinition(
                customLabel: "🍕",
                action: .snippet(text: "🍕", submits: false),
                row: .top
            ), at: 0)
            return RemoteTerminalKeyboardLayout(keys: keys)
        }
#endif
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
        do {
            try Self.validate(layouts)
        } catch {
            MobileDiagnostics.logFailure(.keyboardStorage, code: .validation)
            recoveryMessage = "Keyboards exceeded their safe storage limits and were not changed."
            return
        }
        let archive = Archive(version: Defaults.archiveVersion, layouts: layouts)
        guard let data = try? JSONEncoder().encode(archive),
              data.count <= Defaults.maximumArchiveBytes else {
            MobileDiagnostics.logFailure(.keyboardStorage, code: .encode)
            recoveryMessage = "Keyboards exceeded their safe storage limit and were not changed."
            return
        }
        defaults.set(data, forKey: Defaults.archiveKey)
        guard defaults.data(forKey: Defaults.archiveKey) == data else {
            MobileDiagnostics.logFailure(.keyboardStorage, code: .writeVerification)
            writesAllowed = false
            recoveryMessage = "Keyboards could not be saved. Changes are paused."
            return
        }
        customLayouts = layouts
        recoveryMessage = nil
    }

    private enum ValidationError: Error {
        case invalidArchive
    }

    private static func validate(
        _ layouts: [String: RemoteTerminalKeyboardLayout]
    ) throws {
        guard layouts.count <= Defaults.maximumLayoutCount else {
            throw ValidationError.invalidArchive
        }

        var aggregateBytes = 0
        func count(_ value: String, maximum: Int, mayBeEmpty: Bool = false) throws {
            let bytes = value.utf8.count
            guard (mayBeEmpty || !value.isEmpty), bytes <= maximum else {
                throw ValidationError.invalidArchive
            }
            let (total, overflow) = aggregateBytes.addingReportingOverflow(bytes)
            guard !overflow, total <= Defaults.maximumAggregateStringBytes else {
                throw ValidationError.invalidArchive
            }
            aggregateBytes = total
        }

        for (agentKind, layout) in layouts {
            try count(agentKind, maximum: Defaults.maximumAgentKindBytes)
            guard layout.keys.count <= Defaults.maximumKeysPerLayout,
                  Set(layout.keys.map(\.id)).count == layout.keys.count else {
                throw ValidationError.invalidArchive
            }
            for key in layout.keys {
                if let customLabel = key.customLabel {
                    try count(
                        customLabel,
                        maximum: Defaults.maximumLabelBytes,
                        mayBeEmpty: true
                    )
                }
                switch key.action {
                case .sequence(let sequence):
                    try count(
                        sequence,
                        maximum: Defaults.maximumActionBytes,
                        mayBeEmpty: true
                    )
                case .snippet(let text, _):
                    try count(
                        text,
                        maximum: Defaults.maximumActionBytes,
                        mayBeEmpty: true
                    )
                case .named, .latch:
                    break
                }
            }
        }
    }
}
