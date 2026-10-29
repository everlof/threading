import Foundation
@testable import CoreSlice

/// Linux host persistence for the shared selected-session setting.
enum LinuxGeneralSettings {
    private static let persistence = DispatchQueue(label: "threading.linux.general-settings",
                                                   qos: .utility)

    static func detectsAttachmentReferences(for kind: AgentKind) -> Bool {
        let disabled = PreferenceStore.shared.stringArray(
            forKey: AttachmentDetectionPreferences.disabledAgentKindsKey) ?? []
        return !disabled.contains(kind.rawValue)
    }

    static func setAttachmentReferenceDetection(for kind: AgentKind, enabled: Bool) {
        var disabled = Set(PreferenceStore.shared.stringArray(
            forKey: AttachmentDetectionPreferences.disabledAgentKindsKey) ?? [])
        if enabled { disabled.remove(kind.rawValue) }
        else { disabled.insert(kind.rawValue) }
        PreferenceStore.shared.set(disabled.sorted(),
            forKey: AttachmentDetectionPreferences.disabledAgentKindsKey)
        persistChoice()
    }

    static var includesAttachmentsOutsideProject: Bool {
        get { PreferenceStore.shared.bool(forKey: AttachmentDetectionPreferences.includesOutsideProjectKey) }
        set {
            PreferenceStore.shared.set(newValue,
                forKey: AttachmentDetectionPreferences.includesOutsideProjectKey)
            persistChoice()
        }
    }

    static var defaultAgentKind: AgentKind {
        get {
            guard let raw = PreferenceStore.shared.string(forKey: NewChatDefaults.agentPersistenceKey),
                  let kind = AgentKind(rawValue: raw), kind == .claude || kind == .codex else {
                return AgentDefaults.defaultKind
            }
            return kind
        }
        set {
            guard newValue == .claude || newValue == .codex else { return }
            PreferenceStore.shared.set(newValue.rawValue, forKey: NewChatDefaults.agentPersistenceKey)
            persistChoice()
        }
    }

    static var defaultPermissionMode: AgentPermissionMode? {
        get {
            PreferenceStore.shared.string(forKey: NewChatDefaults.permissionPersistenceKey)
                .flatMap(AgentPermissionMode.init(rawValue:))
        }
        set {
            if let newValue {
                PreferenceStore.shared.set(newValue.rawValue,
                                           forKey: NewChatDefaults.permissionPersistenceKey)
            } else {
                PreferenceStore.shared.removeObject(forKey: NewChatDefaults.permissionPersistenceKey)
            }
            persistChoice()
        }
    }

    static func effectivePermissionMode(selected: AgentPermissionMode?) -> AgentPermissionMode? {
        NewChatDefaults.permissionMode(selected: selected, appDefault: defaultPermissionMode)
    }

    static var newChatOpeningPrefix: String {
        get { openingText(for: NewChatDefaults.openingPrefixPersistenceKey) }
        set { setOpeningText(newValue, for: NewChatDefaults.openingPrefixPersistenceKey) }
    }

    static var newChatOpeningSuffix: String {
        get { openingText(for: NewChatDefaults.openingSuffixPersistenceKey) }
        set { setOpeningText(newValue, for: NewChatDefaults.openingSuffixPersistenceKey) }
    }

    static func openingMessage(for task: String?) -> String? {
        NewChatOpeningMessage.compose(prompt: task,
            prefix: newChatOpeningPrefix, suffix: newChatOpeningSuffix)
    }

    static var configuredScratchpadFolderURL: URL? {
        ScratchpadLocation.configuredFolderURL(path: PreferenceStore.shared.string(
            forKey: ScratchpadDefaults.folderPathKey))
    }

