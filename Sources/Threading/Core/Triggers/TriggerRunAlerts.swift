import Foundation

// MARK: - Trigger Run Diagnostic

/// The words a run settles with when its agent did not report a result itself.
///
/// The cause is decided from typed facts — the run's state and the provider's typed refusal of
/// the turn — never from prose. "Ended without reporting a result" stays for an exit nothing
/// explains.
enum TriggerRunDiagnostic {

    /// Where the login that failed lives, named the way Settings ▸ Agents & Accounts lists it.
    struct Login: Equatable, Sendable {
        let provider: AgentKind
        let name: String
    }

    static func unreported(
        state: TriggerRunState,
        failure: AgentTurnFailure?,
        login: Login?
    ) -> String {
        if let failure, let login {
            switch failure {
            case .authenticationFailed:
                return signedOut(login)
            }
        }
        switch state {
        case .fixing: return L10n.string("The fix agent ended without reporting a final result.")
        case .running: return L10n.string("The automation ended without reporting a result.")
        // The result is kept; what is missing is the ready prompt that proves the turn ended.
        case .finishing: return L10n.string("The agent reported a result but did not finish its turn at a ready prompt.")
        default: return L10n.string("The assessment agent ended without reporting an assessment.")
        }
    }

    private static func signedOut(_ login: Login) -> String {
        // The one-year token is offered only where the runtime accepts one; elsewhere signing in
        // again is the whole answer.
        if login.provider.supports(.longLivedAccountToken) {
            return L10n.format(
                "The %@ login “%@” is no longer signed in. Sign in again, or give it a one-year token in Settings ▸ Agents & Accounts.",
                login.provider.displayName,
                login.name
            )
        }
        return L10n.format(
            "The %@ login “%@” is no longer signed in. Sign in again in Settings ▸ Agents & Accounts.",
            login.provider.displayName,
            login.name
        )
    }

    /// The login a session runs on: its own folder name, or the default folder's path for the
    /// standard login, because "default" alone does not say which sign-in to renew.
    @MainActor
    static func login(for session: AgentSession) -> Login {
        let name: String
        switch session.accountHandle {
        case .named(let handle):
            name = handle
        case .standard:
            name = AgentAccountDiscovery.account(for: session.kind, handle: .standard)
                .map { ($0.configPath as NSString).abbreviatingWithTildeInPath }
                ?? AccountHandle.standardName
        }
        return Login(provider: session.kind, name: name)
    }
}

// MARK: - Trigger Run Alerts

/// Whether a settled run reaches the person off screen, decided once per run.
///
/// A run that failed or needs attention alerts the Mac and the paired iPhone; a successful one
/// does not, because success is what an automation is for and its receipt waits in Activity and
/// the in-app toast. Settlement can be observed from more than one edge (an assessment report,
/// a turn ending, a refused start), so the alert is keyed to the run, not to the edge.
@MainActor
final class TriggerRunAlerts {

    struct Alert: Equatable, Sendable {
        let runID: TriggerRunID
        let sessionID: SessionID?
        let title: String
        let body: String
    }

    /// Where an alert goes. The phone half requires a session, because the remote notification
    /// contract scopes every event to one; a run refused before its session existed reaches the
    /// Mac only.
    struct Sinks {
        var mac: @MainActor (Alert) -> Void
        var phone: @MainActor (Alert, SessionID) -> Void
        var phoneEnabled: @MainActor () -> Bool
    }

    static let shared = TriggerRunAlerts(sinks: .live)

    /// Normal use is a handful of runs a day; the bound only keeps a runaway source from growing
    /// this without limit. An evicted run was settled long ago and cannot settle again.
    static let ledgerLimit = 256

    private let sinks: Sinks
    private var announced: Set<TriggerRunID> = []
    private var announcedOrder: [TriggerRunID] = []

    init(sinks: Sinks) {
        self.sinks = sinks
    }

    /// The alert a settled run warrants, or nil when it warrants none.
    static func alert(for run: TriggerRun, automationName: String?) -> Alert? {
        let title: String
        switch run.state {
        case .failed:
            title = automationName.map { L10n.format("“%@” failed", $0) }
                ?? L10n.string("Automation failed")
        case .needsAttention:
            title = automationName.map { L10n.format("“%@” needs attention", $0) }
                ?? L10n.string("Automation needs attention")
        default:
            return nil
        }
        let body = run.result?.summary
            ?? run.boundedDiagnostic
            ?? L10n.string("The trigger run needs review.")
        return Alert(runID: run.id, sessionID: run.sessionID, title: title, body: body)
    }

    /// Sends the run's alert at most once. Returns what was sent, or nil.
    @discardableResult
    func announce(_ run: TriggerRun, automationName: String?) -> Alert? {
        guard !announced.contains(run.id),
              let alert = Self.alert(for: run, automationName: automationName) else { return nil }
        remember(run.id)
        sinks.mac(alert)
        if let sessionID = alert.sessionID, sinks.phoneEnabled() {
            sinks.phone(alert, sessionID)
        }
        return alert
    }

    private func remember(_ runID: TriggerRunID) {
        announced.insert(runID)
        announcedOrder.append(runID)
        if announcedOrder.count > Self.ledgerLimit {
            announced.remove(announcedOrder.removeFirst())
        }
    }
}

extension TriggerRunAlerts.Sinks {
    /// The paths every "needs you" alert already takes: `AttentionAlertCenter` on the Mac, with
    /// its master switch and per-session mute, and the requested-notification route to paired
    /// devices, with their own opt-in, authorization and Remote Access gates.
    @MainActor static let live = TriggerRunAlerts.Sinks(
        mac: { alert in
            let eventID = "automation-\(alert.runID.uuidString)"
            if let sessionID = alert.sessionID {
                _ = AttentionAlertCenter.shared.postRequestedUpdate(
                    eventID: eventID,
                    sessionID: sessionID,
                    title: alert.title,
                    body: alert.body,
                    destination: .session
                )
            } else {
                _ = AttentionAlertCenter.shared.postAppUpdate(
                    eventID: eventID,
                    title: alert.title,
                    body: alert.body
                )
            }
        },
        phone: { alert, sessionID in
            _ = RemoteNotificationService.shared.notifyRequested(
                sessionID: sessionID,
                title: alert.title,
                body: alert.body,
                recipient: nil,
                destination: .session
            )
        },
        phoneEnabled: { AppSettings.shared.remoteAccessEnabled }
    )
}
