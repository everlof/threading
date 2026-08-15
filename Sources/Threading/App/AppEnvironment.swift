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

    static var live: AppEnvironment {
        AppEnvironment(
            projectStore: .shared,
            agentRuntime: .shared,
            settings: .shared,
            eventLog: .shared
        )
    }
}
