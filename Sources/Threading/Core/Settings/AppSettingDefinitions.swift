import Foundation

/// Closed source identities for persisted app settings.
///
/// Persistence keys remain strings because they are a compatibility contract on disk. Production
/// code never names an identity with a string, though: it receives an `AppSettingDescriptor<T>`
/// from `AppSettingDefinitions`, so misspelling `githubAppClientID` is a compiler error.
enum AppSettingIdentity: String, CaseIterable, Sendable {
    case defaultAgentKind
    case githubAppClientID
    case restoresLastSession
    case restoresRunningSessions
    case sessionRestorePolicy
    case sessionRestoreWindowDays
    case sessionRestoreLimit
    case newChatOpeningPrefix
    case newChatOpeningSuffix
    case legacyClosingConfirmation
    case suppressedConfirmations
    case hiddenNotices
    case closingConfirmationMigration
    case usesAgentTitleInSidebar
    case groupsSessionsByBranch
    case groupsLoneBranches
    case compactsSidebarTree
    case followsCheckoutBranch
    case sidebarSessionOrder
    case sidebarSessionOrderIsReversed
    case promptReturnKey
    case discoversProjectIcons
    case discoversAccountAvatars
    case harmonizesTerminalBackgrounds
    case convertsDroppedImages
    case copiesTerminalSelection
    case notifiesOnAttention
    case disabledAttentionAlerts
    case legacyPlaysAttentionAlertSound
    case attentionAlertSound
    case terminalBellSound
    case soundEventChoices
    case silencesAllSounds
    case disabledAttachmentDetectionAgentKinds
    case includesAttachmentsOutsideProject
    case capturesPageBeforeAgentActions
    case sessionCheckoutAuthorityPolicy
    case disabledToolGroupIDs
    case usesContainedExtensionLauncher
    case usesMCPStdioBridge
    case ptyHostEnabled
    case prependsCommandLineToolsToPATH
    case workspaceNavigatorSelection
    case reportsClaudeLifecycleEvents
    case installsCodexHooks
    case readsClaudeLoginFromKeychain
    case suppressesClaudeStatusLine
    case bypassesCodexHookTrust
    case claudeRemoteControl
    case claudeStartupSpeed
    case codexStartupSpeed
    case defaultPermissionMode
    case localDiagnosticsEnabled
    case remoteAccessEnabled
    case remoteAccessDoorMigration
    case remoteAccessTailscaleEnabled
    case remoteAccessTailscaleServeEnabled
    case remoteAccessListenerPort
    case remoteViewportLeaseGraceSeconds
    case remoteAccessDoors
    case remoteAccessAdvertisedHostname
    case remoteAccessDiscoveryEnabled
    case remoteInputControlDefault
    case phoneReportWorkspace
    case automaticUpdateChecksEnabled
    case updateChannelSubscription
    case preventsIdleSystemSleepWhileAgentsWork
    case workingOrbStyle
    case chatNameMorphStyle
    case chromeFontFamily
    case conversationFontFamily
    case appTextSize
}

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

/// How the Swift value becomes a value in the defaults domain.
enum AppSettingEncoding: Equatable, Sendable {
    /// Store the property-list value exactly as supplied.
    case propertyList
    /// Empty is absence; used by optional text overrides and the reusable opening message.
    case removeEmptyString
    /// An empty map is absence so broader sound-choice scopes remain authoritative.
    case removeEmptyCollection
    /// A recoverable Codable envelope owns quarantine and read-back verification.
    case recoverableCodable
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
    case legacy(settingIdentity: AppSettingIdentity)
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
    let encoding: AppSettingEncoding
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

/// A Swift type that has one exact property-list representation.
protocol AppSettingValue: Sendable {
    static var appSettingValueType: AppSettingValueType { get }
    static func read(from defaults: UserDefaults, key: String) -> Self?
    static func value(from stored: AppSettingStoredValue) -> Self?
    var storedAppSettingValue: AppSettingStoredValue { get }
}

extension Bool: AppSettingValue {
    static var appSettingValueType: AppSettingValueType { .boolean }

    static func read(from defaults: UserDefaults, key: String) -> Bool? {
        defaults.object(forKey: key) as? Bool
    }

    static func value(from stored: AppSettingStoredValue) -> Bool? {
        guard case .boolean(let value) = stored else { return nil }
        return value
    }

    var storedAppSettingValue: AppSettingStoredValue { .boolean(self) }
}

extension Int: AppSettingValue {
    static var appSettingValueType: AppSettingValueType { .integer }

    static func read(from defaults: UserDefaults, key: String) -> Int? {
        defaults.object(forKey: key) as? Int
    }

    static func value(from stored: AppSettingStoredValue) -> Int? {
        guard case .integer(let value) = stored else { return nil }
        return value
    }

    var storedAppSettingValue: AppSettingStoredValue { .integer(self) }
}

extension String: AppSettingValue {
    static var appSettingValueType: AppSettingValueType { .string }

    static func read(from defaults: UserDefaults, key: String) -> String? {
        defaults.string(forKey: key)
    }

    static func value(from stored: AppSettingStoredValue) -> String? {
        guard case .string(let value) = stored else { return nil }
        return value
    }

    var storedAppSettingValue: AppSettingStoredValue { .string(self) }
}

extension Array: AppSettingValue where Element == String {
    static var appSettingValueType: AppSettingValueType { .stringArray }

    static func read(from defaults: UserDefaults, key: String) -> [String]? {
        defaults.stringArray(forKey: key)
    }

    static func value(from stored: AppSettingStoredValue) -> [String]? {
        guard case .stringArray(let value) = stored else { return nil }
        return value
    }

    var storedAppSettingValue: AppSettingStoredValue { .stringArray(self) }
}

extension Dictionary: AppSettingValue where Key == String, Value == String {
    static var appSettingValueType: AppSettingValueType { .stringDictionary }

    static func read(from defaults: UserDefaults, key: String) -> [String: String]? {
        // Keep healthy siblings when one externally-written dictionary value has the wrong
        // property-list type. This is the pre-existing sound-choice compatibility behavior.
        defaults.dictionary(forKey: key)?.compactMapValues { $0 as? String }
    }

    static func value(from stored: AppSettingStoredValue) -> [String: String]? {
        guard case .stringDictionary(let value) = stored else { return nil }
        return value
    }

    var storedAppSettingValue: AppSettingStoredValue { .stringDictionary(self) }
}

extension Data: AppSettingValue {
    static var appSettingValueType: AppSettingValueType { .data }

    static func read(from defaults: UserDefaults, key: String) -> Data? {
        defaults.data(forKey: key)
    }

    static func value(from stored: AppSettingStoredValue) -> Data? {
        guard case .data(let value) = stored else { return nil }
        return value
    }

    var storedAppSettingValue: AppSettingStoredValue { .data(self) }
}

/// A typed absence contract. The erased semantic is retained for catalogue and migration audits,
/// while the generic value supplies the production read fallback. Consequently a Boolean
/// descriptor cannot be given a String registered default, and an array cannot accidentally use
/// the dictionary empty value.
struct TypedAppSettingAbsence<Value: AppSettingValue>: Sendable {
    let erased: AppSettingAbsenceSemantics
    let value: Value?

    static func registered(_ value: Value) -> Self {
        Self(erased: .registered(value.storedAppSettingValue), value: value)
    }

