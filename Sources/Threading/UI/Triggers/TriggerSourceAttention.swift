import Foundation

/// What stands between an automation and the event source it waits for, as one row: the source,
/// the problem in a few words, what that means, and the host action that fixes it.
///
/// The project page and an automation's own page show it where the person is looking, because
/// an event automation whose source was never approved looks Active and simply never runs, and
/// the Sources page that could say so was one destination away (2026-10-05). The action opens
/// the flow the Sources page uses — the probe's approval sheet, Resume, Reconnect — and never a
/// shortcut around it.
@MainActor
struct TriggerSourceAttention: Equatable {
    enum Problem: Equatable {
        /// A probe nobody approved yet: it is not in the listener's configuration at all.
        case needsApproval
        /// A probe whose files no longer hash to its approval: it does not run.
        case changed
        case paused
        /// A connected source with no credential.
        case disconnected
        /// Polled, and failing.
        case unhealthy(TriggerSourceHealth)
        /// Nothing is polled, because the background listener is not running.
        case notPolling(TriggerListenerState)
    }

    enum Action: Equatable {
        case review
        case resume
        case reconnect
        case openLoginItems
        case restartListener
    }

    let sourceID: TriggerSourceInstallationID
    let sourceName: String
    let problem: Problem
    /// The listener's or the source's own bounded diagnostic, when it has one.
    let diagnostic: String?

    /// `daemonStatus` must already be the listener's latest receipt for this revision of the
    /// source (the Sources page drops receipts older than the source's last edit).
    static func evaluate(
        _ source: TriggerSourceInstallation,
        daemonStatus: TriggerDaemonSourceStatus?,
        listener: TriggerListenerState
    ) -> TriggerSourceAttention? {
        guard !source.isDeleted else { return nil }
        let diagnostic = daemonStatus?.boundedDiagnostic ?? source.boundedDiagnostic
        func make(_ problem: Problem, diagnostic: String? = nil) -> TriggerSourceAttention {
            TriggerSourceAttention(sourceID: source.id, sourceName: source.displayName,
                                   problem: problem, diagnostic: diagnostic)
        }
        let health: TriggerSourceHealth
        if source.sourceType == TriggerProbeDefaults.sourceType {
            switch TriggerProbePresentation.state(of: source, daemonStatus: daemonStatus) {
            case .needsApproval: return make(.needsApproval)
            case .changed: return make(.changed)
            case .paused: return make(.paused)
            case .listening(let observed): health = observed
            }
        } else {
            guard source.credentialReference != nil else { return make(.disconnected) }
            guard source.enabled else { return make(.paused) }
            health = daemonStatus?.health ?? source.health
        }
        guard listener.isListening else { return make(.notPolling(listener), diagnostic: listener.diagnostic) }
        switch health {
        case .failed, .backingOff, .authenticationRequired, .disconnected, .changed:
            return make(.unhealthy(health), diagnostic: diagnostic)
        case .healthy, .checking:
            return nil
        }
    }

    /// The state word beside the source's name.
    var stateWords: String {
        switch problem {
        case .needsApproval: return L10n.string("Needs approval")
        case .changed: return L10n.string("Changed since approval")
        case .paused: return L10n.string("Paused")
        case .disconnected: return L10n.string("Disconnected")
        case .unhealthy(let health): return health.displayTitle
        case .notPolling: return L10n.string("Not checked")
        }
    }

    var tone: AutomationInk.Tone {
        switch problem {
        case .needsApproval, .changed, .paused, .disconnected: return .attention
        case .unhealthy, .notPolling: return .failure
        }
    }

    /// What the problem means for the automations waiting on it.
    var consequence: String {
        switch problem {
        case .needsApproval:
            return L10n.string("It does not run until you approve it, so no events arrive.")
        case .changed:
            return L10n.string("Its files changed after you approved them, so it does not run until you approve it again.")
        case .paused:
            return L10n.string("It reports no events while paused.")
        case .disconnected:
            return L10n.string("It has no credential, so no events arrive.")
        case .unhealthy:
            return diagnostic ?? L10n.string("Its last check failed.")
        case .notPolling(let listener):
            return listener.sourceConsequence
        }
    }