    static var scratchpadFolderURL: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return configuredScratchpadFolderURL ?? ScratchpadLocation.defaultFolderURL(
            home: URL(fileURLWithPath: home, isDirectory: true))
    }

    static func setScratchpadFolderURL(_ destination: URL) {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let defaultFolder = ScratchpadLocation.defaultFolderURL(
            home: URL(fileURLWithPath: home, isDirectory: true))
        if ScratchpadLocation.directoryURL(destination) == defaultFolder {
            PreferenceStore.shared.removeObject(forKey: ScratchpadDefaults.folderPathKey)
        } else {
            PreferenceStore.shared.set(destination.path, forKey: ScratchpadDefaults.folderPathKey)
        }
        persistChoice()
    }

    private static func openingText(for key: String) -> String {
        guard let text = PreferenceStore.shared.string(forKey: key),
              text.utf8.count <= NewChatDefaults.openingTextMaximumBytes else { return "" }
        return text
    }

    private static func setOpeningText(_ text: String, for key: String) {
        guard text.utf8.count <= NewChatDefaults.openingTextMaximumBytes else { return }
        if text.isEmpty { PreferenceStore.shared.removeObject(forKey: key) }
        else { PreferenceStore.shared.set(text, forKey: key) }
        persistChoice()
    }

    static func startupSpeed(for kind: AgentKind) -> AgentStartupSpeed {
        guard let key = AgentStartupSpeed.persistenceKey(for: kind),
              let raw = PreferenceStore.shared.string(forKey: key),
              let speed = AgentStartupSpeed(rawValue: raw) else { return .agentSetting }
        return speed
    }

    static func setStartupSpeed(_ speed: AgentStartupSpeed, for kind: AgentKind) {
        guard let key = AgentStartupSpeed.persistenceKey(for: kind) else { return }
        PreferenceStore.shared.set(speed.rawValue, forKey: key)
        persistChoice()
    }

    static func effectiveSpeed(selected: Bool?, kind: AgentKind,
                               configured: @autoclosure () -> Bool?) -> Bool? {
        startupSpeed(for: kind).resolve(selected: selected, configured: configured())
    }

    static var restoresLastSession: Bool {
        get { SelectedSessionRestorePreference.read(from: PreferenceStore.shared) }
        set {
            SelectedSessionRestorePreference.write(newValue, to: PreferenceStore.shared)
            persistChoice()
        }
    }

    static var sessionRestorePolicy: SessionRestorePolicy {
        get {
            let defaults = PreferenceStore.shared
            let legacy = defaults.object(forKey: SessionRestoreDefaults.legacyRunningSessionsKey)
                .map { _ in defaults.bool(forKey: SessionRestoreDefaults.legacyRunningSessionsKey) }
                ?? true
            return SessionRestorePolicy.resolved(
                stored: defaults.string(forKey: SessionRestoreDefaults.policyKey),
                legacyRestoresRunningSessions: legacy
            )
        }
        set {
            PreferenceStore.shared.set(newValue.rawValue, forKey: SessionRestoreDefaults.policyKey)
            persistChoice()
        }
    }

    static var sessionRestoreWindowDays: Int {
        get {
            let defaults = PreferenceStore.shared
            guard defaults.object(forKey: SessionRestoreDefaults.windowDaysKey) != nil else {
                return SessionRestoreDefaults.windowDays
            }
            return SessionRestoreDefaults.clampWindowDays(
                defaults.integer(forKey: SessionRestoreDefaults.windowDaysKey))
        }
        set {
            PreferenceStore.shared.set(SessionRestoreDefaults.clampWindowDays(newValue),
                                       forKey: SessionRestoreDefaults.windowDaysKey)
            persistChoice()
        }
    }

    static var sessionRestoreLimit: Int {
        get {
            let defaults = PreferenceStore.shared
            guard defaults.object(forKey: SessionRestoreDefaults.limitKey) != nil else {
                return SessionRestoreDefaults.limit
            }
            return SessionRestoreDefaults.clampLimit(
                defaults.integer(forKey: SessionRestoreDefaults.limitKey))
        }
        set {
            PreferenceStore.shared.set(SessionRestoreDefaults.clampLimit(newValue),
                                       forKey: SessionRestoreDefaults.limitKey)
            persistChoice()
        }
    }

    private static func persistChoice() {
        persistence.async {
            if !PreferenceStore.shared.synchronize() {
                FileHandle.standardError.write(Data(
                    "Linux preference was not saved\n".utf8))
            }
        }
    }

    /// A quick close after a click still commits the choice before the next process reads it.
    static func finishPendingWrites() {
        persistence.sync {}
    }
}