    static func legacy(_ identity: AppSettingIdentity) -> Self {
        Self(erased: .legacy(settingIdentity: identity), value: nil)
    }
}

extension TypedAppSettingAbsence where Value == Bool {
    static var falseValue: Self { Self(erased: .falseValue, value: false) }
}

extension TypedAppSettingAbsence where Value == String {
    static var emptyString: Self { Self(erased: .emptyString, value: "") }
    static var inherit: Self { Self(erased: .inherit, value: nil) }
    static var systemDefault: Self { Self(erased: .systemDefault, value: nil) }
    static func fallback(_ value: String) -> Self {
        Self(erased: .fallback(value), value: value)
    }
}

extension TypedAppSettingAbsence where Value == [String] {
    static var emptyCollection: Self { Self(erased: .emptyCollection, value: []) }
}

extension TypedAppSettingAbsence where Value == [String: String] {
    static var emptyCollection: Self { Self(erased: .emptyCollection, value: [:]) }
}

extension TypedAppSettingAbsence where Value == Data {
    /// The recoverable Codable owner interprets this semantic fallback before it asks the raw
    /// Data descriptor to read. There is intentionally no fabricated Data default.
    static func recoverableFallback(_ identity: String) -> Self {
        Self(erased: .fallback(identity), value: nil)
    }
}

/// A typed validation contract. Its factories exist only on compatible Value specializations,
/// so a byte-bounded string rule or integer range cannot be attached to the wrong descriptor.
struct TypedAppSettingValidation<Value: AppSettingValue>: Sendable {
    let erased: AppSettingValidation
    private let normalizeValue: @Sendable (Value, Value?) -> Value?

    static var any: Self {
        Self(erased: .any) { value, _ in value }
    }

    func accepts(_ value: Value) -> Bool {
        erased.accepts(value.storedAppSettingValue)
    }

    func normalize(_ value: Value, absenceValue: Value?) -> Value? {
        normalizeValue(value, absenceValue)
    }

    private init(
        erased: AppSettingValidation,
        normalizeValue: @escaping @Sendable (Value, Value?) -> Value?
    ) {
        self.erased = erased
        self.normalizeValue = normalizeValue
    }
}

extension TypedAppSettingValidation where Value == String {
    static func allowedStrings(_ values: Set<String>) -> Self {
        Self(erased: .allowedStrings(values)) { value, _ in
            values.contains(value) ? value : nil
        }
    }

    static func maximumBytes(_ maximum: Int) -> Self {
        Self(erased: .maximumStringBytes(maximum)) { value, _ in
            value.utf8.count <= maximum ? value : nil
        }
    }
}

extension TypedAppSettingValidation where Value == Int {
    static func range(_ range: ClosedRange<Int>) -> Self {
        Self(erased: .integerRange(range)) { value, absenceValue in
            if value <= 0 { return absenceValue }
            return min(max(value, range.lowerBound), range.upperBound)
        }
    }

    /// A range that clamps and honours its own floor.
    ///
    /// `range(_:)` folds any `value <= 0` to the absence value, which is right for a count where
    /// zero is a way of saying "unset" and wrong for a duration where zero is a decision: it
    /// makes "off" unreachable through the key, because writing `0` silently restores the
    /// default. This factory clamps into the stated range and does nothing else, so a floor of
    /// zero means zero.
    static func clampingRange(_ range: ClosedRange<Int>) -> Self {
        Self(erased: .integerRange(range)) { value, _ in
            min(max(value, range.lowerBound), range.upperBound)
        }
    }

    /// A range that refuses rather than clamps.
    ///
    /// Clamping is right for a choice out of a list, where the nearest allowed value is what the
    /// person meant. It is wrong where the number *is* the meaning: `80` clamped to `1024` is a
    /// listener on a port nobody asked for, and the answer to a privileged port is to refuse it
    /// and keep the value that was already working.
    static func refusingRange(_ range: ClosedRange<Int>) -> Self {
        Self(erased: .integerRange(range)) { value, _ in
            range.contains(value) ? value : nil
        }
    }
}

extension TypedAppSettingValidation where Value == Data {
    static func workspaceNavigatorIdentity(
        maximumIdentityBytes: Int,
        maximumDataBytes: Int
    ) -> Self {
        Self(
            erased: .workspaceNavigatorIdentity(
                maximumIdentityBytes: maximumIdentityBytes,
                maximumDataBytes: maximumDataBytes
            )
        ) { value, _ in
            value.count <= maximumDataBytes ? value : nil
        }
    }
}

/// Typed persistence encoding. Factories for empty-as-absence and recoverable storage exist only
/// for compatible Swift values; the erased encoding is a catalogue projection, not an authored
/// type tag.
struct TypedAppSettingEncoding<Value: AppSettingValue>: Sendable {
    let erased: AppSettingEncoding
    private let shouldRemoveValue: @Sendable (Value) -> Bool

    static var propertyList: Self {
        Self(erased: .propertyList) { _ in false }
    }

    func shouldRemove(_ value: Value) -> Bool {
        shouldRemoveValue(value)
    }

    private init(
        erased: AppSettingEncoding,
        shouldRemoveValue: @escaping @Sendable (Value) -> Bool
    ) {
        self.erased = erased
        self.shouldRemoveValue = shouldRemoveValue
    }
}

extension TypedAppSettingEncoding where Value == String {
    static var removeEmpty: Self {
        Self(erased: .removeEmptyString, shouldRemoveValue: \.isEmpty)
    }
}

extension TypedAppSettingEncoding where Value == [String] {
    static var removeEmpty: Self {
        Self(erased: .removeEmptyCollection, shouldRemoveValue: \.isEmpty)
    }
}

extension TypedAppSettingEncoding where Value == [String: String] {
    static var removeEmpty: Self {
        Self(erased: .removeEmptyCollection, shouldRemoveValue: \.isEmpty)
    }
}

extension TypedAppSettingEncoding where Value == Data {
    static var recoverableCodable: Self {
        Self(erased: .recoverableCodable) { _ in false }
    }
}

/// The authored production contract for one persisted setting.
///
/// `Value` determines the stored value type. Identity, key, typed absence/default, typed
/// validation, encoding, notification, presentations, and remote policy are supplied here once;
/// `definition` is the erased projection consumed by catalogue-only clients.
struct AppSettingDescriptor<Value: AppSettingValue>: Sendable {
    let identity: AppSettingIdentity
    let persistenceKey: String
    let encoding: TypedAppSettingEncoding<Value>
    let absence: TypedAppSettingAbsence<Value>
    let validation: TypedAppSettingValidation<Value>
    let notification: AppSettingChangeNotification
    let presentations: [AppSettingPresentation]
    let remotePolicy: AppSettingRemotePolicy

    init(
        identity: AppSettingIdentity,
        persistenceKey: String,
        absence: TypedAppSettingAbsence<Value>,
        validation: TypedAppSettingValidation<Value> = .any,
        encoding: TypedAppSettingEncoding<Value> = .propertyList,
        notification: AppSettingChangeNotification = .appSettingsChanged,
        presentations: [AppSettingPresentation] = [],
        remotePolicy: AppSettingRemotePolicy? = nil
    ) {
        self.identity = identity
        self.persistenceKey = persistenceKey
        self.absence = absence
        self.validation = validation
        self.encoding = encoding
        self.notification = notification
        self.presentations = presentations
        self.remotePolicy = remotePolicy
            ?? (presentations.isEmpty ? .hidden : .catalogueOnly)
    }

    var definition: AppSettingDefinition {
        AppSettingDefinition(
            identity: identity.rawValue,
            persistence: AppSettingPersistence(
                key: persistenceKey,
                valueType: Value.appSettingValueType,
                encoding: encoding.erased,
                absence: absence.erased,
                validation: validation.erased
            ),
            presentations: presentations,
            notification: notification,
            remotePolicy: remotePolicy
        )
    }

