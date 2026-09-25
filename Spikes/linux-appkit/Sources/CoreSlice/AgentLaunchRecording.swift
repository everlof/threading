import Foundation

/// The durable state of a terminal launch attempt, applied before handing its plan to a host.
/// Hosts decide admission, persistence and process ownership; this transition is shared so a
/// saved Linux session and a saved macOS session describe the same launch.
enum AgentLaunchRecording {
    static func apply(_ plan: AgentLaunchPlan, to session: inout AgentSession, at date: Date) {
        session.hasLaunched = true
        session.lastActiveAt = date
        session.lastExitCode = nil
        session.resumeState = plan.resumeState
    }
}
