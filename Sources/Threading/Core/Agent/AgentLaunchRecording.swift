import Foundation

/// The durable state of an admitted terminal launch attempt. A fresh record can be saved before
/// spawn; an existing record can wait for the daemon's spawned reply so a duplicate-live refusal
/// leaves it untouched. Hosts decide admission, persistence and process ownership; this shared
/// transition keeps saved Linux and macOS sessions describing the same launch.
enum AgentLaunchRecording {
    static func apply(_ plan: AgentLaunchPlan, to session: inout AgentSession, at date: Date) {
        session.hasLaunched = true
        session.lastActiveAt = date
        session.lastExitCode = nil
        session.resumeState = plan.resumeState
    }
}