    func read(from defaults: UserDefaults) -> Value? {
        if let value = Value.read(from: defaults, key: persistenceKey),
           let normalized = validation.normalize(value, absenceValue: absence.value) {
            return normalized
        }
        return absence.value
    }

    func accepts(_ value: Value) -> Bool {
        validation.accepts(value)
    }

    /// Persists a validated value and applies this setting's declared notification policy.
    /// Invalid input is fail-closed: the previous durable value remains in place and observers
    /// are not told a change occurred.
    @discardableResult
    func write(
        _ value: Value,
        to defaults: UserDefaults,
        notifying: Bool = true
    ) -> Bool {
        guard let normalized = validation.normalize(value, absenceValue: absence.value) else {
            return false
        }
        if encoding.shouldRemove(normalized) {
            defaults.removeObject(forKey: persistenceKey)
        } else {
            defaults.set(normalized.storedAppSettingValue.propertyListValue, forKey: persistenceKey)
        }
        postChangeIfNeeded(notifying: notifying)
        return true
    }

    func remove(from defaults: UserDefaults, notifying: Bool = true) {
        defaults.removeObject(forKey: persistenceKey)
        postChangeIfNeeded(notifying: notifying)
    }

    func containsValue(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: persistenceKey) != nil
    }

    /// Applies the descriptor's notification policy after a specialised persistence adapter
    /// has durably committed the value. Most settings use `write`; recoverable Codable stores
    /// use this handoff so notification policy still has one owner.
    func notifyChange() {
        postChangeIfNeeded(notifying: true)
    }

    fileprivate func applyRemoteMutation(
        _ storedValue: AppSettingStoredValue,
        defaults: UserDefaults
    ) -> AppSettingRemoteMutationResult {
        guard let value = Value.value(from: storedValue), write(value, to: defaults) else {
            return .invalidValue
        }
        return .applied
    }

    private func postChangeIfNeeded(notifying: Bool) {
        guard notifying, notification == .appSettingsChanged else { return }
        NotificationCenter.default.post(AppSettingsDidChange())
    }
}

/// A heterogeneous reference to an authored typed descriptor. It copies no setting metadata:
/// both its catalogue definition and remote writer are projections of the descriptor supplied
/// at initialization.
struct AnyAppSettingDescriptor: Sendable {
    let identity: AppSettingIdentity
    let definition: AppSettingDefinition
    private let remoteWriter: @Sendable (AppSettingStoredValue, UserDefaults) -> AppSettingRemoteMutationResult

    init<Value>(_ descriptor: AppSettingDescriptor<Value>) {
        identity = descriptor.identity
        definition = descriptor.definition
        remoteWriter = { value, defaults in
            descriptor.applyRemoteMutation(value, defaults: defaults)
        }
    }

    func applyRemoteMutation(
        _ value: AppSettingStoredValue,
        defaults: UserDefaults
    ) -> AppSettingRemoteMutationResult {
        remoteWriter(value, defaults)
    }
}

enum AppSettingRemoteMutationResult: Equatable {
    case applied
    case unknownSetting
    case notMutable
    case invalidValue
}

/// The single authored inventory for app settings.
///
/// Each persisted setting is authored once as a typed descriptor. The heterogeneous registry
/// below only references those declarations, and `all` erases them for catalogue consumers.
enum AppSettingDefinitions {
    // MARK: Typed Persisted Descriptors

    static let defaultAgentKind = AppSettingDescriptor<String>(
        identity: .defaultAgentKind,
        persistenceKey: "defaultAgentKind",
        absence: .registered(AgentDefaults.defaultKind.rawValue),
        validation: .allowedStrings(Set(AgentKind.allCases.map(\.rawValue))),
        presentations: [row("general", 0, "Sessions", "New sessions use",
                            ["agent", "Claude Code", "Codex"])]
    )
    static let githubAppClientID = AppSettingDescriptor<String>(
        identity: .githubAppClientID,
        persistenceKey: "githubAppClientID",
        absence: .emptyString,
        validation: .maximumBytes(1_024),
        presentations: [row("github", 0, "GitHub App", "Client ID",
                            ["client ID", "device flow", "connect", "app"])]
    )
    static let restoresLastSession = AppSettingDescriptor<Bool>(
        identity: .restoresLastSession,
        persistenceKey: "restoresLastSession",
        absence: .registered(true),
        presentations: [row("general", 13, "Startup", "Reopen the last session at launch",
                            ["relaunch", "restore", "startup"])]
    )
    static let restoresRunningSessions = AppSettingDescriptor<Bool>(
        identity: .restoresRunningSessions,
        persistenceKey: "restoresRunningSessions",
        absence: .registered(true)
    )
    static let sessionRestorePolicy = AppSettingDescriptor<String>(
        identity: .sessionRestorePolicy,
        persistenceKey: "sessionRestorePolicy",
        absence: .legacy(.restoresRunningSessions),
        validation: .allowedStrings(Set(SessionRestorePolicy.allCases.map(\.rawValue))),
        presentations: [row("general", 14, "Startup", "Bring back at launch",
                            ["reopen", "resume automatically", "running at quit", "restore"])]
    )
    static let sessionRestoreWindowDays = AppSettingDescriptor<Int>(
        identity: .sessionRestoreWindowDays,
        persistenceKey: "sessionRestoreWindowDays",
        absence: .registered(SessionRestoreDefaults.windowDays),
        validation: .range((SessionRestoreDefaults.windowDayChoices.first ?? 1)...(SessionRestoreDefaults.windowDayChoices.last ?? 30)),
        presentations: [row("general", 15, "Startup", "Counts as recently used",
                            ["recently used", "days", "dormant"])]
    )
    static let sessionRestoreLimit = AppSettingDescriptor<Int>(
        identity: .sessionRestoreLimit,
        persistenceKey: "sessionRestoreLimit",
        absence: .registered(SessionRestoreDefaults.limit),
        validation: .range((SessionRestoreDefaults.limitChoices.first ?? 4)...(SessionRestoreDefaults.limitChoices.last ?? 32)),
        presentations: [row("general", 16, "Startup", "Sessions brought back",
                            ["restore limit"])]
    )
    static let newChatOpeningPrefix = AppSettingDescriptor<String>(
        identity: .newChatOpeningPrefix,
        persistenceKey: "newChatOpeningPrefix",
        absence: .emptyString,
        validation: .maximumBytes(1_048_576),
        encoding: .removeEmpty,
        presentations: [row("general", 9, "Opening Message", "Before the task you write",
                            ["first message", "instructions", "opening message", "prefix",
                             "prepend"])]
    )
    /// The historical key is the suffix's: this setting shipped alone, before the prefix
    /// existed, and a stored instruction is not worth losing to a tidier spelling.
    static let newChatOpeningSuffix = AppSettingDescriptor<String>(
        identity: .newChatOpeningSuffix,
        persistenceKey: "newChatOpeningMessage",
        absence: .emptyString,
        validation: .maximumBytes(1_048_576),
        encoding: .removeEmpty,
        presentations: [row("general", 10, "Opening Message", "After the task you write",
                            ["first message", "instructions", "opening message", "suffix",
                             "append", "add to every new chat"])]
    )

