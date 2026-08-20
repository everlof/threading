import Foundation

/// Application-owned services assembled once and passed down through ownership boundaries.
///
/// `live` is the only place this composition names the legacy process singletons. Feature
/// controllers receive the concrete instances they use, which makes each migrated boundary
/// independently constructible without turning the environment into a new service locator.
@MainActor
struct AppEnvironment {
    let projectStore: ProjectStore
    let agentRuntime: AgentRuntime
    let settings: AppSettings
    let eventLog: EventLog
    let remoteTerminals: any RemoteTerminalApplicationCapability

    init(
        projectStore: ProjectStore,
        agentRuntime: AgentRuntime,
        settings: AppSettings,
        eventLog: EventLog,
        remoteTerminals: (any RemoteTerminalApplicationCapability)? = nil
    ) {
        self.projectStore = projectStore
        self.agentRuntime = agentRuntime
        self.settings = settings
        self.eventLog = eventLog
        self.remoteTerminals = remoteTerminals
            ?? Self.makeRemoteTerminalCapability(agentRuntime: agentRuntime)
    }

    static var live: AppEnvironment {
        let agentRuntime: AgentRuntime = .shared
        return AppEnvironment(
            projectStore: .shared,
            agentRuntime: agentRuntime,
            settings: .shared,
            eventLog: .shared,
            remoteTerminals: makeRemoteTerminalCapability(agentRuntime: agentRuntime)
        )
    }

    private static func makeRemoteTerminalCapability(
        agentRuntime: AgentRuntime
    ) -> LiveRemoteTerminalApplicationCapability {
        LiveRemoteTerminalApplicationCapability(surfaces: CompositeRemoteTerminalSurfaceQuery(
            sources: [agentRuntime, ProjectTerminalRuntime.shared]
        ))
    }
}
