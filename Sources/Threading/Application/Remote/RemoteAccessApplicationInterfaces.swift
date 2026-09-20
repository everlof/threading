import Foundation
import ThreadingRemoteKit

/// Read-only session facts the remote transport is allowed to expose or validate.
///
/// Keeping this separate from mutations prevents a route that only prepares a response from
/// acquiring the whole project graph as an ambient capability.
@MainActor
protocol RemoteSessionQuerying: Sendable {
    func session(withID sessionID: SessionID) -> AgentSession?
    func terminal(withID terminalID: TerminalID) -> ProjectTerminal?
    func project(withID projectID: ProjectID) -> Project?
    func project(forSessionID sessionID: SessionID) -> Project?
}

/// The durable project-graph changes admitted by the remote lifecycle routes.
@MainActor
protocol RemoteSessionMutating: Sendable {
    /// The typed reason a durable mutation is currently blocked, if the store already knows it.
    /// A failed mutation remains authoritative on its own; this value only preserves the
    /// actionable storage-exhaustion cause across the remote wire.
    var persistenceBlockReason: ProjectStorePersistenceBlock? { get }

    func renameSession(id sessionID: SessionID, to title: String?) -> ProjectMutationResult
    func setProjectHidden(_ hidden: Bool, projectID: ProjectID) -> ProjectMutationResult
    func setPinned(_ pinned: Bool, for sessionID: SessionID) -> ProjectMutationResult
    func setUsesNativeUI(
        _ usesNativeUI: Bool,
        for sessionID: SessionID
    ) -> ProjectMutationResult
    func setLimitRecoveryPolicy(
        _ policy: LimitRecoveryPolicy?,
        forSessionID sessionID: SessionID
    ) -> ProjectMutationResult
}

/// Runtime state needed by remote resume, surface switching, and permission decisions.
@MainActor
protocol RemoteRuntimeStatus: Sendable {
    func isRunning(sessionID: SessionID) -> Bool

    /// Whether a live surface — a terminal or a rendered conversation — is already retained for
    /// this session. Reopening such a session attaches rather than launching, which is the one
    /// case where a stored launch failure says nothing about what a resume will do.
    func hasTerminal(sessionID: SessionID) -> Bool
    func discard(sessionID: SessionID, preservingViewport: Bool)
    func resolveRemoteBrowserPermission(
        sessionID: SessionID,
        id: String,
        decision: RemoteBrowserPermissionDecision
    ) -> Bool
    func resolveRemotePermission(
        sessionID: SessionID,
        id: String,
        decision: RemotePermissionDecision
    ) -> Bool
}

enum RemoteAppThemeMutationResult: Equatable {
    case applied(AppThemeID)
    case unknownTheme
}

/// Settings mutations exposed to an authenticated owner. Validation and persistence stay behind
/// this boundary instead of being reconstructed in the HTTP adapter.
@MainActor
protocol RemoteSettingsMutating: Sendable {
    func applyAppSetting(
        identity: String,
        value: AppSettingStoredValue
    ) -> AppSettingRemoteMutationResult
    func applyAppTheme(id: AppThemeID) -> RemoteAppThemeMutationResult
    func setSessionTheme(
        id: TerminalThemeID?,
        for sessionID: SessionID
    ) -> ProjectMutationResult
}

/// The detail keys a remote event may carry.
///
/// A journal row's *message* is prose a person reads, and stays free text. Its keys are not: they
/// become the JSON object keys of `detail`, which is what a support report groups and joins on, so
/// `"sesion"` hand-spelled once is a column that quietly loses a row rather than anything anyone
/// notices. Naming them here makes that a compile error, the same way `RemoteDiagnosticField` does
/// for the phone's diagnostics journal — a *different* vocabulary, generated from a contract and
/// bound for a public intake, which this one is deliberately not merged into.
///
/// The raw values are the strings already in every journal on disk. Renaming a case renames the
/// key, so a rename is a decision about existing records, not a tidy-up.
enum RemoteEventField: String, CaseIterable, Hashable, Sendable {
    /// The paired device as the client named itself, or `unknown`.
    case device
    /// `MacRemoteDiagnostics.pseudonym` of a device — the hashed form, where the raw id is not
    /// what the row is about.
    case peer
    /// The session a route acted on, as a UUID string.
    case session
    /// The terminal a route acted on, as a UUID string.
    case terminal
    /// The share a registration or route authenticated against.
    case share
    /// What the authorization was allowed to do.
    case capability
    /// The terminal or app theme applied, or `inherit`.
    case theme
    /// The app setting's identity.
    case setting
    /// The session surface switched to.
    case surface
    /// The account a session was moved to.
    case account
    /// The limit-recovery action chosen.
    case policy
    /// Where an upload came from.
    case source
    /// How many records an upload carried.
    case records
    /// Whether a cached capture included a screenshot.
    case screenshot
    /// How a notification registration will be delivered.
    case delivery
    /// The answer given to a permission request.
    case decision
    /// Which side of the protocol needs updating.
    case update
    /// Why something was refused.
    case reason
    /// The runtime a launch request named.
    case agent
    /// The model a launch request named, or `inherit` when it left that to the account.
    case model
}

/// The remote adapter may append structured events but cannot inspect or manage the journal.
protocol RemoteEventRecording: Sendable {
    func recordRemoteEvent(
        _ message: String,
        _ detail: [RemoteEventField: String]
    )
}

