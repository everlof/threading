import Foundation
import ThreadingDomain
import ThreadingPTYHostKit

/// Whether one session's pty belongs in `threading-ptyd`, and — if it does — how to reach it.
///
/// Two questions that are deliberately separate. The first is a **choice**: a per-conversation
/// override over a hidden global, with the same three states `AgentSession.fastMode` and
/// `AgentSession.remoteControl` established, and nothing about the machine in it. The second is a
/// **fact**: whether a compatible daemon is actually listening, which is `PTYHostAvailability`
/// and degrades to today's in-process `forkpty` in every one of its cases. Keeping them apart is
/// what lets the Advanced page one day say "you asked for this and it is not happening, here is
/// why" instead of showing a checkbox that silently means nothing.
///
/// **No new `AgentKind` capability, deliberately.** Whether a session has a pty at all is already
/// `kind.supports(.terminalUI)`, withheld from exactly one runtime for a reason of its own; a
/// `.backgroundHost` capability would be true for four runtimes and false for the same one, for
/// the same reason, which is the definition of a duplicated fact. `AgentCapabilities`' own rule —
/// a capability earns a member only when the difference is a *static fact about the runtime* —
/// refuses it. Host-backing is a fact about the surface, and the surface clamp is the
/// `TerminalInstanceIdentity` check below.
enum PTYHostPolicy {

    // MARK: - The choice

    /// Session, then the hidden global, then off.
    ///
    /// `nil` survives from the setting all the way to the JSON rather than collapsing into a
    /// boolean on the way, which is what keeps a later change of the global from being silently
    /// pinned by every record written before it.
    ///
    /// A session that says `true` while the global is off still runs in-process, and not because
    /// this function lies to it: `PTYHostAvailability` answers `.unavailable(.disabled)` first
    /// and without touching anything, so the global is a master switch through *availability*
    /// while staying an inheritable default here. That is the arrangement the feature needs while
    /// it ships off by default.
    static func hostsSession(_ preference: Bool?, whenEnabled isEnabled: Bool) -> Bool {
        preference ?? isEnabled
    }

    /// The same question asked of a stored conversation.
    @MainActor
    static func hostsSession(_ session: AgentSession, settings: AppSettings = .shared) -> Bool {
        hostsSession(session.backgroundHost, whenEnabled: settings.ptyHostEnabled)
    }

    // MARK: - The launch-time composition

    /// Everything a launch has to decide before it knows whether to spawn locally, as one call.
    ///
    /// Answers the factory a host-backed launch connects through, or **nil** meaning today's
    /// in-process `forkpty`, unchanged. The order is the design rather than tidiness, and it is
    /// the same argument `PTYHostAvailability.resolve` makes one level down: the surface clamp is
    /// a pattern match, the choice is a `UserDefaults` read the app has already taken, and only
    /// after both does anything open a socket.
    ///
    /// **It can block, and it is bounded.** `PTYHostProbe.connecting()` connects and exchanges
    /// `hello`, so a launch with the feature switched on pays at most
    /// `PTYHostDefaults.connectTimeout + helloTimeout` before degrading — which is why those two
    /// numbers are stated as launch-path deadlines. With the feature off, which is every launch
    /// until the hidden key is set, nothing is opened at all.
    ///
    /// Every dependency is the caller's, in `MCPBridgeDecision.live`'s shape, so a test can force
    /// each branch without process defaults, a real bundle or a daemon.
    @MainActor
    static func transportFactory(
        for identity: TerminalInstanceIdentity,
        session: AgentSession?,
        settings: AppSettings = .shared,
        bundle: Bundle = .main,
        probe: PTYHostProbe = .connecting(),
        eventLog: EventLog = .shared,
        newSessionAdmission: PTYHostNewSessionAdmission = .shared
    ) -> PTYHostTransportFactory? {
        // Version 1 hosts agent sessions only. A project terminal, a session shell and an
        // ephemeral terminal all poll `tcgetpgrp` on a descriptor a host-backed session does not
        // have, and the `foreground` frame that replaces it is only wired up for the one surface
        // that has been measured. The protocol spells all four out so hosting them later is a
        // daemon change rather than a protocol change.
        guard case .agentSession = identity else { return nil }
        guard let session, hostsSession(session, settings: settings) else { return nil }
        // The gate's own token, not one fixed token for both of its refusals.
        // `registrationRefreshing` means "a stale or ambiguous launchd association is being
        // replaced safely", and it was being written for a daemon that was merely a different
        // build holding somebody's agents — a state that lasts as long as the work does. A cause
        // that names the wrong condition is worse than no cause, because it sends the next person
        // to look at registration.
        let admission = newSessionAdmission.current
        guard admission.permitsHostedSpawn else {
            eventLog.record(.session, "Session runs its PTY in-process", [
                "session": identity.historyFileStem,
                "cause": admission.token
            ])
            return nil
        }

        let availability = PTYHostAvailability.live(
            settings: settings,
            bundle: bundle,
            probe: probe
        )
        guard let socketPath = availability.socketPath else {
            // Once per launch, with the structural cause. A feature that quietly stopped working
            // is unexplainable without this line, and it is the same token the Advanced page and
            // a support report read.
            eventLog.record(
                .session,
                "Session runs its PTY in-process",
                [
                    "session": identity.historyFileStem,
                    "cause": availability.unavailability?.token ?? "unknown"
                ]
            )
            return nil
        }

        return attachingTransportFactory(socketPath: socketPath, bundle: bundle)
    }

    /// A factory for a rendezvous somebody has already decided on.
    ///
    /// The reattach path's, and it takes no availability of its own on purpose: the daemon has
    /// just answered `list` on this exact socket, so asking again would be asking a question
    /// already answered — and answering it differently the second time would mean building a
    /// terminal for a session nothing is going to hand back.
    static func attachingTransportFactory(
        socketPath: String,
        bundle: Bundle = .main
    ) -> PTYHostTransportFactory {
        let build = PTYHostBuild.string(for: bundle)
        return { events in
            let client = PTYHostClient(socketPath: socketPath, build: build, events: events)
            try client.connect()
            return client
        }
    }
}
