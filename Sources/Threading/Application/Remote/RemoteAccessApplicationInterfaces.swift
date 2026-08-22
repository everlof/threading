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
    func renameSession(id sessionID: SessionID, to title: String?) -> ProjectMutationResult
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
    func discard(sessionID: SessionID, preservingViewport: Bool)
    func resolveRemotePermission(
        sessionID: SessionID,
        id: String,
        decision: String
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

/// The remote adapter may append structured events but cannot inspect or manage the journal.
protocol RemoteEventRecording: Sendable {
    func recordRemoteEvent(
        _ message: String,
        _ detail: [String: String]
    )
}

/// Host-scoped lifecycle operations owned by the remote coordinator, kept separate from socket
/// routing so the transport neither locates nor retains that concrete composition owner.
@MainActor
protocol RemoteHostCommanding: AnyObject, Sendable {
    func issueHostedDeviceCredential(deviceID: String) async throws
        -> RemoteHostedDeviceCredentialDTO
    func completeHostedPairingBootstrap()
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
    func recordRemoteEvent(_ message: String, _ detail: [String: String]) {
        record(.remote, message, detail)
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
    let usageDashboard: RemoteUsageDashboardLoader
    let usageLimit: RemoteUsageLimitLoader
}