/// Host-scoped lifecycle operations owned by the remote coordinator, kept separate from socket
/// routing so the transport neither locates nor retains that concrete composition owner.
@MainActor
protocol RemoteHostCommanding: AnyObject, Sendable {
    func issueHostedDeviceCredential(accessToken: String, deviceID: String) async throws
        -> RemoteHostedDeviceCredentialDTO
    func completeHostedPairingBootstrap()
    func prepareSessionShare(
        for sessionID: SessionID,
        capability: RemoteCapability,
        canApprovePermissions: Bool
    ) async -> Result<RemoteCreatedShare, RemoteSharePreparationError>
    func createSessionShare(
        for sessionID: SessionID,
        capability: RemoteCapability,
        canApprovePermissions: Bool
    ) -> Result<RemoteCreatedShare, RemoteSharePreparationError>
    func revokeSessionShares(_ sessionID: SessionID)
    func createTerminalShare(
        for terminalID: TerminalID,
        capability: RemoteCapability
    ) -> Result<RemoteCreatedShare, RemoteSharePreparationError>
    func revokeTerminalShares(_ terminalID: TerminalID)
}

extension ProjectStore: RemoteSessionQuerying, RemoteSessionMutating {}
extension AgentRuntime: RemoteRuntimeStatus {}
extension EventLog: RemoteEventRecording {
    func recordRemoteEvent(_ message: String, _ detail: [RemoteEventField: String]) {
        record(.remote, message, detail.reduce(into: [String: String]()) { keyed, entry in
            keyed[entry.key.rawValue] = entry.value
        })
    }
}

@MainActor
struct LiveRemoteSettingsMutator: RemoteSettingsMutating {
    private let appSettings: AppSettings

    init(appSettings: AppSettings) {
        self.appSettings = appSettings
    }

    func applyAppSetting(
        identity: String,
        value: AppSettingStoredValue
    ) -> AppSettingRemoteMutationResult {
        appSettings.applyRemoteMutation(identity: identity, value: value)
    }

    func applyAppTheme(id: AppThemeID) -> RemoteAppThemeMutationResult {
        guard let theme = AppThemeLibrary.theme(withID: id) else { return .unknownTheme }
        AppThemeLibrary.apply(theme)
        return .applied(theme.id)
    }

    func setSessionTheme(
        id: TerminalThemeID?,
        for sessionID: SessionID
    ) -> ProjectMutationResult {
        if let id, ThemeAssignments.selectableTheme(withID: id) == nil {
            return .unsupportedValue
        }
        return ThemeAssignments.setTheme(id: id, forSession: sessionID)
    }
}

/// Complete application capabilities required by the loopback transport. Every field is
/// supplied at construction; the server has no fallback path to process singletons.
struct RemoteAccessServerServices {
    let sessionQueries: any RemoteSessionQuerying
    let sessionMutations: any RemoteSessionMutating
    let runtimeStatus: any RemoteRuntimeStatus
    let settings: any RemoteSettingsMutating
    let eventLog: any RemoteEventRecording

    let mirrors: RemoteSessionMirrorRegistry
    let notifications: RemoteNotificationService
    let archiveSync: ProviderArchiveSync
    let snoozeCenter: SessionSnoozeCenter
    let attachments: SessionAttachmentStore
    let extensions: ExtensionManager
    let mobileDiagnosticsCaptures: MobileDiagnosticsCaptureStore
    let usageCapacity: @MainActor @Sendable () async throws -> RemoteUsageCapacityDTO
    let usageDashboard: RemoteUsageDashboardLoader
    let usageLimit: RemoteUsageLimitLoader
    let usageResetOffer: RemoteUsageResetOfferLoader
    let usageResetConsumer: RemoteUsageResetConsumer

    init(
        sessionQueries: any RemoteSessionQuerying,
        sessionMutations: any RemoteSessionMutating,
        runtimeStatus: any RemoteRuntimeStatus,
        settings: any RemoteSettingsMutating,
        eventLog: any RemoteEventRecording,
        mirrors: RemoteSessionMirrorRegistry,
        notifications: RemoteNotificationService,
        archiveSync: ProviderArchiveSync,
        snoozeCenter: SessionSnoozeCenter,
        attachments: SessionAttachmentStore,
        extensions: ExtensionManager,
        mobileDiagnosticsCaptures: MobileDiagnosticsCaptureStore,
        usageDashboard: @escaping RemoteUsageDashboardLoader,
        usageLimit: @escaping RemoteUsageLimitLoader,
        usageCapacity: @escaping @MainActor @Sendable () async throws -> RemoteUsageCapacityDTO = {
            throw RemoteUsageCapacityError.invalidSnapshot
        },
        usageResetOffer: @escaping RemoteUsageResetOfferLoader = { _ in nil },
        usageResetConsumer: @escaping RemoteUsageResetConsumer = { _, _ in
            throw BankedUsageResetError.unsupportedAccount
        }
    ) {
        self.sessionQueries = sessionQueries
        self.sessionMutations = sessionMutations
        self.runtimeStatus = runtimeStatus
        self.settings = settings
        self.eventLog = eventLog
        self.mirrors = mirrors
        self.notifications = notifications
        self.archiveSync = archiveSync
        self.snoozeCenter = snoozeCenter
        self.attachments = attachments
        self.extensions = extensions
        self.mobileDiagnosticsCaptures = mobileDiagnosticsCaptures
        self.usageCapacity = usageCapacity
        self.usageDashboard = usageDashboard
        self.usageLimit = usageLimit
        self.usageResetOffer = usageResetOffer
        self.usageResetConsumer = usageResetConsumer
    }
}

extension RemoteHostCommanding {
    func prepareSessionShare(
        for sessionID: SessionID,
        capability: RemoteCapability,
        canApprovePermissions: Bool
    ) async -> Result<RemoteCreatedShare, RemoteSharePreparationError> {
        createSessionShare(for: sessionID, capability: capability,
                           canApprovePermissions: canApprovePermissions)
    }
}
