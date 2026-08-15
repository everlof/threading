import Foundation

/// The property-list value category a setting persists.
///
/// This is intentionally closed. `UserDefaults` accepts `Any`, but the settings catalogue does
/// not: a definition has to state the exact stored shape before it can supply a default or a
/// validation rule.
enum AppSettingStoredValue: Equatable, Sendable {
    case boolean(Bool)
    case integer(Int)
    case string(String)
    case stringArray([String])
    case stringDictionary([String: String])
    case data(Data)

    var valueType: AppSettingValueType {
        switch self {
        case .boolean: .boolean
        case .integer: .integer
        case .string: .string
        case .stringArray: .stringArray
        case .stringDictionary: .stringDictionary
        case .data: .data
        }
    }

    /// The one deliberate bridge to Foundation's untyped defaults API.
    var propertyListValue: Any {
        switch self {
        case .boolean(let value): value
        case .integer(let value): value
        case .string(let value): value
        case .stringArray(let value): value
        case .stringDictionary(let value): value
        case .data(let value): value
        }
    }
}

enum AppSettingValueType: String, Equatable, Sendable {
    case boolean
    case integer
    case string
    case stringArray
    case stringDictionary
    case data
}

/// What an absent current key means. Absence is part of the persistence contract: several
/// settings deliberately inherit, consult a legacy key, or ask macOS instead of registering a
/// concrete value.
enum AppSettingAbsenceSemantics: Equatable, Sendable {
    case registered(AppSettingStoredValue)
    case falseValue
    case emptyString
    case emptyCollection
    case inherit
    case systemDefault
    case fallback(String)
    case legacy(settingIdentity: String)
}

enum AppSettingValidation: Equatable, Sendable {
    case any
    case allowedStrings(Set<String>)
    case integerRange(ClosedRange<Int>)
    case maximumStringBytes(Int)
    case maximumDataBytes(Int)
    case workspaceNavigatorIdentity(maximumIdentityBytes: Int, maximumDataBytes: Int)

    func accepts(_ value: AppSettingStoredValue) -> Bool {
        switch self {
        case .any:
            return true
        case .allowedStrings(let allowed):
            guard case .string(let value) = value else { return false }
            return allowed.contains(value)
        case .integerRange(let range):
            guard case .integer(let value) = value else { return false }
            return range.contains(value)
        case .maximumStringBytes(let maximum):
            guard case .string(let value) = value else { return false }
            return value.utf8.count <= maximum
        case .maximumDataBytes(let maximum):
            guard case .data(let value) = value else { return false }
            return value.count <= maximum
        case .workspaceNavigatorIdentity(_, let maximumDataBytes):
            guard case .data(let value) = value else { return false }
            return value.count <= maximumDataBytes
        }
    }
}

enum AppSettingChangeNotification: Equatable, Sendable {
    case appSettingsChanged
    case none
}

enum AppSettingRemotePolicy: Equatable, Sendable {
    /// Neither metadata nor value crosses a remote boundary.
    case hidden
    /// `list_settings` may describe the row, but never disclose or mutate its value.
    case catalogueOnly
    /// An authenticated owner endpoint may mutate the value through its application interface.
    case ownerMutable
}

struct AppSettingPersistence: Equatable, Sendable {
    let key: String
    let valueType: AppSettingValueType
    let absence: AppSettingAbsenceSemantics
    let validation: AppSettingValidation
}

struct AppSettingPresentation: Equatable, Sendable {
    let pageID: String
    let catalogueOrder: Int
    let section: String?
    let rowAnchor: String
    let searchTerms: [String]
}

/// One stable setting contract. Page navigation and search consume `presentations`; persistence,
/// migrations and defaults consume `persistence`; remote adapters consume `remotePolicy`.
struct AppSettingDefinition: Equatable, Sendable {
    let identity: String
    let persistence: AppSettingPersistence?
    let presentations: [AppSettingPresentation]
    let notification: AppSettingChangeNotification
    let remotePolicy: AppSettingRemotePolicy
}