    // Migration-only identities remain typed descriptors so migrations never duplicate a
    // retired key or marker spelling.
    static let legacyClosingConfirmation = AppSettingDescriptor<Bool>(
        identity: .legacyClosingConfirmation,
        persistenceKey: "confirmsBeforeClosingRunningSession",
        absence: .registered(true),
        notification: .none
    )
    static let suppressedConfirmations = AppSettingDescriptor<[String]>(
        identity: .suppressedConfirmations,
        persistenceKey: "suppressedConfirmations",
        absence: .emptyCollection
    )
    static let hiddenNotices = AppSettingDescriptor<[String]>(
        identity: .hiddenNotices,
        persistenceKey: "hiddenNotices",
        absence: .emptyCollection,
        presentations: [row("general", 17, "Confirmations", "Hidden extension messages",
                            ["notices"])]
    )
    static let closingConfirmationMigration = AppSettingDescriptor<Bool>(
        identity: .closingConfirmationMigration,
        persistenceKey: "didMigrateClosingConfirmation",
        absence: .falseValue,
        notification: .none
    )

    static let usesAgentTitleInSidebar = AppSettingDescriptor<Bool>(
        identity: .usesAgentTitleInSidebar,
        persistenceKey: "usesTerminalTitleInSidebar",
        absence: .registered(true),
        presentations: [row("general", 1, "Sessions", "Name sessions after the agent's own title",
                            ["naming", "rename"])]
    )
    static let groupsSessionsByBranch = AppSettingDescriptor<Bool>(
        identity: .groupsSessionsByBranch,
        persistenceKey: "groupsSessionsByBranch",
        absence: .registered(true),
        presentations: [row("general", 2, "Sessions", "Group sessions by branch", ["branch"])]
    )
    static let groupsLoneBranches = AppSettingDescriptor<Bool>(
        identity: .groupsLoneBranches,
        persistenceKey: "groupsLoneBranches",
        absence: .registered(true)
    )
    static let compactsSidebarTree = AppSettingDescriptor<Bool>(
        identity: .compactsSidebarTree,
        persistenceKey: "compactsSidebarTree",
        absence: .falseValue,
        presentations: [row("general", 3, "Sessions", "Compact tree",
                            ["indentation", "sidebar density"])]
    )
    static let followsCheckoutBranch = AppSettingDescriptor<Bool>(
        identity: .followsCheckoutBranch,
        persistenceKey: "followsCheckoutBranch",
        absence: .registered(true),
        presentations: [row("general", 4, "Sessions", "Follow the checkout's branch",
                            ["branch", "checkout"])]
    )
    static let sidebarSessionOrder = AppSettingDescriptor<String>(
        identity: .sidebarSessionOrder,
        persistenceKey: "sidebarSessionOrder",
        absence: .fallback("manual"),
        validation: .allowedStrings(Set(SidebarSessionOrder.allCases.map(\.rawValue)))
    )
    static let sidebarSessionOrderIsReversed = AppSettingDescriptor<Bool>(
        identity: .sidebarSessionOrderIsReversed,
        persistenceKey: "sidebarSessionOrderIsReversed",
        absence: .falseValue
    )
    static let promptReturnKey = AppSettingDescriptor<String>(
        identity: .promptReturnKey,
        persistenceKey: "promptReturnKey",
        absence: .fallback("matchesComposer"),
        validation: .allowedStrings(Set(PromptReturnKey.allCases.map(\.rawValue))),
        presentations: [row("keyboard", 0, "Composer", "When writing a prompt, press Return to",
                            ["return", "enter", "send", "new line"])]
    )

    static let discoversProjectIcons = AppSettingDescriptor<Bool>(
        identity: .discoversProjectIcons,
        persistenceKey: "discoversProjectIcons",
        absence: .registered(true),
        presentations: [row("general", 5, "Sessions", "Discover project icons",
                            ["project icons", "favicon"])]
    )
    static let discoversAccountAvatars = AppSettingDescriptor<Bool>(
        identity: .discoversAccountAvatars,
        persistenceKey: "discoversAccountAvatars",
        absence: .registered(true),
        presentations: [row("general", 6, "Sessions", "Discover account avatars",
                            ["account avatars", "Gravatar"])]
    )
    static let harmonizesTerminalBackgrounds = AppSettingDescriptor<Bool>(
        identity: .harmonizesTerminalBackgrounds,
        persistenceKey: "harmonizesTerminalBackgrounds",
        absence: .registered(true),
        presentations: [row("profiles", 3, "Colour", "Keep backgrounds in tune with the theme",
                            ["background", "colour", "colors"])]
    )
    static let convertsDroppedImages = AppSettingDescriptor<Bool>(
        identity: .convertsDroppedImages,
        persistenceKey: "convertsDroppedImages",
        absence: .registered(true),
        presentations: [row("profiles", 6, "Dropped files",
                            "Convert dropped images agents can't open",
                            ["dropped images", "HEIC", "TIFF"])]
    )
    static let copiesTerminalSelection = AppSettingDescriptor<Bool>(
        identity: .copiesTerminalSelection,
        persistenceKey: "copiesTerminalSelection",
        absence: .falseValue,
        presentations: [row("profiles", 5, "Selection",
                            "Copy selected text to the clipboard",
                            ["copy on select", "clipboard", "terminal selection"])]
    )

    static let notifiesOnAttention = AppSettingDescriptor<Bool>(
        identity: .notifiesOnAttention,
        persistenceKey: "notifiesOnAttention",
        absence: .registered(true),
        presentations: [row("general", 18, "Notifications", "Notify when a session needs you",
                            ["notifications", "alerts", "needs attention"])]
    )
    static let disabledAttentionAlerts = AppSettingDescriptor<[String]>(
        identity: .disabledAttentionAlerts,
        persistenceKey: "disabledAttentionAlerts",
        absence: .emptyCollection
    )
    static let legacyPlaysAttentionAlertSound = AppSettingDescriptor<Bool>(
        identity: .legacyPlaysAttentionAlertSound,
        persistenceKey: "playsAttentionAlertSound",
        absence: .falseValue,
        notification: .none
    )
    static let attentionAlertSound = AppSettingDescriptor<String>(
        identity: .attentionAlertSound,
        persistenceKey: "attentionAlertSound",
        absence: .systemDefault,
        presentations: [row("general", 19, "Notifications", "Alert sound",
                            ["sound", "alerts", "notifications"])]
    )
    static let terminalBellSound = AppSettingDescriptor<String>(
        identity: .terminalBellSound,
        persistenceKey: "terminalBellSound",
        absence: .systemDefault,
        presentations: [row("general", 21, "Terminal Bell", "Bell sound",
                            ["bell", "beep", "terminal bell", "alert sound"])]
    )
    static let soundEventChoices = AppSettingDescriptor<[String: String]>(
        identity: .soundEventChoices,
        persistenceKey: "soundEventChoices",
        absence: .emptyCollection,
        encoding: .removeEmpty,
        presentations: [
            row("general", 20, "Notifications", "Sounds for each alert",
                ["custom sounds", "per-event sounds", "customize events", "override"]),
            row("general", 22, "Terminal Bell", "Sounds for each bell",
                ["custom sounds", "beep", "override"])
        ]
    )
    static let silencesAllSounds = AppSettingDescriptor<Bool>(
        identity: .silencesAllSounds,
        persistenceKey: "silencesAllSounds",
        absence: .falseValue,
        presentations: [row("general", 23, "Silence", "Silence every sound",
                            ["silence", "silence sounds", "mute"])]
    )