    var action: Action? {
        switch problem {
        case .needsApproval, .changed: return .review
        case .paused: return .resume
        case .disconnected: return .reconnect
        case .unhealthy: return nil
        case .notPolling(let listener): return listener.action
        }
    }

    var actionTitle: String? { action.map(Self.title(for:)) }

    static func title(for action: Action) -> String {
        switch action {
        case .review: return L10n.string("Review & Approve…")
        case .resume: return L10n.string("Resume")
        case .reconnect: return L10n.string("Reconnect")
        case .openLoginItems: return L10n.string("Open Login Items…")
        case .restartListener: return L10n.string("Restart Listener")
        }
    }
}

@MainActor
extension TriggerListenerState {
    /// The Sources page's listener row: what it is doing, in a few words.
    var title: String {
        switch self {
        case .running: return L10n.string("Running")
        case .starting: return L10n.string("Starting")
        case .refused: return L10n.string("Blocked by macOS")
        case .stopped: return L10n.string("Not running")
        case .requiresApproval: return L10n.string("Needs approval in Login Items")
        case .notRegistered: return L10n.string("Not registered")
        case .idle: return L10n.string("Off")
        case .missingHelper: return L10n.string("Unavailable in this build")
        }
    }

    var tone: AutomationInk.Tone {
        switch self {
        case .running: return .positive
        case .starting: return .working
        case .requiresApproval, .notRegistered: return .attention
        case .idle: return .quiet
        case .refused, .stopped, .missingHelper: return .failure
        }
    }

    /// The listener row's explanation, naming launchd's own reason where it gave one.
    var detail: String {
        switch self {
        case .running:
            return L10n.string("Checks your sources even while Threading is closed.")
        case .starting:
            return L10n.string("macOS is starting the listener.")
        case .refused(let reason, let attempts):
            let cause = reason?.contains("CODESIGNING") == true
                ? L10n.format("macOS refuses to start the listener because it rejected its code signature (%@).", reason ?? "")
                // launchd's own words when it gave no exit reason, as `launchctl print` spells them.
                : L10n.format("macOS refuses to start the listener (%@).", reason ?? "spawn failed")
            let tries = attempts.map { L10n.format("It has tried %lld times.", Int64($0)) }
            return [cause, tries, L10n.string("No source is checked until a build that macOS accepts is installed.")]
                .compactMap { $0 }.joined(separator: " ")
        case .stopped(let lastReport, let exitCode):
            var parts = [L10n.string("The listener is registered but not running, so no source is checked.")]
            if let lastReport {
                parts.append(L10n.format(
                    "It last reported %@.",
                    AutomationInk.relativeDate.localizedString(for: lastReport, relativeTo: Date())
                ))
            }
            if let exitCode { parts.append(L10n.format("Last exit code: %@.", exitCode)) }
            return parts.joined(separator: " ")
        case .requiresApproval:
            return L10n.string("Allow Threading in System Settings ▸ General ▸ Login Items so it can check sources.")
        case .notRegistered:
            return L10n.string("The listener is not registered, so no source is checked.")
        case .idle:
            return L10n.string("Nothing needs it yet. Threading starts it when you enable a source or schedule an automation.")
        case .missingHelper:
            return L10n.string("This build has no background listener, so no source is checked.")
        }
    }

    /// What a source row says when the listener is the reason it is not checked.
    var sourceConsequence: String {
        switch self {
        case .requiresApproval:
            return L10n.string("Not checked: the background listener is waiting for approval in Login Items.")
        case .refused:
            return L10n.string("Not checked: macOS refuses to start the background listener.")
        default:
            return L10n.string("Not checked: the background listener is not running.")
        }
    }

    var action: TriggerSourceAttention.Action? {
        switch self {
        case .requiresApproval: return .openLoginItems
        case .notRegistered, .stopped: return .restartListener
        case .running, .starting, .refused, .idle, .missingHelper: return nil
        }
    }
}