/// The single authored inventory for app settings.
///
/// Call sites refer to a stable identity and project the key from here. They never repeat the
/// current `UserDefaults` key, registered default, validation rule, page anchor, or remote policy.
enum AppSettingDefinitions {
    static let all: [AppSettingDefinition] = [
        stored("defaultAgentKind", "defaultAgentKind", .string,
               .registered(.string(AgentDefaults.defaultKind.rawValue)),
               .allowedStrings(Set(AgentKind.allCases.map(\.rawValue))),
               presentations: [row("general", 0, "Sessions", "New sessions use",
                                   ["agent", "Claude Code", "Codex"])]),
        stored("githubAppClientID", "githubAppClientID", .string, .emptyString,
               .maximumStringBytes(1_024),
               presentations: [row("github", 0, "GitHub App", "Client ID",
                                   ["client ID", "device flow", "connect", "app"])]),
        stored("restoresLastSession", "restoresLastSession", .boolean,
               .registered(.boolean(true)),
               presentations: [row("general", 12, "Startup", "Reopen the last session at launch",
                                   ["relaunch", "restore", "startup"])]),
        stored("restoresRunningSessions", "restoresRunningSessions", .boolean,
               .registered(.boolean(true))),
        stored("sessionRestorePolicy", "sessionRestorePolicy", .string,
               .legacy(settingIdentity: "restoresRunningSessions"),
               .allowedStrings(Set(SessionRestorePolicy.allCases.map(\.rawValue))),
               presentations: [row("general", 13, "Startup", "Bring back at launch",
                                   ["reopen", "resume automatically", "running at quit", "restore"])]),
        stored("sessionRestoreWindowDays", "sessionRestoreWindowDays", .integer,
               .registered(.integer(SessionRestoreDefaults.windowDays)),
               .integerRange(
                   (SessionRestoreDefaults.windowDayChoices.first ?? 1)...(SessionRestoreDefaults.windowDayChoices.last ?? 30)
               ),
               presentations: [row("general", 14, "Startup", "Counts as recently used",
                                   ["recently used", "days", "dormant"])]),
        stored("sessionRestoreLimit", "sessionRestoreLimit", .integer,
               .registered(.integer(SessionRestoreDefaults.limit)),
               .integerRange(
                   (SessionRestoreDefaults.limitChoices.first ?? 4)...(SessionRestoreDefaults.limitChoices.last ?? 32)
               ),
               presentations: [row("general", 15, "Startup", "Sessions brought back",
                                   ["restore limit"])]),
        stored("newChatOpeningMessage", "newChatOpeningMessage", .string, .emptyString,
               .maximumStringBytes(1_048_576),
               presentations: [row("general", 9, "Opening Message", "Add to every new chat",
                                   ["first message", "instructions", "opening message"])]),

        // Migration-only identities remain typed definitions so migrations never duplicate a
        // retired key or marker spelling.
        stored("legacyClosingConfirmation", "confirmsBeforeClosingRunningSession", .boolean,
               .registered(.boolean(true)), notification: .none),
        stored("suppressedConfirmations", "suppressedConfirmations", .stringArray,
               .emptyCollection),
        stored("hiddenNotices", "hiddenNotices", .stringArray, .emptyCollection,
               presentations: [row("general", 16, "Confirmations", "Hidden extension messages",
                                   ["notices"])]),
        stored("closingConfirmationMigration", "didMigrateClosingConfirmation", .boolean,
               .falseValue, notification: .none),

        stored("usesAgentTitleInSidebar", "usesTerminalTitleInSidebar", .boolean,
               .registered(.boolean(true)),
               presentations: [row("general", 1, "Sessions", "Name sessions after the agent's own title",
                                   ["naming", "rename"])]),
        stored("groupsSessionsByBranch", "groupsSessionsByBranch", .boolean,
               .registered(.boolean(true)),
               presentations: [row("general", 2, "Sessions", "Group sessions by branch",
                                   ["branch"])]),
        stored("groupsLoneBranches", "groupsLoneBranches", .boolean,
               .registered(.boolean(true))),
        stored("compactsSidebarTree", "compactsSidebarTree", .boolean, .falseValue,
               presentations: [row("general", 3, "Sessions", "Compact tree",
                                   ["indentation", "sidebar density"])]),
        stored("followsCheckoutBranch", "followsCheckoutBranch", .boolean,
               .registered(.boolean(true)),
               presentations: [row("general", 4, "Sessions", "Follow the checkout's branch",
                                   ["branch", "checkout"])]),
        stored("sidebarSessionOrder", "sidebarSessionOrder", .string, .fallback("manual"),
               .allowedStrings(Set(SidebarSessionOrder.allCases.map(\.rawValue)))),
        stored("sidebarSessionOrderIsReversed", "sidebarSessionOrderIsReversed", .boolean,
               .falseValue),
        stored("promptReturnKey", "promptReturnKey", .string, .fallback("matchesComposer"),
               .allowedStrings(Set(PromptReturnKey.allCases.map(\.rawValue))),
               presentations: [row("keyboard", 0, "Composer", "When writing a prompt, press Return to",
                                   ["return", "enter", "send", "new line"])]),

        stored("discoversProjectIcons", "discoversProjectIcons", .boolean,
               .registered(.boolean(true)),
               presentations: [row("general", 5, "Sessions", "Discover project icons",
                                   ["project icons", "favicon"])]),
        stored("discoversAccountAvatars", "discoversAccountAvatars", .boolean,
               .registered(.boolean(true)),
               presentations: [row("general", 6, "Sessions", "Discover account avatars",
                                   ["account avatars", "Gravatar"])]),
        stored("harmonizesTerminalBackgrounds", "harmonizesTerminalBackgrounds", .boolean,
               .registered(.boolean(true)),
               presentations: [row("profiles", 3, "Colour", "Keep backgrounds in tune with the theme",
                                   ["background", "colour", "colors"])]),
        stored("convertsDroppedImages", "convertsDroppedImages", .boolean,
               .registered(.boolean(true)),
               presentations: [row("profiles", 6, "Dropped files", "Convert dropped images agents can't open",
                                   ["dropped images", "HEIC", "TIFF"])]),
        stored("copiesTerminalSelection", "copiesTerminalSelection", .boolean, .falseValue,
               presentations: [row("profiles", 5, "Selection", "Copy selected text to the clipboard",
                                   ["copy on select", "clipboard", "terminal selection"])]),

        stored("notifiesOnAttention", "notifiesOnAttention", .boolean,
               .registered(.boolean(true)),
               presentations: [row("general", 17, "Notifications", "Notify when a session needs you",
                                   ["notifications", "alerts", "needs attention"])]),
        stored("disabledAttentionAlerts", "disabledAttentionAlerts", .stringArray,
               .emptyCollection),
        stored("legacyPlaysAttentionAlertSound", "playsAttentionAlertSound", .boolean,
               .falseValue, notification: .none),
        stored("attentionAlertSound", "attentionAlertSound", .string, .systemDefault,
               presentations: [row("general", 18, "Notifications", "Alert sound",
                                   ["sound", "alerts", "notifications"])]),
        stored("terminalBellSound", "terminalBellSound", .string, .systemDefault,
               presentations: [row("general", 20, "Terminal Bell", "Bell sound",
                                   ["bell", "beep", "terminal bell", "alert sound"])]),
        stored("soundEventChoices", "soundEventChoices", .stringDictionary, .emptyCollection,
               presentations: [
                   row("general", 19, "Notifications", "Sounds for each alert",
                       ["custom sounds", "per-event sounds", "customize events", "override"]),
                   row("general", 21, "Terminal Bell", "Sounds for each bell",
                       ["custom sounds", "beep", "override"])
               ]),
        stored("silencesAllSounds", "silencesAllSounds", .boolean, .falseValue,
               presentations: [row("general", 22, "Silence", "Silence every sound",
                                   ["silence", "silence sounds", "mute"])]),

        stored("disabledAttachmentDetectionAgentKinds",
               "disabledAttachmentDetectionAgentKinds", .stringArray, .emptyCollection),
        stored("includesAttachmentsOutsideProject", "includesAttachmentsOutsideProject",
               .boolean, .falseValue,
               presentations: [row("general", 10, "Attachments", "Include files outside the project", ["attachments"])]),
        stored("capturesPageBeforeAgentActions", "capturesPageBeforeAgentActions", .boolean,
               .falseValue,
               presentations: [row("general", 11, "Attachments", "Keep the page as it was before each agent action",
                                   ["attachments", "browser"])]),
        stored("disabledToolGroupIDs", "disabledToolGroupIDs", .stringArray, .emptyCollection),

        stored("usesContainedExtensionLauncher", "usesContainedExtensionLauncher", .boolean,
               .falseValue),
        stored("workspaceNavigatorSelection", "workspaceNavigatorSelection", .data,
               .fallback("native"),
               .workspaceNavigatorIdentity(maximumIdentityBytes: 1_024,
                                           maximumDataBytes: 65_536)),

        stored("reportsClaudeLifecycleEvents", "reportsClaudeLifecycleEvents", .boolean,
               .registered(.boolean(true)),
               presentations: [row("general", 25, "Claude Hooks", "Report Claude turn and subagent activity", ["hooks"])]),
        stored("installsCodexHooks", "installsCodexHooks", .boolean, .falseValue,
               presentations: [row("general", 27, "Codex Hooks", "Report Codex turn boundaries",
                                   ["Codex hooks", "hooks.json"])]),
        stored("readsClaudeLoginFromKeychain", "readsClaudeLoginFromKeychain", .boolean,
               .falseValue,
               presentations: [row("privacy", 4, "Stored Credentials", "Live usage from your Claude login", ["keychain", "usage"])]),
        stored("suppressesClaudeStatusLine", "suppressesClaudeStatusLine", .boolean,
               .falseValue,
               presentations: [row("general", 26, "Claude Hooks", "Hide Claude's status line in Threading terminals",
                                   ["status line"])]),
        stored("bypassesCodexHookTrust", "bypassesCodexHookTrust", .boolean, .falseValue,
               presentations: [row("general", 28, "Codex Hooks", "Skip Codex hook review",
                                   ["hooks"])]),
        stored("claudeRemoteControl", "claudeRemoteControl", .string,
               .fallback("followClaude"),
               .allowedStrings(Set(ClaudeRemoteControl.allCases.map(\.rawValue))),
               presentations: [row("general", 24, "Claude Remote Control", "Remote Control for new Claude sessions",
                                   ["Claude Remote Control", "claude.ai", "mobile"])]),
        stored("claudeStartupSpeed", "claudeStartupSpeed", .string,
               .fallback("agentSetting"),
               .allowedStrings(Set(AgentStartupSpeed.allCases.map(\.rawValue))),
               presentations: [row("general", 7, "Conversation Speed", "Claude sessions start in",
                                   ["fast mode", "standard mode", "credits", "conversation speed"])]),
        stored("codexStartupSpeed", "codexStartupSpeed", .string,
               .fallback("agentSetting"),
               .allowedStrings(Set(AgentStartupSpeed.allCases.map(\.rawValue))),
               presentations: [row("general", 8, "Conversation Speed", "Codex sessions start in",
                                   ["service tier", "credits", "conversation speed"])]),
        stored("defaultPermissionMode", "defaultPermissionMode", .string, .inherit,
               .allowedStrings(Set(AgentPermissionMode.allCases.map(\.rawValue))),
               presentations: [row("general", 23, "Permission Mode", "New sessions start in",
                                   ["permission mode", "ask before"])]),

        stored("remoteAccessEnabled", "remoteAccessEnabled", .boolean, .falseValue,
               presentations: [row("remote-access", 0, "Connection", "Remote Access",
                                   ["iPhone", "remote", "sharing"])],
               remotePolicy: .ownerMutable),
        stored("remoteAccessConnectionMode", "remoteAccessConnectionMode", .string,
               .fallback("relay"),
               .allowedStrings(Set(RemoteAccessConnectionMode.allCases.map(\.rawValue))),
               presentations: [
                   row("remote-access", 1, "Connection", "Connection", ["relay", "Tailscale"]),
                   row("remote-access", 2, "Connection", "Hosted Direct", ["direct", "introduce"])
               ],
               remotePolicy: .ownerMutable),
        stored("remoteAccessAllowsOwnerRelayFallback", "remoteAccessAllowsOwnerRelayFallback",
               .boolean, .registered(.boolean(false)),
               presentations: [row("remote-access", 3, "Connection", "Owner Relay Fallback",
                                   ["relay", "fallback"])], remotePolicy: .ownerMutable),
        stored("remoteAccessKeepsRelayReady", "remoteAccessKeepsRelayReady", .boolean,
               .registered(.boolean(false)),
               presentations: [row("remote-access", 4, "Connection", "Keep Sharing Relay Ready",
                                   ["relay", "share links"])], remotePolicy: .ownerMutable),
        stored("remoteInputControlDefault", "remoteInputControlDefault", .string,
               .registered(.string(RemoteInputControlDefault.collaborative.rawValue)),
               .allowedStrings(Set(RemoteInputControlDefault.allCases.map(\.rawValue))),
               presentations: [row("remote-access", 5, "Sharing & Security", "New shared chats",
                                   ["security", "collaborative", "focused", "share"])],
               remotePolicy: .ownerMutable),

        stored("automaticUpdateChecksEnabled", "automaticUpdateChecksEnabled", .boolean,
               .registered(.boolean(true)),
               presentations: [row("general", 29, "Software Updates", "Check for updates automatically", ["updates", "Sparkle"])]),
        stored("workingOrbStyle", "workingOrbStyle", .string,
               .registered(.string(MotionPreferencesDefaults.workingOrbStyle.rawValue)),
               .allowedStrings(Set(WorkingOrbStyle.allCases.map(\.rawValue))),
               presentations: [row("motion", 0, "Working", "Working indicator",
                                   ["orb", "animation", "spinner"])]),
        stored("chatNameMorphStyle", "chatNameMorphStyle", .string,
               .registered(.string(MotionPreferencesDefaults.chatNameMorphStyle.rawValue)),
               .allowedStrings(Set(ChatNameMorphStyle.allCases.map(\.rawValue))),
               presentations: [row("motion", 1, "Chat names", "Chat name transition",
                                   ["transition", "animation", "morph"])]),
        stored("chromeFontFamily", "chromeFontFamily", .string, .inherit,
               .maximumStringBytes(1_024),
               presentations: [row("themes", 4, "Fonts", "App font", ["typeface", "font"])]),
        stored("conversationFontFamily", "conversationFontFamily", .string, .inherit,
               .maximumStringBytes(1_024),
               presentations: [row("themes", 5, "Fonts", "Conversation font",
                                   ["typeface", "font", "chat"])]),
        stored("appTextSize", "appTextSize", .string,
               .registered(.string(AppTextSize.standard.rawValue)),
               .allowedStrings(Set(AppTextSize.allCases.map(\.rawValue))),
               presentations: [row("themes", 3, "Fonts", "Text size",
                                   ["large text", "text size"])]),

        // Rows backed by another typed store, a system capability, or an action still belong
        // to the same presentation catalogue. `.catalogueOnly` means remote callers may learn
        // the destination, never a value or mutation route.
        surfaced("keyboard.resetShortcuts", pageID: "keyboard", order: 1, section: nil,
                  title: "Reset Shortcuts", "reset", "defaults"),
        surfaced("themes.appTheme", pageID: "themes", order: 0, section: "App",
                  title: "App theme", "appearance", "chrome"),
        surfaced("themes.customThemes", pageID: "themes", order: 1, section: "App",
                  title: "Custom themes", "duplicate", "edit"),
        surfaced("themes.classicSkins", pageID: "themes", order: 2, section: "App",
                  title: "Classic skins", "Winamp", "import", "skin"),
        surfaced("profiles.font", pageID: "profiles", order: 0, section: "Text", title: "Font",
                  "terminal font", "terminal size"),
        surfaced("profiles.cursorStyle", pageID: "profiles", order: 1, section: "Cursor",
                  title: "Style", "cursor", "block", "underline", "bar"),
        surfaced("profiles.cursorBlink", pageID: "profiles", order: 2, section: "Cursor",
                  title: "Blinking cursor", "cursor", "blink"),
        surfaced("profiles.scrollback", pageID: "profiles", order: 4, section: "Scrollback",
                  title: "Lines kept", "scrollback", "history"),
        surfaced("usageWindows.openBeforeStart", pageID: "usage-windows", order: 0,
                  section: "Schedule", title: "Open a window before I start", "poke", "schedule"),
        surfaced("usageWindows.start", pageID: "usage-windows", order: 1, section: "Schedule",
                  title: "I start at", "working hours", "workday"),
        surfaced("usageWindows.stop", pageID: "usage-windows", order: 2, section: "Schedule",
                  title: "I stop at", "working hours", "workday"),
        surfaced("usageWindows.days", pageID: "usage-windows", order: 3, section: "Schedule",
                  title: "Days", "weekdays", "schedule"),
        surfaced("usageWindows.scheduledSendPolicy", pageID: "usage-windows", order: 4,
                  section: "Scheduled sends", title: "If the window has not reset",
                  "reset", "scheduled"),
        surfaced("usageWindows.limitRecovery", pageID: "usage-windows", order: 5,
                  section: "Limit recovery", title: "When a session hits its usage limit",
                  "rate limit", "session limit"),
        surfaced("github.ghCLI", pageID: "github", order: 1,
                  section: "Command-Line Fallbacks", title: "gh CLI",
                  "gh", "token", "credentials"),
        surfaced("github.credentialHelper", pageID: "github", order: 2,
                  section: "Command-Line Fallbacks", title: "Git credential helper",
                  "credentials", "token"),
        surfaced("privacy.filesAndFolders", pageID: "privacy", order: 0,
                  section: "System Permissions", title: "Files & Folders",
                  "permissions", "TCC", "grant"),
        surfaced("privacy.notifications", pageID: "privacy", order: 1,
                  section: "System Permissions", title: "Notifications",
                  "permissions", "TCC", "grant"),
        surfaced("privacy.accessibility", pageID: "privacy", order: 2,
                  section: "System Permissions", title: "Accessibility",
                  "permissions", "TCC", "grant"),
        surfaced("privacy.screenRecording", pageID: "privacy", order: 3,
                  section: "System Permissions", title: "Screen Recording",
                  "permissions", "TCC", "grant"),
        surfaced("advanced.settingsLocation", pageID: "advanced", order: 0,
                  section: "Locations", title: "Settings",
                  "preferences file", "where", "location", "reveal"),
        surfaced("advanced.applicationSupportLocation", pageID: "advanced", order: 1,
                  section: "Locations", title: "Projects, sessions and caches",
                  "application support", "location", "reveal"),
        surfaced("advanced.welcomeTour", pageID: "advanced", order: 2,
                  section: "Welcome Tour", title: "First-launch walkthrough",
                  "onboarding", "welcome tour"),
        surfaced("advanced.runWelcomeTour", pageID: "advanced", order: 3,
                  section: "Welcome Tour", title: "Run at next launch", "onboarding", "flag"),
        surfaced("advanced.resetSettings", pageID: "advanced", order: 4,
                  section: "Start Over", title: "Reset settings",
                  "reset", "start over", "fresh"),
        surfaced("advanced.resetEverything", pageID: "advanced", order: 5,
                  section: "Start Over", title: "Reset everything",
                  "erase", "corrupt", "start over")
    ]