    static let disabledAttachmentDetectionAgentKinds = AppSettingDescriptor<[String]>(
        identity: .disabledAttachmentDetectionAgentKinds,
        persistenceKey: "disabledAttachmentDetectionAgentKinds",
        absence: .emptyCollection
    )
    static let includesAttachmentsOutsideProject = AppSettingDescriptor<Bool>(
        identity: .includesAttachmentsOutsideProject,
        persistenceKey: "includesAttachmentsOutsideProject",
        absence: .falseValue,
        presentations: [row("general", 11, "Attachments",
                            "Include files outside the project", ["attachments"])]
    )
    static let capturesPageBeforeAgentActions = AppSettingDescriptor<Bool>(
        identity: .capturesPageBeforeAgentActions,
        persistenceKey: "capturesPageBeforeAgentActions",
        absence: .falseValue,
        presentations: [row("general", 12, "Attachments",
                            "Keep the page as it was before each agent action",
                            ["attachments", "browser"])]
    )
    static let sessionCheckoutAuthorityPolicy = AppSettingDescriptor<String>(
        identity: .sessionCheckoutAuthorityPolicy,
        persistenceKey: "sessionCheckoutAuthorityPolicy",
        absence: .registered(SessionCheckoutAuthorityPolicy.allowExplicitRequests.rawValue),
        validation: .allowedStrings(Set(SessionCheckoutAuthorityPolicy.allCases.map(\.rawValue))),
        presentations: [row(
            "tools", 0, "Project", "Agents may move chats between checkouts",
            ["checkout", "worktree", "move chat", "project", "approval"]
        )]
    )
    static let disabledToolGroupIDs = AppSettingDescriptor<[String]>(
        identity: .disabledToolGroupIDs,
        persistenceKey: "disabledToolGroupIDs",
        absence: .emptyCollection
    )
    static let usesContainedExtensionLauncher = AppSettingDescriptor<Bool>(
        identity: .usesContainedExtensionLauncher,
        persistenceKey: "usesContainedExtensionLauncher",
        absence: .falseValue
    )
    /// Whether a launch addresses Threading's tool channel through the stdio bridge.
    ///
    /// Behavioural rather than presented: no `presentations`, so `remotePolicy` resolves to
    /// `.hidden` and this produces no Settings row and does not cross to the phone's mirror.
    /// `defaults write codes.threading mcpStdioBridgeEnabled -bool true` turns it on.
    ///
    /// **Off by default on purpose, and only for now.** The bridge is rollout step 2 of
    /// `docs/feature-drafts/durable-sessions.md` (§3c, §9): the shim ships behind a setting with
    /// HTTP still available as the fallback while it settles, and the TCP endpoint retires in
    /// step 3 once the bridge is the default and nothing launches against the port. Until then
    /// the two forms have to be reachable side by side, and the person choosing between them is
    /// whoever is testing the rollout — which is exactly the shape of a hidden key.
    static let usesMCPStdioBridge = AppSettingDescriptor<Bool>(
        identity: .usesMCPStdioBridge,
        persistenceKey: "mcpStdioBridgeEnabled",
        absence: .falseValue
    )
    /// Whether a session's PTY may live in the `threading-ptyd` background host.
    ///
    /// Behavioural rather than presented: no `presentations`, so `remotePolicy` resolves to
    /// `.hidden` and this produces no Settings row and does not cross to the phone's mirror.
    /// `defaults write codes.threading ptyHostEnabled -bool true` turns it on.
    ///
    /// **Off by default, and it must stay off.** §9 step 4 of
    /// `docs/feature-drafts/durable-sessions.md` ships the host behind a setting, and there is a
    /// second, harder gate on top of it: the daemon is a launchd agent, not a supervised child of
    /// Threading, and macOS attributes file access by *directly spawned, supervised* children
    /// (`permissions.md`). Whether an agent spawned by the daemon inherits Threading's TCC grants
    /// is unanswerable on the machine this was written on — `csrutil status` is disabled there, so
    /// every arm of the experiment passed trivially. Until R1/P4 of the PTY-host design has been
    /// run on a **SIP-enabled** Mac and the answer written into `permissions.md`, turning this on
    /// by default risks agents that silently cannot read the user's files. Off is the only
    /// defensible default until then.
    ///
    /// **Presented on the Advanced page only, and `.catalogueOnly` by construction.** The switch
    /// stopped being a `defaults write` when the Background Sessions section landed: a feature
    /// whose whole point is work with no window has to be findable, and a key nothing names is a
    /// key nobody can turn off either. Omitting `remotePolicy` is deliberate — a presented
    /// descriptor resolves to `.catalogueOnly`, so `list_settings` may describe the row and
    /// neither the phone nor an agent can read or move the value. `.ownerMutable` would open the
    /// remote `PATCH`, and starting a background daemon on somebody's Mac from a phone is not a
    /// thing this switch is going to do.
    static let ptyHostEnabled = AppSettingDescriptor<Bool>(
        identity: .ptyHostEnabled,
        persistenceKey: "ptyHostEnabled",
        absence: .falseValue,
        presentations: [row(
            "advanced", 7, "Background Sessions", "Background host",
            ["PTY", "daemon", "background", "durable", "keep running", "threading-ptyd"]
        )]
    )
    /// Whether every shell and agent Threading launches gets its command-line tools on `PATH`.
    ///
    /// Off by default, because it changes the `PATH` of every child the app starts and that is
    /// not something to do to somebody's terminal without being asked. On, it prepends the shim
    /// directory — never replaces `PATH` — so `threading-ptyd` works inside Threading's own
    /// terminals and the shell drawer with no profile edit, while every other command resolves
    /// exactly as it did. The composition itself is `AgentEnvironment.applyingCommandLineTools`.
    ///
    /// **Presented, and `.catalogueOnly` by construction.** Omitting `remotePolicy` is
    /// deliberate for the reason the switch above it gives: `list_settings` may describe the row,
    /// and neither the phone nor an agent can read or move the value. Changing what is on the
    /// `PATH` of every process this Mac's agents run is not a remote `PATCH`.
    static let prependsCommandLineToolsToPATH = AppSettingDescriptor<Bool>(
        identity: .prependsCommandLineToolsToPATH,
        persistenceKey: "prependsCommandLineToolsToPATH",
        absence: .falseValue,
        presentations: [row(
            "advanced", 10, "Background Sessions", "Tools in Threading's terminals",
            ["PATH", "command line", "CLI", "terminal", "threading-ptyd", "shell"]
        )]
    )
    static let workspaceNavigatorSelection = AppSettingDescriptor<Data>(
        identity: .workspaceNavigatorSelection,
        persistenceKey: "workspaceNavigatorSelection",
        absence: .recoverableFallback("native"),
        validation: .workspaceNavigatorIdentity(
            maximumIdentityBytes: 1_024,
            maximumDataBytes: 65_536
        ),
        encoding: .recoverableCodable
    )

    static let reportsClaudeLifecycleEvents = AppSettingDescriptor<Bool>(
        identity: .reportsClaudeLifecycleEvents,
        persistenceKey: "reportsClaudeLifecycleEvents",
        absence: .registered(true),
        presentations: [row("general", 26, "Claude Hooks",
                            "Report Claude turn and subagent activity", ["hooks"])]
    )
    static let installsCodexHooks = AppSettingDescriptor<Bool>(
        identity: .installsCodexHooks,
        persistenceKey: "installsCodexHooks",
        absence: .falseValue,
        presentations: [row("general", 28, "Codex Hooks", "Report Codex turn boundaries",
                            ["Codex hooks", "hooks.json"])]
    )
    static let readsClaudeLoginFromKeychain = AppSettingDescriptor<Bool>(
        identity: .readsClaudeLoginFromKeychain,
        persistenceKey: "readsClaudeLoginFromKeychain",
        absence: .falseValue,
        presentations: [row("privacy", 4, "Stored Credentials",
                            "Live usage from your Claude login", ["keychain", "usage"])]
    )
    static let suppressesClaudeStatusLine = AppSettingDescriptor<Bool>(
        identity: .suppressesClaudeStatusLine,
        persistenceKey: "suppressesClaudeStatusLine",
        absence: .falseValue,
        presentations: [row("general", 27, "Claude Hooks",
                            "Hide Claude's status line in Threading terminals", ["status line"])]
    )
    static let bypassesCodexHookTrust = AppSettingDescriptor<Bool>(
        identity: .bypassesCodexHookTrust,
        persistenceKey: "bypassesCodexHookTrust",
        absence: .falseValue,
        presentations: [row("general", 29, "Codex Hooks", "Skip Codex hook review", ["hooks"])]
    )
    static let claudeRemoteControl = AppSettingDescriptor<String>(
        identity: .claudeRemoteControl,
        persistenceKey: "claudeRemoteControl",
        absence: .fallback("followClaude"),
        validation: .allowedStrings(Set(ClaudeRemoteControl.allCases.map(\.rawValue))),
        presentations: [row("general", 25, "Claude Remote Control",
                            "Remote Control for new Claude sessions",
                            ["Claude Remote Control", "claude.ai", "mobile"])]
    )
    static let claudeStartupSpeed = AppSettingDescriptor<String>(
        identity: .claudeStartupSpeed,
        persistenceKey: "claudeStartupSpeed",
        absence: .fallback("agentSetting"),
        validation: .allowedStrings(Set(AgentStartupSpeed.allCases.map(\.rawValue))),
        presentations: [row("general", 7, "Conversation Speed", "Claude sessions start in",
                            ["fast mode", "standard mode", "credits", "conversation speed"])]
    )
    static let codexStartupSpeed = AppSettingDescriptor<String>(
        identity: .codexStartupSpeed,
        persistenceKey: "codexStartupSpeed",
        absence: .fallback("agentSetting"),
        validation: .allowedStrings(Set(AgentStartupSpeed.allCases.map(\.rawValue))),
        presentations: [row("general", 8, "Conversation Speed", "Codex sessions start in",
                            ["service tier", "credits", "conversation speed"])]
    )
    static let defaultPermissionMode = AppSettingDescriptor<String>(
        identity: .defaultPermissionMode,
        persistenceKey: "defaultPermissionMode",
        absence: .inherit,
        validation: .allowedStrings(Set(AgentPermissionMode.allCases.map(\.rawValue))),
        presentations: [row("general", 24, "Permission Mode", "New sessions start in",
                            ["permission mode", "ask before"])]
    )

    static let localDiagnosticsEnabled = AppSettingDescriptor<Bool>(
        identity: .localDiagnosticsEnabled,
        persistenceKey: "localDiagnosticsEnabled",
        absence: .falseValue,
        presentations: [row(
            "advanced", 0, "Local Diagnostics", "Allow paired-iPhone checkups",
            ["iPhone", "device checkup", "diagnostics", "local network", "agent"]
        )]
    )

    static let remoteAccessEnabled = AppSettingDescriptor<Bool>(
        identity: .remoteAccessEnabled,
        persistenceKey: "remoteAccessEnabled",
        absence: .falseValue,
        presentations: [row("remote-access", 0, "Connection", "Remote Access",
                            ["iPhone", "remote", "sharing"])]
    )
    /// Written once the retired connection mode has been carried over to the door switches.
    ///
    /// Never seeded, and written last, so an interrupted migration re-runs. Re-running is safe
    /// and, after the first run, a no-op: the migration deletes the keys it read, so a person who
    /// later switched Tailscale off is not undone by the next launch.
    static let remoteAccessDoorMigration = AppSettingDescriptor<Bool>(
        identity: .remoteAccessDoorMigration,
        persistenceKey: "didMigrateRemoteAccessDoors",
        absence: .falseValue,
        notification: .none
    )
    /// The port the listener tries first.
    ///
    /// Editable because the port is now sticky: a sticky port that collides with something else
    /// on this Mac has to be movable, or the collision is permanent. The range refuses rather
    /// than clamps, so a privileged port typed into `defaults write` leaves the working value in
    /// place instead of quietly becoming 1024.
    static let remoteAccessListenerPort = AppSettingDescriptor<Int>(
        identity: .remoteAccessListenerPort,
        persistenceKey: "remoteAccessListenerPort",
        absence: .registered(Int(RemoteAccessDefaults.defaultListenerPort)),
        validation: .refusingRange(
            RemoteAccessDefaults.minimumListenerPort...RemoteAccessDefaults.maximumListenerPort
        )
    )
    /// How long a released remote viewport lease keeps holding its grid.
    ///
    /// Behavioural rather than presented: no `presentations`, so `remotePolicy` resolves to
    /// `.hidden` and this produces no Settings row and does not cross to the phone's mirror. It
    /// is reachable by `defaults write` for somebody who needs a different window, and by a test.
    ///
    /// The range clamps rather than refuses, because the nearest allowed delay is what a person
    /// typing a number meant — a port is the case where the number *is* the meaning, and a delay
    /// is not. Zero is inside the range and is the kill switch: release immediately.
    static let remoteViewportLeaseGraceSeconds = AppSettingDescriptor<Int>(
        identity: .remoteViewportLeaseGraceSeconds,
        persistenceKey: "remoteViewportLeaseGraceSeconds",
        absence: .registered(RemoteAccessDefaults.viewportLeaseGraceSeconds),
        validation: .clampingRange(
            RemoteAccessDefaults.minimumViewportLeaseGraceSeconds ...
                RemoteAccessDefaults.maximumViewportLeaseGraceSeconds
        )
    )
    /// Which routable doors get a listener.
    ///
    /// `lan` by default now that the listener presents a pinned TLS identity: the door is
    /// offered, and "This network" is the primary way a phone reaches this Mac rather than a
    /// fallback. Loopback is never in here — it is bound whenever Remote Access is on and is
    /// not a door the user sees.
    ///
    /// **The encoding is deliberately `propertyList` rather than `removeEmpty`.** An empty set
    /// is a decision ("no network may reach this Mac"), and removing the key would hand the read
    /// back to the registered default, so switching the only door off would silently switch it
    /// on again at the next launch.
    static let remoteAccessDoors = AppSettingDescriptor<[String]>(
        identity: .remoteAccessDoors,
        persistenceKey: "remoteAccessDoors",
        absence: .registered([RemoteAccessDoor.lan.rawValue]),
        presentations: [row("remote-access", 1, "Ways In", "This network",
                            ["Wi-Fi", "LAN", "local network", "VPN", "Teleport"])]
    )
    /// Whether this Mac is reachable on its tailnet.
    ///
    /// One door, one switch. Off by default, and turning it on does not put Threading on any
    /// other network: every door is bound separately, which is the guarantee
    /// `docs/REMOTE_ACCESS.md` makes about publishing "only inside the owner's tailnet".
    static let remoteAccessTailscaleEnabled = AppSettingDescriptor<Bool>(
        identity: .remoteAccessTailscaleEnabled,
        persistenceKey: "remoteAccessTailscaleEnabled",
        absence: .registered(false),
        presentations: [row("remote-access", 2, "Ways In", "Tailscale",
                            ["tailnet", "Tailscale", "VPN", "away from home"])]
    )
    /// The browser convenience on the tailnet, and nothing else.
    ///
    /// Off by default and not a way in: the phone reaches this Mac at the tailnet address the
    /// listener binds, with the certificate it pinned, so nothing here is a route. What Serve
    /// adds is a publicly trusted certificate for the `*.ts.net` name, which is the only way a
    /// *browser* on the tailnet opens Threading without a full-page certificate warning. What it
    /// costs is a public certificate-transparency entry naming this Mac and the tailnet, which is
    /// why it is a switch a person makes rather than something the tailnet door turns on.
    static let remoteAccessTailscaleServeEnabled = AppSettingDescriptor<Bool>(
        identity: .remoteAccessTailscaleServeEnabled,
        persistenceKey: "remoteAccessTailscaleServeEnabled",
        absence: .registered(false),
        presentations: [row("remote-access", 3, "Ways In", "Open in a browser on your tailnet",
                            ["browser", "Serve", "certificate", "tailnet", "HTTPS"])]
    )
    /// An address to advertise beside the ones enumerated from the interfaces.
    ///
    /// Empty means "advertise what this Mac actually has". It exists for the two cases
    /// enumeration cannot see: a static DNS name pointing at this Mac, and a fixed address on
    /// the far side of a VPN whose interface the Mac does not hold.
    static let remoteAccessAdvertisedHostname = AppSettingDescriptor<String>(
        identity: .remoteAccessAdvertisedHostname,
        persistenceKey: "remoteAccessAdvertisedHostname",
        absence: .emptyString,
        validation: .maximumBytes(RemoteAccessDefaults.maximumAdvertisedHostnameBytes),
        encoding: .removeEmpty
    )
    /// Whether the LAN door is announced on the network with Bonjour.
    ///
    /// On, because finding the Mac by itself is the point of the same-Wi-Fi door: without it a
    /// DHCP lease change costs a re-pair, and with it the phone re-resolves and carries on. It is
    /// still a switch, because an advertisement is a broadcast that everyone on the network can
    /// see. What it carries is this Mac's id, the protocol version and the certificate
    /// fingerprint, and never the computer name, the user's name or a project name.
    ///
    /// Turning it off leaves the door open and the addresses advertised through `/api/me`; it
    /// only stops the announcement, which is the same position a VPN or tailnet address is
    /// already in, since multicast does not cross a tunnel.
    static let remoteAccessDiscoveryEnabled = AppSettingDescriptor<Bool>(
        identity: .remoteAccessDiscoveryEnabled,
        persistenceKey: "remoteAccessDiscoveryEnabled",
        absence: .registered(true)
    )
    static let phoneReportWorkspace = AppSettingDescriptor<String>(
        identity: .phoneReportWorkspace,
        persistenceKey: "phoneReportWorkspace",
        absence: .registered(PhoneReportWorkspacePolicy.sameCheckout.rawValue),
        validation: .allowedStrings(Set(PhoneReportWorkspacePolicy.allCases.map(\.rawValue))),
        presentations: [row("remote-access", 5, "Sharing & Security", "Reports from your phone",
                            ["shake", "report", "worktree", "workspace", "isolated"])]
    )
    static let remoteInputControlDefault = AppSettingDescriptor<String>(
        identity: .remoteInputControlDefault,
        persistenceKey: "remoteInputControlDefault",
        absence: .registered(RemoteInputControlDefault.collaborative.rawValue),
        validation: .allowedStrings(Set(RemoteInputControlDefault.allCases.map(\.rawValue))),
        presentations: [row("remote-access", 4, "Sharing & Security", "New shared chats",
                            ["security", "collaborative", "focused", "share"])],
        remotePolicy: .ownerMutable
    )