    private static let catalogue = AppSettingDefinitionCatalogue(definitions: all)

    static var issues: [String] { catalogue.issues }

    static var registeredDefaults: [String: Any] {
        catalogue.registeredDefaults
    }

    static func definition(_ identity: String) -> AppSettingDefinition {
        guard let definition = catalogue.definition(identity) else {
            preconditionFailure("Missing app setting definition: \(identity)")
        }
        return definition
    }

    static func key(_ identity: String) -> String {
        guard let key = definition(identity).persistence?.key else {
            preconditionFailure("App setting has no persistence key: \(identity)")
        }
        return key
    }

    static func accepts(_ value: AppSettingStoredValue, for identity: String) -> Bool {
        guard let persistence = definition(identity).persistence,
              persistence.valueType == value.valueType else { return false }
        return persistence.validation.accepts(value)
    }

    static func validatedString(_ value: String?, for identity: String) -> String? {
        guard let value, accepts(.string(value), for: identity) else { return nil }
        return value
    }

    static func normalizedInteger(_ value: Int, for identity: String, fallback: Int) -> Int {
        guard let validation = definition(identity).persistence?.validation else { return fallback }
        guard case .integerRange(let range) = validation else {
            return accepts(.integer(value), for: identity) ? value : fallback
        }
        if value <= 0 { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func accepts(
        _ selection: WorkspaceNavigatorSelection,
        for identity: String
    ) -> Bool {
        guard let validation = definition(identity).persistence?.validation,
              case .workspaceNavigatorIdentity(let maximumIdentityBytes, _) = validation else {
            return false
        }
        guard case .extensionNavigator(let extensionIdentifier, let navigatorID) = selection else {
            return true
        }
        return !extensionIdentifier.isEmpty
            && extensionIdentifier.utf8.count <= maximumIdentityBytes
            && !navigatorID.isEmpty
            && navigatorID.utf8.count <= maximumIdentityBytes
    }

    private static func stored(
        _ identity: String,
        _ key: String,
        _ valueType: AppSettingValueType,
        _ absence: AppSettingAbsenceSemantics,
        _ validation: AppSettingValidation = .any,
        presentations: [AppSettingPresentation] = [],
        notification: AppSettingChangeNotification = .appSettingsChanged,
        remotePolicy: AppSettingRemotePolicy = .hidden
    ) -> AppSettingDefinition {
        AppSettingDefinition(
            identity: identity,
            persistence: AppSettingPersistence(
                key: key,
                valueType: valueType,
                absence: absence,
                validation: validation
            ),
            presentations: presentations,
            notification: notification,
            remotePolicy: presentations.isEmpty && remotePolicy == .hidden
                ? .hidden
                : (remotePolicy == .hidden ? .catalogueOnly : remotePolicy)
        )
    }

    private static func surfaced(
        _ identity: String,
        pageID: String,
        order: Int,
        section: String?,
        title: String,
        _ searchTerms: String...
    ) -> AppSettingDefinition {
        AppSettingDefinition(
            identity: identity,
            persistence: nil,
            presentations: [row(pageID, order, section, title, searchTerms)],
            notification: .none,
            remotePolicy: .catalogueOnly
        )
    }

    private static func row(
        _ pageID: String,
        _ catalogueOrder: Int,
        _ section: String?,
        _ title: String,
        _ searchTerms: [String]
    ) -> AppSettingPresentation {
        AppSettingPresentation(
            pageID: pageID,
            catalogueOrder: catalogueOrder,
            section: section,
            rowAnchor: title,
            searchTerms: searchTerms
        )
    }
}

/// Independently auditable projection used by production and synthetic checker tests.
struct AppSettingDefinitionCatalogue: Sendable {
    let definitions: [AppSettingDefinition]
    let issues: [String]

    private let definitionsByIdentity: [String: AppSettingDefinition]
    private let registeredDefaultValues: [AppSettingRegisteredDefault]

    var registeredDefaults: [String: Any] {
        Dictionary(
            uniqueKeysWithValues: registeredDefaultValues.map {
                ($0.key, $0.value.propertyListValue)
            }
        )
    }

    init(definitions: [AppSettingDefinition]) {
        var issues: [String] = []
        let identities = Dictionary(grouping: definitions, by: \.identity)
        for (identity, definitions) in identities where definitions.count != 1 {
            issues.append("duplicate setting identity \(identity)")
        }

        let persisted = definitions.compactMap { definition in
            definition.persistence.map { (definition, $0) }
        }
        let keys = Dictionary(grouping: persisted, by: { $0.1.key })
        for (key, definitions) in keys where definitions.count != 1 {
            issues.append("duplicate persistence key \(key)")
        }

        let anchored = definitions.flatMap { definition in
            definition.presentations.map { (definition, $0) }
        }
        let anchors = Dictionary(grouping: anchored) {
            "\($0.1.pageID)\u{0}\($0.1.rowAnchor)"
        }
        for (_, rows) in anchors where rows.count != 1 {
            let location = rows[0].1
            issues.append(
                "duplicate row anchor \(location.pageID)/\(location.rowAnchor)"
            )
        }
        let rowsByPage = Dictionary(grouping: anchored, by: { $0.1.pageID })
        for (pageID, rows) in rowsByPage {
            let orders = rows.map { $0.1.catalogueOrder }.sorted()
            if orders != Array(0..<rows.count) {
                issues.append("\(pageID) row order is duplicate or incomplete")
            }
        }

        for (definition, persistence) in persisted {
            if case .registered(let value) = persistence.absence {
                if value.valueType != persistence.valueType {
                    issues.append("\(definition.identity) has a default of the wrong value type")
                } else if !persistence.validation.accepts(value) {
                    issues.append("\(definition.identity) has an invalid registered default")
                }
            }
        }
        for definition in definitions where !definition.presentations.isEmpty {
            if definition.remotePolicy == .hidden {
                issues.append("\(definition.identity) has a row hidden from the catalogue")
            }
            for presentation in definition.presentations
                where presentation.pageID.isEmpty || presentation.rowAnchor.isEmpty {
                issues.append("\(definition.identity) has an incomplete row location")
            }
        }
        self.definitions = definitions
        self.issues = issues.sorted()
        var registeredDefaults: [AppSettingRegisteredDefault] = []
        for definition in definitions {
            guard let persistence = definition.persistence,
                  keys[persistence.key]?.count == 1,
                  case .registered(let value) = persistence.absence else { continue }
            registeredDefaults.append(.init(key: persistence.key, value: value))
        }
        self.registeredDefaultValues = registeredDefaults
        self.definitionsByIdentity = identities.compactMapValues { candidates in
            candidates.count == 1 ? candidates[0] : nil
        }
    }

    func definition(_ identity: String) -> AppSettingDefinition? {
        definitionsByIdentity[identity]
    }
}

private struct AppSettingRegisteredDefault: Sendable {
    let key: String
    let value: AppSettingStoredValue
}