    /// Which builds this person is willing to receive. See `UpdateChannelSubscription`.
    ///
    /// Deliberately has no fixed default. A beta build must default to the beta subscription or a
    /// friend handed a beta zip is filtered away from every beta item and never updates again —
    /// the common way onto a beta, not an exotic one. The resolved default therefore depends on
    /// `AppInfo.buildChannel`, which the accessor applies; the stored value only ever records a
    /// choice somebody actually made.
    static let updateChannelSubscription = AppSettingDescriptor<String>(
        identity: .updateChannelSubscription,
        persistenceKey: "updateChannelSubscription",
        absence: .emptyString,
        validation: .allowedStrings(
            Set(UpdateChannelSubscription.allCases.map(\.rawValue)).union([""])
        ),
        presentations: [row("general", 30, "Software Updates", "Updates you receive",
                            ["beta", "channel", "prerelease", "nightly", "updates"])]
    )
    static let automaticUpdateChecksEnabled = AppSettingDescriptor<Bool>(
        identity: .automaticUpdateChecksEnabled,
        persistenceKey: "automaticUpdateChecksEnabled",
        absence: .registered(true),
        presentations: [row("general", 31, "Software Updates",
                            "Check for updates automatically", [
                                "updates", "Sparkle", "agent", "CLI", "Claude", "Codex",
                                "Grok", "OpenCode", "Cursor"
                            ])]
    )
    static let preventsIdleSystemSleepWhileAgentsWork = AppSettingDescriptor<Bool>(
        identity: .preventsIdleSystemSleepWhileAgentsWork,
        persistenceKey: "preventsIdleSystemSleepWhileAgentsWork",
        absence: .registered(false),
        presentations: [row(
            "general", 32, "Power", "Keep this Mac awake while agents work",
            ["sleep", "awake", "lid", "battery", "energy", "active turn"]
        )]
    )
    static let workingOrbStyle = AppSettingDescriptor<String>(
        identity: .workingOrbStyle,
        persistenceKey: "workingOrbStyle",
        absence: .registered(MotionPreferencesDefaults.workingOrbStyle.rawValue),
        validation: .allowedStrings(Set(WorkingOrbStyle.allCases.map(\.rawValue))),
        presentations: [row("motion", 0, "Working", "Working indicator",
                            ["orb", "animation", "spinner"])]
    )
    static let chatNameMorphStyle = AppSettingDescriptor<String>(
        identity: .chatNameMorphStyle,
        persistenceKey: "chatNameMorphStyle",
        absence: .registered(MotionPreferencesDefaults.chatNameMorphStyle.rawValue),
        validation: .allowedStrings(Set(ChatNameMorphStyle.allCases.map(\.rawValue))),
        presentations: [row("motion", 1, "Chat names", "Chat name transition",
                            ["transition", "animation", "morph"])]
    )
    static let chromeFontFamily = AppSettingDescriptor<String>(
        identity: .chromeFontFamily,
        persistenceKey: "chromeFontFamily",
        absence: .inherit,
        validation: .maximumBytes(1_024),
        encoding: .removeEmpty,
        presentations: [row("themes", 4, "Fonts", "App font", ["typeface", "font"])]
    )
    static let conversationFontFamily = AppSettingDescriptor<String>(
        identity: .conversationFontFamily,
        persistenceKey: "conversationFontFamily",
        absence: .inherit,
        validation: .maximumBytes(1_024),
        encoding: .removeEmpty,
        presentations: [row("themes", 5, "Fonts", "Conversation font",
                            ["typeface", "font", "chat"])]
    )
    static let appTextSize = AppSettingDescriptor<String>(
        identity: .appTextSize,
        persistenceKey: "appTextSize",
        absence: .registered(AppTextSize.standard.rawValue),
        validation: .allowedStrings(Set(AppTextSize.allCases.map(\.rawValue))),
        presentations: [row("themes", 3, "Fonts", "Text size",
                            ["large text", "text size"])]
    )

    // MARK: Erased Projections

    /// This registry repeats only typed declaration names. It contains no authored setting
    /// metadata and is therefore incapable of disagreeing with a descriptor's contract.
    static let persistedDescriptors: [AnyAppSettingDescriptor] = [
        .init(defaultAgentKind), .init(githubAppClientID), .init(restoresLastSession),
        .init(restoresRunningSessions), .init(sessionRestorePolicy),
        .init(sessionRestoreWindowDays), .init(sessionRestoreLimit),
        .init(newChatOpeningPrefix), .init(newChatOpeningSuffix),
        .init(legacyClosingConfirmation),
        .init(suppressedConfirmations), .init(hiddenNotices),
        .init(closingConfirmationMigration), .init(usesAgentTitleInSidebar),
        .init(groupsSessionsByBranch), .init(groupsLoneBranches), .init(compactsSidebarTree),
        .init(followsCheckoutBranch), .init(sidebarSessionOrder),
        .init(sidebarSessionOrderIsReversed), .init(promptReturnKey),
        .init(discoversProjectIcons), .init(discoversAccountAvatars),
        .init(harmonizesTerminalBackgrounds), .init(convertsDroppedImages),
        .init(copiesTerminalSelection), .init(notifiesOnAttention),
        .init(disabledAttentionAlerts), .init(legacyPlaysAttentionAlertSound),
        .init(attentionAlertSound), .init(terminalBellSound), .init(soundEventChoices),
        .init(silencesAllSounds), .init(disabledAttachmentDetectionAgentKinds),
        .init(includesAttachmentsOutsideProject), .init(capturesPageBeforeAgentActions),
        .init(sessionCheckoutAuthorityPolicy),
        .init(disabledToolGroupIDs), .init(usesContainedExtensionLauncher),
        .init(usesMCPStdioBridge), .init(ptyHostEnabled),
        .init(prependsCommandLineToolsToPATH),
        .init(workspaceNavigatorSelection), .init(reportsClaudeLifecycleEvents),
        .init(installsCodexHooks), .init(readsClaudeLoginFromKeychain),
        .init(suppressesClaudeStatusLine), .init(bypassesCodexHookTrust),
        .init(claudeRemoteControl), .init(claudeStartupSpeed), .init(codexStartupSpeed),
        .init(defaultPermissionMode), .init(localDiagnosticsEnabled),
        .init(remoteAccessEnabled),
        .init(remoteAccessDoorMigration),
        .init(remoteAccessListenerPort),
        .init(remoteViewportLeaseGraceSeconds),
        // In catalogue order: the ways in, then the browser convenience under the tailnet one.
        // `SettingsPages` projects its rows from this list, and a search result that lands on a
        // row above the one it names is how that projection goes wrong.
        .init(remoteAccessDoors), .init(remoteAccessTailscaleEnabled),
        .init(remoteAccessTailscaleServeEnabled),
        .init(remoteAccessAdvertisedHostname),
        .init(remoteAccessDiscoveryEnabled),
        .init(remoteInputControlDefault),
        .init(phoneReportWorkspace),
        .init(updateChannelSubscription),
        .init(automaticUpdateChecksEnabled), .init(preventsIdleSystemSleepWhileAgentsWork),
        .init(workingOrbStyle),
        .init(chatNameMorphStyle), .init(chromeFontFamily), .init(conversationFontFamily),
        .init(appTextSize)
    ]

    private static let surfaceDefinitions: [AppSettingDefinition] = [
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
        // Sign-in rather than a stored setting, so it is surfaced instead of persisted. It used
        // to borrow the connection mode's second presentation, and that descriptor is now a
        // migration record with no row of its own.
        surfaced("remoteAccess.hostedDirect", pageID: "remote-access", order: 6,
                  section: "Connection", title: "Hosted Direct",
                  "direct", "introduce", "sign in", "Threading Direct"),
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
        surfaced("advanced.settingsLocation", pageID: "advanced", order: 1,
                  section: "Locations", title: "Settings",
                  "preferences file", "where", "location", "reveal"),
        surfaced("advanced.applicationSupportLocation", pageID: "advanced", order: 2,
                  section: "Locations", title: "Projects, sessions and caches",
                  "application support", "location", "reveal"),
        surfaced("advanced.welcomeTour", pageID: "advanced", order: 3,
                  section: "Welcome Tour", title: "First-launch walkthrough",
                  "onboarding", "welcome tour"),
        surfaced("advanced.runWelcomeTour", pageID: "advanced", order: 4,
                  section: "Welcome Tour", title: "Run at next launch", "onboarding", "flag"),
        surfaced("advanced.resetSettings", pageID: "advanced", order: 5,
                  section: "Start Over", title: "Reset settings",
                  "reset", "start over", "fresh"),
        surfaced("advanced.resetEverything", pageID: "advanced", order: 6,
                  section: "Start Over", title: "Reset everything",
                  "erase", "corrupt", "start over"),
        surfaced("advanced.turnOffBackgroundHost", pageID: "advanced", order: 8,
                  section: "Background Sessions", title: "Turn off the background host",
                  "login items", "launch agent", "daemon", "threading-ptyd"),
        surfaced("advanced.commandLineTool", pageID: "advanced", order: 9,
                  section: "Background Sessions", title: "Command line tool",
                  "install", "symlink", "PATH", "terminal", "threading-ptyd", ".local/bin")
    ]

    static let all: [AppSettingDefinition] =
        persistedDescriptors.map(\.definition) + surfaceDefinitions

    private static let catalogue = AppSettingDefinitionCatalogue(definitions: all)
    private static let persistedByIdentity = Dictionary(
        persistedDescriptors.map { ($0.identity, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static var issues: [String] {
        var issues = catalogue.issues
        let identities = Dictionary(grouping: persistedDescriptors, by: \.identity)
        for identity in AppSettingIdentity.allCases where identities[identity]?.count != 1 {
            issues.append(
                "typed setting identity \(identity.rawValue) appears \(identities[identity]?.count ?? 0) times"
            )
        }
        return issues.sorted()
    }

    static var registeredDefaults: [String: Any] {
        catalogue.registeredDefaults
    }

    /// Applies an authenticated-owner mutation. Dynamic identity exists only at this wire-facing
    /// boundary; authorization and typed decoding are projected from the authored descriptor.
    static func applyRemoteMutation(
        identity: String,
        value: AppSettingStoredValue,
        defaults: UserDefaults
    ) -> AppSettingRemoteMutationResult {
        guard let definition = catalogue.definition(identity) else { return .unknownSetting }
        guard definition.remotePolicy == .ownerMutable,
              let typedIdentity = AppSettingIdentity(rawValue: identity),
              let descriptor = persistedByIdentity[typedIdentity] else { return .notMutable }
        return descriptor.applyRemoteMutation(value, defaults: defaults)
    }

    static func accepts(_ selection: WorkspaceNavigatorSelection) -> Bool {
        guard case .workspaceNavigatorIdentity(let maximumIdentityBytes, _) =
            workspaceNavigatorSelection.validation.erased else { return false }
        guard case .extensionNavigator(let extensionIdentifier, let navigatorID) = selection else {
            return true
        }
        return !extensionIdentifier.isEmpty
            && extensionIdentifier.utf8.count <= maximumIdentityBytes
            && !navigatorID.isEmpty
            && navigatorID.utf8.count <= maximumIdentityBytes
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

    fileprivate func definition(_ identity: String) -> AppSettingDefinition? {
        definitionsByIdentity[identity]
    }
}

private struct AppSettingRegisteredDefault: Sendable {
    let key: String
    let value: AppSettingStoredValue
}
